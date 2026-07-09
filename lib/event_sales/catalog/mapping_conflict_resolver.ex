defmodule EventSales.Catalog.MappingConflictResolver do
  @moduledoc """
  Admin-only safe resolver for stale ProductMapping catalog conflicts.

  This module only deactivates stale mappings through the existing
  `ProductMapping` `:deactivate` action. It does not remap, delete, create
  catalog records, or move order history.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.OrderItem

  @type reason ::
          :safe
          | :stale_preview
          | :conflict_not_found
          | :mapping_not_active
          | :manual_review_required
          | :order_history_exists
          | :forbidden

  @type conflict_row :: %{
          run_id: Ecto.UUID.t(),
          dry_run_hash: String.t(),
          source_system_id: Ecto.UUID.t(),
          woo_product_id: integer(),
          woo_variation_id: integer() | nil,
          feed_tickera_event_id: integer(),
          mapped_event_name: String.t() | nil,
          mapped_event_external_event_id: integer() | nil,
          mapped_ticket_type_name: String.t() | nil,
          mapping_id: Ecto.UUID.t() | nil,
          order_item_count: non_neg_integer(),
          resolution_status: :safe | :blocked,
          reason: reason()
        }

  @spec list_conflicts(Ecto.UUID.t(), String.t(), keyword()) ::
          {:ok, [conflict_row()]} | {:error, :forbidden | :stale_preview}
  def list_conflicts(run_id, dry_run_hash, opts \\ []) do
    with :ok <- authorize_admin(opts),
         {:ok, run, snapshot} <- load_exact_preview(run_id, dry_run_hash) do
      {:ok, Enum.map(conflict_findings(snapshot), &public_conflict_row(conflict_row(run, &1)))}
    end
  end

  @spec deactivate_stale_mapping(
          Ecto.UUID.t(),
          String.t(),
          integer() | String.t(),
          integer() | String.t() | nil,
          keyword()
        ) ::
          {:ok, %{mapping: ProductMapping.t(), conflict: conflict_row()}}
          | {:error,
             :forbidden
             | :stale_preview
             | :conflict_not_found
             | :mapping_not_active
             | :manual_review_required
             | :order_history_exists}
  def deactivate_stale_mapping(run_id, dry_run_hash, woo_product_id, woo_variation_id, opts \\ []) do
    with :ok <- authorize_admin(opts),
         {:ok, product_id} <- cast_positive_integer(woo_product_id),
         {:ok, variation_id} <- cast_optional_positive_integer(woo_variation_id),
         {:ok, run, snapshot} <- load_exact_preview(run_id, dry_run_hash),
         {:ok, finding} <- find_requested_conflict(snapshot, product_id, variation_id),
         %{} = conflict <- conflict_row(run, finding),
         :safe <- conflict.reason,
         {:ok, result} <- deactivate_with_final_guardrails(conflict, Keyword.get(opts, :actor)) do
      {:ok, result}
    else
      {:error, :invalid_integer} ->
        {:error, :conflict_not_found}

      {:error, reason} ->
        {:error, reason}

      reason
      when reason in [:mapping_not_active, :manual_review_required, :order_history_exists] ->
        {:error, reason}
    end
  end

  defp deactivate_with_final_guardrails(conflict, actor) do
    Repo.transaction(fn ->
      conflict
      |> final_conflict_row()
      |> deactivate_final_conflict(actor)
    end)
    |> case do
      {:ok, {mapping, conflict, notifications}} ->
        Ash.Notifier.notify(notifications)
        {:ok, %{mapping: mapping, conflict: conflict}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp deactivate_final_conflict(%{reason: :safe} = final_conflict, actor) do
    case Ash.update(final_conflict.mapping, %{},
           action: :deactivate,
           domain: Catalog,
           actor: actor,
           context: %{warn_on_transaction_hooks?: false},
           return_notifications?: true
         ) do
      {:ok, mapping, notifications} ->
        {mapping, public_conflict_row(final_conflict), notifications}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp deactivate_final_conflict(%{reason: reason}, _actor)
       when reason in [:mapping_not_active, :manual_review_required, :order_history_exists] do
    Repo.rollback(reason)
  end

  defp authorize_admin(opts) do
    if opts |> Keyword.get(:actor) |> Policies.global_admin?() do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp load_exact_preview(run_id, dry_run_hash)
       when is_binary(dry_run_hash) and dry_run_hash != "" do
    with {:ok, uuid} <- Ecto.UUID.cast(run_id),
         {:ok, %TickeraCatalogSyncRun{} = run} <-
           Ash.get(TickeraCatalogSyncRun, uuid, domain: Ingestion),
         :ok <- validate_run(run, dry_run_hash) do
      {:ok, run, run.plan_snapshot}
    else
      _error -> {:error, :stale_preview}
    end
  end

  defp load_exact_preview(_run_id, _dry_run_hash), do: {:error, :stale_preview}

  defp validate_run(%TickeraCatalogSyncRun{} = run, dry_run_hash) do
    cond do
      run.status != :dry_run_ready ->
        {:error, :stale_preview}

      not is_map(run.plan_snapshot) ->
        {:error, :stale_preview}

      not is_binary(run.dry_run_hash) or run.dry_run_hash == "" ->
        {:error, :stale_preview}

      dry_run_hash != run.dry_run_hash ->
        {:error, :stale_preview}

      value(run.plan_snapshot, "dry_run_hash") != run.dry_run_hash ->
        {:error, :stale_preview}

      true ->
        :ok
    end
  end

  defp conflict_findings(snapshot) do
    snapshot
    |> list("findings")
    |> Enum.filter(fn finding ->
      value(finding, "severity") in [:blocking, "blocking"] and
        value(finding, "code") in [:existing_mapping_conflict, "existing_mapping_conflict"]
    end)
  end

  defp find_requested_conflict(snapshot, product_id, variation_id) do
    snapshot
    |> conflict_findings()
    |> Enum.find(fn finding ->
      value(finding, "woo_product_id") == product_id and
        value(finding, "woo_variation_id") == variation_id
    end)
    |> case do
      nil -> {:error, :conflict_not_found}
      finding -> {:ok, finding}
    end
  end

  defp conflict_row(%TickeraCatalogSyncRun{} = run, finding) do
    product_id = value(finding, "woo_product_id")
    variation_id = value(finding, "woo_variation_id")
    feed_event_id = value(finding, "tickera_event_id")

    conflict_row_from_identity(
      run.id,
      run.dry_run_hash,
      run.source_system_id,
      product_id,
      variation_id,
      feed_event_id
    )
  end

  defp final_conflict_row(conflict) do
    conflict_row_from_identity(
      conflict.run_id,
      conflict.dry_run_hash,
      conflict.source_system_id,
      conflict.woo_product_id,
      conflict.woo_variation_id,
      conflict.feed_tickera_event_id,
      lock?: true
    )
  end

  defp conflict_row_from_identity(
         run_id,
         dry_run_hash,
         source_system_id,
         product_id,
         variation_id,
         feed_event_id,
         opts \\ []
       ) do
    {mapping, loaded_mapping} =
      active_mapping(source_system_id, product_id, variation_id, opts)

    order_item_count = if loaded_mapping, do: order_item_count(loaded_mapping), else: 0
    reason = conflict_reason(loaded_mapping, feed_event_id, order_item_count)

    %{
      run_id: run_id,
      dry_run_hash: dry_run_hash,
      source_system_id: source_system_id,
      woo_product_id: product_id,
      woo_variation_id: variation_id,
      feed_tickera_event_id: feed_event_id,
      mapped_event_name: loaded_mapping && loaded_mapping.event.name,
      mapped_event_external_event_id: loaded_mapping && loaded_mapping.event.external_event_id,
      mapped_ticket_type_name: loaded_mapping && loaded_mapping.ticket_type.name,
      mapping_id: loaded_mapping && loaded_mapping.id,
      order_item_count: order_item_count,
      resolution_status: if(reason == :safe, do: :safe, else: :blocked),
      reason: reason,
      mapping: mapping
    }
  end

  defp public_conflict_row(row), do: Map.delete(row, :mapping)

  defp conflict_reason(nil, _feed_event_id, _order_item_count), do: :mapping_not_active

  defp conflict_reason(%ProductMapping{} = mapping, feed_event_id, _order_item_count)
       when mapping.event.external_event_id == feed_event_id,
       do: :manual_review_required

  defp conflict_reason(%ProductMapping{}, _feed_event_id, order_item_count)
       when order_item_count > 0,
       do: :order_history_exists

  defp conflict_reason(%ProductMapping{}, _feed_event_id, _order_item_count), do: :safe

  defp active_mapping(source_system_id, product_id, variation_id, opts)

  defp active_mapping(_source_system_id, nil, _variation_id, _opts), do: {nil, nil}

  defp active_mapping(source_system_id, product_id, nil, opts) do
    ProductMapping
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and woo_product_id == ^product_id and
        is_nil(woo_variation_id) and active == true
    )
    |> Ash.Query.limit(1)
    |> maybe_lock(opts)
    |> Ash.read_one(domain: Catalog)
    |> load_mapping()
  end

  defp active_mapping(source_system_id, product_id, variation_id, opts) do
    ProductMapping
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and woo_product_id == ^product_id and
        woo_variation_id == ^variation_id and active == true
    )
    |> Ash.Query.limit(1)
    |> maybe_lock(opts)
    |> Ash.read_one(domain: Catalog)
    |> load_mapping()
  end

  defp maybe_lock(query, opts) do
    if Keyword.get(opts, :lock?, false) do
      Ash.Query.lock(query, :for_update)
    else
      query
    end
  end

  defp load_mapping({:ok, %ProductMapping{} = mapping}) do
    loaded = Ash.load!(mapping, [:event, :ticket_type], domain: Catalog)
    {loaded, loaded}
  end

  defp load_mapping(_result), do: {nil, nil}

  defp order_item_count(%ProductMapping{} = mapping) do
    OrderItem
    |> strict_tuple_filter(mapping)
    |> Ash.count!(domain: Sales)
  end

  defp strict_tuple_filter(query, %ProductMapping{woo_variation_id: nil} = mapping) do
    Ash.Query.filter(
      query,
      event_id == ^mapping.event_id and ticket_type_id == ^mapping.ticket_type_id and
        woo_product_id == ^mapping.woo_product_id and is_nil(woo_variation_id) and
        item_kind == :ticket
    )
  end

  defp strict_tuple_filter(query, %ProductMapping{} = mapping) do
    Ash.Query.filter(
      query,
      event_id == ^mapping.event_id and ticket_type_id == ^mapping.ticket_type_id and
        woo_product_id == ^mapping.woo_product_id and
        woo_variation_id == ^mapping.woo_variation_id and item_kind == :ticket
    )
  end

  defp cast_positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp cast_positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, :invalid_integer}
    end
  end

  defp cast_positive_integer(_value), do: {:error, :invalid_integer}

  defp cast_optional_positive_integer(nil), do: {:ok, nil}
  defp cast_optional_positive_integer(""), do: {:ok, nil}
  defp cast_optional_positive_integer(value), do: cast_positive_integer(value)

  defp list(map, key) do
    case value(map, key) do
      values when is_list(values) -> values
      _other -> []
    end
  end

  defp value(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, String.to_existing_atom(key))
  rescue
    ArgumentError -> Map.get(map, key)
  end
end
