defmodule EventSales.Analytics.AdminDashboardTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.AdminDashboard
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers

  setup do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{name: "Dashboard Event", slug: unique_slug("dash")})

    other_event =
      SalesHelpers.create_event!(source, %{name: "Other Event", slug: unique_slug("other")})

    ga = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    vip = SalesHelpers.create_ticket_type!(event, %{name: "VIP"})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other GA"})

    %{
      source: source,
      event: event,
      other_event: other_event,
      ga: ga,
      vip: vip,
      other_ticket: other_ticket
    }
  end

  test "completed mapped ticket rows contribute to dashboard totals", %{
    source: source,
    event: event,
    ga: ga
  } do
    completed =
      create_order!(source, :completed, woo_order_id: 101, raw_total: Decimal.new("900.00"))

    create_item!(completed, event, ga,
      quantity: 2,
      line_total: Decimal.new("900.00"),
      woo_line_item_id: 1
    )

    assert {:ok, snapshot} = AdminDashboard.snapshot(now: ~U[2026-05-17 10:00:00Z])

    assert snapshot.kpis.total_sold == 2
    assert snapshot.kpis.total_revenue == Decimal.new("900.00")

    assert %{event_name: "Dashboard Event", total_sold: 2} =
             Enum.find(snapshot.events, &(&1.event_id == event.id))
  end

  test "non-completed statuses render but do not contribute to sold or revenue", %{
    source: source,
    event: event,
    ga: ga
  } do
    pending = create_order!(source, :pending, woo_order_id: 201, completed_at: nil)
    refunded = create_order!(source, :refunded, woo_order_id: 202)
    cancelled = create_order!(source, :cancelled, woo_order_id: 203)

    create_item!(pending, event, ga, woo_line_item_id: 2, line_total: Decimal.new("450.00"))
    create_item!(refunded, event, ga, woo_line_item_id: 3, line_total: Decimal.new("450.00"))
    create_item!(cancelled, event, ga, woo_line_item_id: 4, line_total: Decimal.new("450.00"))

    assert {:ok, snapshot} = AdminDashboard.snapshot()

    assert snapshot.kpis.total_sold == 0
    assert snapshot.kpis.total_revenue == Decimal.new("0")
    assert snapshot.statuses == %{"cancelled" => 1, "pending" => 1, "refunded" => 1}
  end

  test "ticket type breakdown includes only completed mapped ticket rows", %{
    source: source,
    event: event,
    ga: ga,
    vip: vip
  } do
    completed = create_order!(source, :completed, woo_order_id: 301)
    pending = create_order!(source, :pending, woo_order_id: 302, completed_at: nil)

    create_item!(completed, event, ga,
      woo_line_item_id: 5,
      quantity: 2,
      line_total: Decimal.new("900.00")
    )

    create_item!(completed, event, vip,
      woo_line_item_id: 6,
      mapping_status: :unmapped,
      item_kind: :unknown
    )

    create_item!(completed, event, vip,
      woo_line_item_id: 7,
      mapping_status: :non_ticket,
      item_kind: :non_ticket
    )

    create_item!(pending, event, vip, woo_line_item_id: 8)

    assert {:ok, snapshot} = AdminDashboard.snapshot()

    assert snapshot.ticket_types == [
             %{
               event_id: event.id,
               event_name: "Dashboard Event",
               ticket_type_id: ga.id,
               ticket_type_name: "GA",
               total_sold: 2,
               total_revenue: Decimal.new("900.00")
             }
           ]
  end

  test "recent orders are bounded newest first and exclude PII fields", %{source: source} do
    create_order!(source, :completed,
      woo_order_id: 401,
      order_number: "OLDER",
      updated_at_source: ~U[2026-05-17 08:00:00Z],
      customer_email: "older@example.test",
      customer_name: "Older Customer",
      payment_gateway_transaction_id: "txn_older"
    )

    create_order!(source, :completed,
      woo_order_id: 402,
      order_number: "NEWER",
      updated_at_source: ~U[2026-05-17 09:00:00Z],
      customer_email: "newer@example.test",
      customer_name: "Newer Customer",
      payment_gateway_transaction_id: "txn_newer"
    )

    assert {:ok, snapshot} = AdminDashboard.snapshot(recent_order_limit: 1)

    assert [%{order_number: "NEWER"} = order] = snapshot.recent_orders
    refute Map.has_key?(order, :customer_email)
    refute Map.has_key?(order, :customer_name)
    refute Map.has_key?(order, :payment_gateway_transaction_id)
  end

  test "unmapped alerts come from the bounded mapping queue", %{
    source: source,
    event: event,
    ga: ga
  } do
    order = create_order!(source, :completed, woo_order_id: 501)

    create_item!(order, event, ga,
      name: "Needs Mapping",
      woo_line_item_id: 9,
      woo_product_id: 777,
      mapping_status: :pending_mapping_resolution,
      item_kind: :unknown
    )

    assert {:ok, snapshot} = AdminDashboard.snapshot(unmapped_limit: 5)

    assert [
             %{
               name: "Needs Mapping",
               woo_product_id: 777,
               mapping_status: :pending_mapping_resolution
             }
           ] =
             snapshot.unmapped_alerts
  end

  defp create_order!(source, status, attrs) do
    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "AD-#{System.unique_integer([:positive])}",
      status: status,
      currency: "ZAR",
      completed_at: ~U[2026-05-17 08:00:00.000000Z],
      created_at_source: ~U[2026-05-17 07:00:00.000000Z],
      updated_at_source: ~U[2026-05-17 08:00:00.000000Z],
      customer_name: "Private Customer",
      customer_email: "private@example.test",
      raw_total: Decimal.new("0"),
      raw_discount_total: Decimal.new("0"),
      raw_tax_total: Decimal.new("0"),
      payment_gateway_transaction_id: "txn_private"
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
      name: "Dashboard Ticket",
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

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
