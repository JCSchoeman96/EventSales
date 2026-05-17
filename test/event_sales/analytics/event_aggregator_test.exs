defmodule EventSales.Analytics.EventAggregatorTest do
  use EventSales.DataCase, async: true

  alias EventSales.Analytics.Aggregators.EventAggregator
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
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
    refunded = create_order!(source, :refunded, woo_order_id: 90_003)
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
end
