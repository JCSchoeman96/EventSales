defmodule EventSales.Ingestion.HistoricalRefundOrderItemImpactResolverTest do
  use ExUnit.Case, async: true

  alias EventSales.Ingestion.HistoricalRefundOrderItemImpactResolver

  @refund_id "00000000-0000-0000-0000-000000000001"
  @item_a "00000000-0000-0000-0000-000000000011"
  @item_b "00000000-0000-0000-0000-000000000012"
  @missing_item "00000000-0000-0000-0000-000000000099"
  @event_a "00000000-0000-0000-0000-0000000000aa"
  @event_b "00000000-0000-0000-0000-0000000000bb"

  test "resolves exact mapped ticket allocation with sorted Event IDs" do
    snapshot =
      snapshot(
        refund_lines: [line(@item_b), line(@item_a)],
        parent_items: [
          item(@item_b, @event_b),
          item(@item_a, @event_a)
        ]
      )

    assert %{
             refund_id: @refund_id,
             allocation_mode: :exact,
             event_ids: [@event_a, @event_b]
           } = HistoricalRefundOrderItemImpactResolver.resolve(snapshot)
  end

  test "uses parent-wide allocation for ambiguous refund detail" do
    snapshot =
      snapshot(
        refund_truth: %{
          shipping_refund_amount: Decimal.new("1.00"),
          shipping_refund_tax: Decimal.new("0.00")
        },
        refund_lines: [line(@item_a)],
        parent_items: [item(@item_a, @event_a), item(@item_b, @event_b)]
      )

    assert %{allocation_mode: :parent_wide, event_ids: [@event_a, @event_b]} =
             HistoricalRefundOrderItemImpactResolver.resolve(snapshot)
  end

  test "keeps non-ticket and ignored lines exact without Event attribution" do
    snapshot =
      snapshot(
        refund_lines: [line(@item_a), line(@item_b)],
        parent_items: [
          item(@item_a, @event_a, item_kind: :non_ticket, mapping_status: :non_ticket),
          item(@item_b, @event_b, item_kind: :ticket, mapping_status: :ignored)
        ]
      )

    assert %{allocation_mode: :exact, event_ids: []} =
             HistoricalRefundOrderItemImpactResolver.resolve(snapshot)
  end

  test "uses parent-wide allocation when a refund line has no OrderItem evidence" do
    snapshot =
      snapshot(
        refund_lines: [line(@missing_item)],
        parent_items: [item(@item_a, @event_a), item(@item_b, @event_b)]
      )

    assert %{allocation_mode: :parent_wide, event_ids: [@event_a, @event_b]} =
             HistoricalRefundOrderItemImpactResolver.resolve(snapshot)
  end

  test "reports changed allocation and the sorted before and after Event union" do
    before = snapshot(refund_lines: [line(@item_a)], parent_items: [item(@item_a, @event_a)])

    after_snapshot =
      snapshot(refund_lines: [line(@item_b)], parent_items: [item(@item_b, @event_b)])

    assert %{changed?: true, candidate_event_ids: [@event_a, @event_b]} =
             HistoricalRefundOrderItemImpactResolver.compare(before, after_snapshot)

    assert %{changed?: false, candidate_event_ids: []} =
             HistoricalRefundOrderItemImpactResolver.compare(before, before)
  end

  defp snapshot(opts) do
    %{
      refund_truth:
        Map.merge(
          %{
            id: @refund_id,
            detail_status: :complete,
            shipping_refund_amount: nil,
            shipping_refund_tax: nil,
            fee_refund_amount: nil,
            fee_refund_tax: nil,
            unallocated_header_amount: Decimal.new("0.00")
          },
          Keyword.get(opts, :refund_truth, %{})
        ),
      refund_line_truth: Keyword.get(opts, :refund_lines, []),
      parent_order_item_evidence: Keyword.get(opts, :parent_items, [])
    }
  end

  defp line(order_item_id, attrs \\ []) do
    Map.merge(%{order_item_id: order_item_id, binding_reason: nil}, Map.new(attrs))
  end

  defp item(id, event_id, attrs \\ []) do
    Map.merge(
      %{id: id, event_id: event_id, item_kind: :ticket, mapping_status: :mapped},
      Map.new(attrs)
    )
  end
end
