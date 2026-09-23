defmodule EventSales.Analytics.EventAggregatorTest do
  use EventSales.DataCase, async: true

  alias EventSales.Analytics.Aggregators.EventAggregator
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem, Refund, RefundLine}
  alias EventSales.TestSupport.SalesHelpers

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Metric Event", slug: "metric-event"})
    other_event = SalesHelpers.create_event!(source, %{name: "Other Event", slug: "other-event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "General Admission"})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other Ticket"})

    %{
      source: source,
      event: event,
      other_event: other_event,
      ticket: ticket,
      other_ticket: other_ticket
    }
  end

  test "summarizes event-scoped rows without pre-filtering mapping status", %{
    source: source,
    event: event,
    other_event: other_event,
    ticket: ticket,
    other_ticket: other_ticket
  } do
    completed =
      create_order!(source, :completed,
        woo_order_id: 90_001,
        completed_at: ~U[2026-05-16 22:30:00.000000Z]
      )

    pending = create_order!(source, :pending, woo_order_id: 90_002, completed_at: nil)
    refunded = create_order!(source, :refunded, woo_order_id: 90_003, completed_at: nil)
    cancelled = create_order!(source, :cancelled, woo_order_id: 90_004)

    create_item!(completed, event, ticket,
      woo_line_item_id: 1,
      quantity: 2,
      line_total: Decimal.new("900.00"),
      mapping_status: :mapped,
      item_kind: :ticket
    )

    create_item!(completed, event, ticket,
      woo_line_item_id: 2,
      quantity: 1,
      line_total: Decimal.new("450.00"),
      mapping_status: :unmapped,
      item_kind: :ticket
    )

    create_item!(completed, event, ticket,
      woo_line_item_id: 3,
      quantity: 1,
      line_total: Decimal.new("200.00"),
      mapping_status: :non_ticket,
      item_kind: :non_ticket
    )

    create_item!(pending, event, ticket,
      woo_line_item_id: 4,
      quantity: 1,
      line_total: Decimal.new("500.00"),
      mapping_status: :mapped,
      item_kind: :ticket
    )

    create_item!(refunded, event, ticket,
      woo_line_item_id: 5,
      quantity: 1,
      line_total: Decimal.new("450.00"),
      mapping_status: :mapped,
      item_kind: :ticket
    )

    create_item!(cancelled, event, ticket,
      woo_line_item_id: 6,
      quantity: 1,
      line_total: Decimal.new("450.00"),
      mapping_status: :mapped,
      item_kind: :ticket
    )

    other_order = create_order!(source, :completed, woo_order_id: 90_005)

    create_item!(other_order, other_event, other_ticket,
      woo_line_item_id: 7,
      quantity: 9,
      line_total: Decimal.new("9999.00"),
      mapping_status: :mapped,
      item_kind: :ticket
    )

    assert {:ok, summary} =
             EventAggregator.summary_for_event(event.id,
               now: ~U[2026-05-17 10:00:00.000000Z],
               timezone: "Africa/Johannesburg"
             )

    assert summary == %{
             total_sold: 2,
             total_revenue: Decimal.new("900.00"),
             today_sold: 2,
             today_revenue: Decimal.new("900.00"),
             status_breakdown: %{completed: 3, pending: 1, refunded: 1, cancelled: 1}
           }
  end

  test "legacy summary_for_event stays completed-only while canonical gross includes historical completion evidence",
       %{
         source: source,
         event: event,
         ticket: ticket
       } do
    cancelled =
      create_order!(source, :cancelled,
        woo_order_id: 92_001,
        completed_at: ~U[2026-05-17 08:00:00.000000Z]
      )

    create_item!(cancelled, event, ticket,
      woo_line_item_id: 40,
      quantity: 1,
      line_total: Decimal.new("450.00"),
      line_total_tax: Decimal.new("67.50")
    )

    assert {:ok, legacy} = EventAggregator.summary_for_event(event.id)
    assert legacy.total_sold == 0
    assert Decimal.equal?(legacy.total_revenue, Decimal.new("0"))

    assert {:ok, canonical} = EventAggregator.financial_summaries_for_event(event.id)
    summary = canonical["ZAR"]
    assert Decimal.equal?(summary.gross_ticket_quantity, Decimal.new(1))
    assert Decimal.equal?(summary.gross_ticket_value, Decimal.new("517.50"))
  end

  test "financial_summaries_for_event returns empty map for only unrecognised pending rows", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    pending = create_order!(source, :pending, woo_order_id: 92_010, completed_at: nil)

    create_item!(pending, event, ticket,
      woo_line_item_id: 41,
      quantity: 3,
      line_total: Decimal.new("900.00")
    )

    assert {:ok, summaries} = EventAggregator.financial_summaries_for_event(event.id)
    assert summaries == %{}
  end

  test "refund on never-recognised order does not produce canonical refund primitives", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    pending = create_order!(source, :pending, woo_order_id: 92_020, completed_at: nil)

    item =
      create_item!(pending, event, ticket,
        woo_line_item_id: 42,
        quantity: 1,
        line_total: Decimal.new("80.00"),
        line_total_tax: Decimal.new("12.00")
      )

    refund = create_refund!(source, pending, 902)
    create_refund_line!(refund, item, qty: 1, total: "40.00", tax: "6.00")

    assert {:ok, summaries} = EventAggregator.financial_summaries_for_event(event.id)
    assert summaries == %{}
  end

  test "financial_summaries_for_event returns canonical tax-inclusive gross and distinct order count",
       %{
         source: source,
         event: event,
         ticket: ticket
       } do
    order =
      create_order!(source, :completed,
        woo_order_id: 91_001,
        completed_at: ~U[2026-05-17 08:00:00.000000Z]
      )

    create_item!(order, event, ticket,
      woo_line_item_id: 11,
      quantity: 2,
      line_total: Decimal.new("100.00"),
      line_total_tax: Decimal.new("15.00")
    )

    assert {:ok, summaries} = EventAggregator.financial_summaries_for_event(event.id)
    summary = summaries["ZAR"]

    assert summary.currency == "ZAR"
    assert Decimal.equal?(summary.gross_ticket_quantity, Decimal.new(2))
    assert Decimal.equal?(summary.gross_ticket_value, Decimal.new("115.00"))
    assert summary.recognised_order_count == 1
    assert Decimal.equal?(summary.net_ticket_value, Decimal.new("115.00"))
  end

  test "preserves historical gross when current status is refunded but completion evidence exists",
       %{
         source: source,
         event: event,
         ticket: ticket
       } do
    order =
      create_order!(source, :refunded,
        woo_order_id: 91_002,
        completed_at: ~U[2026-05-17 08:00:00.000000Z]
      )

    create_item!(order, event, ticket,
      woo_line_item_id: 12,
      quantity: 2,
      line_total: Decimal.new("80.00"),
      line_total_tax: Decimal.new("12.00")
    )

    assert {:ok, summaries} = EventAggregator.financial_summaries_for_event(event.id)
    summary = summaries["ZAR"]

    assert Decimal.equal?(summary.gross_ticket_quantity, Decimal.new(2))
    assert Decimal.equal?(summary.gross_ticket_value, Decimal.new("92.00"))
  end

  test "summary_for_event returns mixed currency error without choosing a currency", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    zar_order = create_order!(source, :completed, woo_order_id: 91_010, currency: "ZAR")
    usd_order = create_order!(source, :completed, woo_order_id: 91_011, currency: "USD")

    create_item!(zar_order, event, ticket,
      woo_line_item_id: 20,
      quantity: 1,
      line_total: Decimal.new("10.00")
    )

    create_item!(usd_order, event, ticket,
      woo_line_item_id: 21,
      quantity: 1,
      line_total: Decimal.new("20.00")
    )

    assert EventAggregator.summary_for_event(event.id) == {:error, :mixed_currency}
  end

  test "financial_summaries_for_event applies qualifying refunds without changing gross", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    order = create_order!(source, :completed, woo_order_id: 91_020)

    item =
      create_item!(order, event, ticket,
        woo_line_item_id: 30,
        quantity: 2,
        line_total: Decimal.new("80.00"),
        line_total_tax: Decimal.new("12.00")
      )

    refund = create_refund!(source, order, 901)
    create_refund_line!(refund, item, qty: 1, total: "40.00", tax: "6.00")

    assert {:ok, summaries} = EventAggregator.financial_summaries_for_event(event.id)
    summary = summaries["ZAR"]

    assert Decimal.equal?(summary.gross_ticket_quantity, Decimal.new(2))
    assert Decimal.equal?(summary.gross_ticket_value, Decimal.new("92.00"))
    assert Decimal.equal?(summary.refund_ticket_quantity, Decimal.new(1))
    assert Decimal.equal?(summary.refund_ticket_value, Decimal.new("46.00"))
    assert Decimal.equal?(summary.net_ticket_quantity, Decimal.new(1))
    assert Decimal.equal?(summary.net_ticket_value, Decimal.new("46.00"))
  end

  defp create_order!(source, status, attrs) do
    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "M-#{System.unique_integer([:positive])}",
      status: status,
      currency: "ZAR",
      completed_at: ~U[2026-05-17 08:00:00.000000Z],
      created_at_source: ~U[2026-05-17 07:00:00.000000Z],
      updated_at_source: ~U[2026-05-17 08:00:00.000000Z],
      raw_total: Decimal.new("0"),
      raw_discount_total: Decimal.new("0"),
      raw_tax_total: Decimal.new("0")
    }

    Ash.create!(Order, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_item!(order, %Event{} = event, %TicketType{} = ticket, attrs) do
    defaults = %{
      order_id: order.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_line_item_id: System.unique_integer([:positive]),
      woo_product_id: System.unique_integer([:positive]),
      woo_variation_id: nil,
      name: "Metric Ticket",
      quantity: 1,
      line_subtotal: Decimal.new("450.00"),
      line_total: Decimal.new("450.00"),
      discount_total: Decimal.new("0"),
      item_kind: :ticket,
      mapping_status: :mapped
    }

    Ash.create!(OrderItem, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_refund!(source, order, woo_refund_id) do
    Ash.create!(
      Refund,
      %{
        source_system_id: source.id,
        order_id: order.id,
        woo_order_id: order.woo_order_id,
        woo_refund_id: woo_refund_id,
        currency: order.currency,
        source_state: :active,
        detail_status: :complete,
        summary_total_amount: Decimal.new("10"),
        header_amount: Decimal.new("0"),
        shipping_refund_amount: Decimal.new("0"),
        shipping_refund_tax: Decimal.new("0"),
        fee_refund_amount: Decimal.new("0"),
        fee_refund_tax: Decimal.new("0"),
        unallocated_header_amount: Decimal.new("0"),
        source_created_at: ~U[2026-05-17 09:00:00.000000Z]
      },
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_refund_line!(refund, item, opts) do
    Ash.create!(
      RefundLine,
      %{
        refund_id: refund.id,
        order_item_id: item.id,
        woo_refund_line_item_id: Keyword.get(opts, :line_id, 1),
        woo_refunded_item_id: item.woo_line_item_id,
        woo_product_id: item.woo_product_id,
        woo_variation_id: item.woo_variation_id,
        refunded_quantity: Keyword.get(opts, :qty, 1),
        refund_subtotal_amount: Decimal.new(Keyword.get(opts, :total, "10.00")),
        refund_total_amount: Decimal.new(Keyword.get(opts, :total, "10.00")),
        refund_total_tax: Decimal.new(Keyword.get(opts, :tax, "0.00"))
      },
      action: :create_normalized,
      domain: Sales
    )
  end
end
