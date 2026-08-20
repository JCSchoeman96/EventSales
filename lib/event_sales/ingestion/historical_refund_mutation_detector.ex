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
          refund_truth: map(),
          refund_line_truth: [map()],
          parent_order_evidence: map() | nil,
          parent_order_item_evidence: [map()]
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
         refund_truth: refund_snapshot(refund),
         refund_line_truth: refund_line_snapshots(refund.id),
         parent_order_evidence: parent_order_snapshot(parent_order),
         parent_order_item_evidence: parent_order_item_snapshots(parent_order)
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
    Map.take(snapshot, [:refund_truth, :refund_line_truth])
  end

  defp validate_refund(%Refund{
         id: id,
         source_system_id: source_system_id,
         order_id: order_id,
         woo_order_id: woo_order_id,
         woo_refund_id: woo_refund_id,
         source_created_at: source_created_at
       }) do
    with true <- valid_uuid?(id),
         true <- valid_uuid?(source_system_id),
         true <- optional_uuid?(order_id),
         true <- positive_integer?(woo_order_id),
         true <- positive_integer?(woo_refund_id),
         true <- optional_utc_datetime?(source_created_at) do
      :ok
    else
      _error -> {:error, :invalid_refund}
    end
  end

  defp validate_refund(_refund), do: {:error, :invalid_refund}

  defp read_parent_order(%Refund{order_id: nil} = refund) do
    with {:ok, parent_order} <- read_source_scoped_parent(refund),
         :ok <- validate_parent_order(parent_order) do
      {:ok, parent_order}
    end
  end

  defp read_parent_order(%Refund{order_id: order_id} = refund) do
    case Ecto.UUID.cast(order_id) do
      {:ok, canonical_order_id} ->
        with {:ok, parent_order} <- read_source_scoped_parent(refund),
             true <- parent_matches?(parent_order, canonical_order_id),
             :ok <- validate_parent_order(parent_order) do
          {:ok, parent_order}
        else
          {:error, _reason} -> {:error, :invalid_refund}
          false -> {:error, :invalid_refund}
        end

      :error ->
        {:error, :invalid_refund}
    end
  end

  defp read_source_scoped_parent(%Refund{} = refund) do
    Order
    |> Ash.Query.filter(
      source_system_id == ^refund.source_system_id and woo_order_id == ^refund.woo_order_id
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Sales)
  end

  defp parent_matches?(%Order{id: parent_id}, canonical_order_id),
    do: parent_id == canonical_order_id

  defp parent_matches?(nil, _canonical_order_id), do: false

  defp validate_parent_order(nil), do: :ok

  defp validate_parent_order(%Order{created_at_source: created_at_source}) do
    if utc_datetime?(created_at_source), do: :ok, else: {:error, :invalid_refund}
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
    Map.take(order, [:id, :source_system_id, :woo_order_id, :currency, :created_at_source])
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
    refund = Map.get(snapshot, :refund_truth, %{})
    refund_lines = Map.get(snapshot, :refund_line_truth, [])
    order_items = Map.get(snapshot, :parent_order_item_evidence, [])

    if Map.get(refund, :detail_status) != :complete or
         refund_lines == [] or
         parent_wide_financial_ambiguity?(refund) do
      :fallback
    else
      exact_event_ids_for_lines(refund_lines, order_items)
    end
  end

  defp parent_wide_financial_ambiguity?(refund) do
    component_ambiguous?(
      Map.get(refund, :shipping_refund_amount),
      Map.get(refund, :shipping_refund_tax)
    ) or
      component_ambiguous?(
        Map.get(refund, :fee_refund_amount),
        Map.get(refund, :fee_refund_tax)
      ) or
      residual_ambiguous?(Map.get(refund, :unallocated_header_amount))
  end

  defp component_ambiguous?(nil, nil), do: false

  defp component_ambiguous?(%Decimal{} = amount, %Decimal{} = tax) do
    not (zero_decimal?(amount) and zero_decimal?(tax))
  end

  defp component_ambiguous?(_amount, _tax), do: true

  defp residual_ambiguous?(%Decimal{} = residual), do: not zero_decimal?(residual)
  defp residual_ambiguous?(_residual), do: true

  defp zero_decimal?(%Decimal{} = value), do: Decimal.equal?(value, Decimal.new(0))

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

  defp exact_line_event_id(%{binding_reason: binding_reason}, _order_items_by_id)
       when not is_nil(binding_reason),
       do: :fallback

  defp exact_line_event_id(%{order_item_id: order_item_id}, order_items_by_id) do
    order_items_by_id
    |> Map.get(order_item_id)
    |> exact_order_item_event_id()
  end

  defp exact_line_event_id(_line, _order_items_by_id), do: :fallback

  defp exact_order_item_event_id(nil), do: :fallback

  defp exact_order_item_event_id(%{mapping_status: status})
       when status in [:non_ticket, :ignored],
       do: {:ok, nil}

  defp exact_order_item_event_id(%{mapping_status: status})
       when status in [:pending_mapping_resolution, :unmapped],
       do: :fallback

  defp exact_order_item_event_id(%{item_kind: :unknown}), do: :fallback
  defp exact_order_item_event_id(%{item_kind: :non_ticket}), do: {:ok, nil}

  defp exact_order_item_event_id(%{event_id: event_id}) do
    case canonical_event_id(event_id) do
      {:ok, canonical_id} -> {:ok, canonical_id}
      :error -> :fallback
    end
  end

  defp exact_order_item_event_id(_unresolved), do: :fallback

  defp parent_event_ids(snapshot) do
    snapshot
    |> Map.get(:parent_order_item_evidence, [])
    |> Enum.map(&Map.get(&1, :event_id))
    |> Enum.flat_map(fn event_id ->
      case canonical_event_id(event_id) do
        {:ok, canonical_id} -> [canonical_id]
        :error -> []
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp canonical_event_id(event_id) when is_binary(event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, canonical_id} -> {:ok, canonical_id}
      :error -> :error
    end
  end

  defp canonical_event_id(_event_id), do: :error

  defp valid_uuid?(value) when is_binary(value) do
    match?({:ok, _uuid}, Ecto.UUID.cast(value))
  end

  defp valid_uuid?(_value), do: false

  defp optional_uuid?(nil), do: true
  defp optional_uuid?(value), do: valid_uuid?(value)

  defp optional_utc_datetime?(nil), do: true
  defp optional_utc_datetime?(value), do: utc_datetime?(value)

  defp utc_datetime?(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}), do: true
  defp utc_datetime?(_value), do: false

  defp positive_integer?(value) when is_integer(value), do: value > 0
  defp positive_integer?(_value), do: false
end
