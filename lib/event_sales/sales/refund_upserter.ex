defmodule EventSales.Sales.RefundUpserter do
  @moduledoc """
  Persists source-scoped WooCommerce refund facts.

  This module is the only durable writer for Refund and RefundLine records.
  Parsing happens before the transaction; parent and line binding happen only
  inside the transaction.
  """

  require Ash.Query

  alias EventSales.Ingestion.Parsers.WoocommerceRefundParser
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, Refund}

  @parent_order_not_found "parent_order_not_found"

  @type result :: {:ok, Refund.t()} | {:error, term()}

  @spec upsert_reference(Ecto.UUID.t(), pos_integer(), map(), keyword()) :: result()
  def upsert_reference(source_system_id, woo_order_id, normalized_reference, opts \\ [])

  def upsert_reference(source_system_id, woo_order_id, normalized_reference, opts)
      when is_map(normalized_reference) do
    with :ok <- validate_identity(source_system_id, woo_order_id),
         {:ok, woo_refund_id} <-
           positive_identity(normalized_reference, :woo_refund_id) do
      persist_reference(
        source_system_id,
        woo_order_id,
        woo_refund_id,
        normalized_reference,
        opts
      )
    end
  end

  def upsert_reference(_source_system_id, _woo_order_id, _normalized_reference, _opts),
    do: {:error, {:invalid_refund_identity, :reference}}

  @spec upsert_refund(Ecto.UUID.t(), pos_integer(), map(), keyword()) :: result()
  def upsert_refund(source_system_id, woo_order_id, raw_refund_payload, opts \\ []) do
    with :ok <- validate_identity(source_system_id, woo_order_id),
         {:ok, normalized} <- WoocommerceRefundParser.parse(raw_refund_payload) do
      upsert_normalized_refund(source_system_id, woo_order_id, normalized, opts)
    end
  end

  @spec upsert_normalized_refund(Ecto.UUID.t(), pos_integer(), map(), keyword()) :: result()
  def upsert_normalized_refund(source_system_id, woo_order_id, normalized_refund, opts \\ [])

  def upsert_normalized_refund(source_system_id, woo_order_id, normalized_refund, _opts)
      when is_map(normalized_refund) do
    with :ok <- validate_identity(source_system_id, woo_order_id),
         {:ok, _woo_refund_id} <-
           positive_identity(normalized_refund, :woo_refund_id) do
      {:error, :normalized_refund_not_implemented}
    end
  end

  def upsert_normalized_refund(_source_system_id, _woo_order_id, _normalized_refund, _opts),
    do: {:error, {:invalid_refund_identity, :normalized_refund}}

  defp persist_reference(
         source_system_id,
         woo_order_id,
         woo_refund_id,
         normalized_reference,
         _opts
       ) do
    Repo.transaction(fn ->
      with {:ok, parent_order} <- lock_parent_order(source_system_id, woo_order_id),
           {:ok, existing} <-
             lock_refund(source_system_id, woo_order_id, woo_refund_id) do
        persist_reference_transaction(
          source_system_id,
          woo_order_id,
          woo_refund_id,
          normalized_reference,
          parent_order,
          existing
        )
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  end

  defp persist_reference_transaction(
         source_system_id,
         woo_order_id,
         woo_refund_id,
         normalized_reference,
         parent_order,
         nil
       ) do
    ash_create(
      Refund,
      %{
        source_system_id: source_system_id,
        order_id: parent_id(parent_order),
        woo_order_id: woo_order_id,
        woo_refund_id: woo_refund_id,
        currency: parent_currency(parent_order),
        summary_total_amount: Map.get(normalized_reference, :summary_total_amount),
        reason: Map.get(normalized_reference, :reason),
        unresolved_reason: unresolved_reason(parent_order)
      },
      :create_reference
    )
  end

  defp persist_reference_transaction(
         _source_system_id,
         _woo_order_id,
         _woo_refund_id,
         normalized_reference,
         parent_order,
         %Refund{} = existing
       ) do
    attrs =
      %{
        order_id: parent_id(parent_order),
        currency: parent_currency(parent_order),
        unresolved_reason: merged_unresolved_reason(existing, parent_order)
      }
      |> maybe_hydrate(existing, :summary_total_amount, normalized_reference)
      |> maybe_hydrate(existing, :reason, normalized_reference)

    if attrs == %{} do
      {:ok, existing}
    else
      ash_update(existing, attrs, :sync_normalized)
    end
  end

  defp lock_parent_order(source_system_id, woo_order_id) do
    Order
    |> Ash.Query.filter(source_system_id == ^source_system_id and woo_order_id == ^woo_order_id)
    |> Ash.Query.limit(1)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(domain: Sales)
  end

  defp lock_refund(source_system_id, woo_order_id, woo_refund_id) do
    Refund
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and
        woo_order_id == ^woo_order_id and
        woo_refund_id == ^woo_refund_id
    )
    |> Ash.Query.limit(1)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(domain: Sales)
  end

  defp validate_identity(source_system_id, woo_order_id) do
    cond do
      not valid_uuid?(source_system_id) ->
        {:error, {:invalid_refund_identity, :source_system_id}}

      not positive_integer?(woo_order_id) ->
        {:error, {:invalid_refund_identity, :woo_order_id}}

      true ->
        :ok
    end
  end

  defp positive_identity(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {integer, ""} when integer > 0 -> {:ok, integer}
          _other -> {:error, {:invalid_refund_identity, key}}
        end

      _value ->
        {:error, {:invalid_refund_identity, key}}
    end
  end

  defp positive_integer?(value) when is_integer(value), do: value > 0

  defp positive_integer?(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer > 0
      _other -> false
    end
  end

  defp positive_integer?(_value), do: false

  defp valid_uuid?(value) when is_binary(value) do
    match?({:ok, _uuid}, Ecto.UUID.cast(value))
  end

  defp valid_uuid?(_value), do: false

  defp parent_id(nil), do: nil
  defp parent_id(parent_order), do: parent_order.id

  defp parent_currency(nil), do: nil
  defp parent_currency(parent_order), do: parent_order.currency

  defp unresolved_reason(nil), do: @parent_order_not_found
  defp unresolved_reason(_parent_order), do: nil

  defp merged_unresolved_reason(%Refund{unresolved_reason: @parent_order_not_found}, nil),
    do: @parent_order_not_found

  defp merged_unresolved_reason(%Refund{unresolved_reason: @parent_order_not_found}, _parent_order),
    do: nil

  defp merged_unresolved_reason(%Refund{unresolved_reason: reason}, _parent_order), do: reason

  defp maybe_hydrate(attrs, %Refund{} = existing, key, incoming) do
    incoming_value = Map.get(incoming, key)

    if is_nil(Map.get(existing, key)) and not is_nil(incoming_value) do
      Map.put(attrs, key, incoming_value)
    else
      attrs
    end
  end

  defp ash_create(resource, attrs, action) do
    case Ash.create(resource, attrs,
           action: action,
           domain: Sales,
           return_notifications?: true
         ) do
      {:ok, record, _notifications} -> {:ok, record}
      {:ok, record} -> {:ok, record}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ash_update(record, attrs, action) do
    case Ash.update(record, attrs,
           action: action,
           domain: Sales,
           return_notifications?: true
         ) do
      {:ok, updated, _notifications} -> {:ok, updated}
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_transaction_result({:ok, {:ok, %Refund{} = refund}}), do: {:ok, refund}
  defp normalize_transaction_result({:ok, %Refund{} = refund}), do: {:ok, refund}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}
end
