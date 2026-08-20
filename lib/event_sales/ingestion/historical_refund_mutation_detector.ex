defmodule EventSales.Ingestion.HistoricalRefundMutationDetector do
  @moduledoc """
  Captures and compares certificate-relevant durable truth for one Refund.

  The detector is deliberately read-only. It reads the Refund's durable line
  facts, its exact parent Order, and that Order's durable OrderItems. It never
  uses payload hashes or persistence timestamps to decide whether certificate
  truth changed.
  """

  require Ash.Query

  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem, Refund, RefundLine}

  @type snapshot :: %{
          refund: map(),
          refund_lines: [map()],
          parent_order: map() | nil,
          parent_order_items: [map()]
        }

  @type comparison :: %{changed?: boolean(), candidate_event_ids: [String.t()]}

  @doc """
  Captures one durable Refund and its exact durable parent/child rows.

  A valid unresolved-parent Refund is still capturable. Its snapshot carries
  no parent Order or parent OrderItems, so a later comparison can only return
  the bounded Event IDs available in the two snapshots.
  """
  @spec capture(Refund.t()) :: {:ok, snapshot()} | {:error, :invalid_refund}
  def capture(%Refund{} = refund) do
    with :ok <- validate_refund(refund),
         {:ok, parent_order} <- read_parent_order(refund) do
      {:ok,
       %{
         refund: refund_snapshot(refund),
         refund_lines: refund_line_snapshots(refund.id),
         parent_order: parent_order_snapshot(parent_order),
         parent_order_items: parent_order_item_snapshots(parent_order)
       }}
    end
  end

  def capture(_refund), do: {:error, :invalid_refund}

  @doc """
  Compares two captured snapshots and returns potentially affected Events.

  Exact line attribution is used only when every durable refund line is bound
  to a parent OrderItem with persisted attribution. Any unresolved line,
  incomplete detail, or order-level refund falls back to every persisted
  parent `OrderItem.event_id`. Candidate IDs are the sorted union of the
  before and after bounded sets.
  """
  @spec compare(snapshot(), snapshot()) :: comparison()
  def compare(before, after_snapshot) when is_map(before) and is_map(after_snapshot) do
    changed? = certificate_truth(before) != certificate_truth(after_snapshot)

    %{
      changed?: changed?,
      candidate_event_ids: if(changed?, do: candidate_event_ids(before, after_snapshot), else: [])
    }
  end

  defp certificate_truth(snapshot) do
    Map.take(snapshot, [:refund, :refund_lines, :parent_order, :parent_order_items])
  end

  defp validate_refund(%Refund{
         id: id,
         source_system_id: source_system_id,
         woo_order_id: woo_order_id,
         woo_refund_id: woo_refund_id
       }) do
    with true <- valid_uuid?(id),
         true <- valid_uuid?(source_system_id),
         true <- positive_integer?(woo_order_id),
         true <- positive_integer?(woo_refund_id) do
      :ok
    else
      _error -> {:error, :invalid_refund}
    end
  end

  defp validate_refund(_refund), do: {:error, :invalid_refund}

  defp read_parent_order(%Refund{order_id: nil} = refund) do
    Order
    |> Ash.Query.filter(
      source_system_id == ^refund.source_system_id and woo_order_id == ^refund.woo_order_id
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Sales)
  end

  defp read_parent_order(%Refund{order_id: order_id} = refund) do
    case Ecto.UUID.cast(order_id) do
      {:ok, canonical_order_id} ->
        Order
        |> Ash.Query.filter(
          id == ^canonical_order_id and
            source_system_id == ^refund.source_system_id and
            woo_order_id == ^refund.woo_order_id
        )
        |> Ash.Query.limit(1)
        |> Ash.read_one(domain: Sales)

      :error ->
        {:ok, nil}
    end
  end

  defp refund_snapshot(%Refund{} = refund) do
    Map.take(refund, [
      :id,
      :source_system_id,
      :order_id,
      :woo_order_id,
      :woo_refund_id,
      :currency,
      :source_state,
      :detail_status,
      :unresolved_reason,
      :summary_total_amount,
      :header_amount,
      :shipping_refund_amount,
      :shipping_refund_tax,
      :fee_refund_amount,
      :fee_refund_tax,
      :unallocated_header_amount,
      :source_created_at
    ])
  end

  defp refund_line_snapshots(refund_id) do
    RefundLine
    |> Ash.Query.filter(refund_id == ^refund_id)
    |> Ash.Query.sort(woo_refund_line_item_id: :asc, id: :asc)
    |> Ash.read!(domain: Sales)
    |> Enum.map(&refund_line_snapshot/1)
  end

  defp refund_line_snapshot(%RefundLine{} = line) do
    Map.take(line, [
      :order_item_id,
      :woo_refund_line_item_id,
      :woo_refunded_item_id,
      :woo_product_id,
      :woo_variation_id,
      :refunded_quantity,
      :refund_subtotal_amount,
      :refund_total_amount,
      :refund_total_tax,
      :binding_reason,
      :validation_reason
    ])
  end

  defp parent_order_snapshot(nil), do: nil

  defp parent_order_snapshot(%Order{} = order) do
    Map.take(order, [:id, :source_system_id, :woo_order_id, :currency])
  end

  defp parent_order_item_snapshots(nil), do: []

  defp parent_order_item_snapshots(%Order{id: order_id}) do
    OrderItem
    |> Ash.Query.filter(order_id == ^order_id)
    |> Ash.Query.sort(woo_line_item_id: :asc, id: :asc)
    |> Ash.read!(domain: Sales)
    |> Enum.map(&parent_order_item_snapshot/1)
  end

  defp parent_order_item_snapshot(%OrderItem{} = item) do
    Map.take(item, [:id, :woo_line_item_id, :event_id, :item_kind, :mapping_status])
  end

  defp candidate_event_ids(before, after_snapshot) do
    [before, after_snapshot]
    |> Enum.flat_map(&affected_event_ids/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp affected_event_ids(snapshot) do
    parent_event_ids = parent_event_ids(snapshot)

    case exact_event_ids(snapshot) do
      {:ok, event_ids} -> event_ids
      :fallback -> parent_event_ids
    end
  end

  defp exact_event_ids(snapshot) do
    refund = Map.get(snapshot, :refund, %{})
    refund_lines = Map.get(snapshot, :refund_lines, [])
    order_items = Map.get(snapshot, :parent_order_items, [])

    if Map.get(refund, :detail_status) != :complete or refund_lines == [] do
      :fallback
    else
      exact_event_ids_for_lines(refund_lines, order_items)
    end
  end

  defp exact_event_ids_for_lines(refund_lines, order_items) do
    order_items_by_id = Map.new(order_items, &{Map.get(&1, :id), &1})

    case Enum.reduce_while(
           refund_lines,
           {:ok, MapSet.new()},
           &collect_exact_line_event_id(&1, &2, order_items_by_id)
         ) do
      {:ok, event_ids} -> {:ok, MapSet.to_list(event_ids)}
      :fallback -> :fallback
    end
  end

  defp collect_exact_line_event_id(line, {:ok, event_ids}, order_items_by_id) do
    case exact_line_event_id(line, order_items_by_id) do
      {:ok, nil} -> {:cont, {:ok, event_ids}}
      {:ok, event_id} -> {:cont, {:ok, MapSet.put(event_ids, event_id)}}
      :fallback -> {:halt, :fallback}
    end
  end

  defp exact_line_event_id(line, order_items_by_id) do
    order_item_id = Map.get(line, :order_item_id)

    case Map.get(order_items_by_id, order_item_id) do
      nil ->
        :fallback

      %{binding_reason: binding_reason} when not is_nil(binding_reason) ->
        :fallback

      %{mapping_status: status} when status in [:pending_mapping_resolution, :unmapped] ->
        :fallback

      %{item_kind: :unknown} ->
        :fallback

      %{event_id: event_id} when is_binary(event_id) ->
        {:ok, event_id}

      %{item_kind: :non_ticket} ->
        {:ok, nil}

      %{mapping_status: status} when status in [:non_ticket, :ignored] ->
        {:ok, nil}

      _unresolved ->
        :fallback
    end
  end

  defp parent_event_ids(snapshot) do
    snapshot
    |> Map.get(:parent_order_items, [])
    |> Enum.map(&Map.get(&1, :event_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp valid_uuid?(value) when is_binary(value) do
    match?({:ok, _uuid}, Ecto.UUID.cast(value))
  end

  defp valid_uuid?(_value), do: false

  defp positive_integer?(value) when is_integer(value), do: value > 0
  defp positive_integer?(_value), do: false
end
