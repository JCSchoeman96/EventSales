defmodule EventSales.Ingestion.HistoricalRefundMutationDetectorTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Ingestion.HistoricalRefundMutationDetector
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem, Refund, RefundLine}
  alias EventSales.TestSupport.SalesHelpers

  @refund_created_at ~U[2026-08-05 14:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    {:ok, source: source}
  end

  test "accepts only a durable Refund", %{source: source} do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)

    assert {:error, :invalid_refund} = HistoricalRefundMutationDetector.capture(%Order{})

    assert {:error, :invalid_refund} =
             HistoricalRefundMutationDetector.capture(%Refund{order_id: order.id})
  end

  test "captures the exact parent Order, RefundLines, and parent OrderItems read-only", %{
    source: source
  } do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    other_order = create_distinct_order!(source)
    event = SalesHelpers.create_event!(source, %{name: "Refund Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Refund Ticket"})

    line =
      SalesHelpers.create_order_item_from_line!(
        order,
        %{
          "id" => 10_001,
          "product_id" => 1001,
          "variation_id" => 2001,
          "name" => "Refunded Ticket",
          "quantity" => 1,
          "subtotal" => "100.00",
          "total" => "100.00",
          "discount_total" => "0.00"
        },
        %{
          event_id: event.id,
          ticket_type_id: ticket.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    _other_line =
      SalesHelpers.create_order_item_from_line!(
        other_order,
        %{
          "id" => 20_001,
          "product_id" => 2001,
          "variation_id" => 3001,
          "name" => "Other Ticket",
          "quantity" => 1,
          "subtotal" => "200.00",
          "total" => "200.00",
          "discount_total" => "0.00"
        },
        %{
          event_id: event.id,
          ticket_type_id: ticket.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    refund = create_refund!(source, order, %{woo_refund_id: 91_001})
    _refund_line = create_refund_line!(refund, line, %{woo_refund_line_item_id: 88_001})

    refund_ids_before = ids(Refund, nil)
    refund_line_ids_before = refund_line_ids(refund.id)
    order_item_ids_before = ids(OrderItem, order.id)

    assert {:ok, snapshot} = HistoricalRefundMutationDetector.capture(refund)
    assert snapshot.parent_order.id == order.id
    assert snapshot.parent_order.source_system_id == source.id
    assert snapshot.parent_order.woo_order_id == order.woo_order_id

    assert snapshot.parent_order_items |> Enum.map(& &1.woo_line_item_id) == [
             line.woo_line_item_id
           ]

    assert snapshot.refund_lines |> Enum.map(& &1.woo_refund_line_item_id) == [88_001]
    assert snapshot.refund.source_state == :active
    assert snapshot.refund.detail_status == :complete

    assert ids(Refund, nil) == refund_ids_before
    assert refund_line_ids(refund.id) == refund_line_ids_before
    assert ids(OrderItem, order.id) == order_item_ids_before
  end

  test "identical replay and cosmetic reason changes do not change certificate truth", %{
    source: source
  } do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    refund = create_refund!(source, order, %{woo_refund_id: 91_002, reason: "Original"})
    before = capture!(refund)

    assert %{changed?: false, candidate_event_ids: []} =
             HistoricalRefundMutationDetector.compare(before, capture!(refund))

    updated =
      Ash.update!(
        refund,
        %{reason: "Corrected explanation"},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: false, candidate_event_ids: []} =
             HistoricalRefundMutationDetector.compare(before, capture!(updated))
  end

  test "financial and source-state changes report exact persisted Event IDs", %{source: source} do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    event_a = SalesHelpers.create_event!(source, %{name: "Event A"})
    ticket_a = SalesHelpers.create_ticket_type!(event_a, %{name: "Ticket A"})

    item_a =
      SalesHelpers.create_order_item_from_line!(
        order,
        order_line(10_101),
        %{
          event_id: event_a.id,
          ticket_type_id: ticket_a.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    refund = create_refund!(source, order, %{woo_refund_id: 91_003})
    create_refund_line!(refund, item_a, %{woo_refund_line_item_id: 88_003})
    before = capture!(refund)

    changed_amount =
      Ash.update!(
        refund,
        %{header_amount: Decimal.new("12.00")},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: [event_id]} =
             HistoricalRefundMutationDetector.compare(before, capture!(changed_amount))

    assert event_id == event_a.id

    voided =
      Ash.update!(
        changed_amount,
        %{void_reason: "source_deleted", voided_at: @refund_created_at},
        action: :mark_voided,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: [^event_id]} =
             HistoricalRefundMutationDetector.compare(capture!(changed_amount), capture!(voided))
  end

  test "uses the before and after Event union when exact refund allocation moves", %{
    source: source
  } do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    event_a = SalesHelpers.create_event!(source, %{name: "Event A"})
    event_b = SalesHelpers.create_event!(source, %{name: "Event B"})
    ticket_a = SalesHelpers.create_ticket_type!(event_a, %{name: "Ticket A"})
    ticket_b = SalesHelpers.create_ticket_type!(event_b, %{name: "Ticket B"})

    item_a =
      SalesHelpers.create_order_item_from_line!(
        order,
        order_line(10_201),
        %{
          event_id: event_a.id,
          ticket_type_id: ticket_a.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    item_b =
      SalesHelpers.create_order_item_from_line!(
        order,
        order_line(10_202),
        %{
          event_id: event_b.id,
          ticket_type_id: ticket_b.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    refund = create_refund!(source, order, %{woo_refund_id: 91_004})
    line = create_refund_line!(refund, item_a, %{woo_refund_line_item_id: 88_004})
    before = capture!(refund)

    corrected =
      Ash.update!(
        line,
        %{order_item_id: item_b.id, woo_refunded_item_id: item_b.woo_line_item_id},
        action: :sync_normalized,
        domain: Sales
      )

    assert corrected.order_item_id == item_b.id

    assert %{changed?: true, candidate_event_ids: candidate_event_ids} =
             HistoricalRefundMutationDetector.compare(before, capture!(refund))

    assert candidate_event_ids == Enum.sort([event_a.id, event_b.id])
  end

  test "falls back to all bounded parent Events for an unresolved RefundLine", %{
    source: source
  } do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    event_a = SalesHelpers.create_event!(source, %{name: "Event A"})
    event_b = SalesHelpers.create_event!(source, %{name: "Event B"})
    ticket_a = SalesHelpers.create_ticket_type!(event_a, %{name: "Ticket A"})
    ticket_b = SalesHelpers.create_ticket_type!(event_b, %{name: "Ticket B"})

    item_a =
      SalesHelpers.create_order_item_from_line!(
        order,
        order_line(10_301),
        %{
          event_id: event_a.id,
          ticket_type_id: ticket_a.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    _item_b =
      SalesHelpers.create_order_item_from_line!(
        order,
        order_line(10_302),
        %{
          event_id: event_b.id,
          ticket_type_id: ticket_b.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    refund = create_refund!(source, order, %{woo_refund_id: 91_005})
    create_refund_line!(refund, item_a, %{woo_refund_line_item_id: 88_005})
    before = capture!(refund)

    unresolved =
      Ash.update!(
        refund,
        %{detail_status: :unresolved, unresolved_reason: "source_detail_conflict"},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: candidate_event_ids} =
             HistoricalRefundMutationDetector.compare(before, capture!(unresolved))

    assert candidate_event_ids == Enum.sort([event_a.id, event_b.id])
  end

  test "falls back to all bounded parent Events for an order-level refund", %{source: source} do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    event_a = SalesHelpers.create_event!(source, %{name: "Event A"})
    event_b = SalesHelpers.create_event!(source, %{name: "Event B"})
    ticket_a = SalesHelpers.create_ticket_type!(event_a, %{name: "Ticket A"})
    ticket_b = SalesHelpers.create_ticket_type!(event_b, %{name: "Ticket B"})

    _item_a =
      SalesHelpers.create_order_item_from_line!(
        order,
        order_line(10_401),
        %{
          event_id: event_a.id,
          ticket_type_id: ticket_a.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    _item_b =
      SalesHelpers.create_order_item_from_line!(
        order,
        order_line(10_402),
        %{
          event_id: event_b.id,
          ticket_type_id: ticket_b.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    refund = create_refund!(source, order, %{woo_refund_id: 91_006})
    before = capture!(refund)

    changed =
      Ash.update!(
        refund,
        %{header_amount: Decimal.new("50.00")},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: candidate_event_ids} =
             HistoricalRefundMutationDetector.compare(before, capture!(changed))

    assert candidate_event_ids == Enum.sort([event_a.id, event_b.id])
  end

  test "does not attribute to Events outside the exact parent Order", %{source: source} do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    other_order = create_distinct_order!(source)
    event = SalesHelpers.create_event!(source, %{name: "Parent Event"})
    other_event = SalesHelpers.create_event!(source, %{name: "Other Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Parent Ticket"})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other Ticket"})

    item =
      SalesHelpers.create_order_item_from_line!(
        order,
        order_line(10_501),
        %{
          event_id: event.id,
          ticket_type_id: ticket.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    _other_item =
      SalesHelpers.create_order_item_from_line!(
        other_order,
        order_line(10_502),
        %{
          event_id: other_event.id,
          ticket_type_id: other_ticket.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    refund = create_refund!(source, order, %{woo_refund_id: 91_007})
    create_refund_line!(refund, item, %{woo_refund_line_item_id: 88_007})
    before = capture!(refund)

    changed =
      Ash.update!(
        refund,
        %{header_amount: Decimal.new("75.00")},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: [candidate_event_id]} =
             HistoricalRefundMutationDetector.compare(before, capture!(changed))

    assert candidate_event_id == event.id
    refute candidate_event_id == other_event.id
  end

  defp capture!(refund) do
    assert {:ok, snapshot} = HistoricalRefundMutationDetector.capture(refund)
    snapshot
  end

  defp create_refund!(source, order, attrs) do
    defaults = %{
      source_system_id: source.id,
      order_id: order.id,
      woo_order_id: order.woo_order_id,
      woo_refund_id: System.unique_integer([:positive]),
      currency: order.currency,
      source_state: :active,
      detail_status: :complete,
      summary_total_amount: Decimal.new("10.00"),
      header_amount: Decimal.new("10.00"),
      source_created_at: @refund_created_at
    }

    Ash.create!(Refund, Map.merge(defaults, attrs), action: :create_normalized, domain: Sales)
  end

  defp create_distinct_order!(source) do
    Ash.create!(
      Order,
      %{
        source_system_id: source.id,
        woo_order_id: System.unique_integer([:positive]),
        status: :completed,
        currency: "ZAR",
        created_at_source: @refund_created_at,
        updated_at_source: @refund_created_at,
        raw_total: Decimal.new("100.00")
      },
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_refund_line!(refund, order_item, attrs) do
    defaults = %{
      refund_id: refund.id,
      order_item_id: order_item.id,
      woo_refund_line_item_id: System.unique_integer([:positive]),
      woo_refunded_item_id: order_item.woo_line_item_id,
      refunded_quantity: 1,
      refund_total_amount: Decimal.new("10.00"),
      refund_total_tax: Decimal.new("0.00"),
      binding_reason: nil,
      validation_reason: nil
    }

    Ash.create!(RefundLine, Map.merge(defaults, attrs), action: :create_normalized, domain: Sales)
  end

  defp order_line(id) do
    %{
      "id" => id,
      "product_id" => id + 1000,
      "variation_id" => id + 2000,
      "name" => "Ticket #{id}",
      "quantity" => 1,
      "subtotal" => "100.00",
      "total" => "100.00",
      "discount_total" => "0.00"
    }
  end

  defp ids(resource, nil) do
    resource
    |> Ash.read!(domain: Sales)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp ids(resource, order_id) do
    resource
    |> Ash.Query.filter(order_id == ^order_id)
    |> Ash.read!(domain: Sales)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp refund_line_ids(refund_id) do
    RefundLine
    |> Ash.Query.filter(refund_id == ^refund_id)
    |> Ash.read!(domain: Sales)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end
end
