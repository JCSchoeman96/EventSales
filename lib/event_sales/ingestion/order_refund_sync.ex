defmodule EventSales.Ingestion.OrderRefundSync do
  @moduledoc """
  Synchronizes WooCommerce refunds for one exact parent order.

  The source list is the current membership observation for the parent order.
  Full listed objects and confirmed source deletions are delegated to
  RefundUpserter, which remains the sole durable Refund writer.
  """

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Changes.NormalizeBaseUrl
  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Ingestion.Clients.{WooCommerceClient, WooCommerceError}
  alias EventSales.Sales
  alias EventSales.Sales.RefundUpserter
  alias EventSales.Sales.Resources.Refund

  @transient_reasons [
    :rate_limited,
    :timeout,
    :server_error,
    :queue_timeout,
    :circuit_open,
    :transport_error
  ]

  @type result :: :ok | {:error, atom()}

  @spec sync_order(Ecto.UUID.t(), pos_integer(), keyword()) :: result()
  def sync_order(source_system_id, woo_order_id, opts \\ []) do
    client = Keyword.get(opts, :woocommerce_client, WooCommerceClient)
    client_opts = woocommerce_client_opts(opts)
    upserter = Keyword.get(opts, :refund_upserter, RefundUpserter)
    upserter_opts = Keyword.get(opts, :refund_upserter_opts, [])
    observed_at = Keyword.get(opts, :observed_at, DateTime.utc_now())

    with {:ok, source_system} <- load_source_system(source_system_id, opts),
         :ok <- validate_source_system(source_system_id, source_system),
         :ok <- validate_client_binding(source_system, client, client_opts),
         {:ok, {raw_refunds, refund_ids}} <-
           list_current_refunds(client, woo_order_id, client_opts),
         :ok <-
           persist_listed_refunds(
             upserter,
             source_system_id,
             woo_order_id,
             raw_refunds,
             upserter_opts
           ),
         {:ok, active_refunds} <- load_active_refunds(source_system_id, woo_order_id) do
      confirmation = %{
        client: client,
        client_opts: client_opts,
        upserter: upserter,
        upserter_opts: upserter_opts,
        observed_at: observed_at,
        source_system_id: source_system_id,
        woo_order_id: woo_order_id
      }

      confirm_deletion_candidates(confirmation, active_refunds, refund_ids)
    end
  end

  defp load_source_system(source_system_id, opts) do
    loader = Keyword.get(opts, :source_system_loader, &default_source_system_loader/1)

    case safe_function_call(loader, [source_system_id]) do
      {:ok, %SourceSystem{} = source_system} -> {:ok, source_system}
      %SourceSystem{} = source_system -> {:ok, source_system}
      {:ok, nil} -> {:error, :source_system_not_found}
      {:error, _reason} -> {:error, :source_system_not_found}
      _other -> {:error, :source_system_not_found}
    end
  end

  defp default_source_system_loader(source_system_id),
    do: Ash.get(SourceSystem, source_system_id, domain: Catalog)

  defp validate_source_system(source_system_id, %SourceSystem{} = source_system) do
    cond do
      source_system.id != source_system_id ->
        {:error, :source_system_mismatch}

      source_system.kind != :woocommerce ->
        {:error, :source_system_kind_mismatch}

      source_system.active != true ->
        {:error, :source_system_inactive}

      not valid_base_url?(source_system.base_url) ->
        {:error, :source_system_invalid}

      true ->
        :ok
    end
  end

  defp validate_client_binding(%SourceSystem{base_url: source_base_url}, client, client_opts) do
    with {:ok, configured_base_url} <- configured_base_url(client, client_opts),
         true <-
           NormalizeBaseUrl.normalize(source_base_url) ==
             NormalizeBaseUrl.normalize(configured_base_url) do
      :ok
    else
      false -> {:error, :source_endpoint_mismatch}
      {:error, _reason} -> {:error, :source_client_misconfigured}
    end
  end

  defp configured_base_url(client, client_opts) do
    case module_call(client, :configured_base_url, [client_opts]) do
      {:ok, url} when is_binary(url) and url != "" ->
        if valid_base_url?(url), do: {:ok, url}, else: {:error, :source_client_misconfigured}

      _other ->
        {:error, :source_client_misconfigured}
    end
  end

  defp list_current_refunds(client, woo_order_id, client_opts) do
    case module_call(client, :list_refunds, [woo_order_id, %{}, client_opts]) do
      {:ok, raw_refunds} ->
        validate_refund_list(raw_refunds)

      {:error, %WooCommerceError{} = error} ->
        normalize_client_error(error)

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      _other ->
        {:error, :invalid_refund_list_response}
    end
  end

  defp validate_refund_list(raw_refunds) when is_list(raw_refunds) do
    raw_refunds
    |> Enum.reduce_while({:ok, [], MapSet.new()}, &validate_refund_entry/2)
    |> case do
      {:ok, valid, refund_ids} -> {:ok, {Enum.reverse(valid), refund_ids}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_refund_list(_raw_refunds), do: {:error, :invalid_refund_list_response}

  defp validate_refund_entry(raw_refund, {:ok, valid, seen_ids}) do
    case refund_id(raw_refund) do
      {:ok, refund_id} -> add_refund_to_list(raw_refund, refund_id, valid, seen_ids)
      _other -> {:halt, {:error, :invalid_refund_list_response}}
    end
  end

  defp add_refund_to_list(raw_refund, refund_id, valid, seen_ids) do
    if MapSet.member?(seen_ids, refund_id) do
      {:halt, {:error, :duplicate_refund_id}}
    else
      {:cont, {:ok, [raw_refund | valid], MapSet.put(seen_ids, refund_id)}}
    end
  end

  defp persist_listed_refunds(_upserter, _source_system_id, _woo_order_id, [], _upserter_opts),
    do: :ok

  defp persist_listed_refunds(
         upserter,
         source_system_id,
         woo_order_id,
         raw_refunds,
         upserter_opts
       ) do
    Enum.reduce_while(raw_refunds, :ok, fn raw_refund, :ok ->
      case persist_listed_refund(
             upserter,
             source_system_id,
             woo_order_id,
             raw_refund,
             upserter_opts
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_listed_refund(
         upserter,
         source_system_id,
         woo_order_id,
         raw_refund,
         upserter_opts
       ) do
    case upsert_refund(upserter, source_system_id, woo_order_id, raw_refund, upserter_opts) do
      {:ok, refund} when is_map(refund) -> listed_refund_result(refund)
      _other -> {:error, :refund_upsert_failed}
    end
  end

  defp listed_refund_result(%{source_state: :voided}),
    do: {:error, :voided_refund_reappeared}

  defp listed_refund_result(_refund), do: :ok

  defp load_active_refunds(source_system_id, woo_order_id) do
    Refund
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and
        woo_order_id == ^woo_order_id and
        source_state == :active
    )
    |> Ash.Query.sort(woo_refund_id: :asc)
    |> Ash.read(domain: Sales)
    |> case do
      {:ok, refunds} -> {:ok, refunds}
      {:error, _reason} -> {:error, :refund_void_failed}
    end
  end

  defp confirm_deletion_candidates(_context, [], _refund_ids),
    do: :ok

  defp confirm_deletion_candidates(context, active_refunds, refund_ids) do
    active_refunds
    |> Enum.reject(&MapSet.member?(refund_ids, &1.woo_refund_id))
    |> Enum.reduce_while(:ok, fn refund, :ok ->
      confirm_candidate(context, refund.woo_refund_id)
      |> case do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp confirm_candidate(context, woo_refund_id) do
    case module_call(context.client, :fetch_refund, [
           context.woo_order_id,
           woo_refund_id,
           context.client_opts
         ]) do
      {:error, %WooCommerceError{reason: :not_found}} ->
        void_deleted_refund(context, woo_refund_id)

      {:ok, exact_refund} when is_map(exact_refund) ->
        persist_exact_refund(context, woo_refund_id, exact_refund)

      {:error, %WooCommerceError{} = error} ->
        normalize_client_error(error)

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      _other ->
        {:error, :invalid_refund_detail_response}
    end
  end

  defp persist_exact_refund(context, woo_refund_id, exact_refund) do
    case validate_exact_refund(exact_refund, woo_refund_id) do
      :ok ->
        case upsert_refund(
               context.upserter,
               context.source_system_id,
               context.woo_order_id,
               exact_refund,
               context.upserter_opts
             ) do
          {:ok, refund} when is_map(refund) -> exact_refund_result(refund)
          _other -> {:error, :refund_upsert_failed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp exact_refund_result(%{source_state: :voided}),
    do: {:error, :voided_refund_reappeared}

  defp exact_refund_result(_refund), do: :ok

  defp void_deleted_refund(context, woo_refund_id) do
    case module_call(
           context.upserter,
           :mark_source_deleted,
           [
             context.source_system_id,
             context.woo_order_id,
             woo_refund_id,
             context.observed_at,
             context.upserter_opts
           ]
         ) do
      {:ok, _refund} -> :ok
      _other -> {:error, :refund_void_failed}
    end
  end

  defp upsert_refund(upserter, source_system_id, woo_order_id, raw_refund, upserter_opts) do
    case module_call(
           upserter,
           :upsert_refund,
           [source_system_id, woo_order_id, raw_refund, upserter_opts]
         ) do
      {:ok, refund} when is_map(refund) -> {:ok, refund}
      _other -> {:error, :refund_upsert_failed}
    end
  end

  defp validate_exact_refund(raw_refund, expected_refund_id) do
    case refund_id(raw_refund) do
      {:ok, ^expected_refund_id} -> :ok
      _other -> {:error, :invalid_refund_detail_response}
    end
  end

  defp refund_id(raw_refund) when is_map(raw_refund) do
    values =
      [Map.get(raw_refund, "id", :missing), Map.get(raw_refund, :id, :missing)]
      |> Enum.reject(&(&1 == :missing))

    with {:ok, ids} <- positive_ids(values),
         [refund_id] <- Enum.uniq(ids) do
      {:ok, refund_id}
    else
      _other -> {:error, :invalid_refund_id}
    end
  end

  defp refund_id(_raw_refund), do: {:error, :invalid_refund_id}

  defp positive_ids([]), do: {:error, :invalid_refund_id}

  defp positive_ids(values) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, ids} ->
      case positive_id(value) do
        {:ok, id} -> {:cont, {:ok, [id | ids]}}
        :error -> {:halt, {:error, :invalid_refund_id}}
      end
    end)
    |> case do
      {:ok, ids} -> {:ok, Enum.reverse(ids)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp positive_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_id(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {id, ""} when id > 0 -> {:ok, id}
      _other -> :error
    end
  end

  defp positive_id(_value), do: :error

  defp woocommerce_client_opts(opts),
    do: Keyword.get(opts, :woocommerce_client_opts, Keyword.get(opts, :client_opts, []))

  defp valid_base_url?(value) when is_binary(value) do
    normalized = NormalizeBaseUrl.normalize(value)
    uri = URI.parse(normalized)

    normalized != "" and uri.scheme in ["http", "https"] and is_binary(uri.host) and
      uri.host != ""
  rescue
    _error -> false
  end

  defp valid_base_url?(_value), do: false

  defp module_call(module, function, args) when is_atom(module) do
    if module_exports?(module, function, length(args)) do
      safe_function_call(module, function, args)
    else
      {:error, :source_client_misconfigured}
    end
  end

  defp module_call(_module, _function, _args), do: {:error, :source_client_misconfigured}

  defp normalize_client_error(%WooCommerceError{reason: reason})
       when reason in @transient_reasons,
       do: {:error, reason}

  defp normalize_client_error(%WooCommerceError{reason: reason}) when is_atom(reason),
    do: {:error, reason}

  defp normalize_client_error(_error), do: {:error, :transport_error}

  defp safe_function_call(function, args) when is_function(function) do
    apply(function, args)
  rescue
    _error -> {:error, :source_system_not_found}
  catch
    :exit, _reason -> {:error, :source_system_not_found}
    :throw, _value -> {:error, :source_system_not_found}
  end

  defp safe_function_call(_function, _args), do: {:error, :source_system_not_found}

  defp safe_function_call(module, function, args) when is_atom(module) do
    apply(module, function, args)
  rescue
    _error -> {:error, :transport_error}
  catch
    :exit, _reason -> {:error, :transport_error}
    :throw, _value -> {:error, :transport_error}
  end

  defp module_exports?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end
end
