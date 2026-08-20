defmodule EventSales.Ingestion.HistoricalOrderMutationDetector do
  @moduledoc """
  Captures and compares the certificate-relevant historical truth for one Order.

  The detector is deliberately read-only. It excludes source-version-only and
  cosmetic metadata so a harmless replay cannot appear to be a historical sale
  mutation. Event candidates come only from persisted OrderItem attribution in
  the before/after snapshots.
  """

  require Ash.Query

  alias EventSales.Sales
  alias EventSales.Sales.Resources.{CouponSnapshot, Order, OrderItem}

  @type snapshot :: %{
          header: %{
            status: atom(),
            currency: String.t(),
            created_at_source: DateTime.t(),
            completed_at: DateTime.t() | nil,
            paid_at: DateTime.t() | nil,
            raw_total: Decimal.t(),
            raw_discount_total: Decimal.t(),
            raw_tax_total: Decimal.t()
          },
          order_items: [map()],
          coupon_snapshots: [map()]
        }

  @type comparison :: %{changed?: boolean(), candidate_event_ids: [String.t()]}

  @doc """
  Captures one durable Order and its exact child rows as a deterministic
  certificate-truth snapshot.

  The child reads are bounded by the Order's primary key and use the existing
  `order_id` relationships/indexes. A successful snapshot contains no source
  version, customer, payment metadata, item name, or persistence timestamps.
  """
  @spec capture(Order.t()) :: {:ok, snapshot()} | {:error, :invalid_order}
  def capture(%Order{} = order) do
    with :ok <- validate_order(order) do
      {:ok,
       %{
         header: header_snapshot(order),
         order_items: order_item_snapshots(order.id),
         coupon_snapshots: coupon_snapshots(order.id)
       }}
    end
  end

  def capture(_order), do: {:error, :invalid_order}

  @doc """
  Compares two captured snapshots and returns the exact candidate Events that
  may have been affected when certificate-relevant truth changed.
  """
  @spec compare(snapshot(), snapshot()) :: comparison()
  def compare(before, after_snapshot) when is_map(before) and is_map(after_snapshot) do
    changed? = before != after_snapshot

    %{
      changed?: changed?,
      candidate_event_ids: if(changed?, do: candidate_event_ids(before, after_snapshot), else: [])
    }
  end

  defp header_snapshot(%Order{} = order) do
    %{
      status: order.status,
      currency: order.currency,
      created_at_source: order.created_at_source,
      completed_at: order.completed_at,
      paid_at: order.paid_at,
      raw_total: order.raw_total,
      raw_discount_total: order.raw_discount_total,
      raw_tax_total: order.raw_tax_total
    }
  end

  defp validate_order(%Order{
         id: id,
         source_system_id: source_system_id,
         created_at_source: %DateTime{} = created_at_source
       }) do
    with true <- valid_uuid?(id),
         true <- valid_uuid?(source_system_id),
         true <- utc_datetime?(created_at_source) do
      :ok
    else
      _error -> {:error, :invalid_order}
    end
  end

  defp validate_order(_order), do: {:error, :invalid_order}

  defp valid_uuid?(value) when is_binary(value) do
    match?({:ok, _uuid}, Ecto.UUID.cast(value))
  end

  defp valid_uuid?(_value), do: false

  defp utc_datetime?(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0}),
    do: true

  defp utc_datetime?(_datetime), do: false

  defp order_item_snapshots(order_id) do
    OrderItem
    |> Ash.Query.filter(order_id == ^order_id)
    |> Ash.Query.sort(woo_line_item_id: :asc, id: :asc)
    |> Ash.read!(domain: Sales)
    |> Enum.map(fn %OrderItem{} = item ->
      %{
        woo_line_item_id: item.woo_line_item_id,
        event_id: item.event_id,
        ticket_type_id: item.ticket_type_id,
        woo_product_id: item.woo_product_id,
        woo_variation_id: item.woo_variation_id,
        quantity: item.quantity,
        line_subtotal: item.line_subtotal,
        line_total: item.line_total,
        line_total_tax: item.line_total_tax,
        discount_total: item.discount_total,
        item_kind: item.item_kind,
        mapping_status: item.mapping_status,
        source_tickera_event_id: item.source_tickera_event_id,
        attribution_status_reason: item.attribution_status_reason
      }
    end)
  end

  defp coupon_snapshots(order_id) do
    CouponSnapshot
    |> Ash.Query.filter(order_id == ^order_id)
    |> Ash.Query.sort(code: :asc, id: :asc)
    |> Ash.read!(domain: Sales)
    |> Enum.map(fn %CouponSnapshot{} = coupon ->
      %{
        code: coupon.code,
        discount_amount: coupon.discount_amount,
        discount_tax: coupon.discount_tax
      }
    end)
  end

  defp candidate_event_ids(before, after_snapshot) do
    [before, after_snapshot]
    |> Enum.flat_map(&Map.get(&1, :order_items, []))
    |> Enum.map(&Map.get(&1, :event_id))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end
end
