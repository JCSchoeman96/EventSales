defmodule EventSales.Analytics.AdminDashboardTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.{AdminDashboard, DashboardCache, HotStateAggregator}
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers

  setup do
    HotStateAggregator.reset_for_test!()
    on_exit(fn -> HotStateAggregator.reset_for_test!() end)

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

  test "hot event summary contributes to dashboard totals", %{
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

    DashboardCache.put_event_summary(event.id, %{
      total_sold: 2,
      total_revenue: Decimal.new("900.00"),
      today_sold: 2,
      today_revenue: Decimal.new("900.00"),
      status_breakdown: %{"completed" => 1},
      currency: "ZAR"
    })

    assert {:ok, snapshot} = AdminDashboard.snapshot(now: ~U[2026-05-17 10:00:00Z])

    assert snapshot.kpis.total_sold == 2
    assert snapshot.kpis.total_revenue == Decimal.new("900.00")

    assert %{event_name: "Dashboard Event", total_sold: 2} =
             Enum.find(snapshot.events, &(&1.event_id == event.id))
  end

  test "event_row returns one event row from hot cache", %{event: event} do
    DashboardCache.put_event_summary(event.id, %{
      total_sold: 3,
      total_revenue: Decimal.new("1350.00"),
      today_sold: 1,
      today_revenue: Decimal.new("450.00"),
      status_breakdown: %{"completed" => 2},
      currency: "ZAR",
      updated_at: ~U[2026-05-17 10:00:00Z]
    })

    assert {:ok, row} = AdminDashboard.event_row(event.id)

    assert row.event_id == event.id
    assert row.event_name == "Dashboard Event"
    assert row.total_sold == 3
    assert row.total_revenue == Decimal.new("1350.00")
    assert row.status_breakdown == %{"completed" => 2}
    assert row.refreshed_at == ~U[2026-05-17 10:00:00Z]
  end

  test "snapshot filters event lifecycle before event limit", %{source: source} do
    now = ~U[2026-07-08 12:00:00Z]

    for index <- 1..55 do
      SalesHelpers.create_event!(source, %{
        name: "Past Dashboard #{String.pad_leading(to_string(index), 2, "0")}",
        slug: unique_slug("past-dashboard-#{index}"),
        starts_at: ~U[2026-07-01 10:00:00Z],
        ends_at: ~U[2026-07-01 12:00:00Z]
      })
    end

    future =
      SalesHelpers.create_event!(source, %{
        name: "Future Dashboard",
        slug: unique_slug("future-dashboard"),
        starts_at: ~U[2026-07-09 10:00:00Z],
        ends_at: ~U[2026-07-09 12:00:00Z],
        venue_name: "Dashboard Venue"
      })

    assert {:ok, current} = AdminDashboard.snapshot(lifecycle: :current, now: now)
    assert Enum.any?(current.events, &(&1.event_id == future.id))
    refute Enum.any?(current.events, &String.starts_with?(&1.event_name, "Past Dashboard"))
    assert Enum.find(current.events, &(&1.event_id == future.id)).venue_name == "Dashboard Venue"

    assert {:ok, past} = AdminDashboard.snapshot(lifecycle: :past, now: now)
    assert Enum.all?(past.events, &String.starts_with?(&1.event_name, "Past Dashboard"))
  end

  test "event_row falls back to zero summary for known event without hot or snapshot data", %{
    event: event
  } do
    assert {:ok, row} = AdminDashboard.event_row(event.id)

    assert row.event_id == event.id
    assert row.total_sold == 0
    assert row.total_revenue == Decimal.new("0")
    assert row.status_breakdown == %{}
  end

  test "event_row returns not_found for unknown event id" do
    assert :not_found = AdminDashboard.event_row(Ecto.UUID.generate())
  end

  test "replace_event_row updates displayed row and recomputes totals", %{
    event: event,
    other_event: other_event
  } do
    snapshot = %{
      kpis: %{total_sold: 1, total_revenue: Decimal.new("100.00")},
      statuses: %{"completed" => 1},
      events: [
        row(event, %{total_sold: 1, total_revenue: Decimal.new("100.00")}),
        row(other_event, %{
          total_sold: 2,
          total_revenue: Decimal.new("200.00"),
          status_breakdown: %{"pending" => 2}
        })
      ],
      ticket_types: [%{ticket_type_name: "GA"}],
      recent_orders: [%{order_number: "R-1"}],
      unmapped_alerts: [%{name: "Needs Mapping"}],
      hot_state: %{state: :ready}
    }

    replacement =
      row(event, %{
        total_sold: 4,
        total_revenue: Decimal.new("400.00"),
        status_breakdown: %{"completed" => 4}
      })

    assert {:ok, updated} = AdminDashboard.replace_event_row(snapshot, replacement)

    event_id = event.id
    other_event_id = other_event.id

    assert [
             %{event_id: ^event_id, total_sold: 4},
             %{event_id: ^other_event_id, total_sold: 2}
           ] = updated.events

    assert updated.kpis.total_sold == 6
    assert updated.kpis.total_revenue == Decimal.new("600.00")
    assert updated.statuses == %{"completed" => 4, "pending" => 2}
    assert updated.ticket_types == snapshot.ticket_types
    assert updated.recent_orders == snapshot.recent_orders
    assert updated.unmapped_alerts == snapshot.unmapped_alerts
    assert updated.hot_state == snapshot.hot_state
  end

  test "replace_event_row returns not_found when row is not displayed", %{
    event: event,
    other_event: other_event
  } do
    snapshot = %{events: [row(event, %{})]}

    assert :not_found = AdminDashboard.replace_event_row(snapshot, row(other_event, %{}))
  end

  test "event KPI rows do not backfill totals from raw order items without hot or snapshot data",
       %{
         source: source,
         event: event,
         ga: ga
       } do
    completed =
      create_order!(source, :completed, woo_order_id: 151, raw_total: Decimal.new("900.00"))

    create_item!(completed, event, ga,
      quantity: 2,
      line_total: Decimal.new("900.00"),
      woo_line_item_id: 15
    )

    assert {:ok, snapshot} = AdminDashboard.snapshot(now: ~U[2026-05-17 10:00:00Z])

    assert %{event_name: "Dashboard Event", total_sold: 0, total_revenue: revenue} =
             Enum.find(snapshot.events, &(&1.event_id == event.id))

    assert revenue == Decimal.new("0")
    assert snapshot.kpis.total_sold == 0
    assert snapshot.kpis.total_revenue == Decimal.new("0")
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

    DashboardCache.put_event_summary(event.id, %{
      total_sold: 0,
      total_revenue: Decimal.new("0"),
      today_sold: 0,
      today_revenue: Decimal.new("0"),
      status_breakdown: %{"cancelled" => 1, "pending" => 1, "refunded" => 1},
      currency: "ZAR"
    })

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

  defp row(%Event{} = event, attrs) do
    defaults = %{
      event_id: event.id,
      event_name: event.name,
      total_sold: 0,
      total_revenue: Decimal.new("0"),
      today_sold: 0,
      today_revenue: Decimal.new("0"),
      status_breakdown: %{},
      currency: "ZAR",
      refreshed_at: nil
    }

    Map.merge(defaults, Map.new(attrs))
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
