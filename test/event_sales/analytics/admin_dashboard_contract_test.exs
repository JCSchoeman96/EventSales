defmodule EventSales.Analytics.AdminDashboardContractTest do
  @moduledoc """
  Executable contract tests for `AdminDashboard.snapshot/0` shape and PII safety.

  When the snapshot contract changes (e.g. adding `:daily_buckets`), update these
  tests and `docs/dashboard/*.md` in the same PR.
  """

  use EventSales.DataCase, async: false

  alias EventSales.Analytics.{AdminDashboard, DashboardCache, HotStateAggregator}
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers

  @snapshot_keys [
    :kpis,
    :events,
    :statuses,
    :ticket_types,
    :recent_orders,
    :unmapped_alerts,
    :hot_state
  ]

  @event_row_keys [
    :event_id,
    :event_name,
    :venue_name,
    :lifecycle,
    :total_sold,
    :total_revenue,
    :today_sold,
    :today_revenue,
    :status_breakdown,
    :currency,
    :refreshed_at
  ]

  @ticket_type_row_keys [
    :event_id,
    :event_name,
    :ticket_type_id,
    :ticket_type_name,
    :total_sold,
    :total_revenue
  ]

  @recent_order_keys [
    :order_number,
    :status,
    :currency,
    :raw_total,
    :completed_at,
    :updated_at_source
  ]

  @unmapped_alert_keys [
    :order_number,
    :name,
    :woo_product_id,
    :woo_variation_id,
    :mapping_status,
    :quantity,
    :updated_at
  ]

  @pii_keys [
    :customer_email,
    :customer_name,
    :billing,
    :shipping,
    :payment_gateway_transaction_id,
    :transaction_id,
    :payload,
    :raw_payload
  ]

  setup do
    HotStateAggregator.reset_for_test!()
    on_exit(fn -> HotStateAggregator.reset_for_test!() end)

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        name: "Contract Dashboard Event",
        slug: unique_slug("contract-dash")
      })

    ga = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    vip = SalesHelpers.create_ticket_type!(event, %{name: "VIP"})

    %{source: source, event: event, ga: ga, vip: vip}
  end

  test "snapshot/0 exposes documented top-level keys only" do
    assert {:ok, snapshot} = AdminDashboard.snapshot()
    assert Map.keys(snapshot) |> Enum.sort() == Enum.sort(@snapshot_keys)
    refute Map.has_key?(snapshot, :daily_buckets)
  end

  test "kpis use integer sold fields and Decimal revenue fields" do
    assert {:ok, %{kpis: kpis}} = AdminDashboard.snapshot()

    assert is_integer(kpis.total_sold)
    assert is_integer(kpis.today_sold)
    assert match?(%Decimal{}, kpis.total_revenue)
    assert match?(%Decimal{}, kpis.today_revenue)
  end

  test "event rows include documented fields from hot summary", %{event: event} do
    DashboardCache.put_event_summary(event.id, %{
      total_sold: 3,
      total_revenue: Decimal.new("1350.00"),
      today_sold: 1,
      today_revenue: Decimal.new("450.00"),
      status_breakdown: %{"completed" => 2},
      currency: "ZAR",
      updated_at: ~U[2026-05-17 10:00:00Z]
    })

    assert {:ok, snapshot} = AdminDashboard.snapshot()

    assert [row] = Enum.filter(snapshot.events, &(&1.event_id == event.id))
    assert Map.keys(row) |> Enum.sort() == Enum.sort(@event_row_keys)
    assert row.event_name == "Contract Dashboard Event"
    assert row.total_sold == 3
    assert row.refreshed_at == ~U[2026-05-17 10:00:00Z]
  end

  test "ticket type rows include documented fields and only completed mapped tickets", %{
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

    create_item!(pending, event, vip, woo_line_item_id: 8)

    assert {:ok, snapshot} = AdminDashboard.snapshot()

    assert [row] = snapshot.ticket_types
    assert Map.keys(row) |> Enum.sort() == Enum.sort(@ticket_type_row_keys)
    assert row.total_sold == 2
    assert Decimal.equal?(row.total_revenue, Decimal.new("900.00"))
  end

  test "recent orders are PII-safe and include only operational fields", %{source: source} do
    create_order!(source, :completed,
      woo_order_id: 401,
      order_number: "CONTRACT-OLD",
      updated_at_source: ~U[2026-05-17 08:00:00Z],
      customer_email: "older@example.test",
      customer_name: "Older Customer",
      payment_gateway_transaction_id: "txn_older"
    )

    create_order!(source, :completed,
      woo_order_id: 402,
      order_number: "CONTRACT-NEW",
      updated_at_source: ~U[2026-05-17 09:00:00Z],
      customer_email: "newer@example.test",
      customer_name: "Newer Customer",
      payment_gateway_transaction_id: "txn_newer"
    )

    assert {:ok, snapshot} = AdminDashboard.snapshot(recent_order_limit: 1)

    assert [%{order_number: "CONTRACT-NEW"} = order] = snapshot.recent_orders
    assert Map.keys(order) |> Enum.sort() == Enum.sort(@recent_order_keys)

    for key <- @pii_keys do
      refute Map.has_key?(order, key)
    end
  end

  test "unmapped alerts include only operational fields", %{
    source: source,
    event: event,
    ga: ga
  } do
    order = create_order!(source, :completed, woo_order_id: 501)

    create_item!(order, event, ga,
      name: "Contract Mapping Gap",
      woo_line_item_id: 9,
      woo_product_id: 777,
      mapping_status: :pending_mapping_resolution,
      item_kind: :unknown
    )

    assert {:ok, snapshot} = AdminDashboard.snapshot(unmapped_limit: 5)

    assert [alert] = snapshot.unmapped_alerts
    assert Map.keys(alert) |> Enum.sort() == Enum.sort(@unmapped_alert_keys)

    for key <- @pii_keys do
      refute Map.has_key?(alert, key)
    end
  end

  test "empty operational data contract without orders or hot cache", %{event: event} do
    assert {:ok, snapshot} = AdminDashboard.snapshot()

    assert snapshot.kpis.total_sold == 0
    assert snapshot.kpis.today_sold == 0
    assert Decimal.equal?(snapshot.kpis.total_revenue, Decimal.new("0"))
    assert Decimal.equal?(snapshot.kpis.today_revenue, Decimal.new("0"))
    assert snapshot.recent_orders == []
    assert snapshot.unmapped_alerts == []
    assert snapshot.statuses == %{}
    assert is_map(snapshot.hot_state)

    row = Enum.find(snapshot.events, &(&1.event_id == event.id))
    assert row.total_sold == 0
    assert Decimal.equal?(row.total_revenue, Decimal.new("0"))
    assert row.status_breakdown == %{}
  end

  test "AdminDashboard does not depend on EventSalesWeb" do
    source = File.read!("lib/event_sales/analytics/admin_dashboard.ex")
    refute source =~ "EventSalesWeb"
  end

  defp create_order!(source, status, attrs) do
    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "CC-#{System.unique_integer([:positive])}",
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
      name: "Contract Ticket",
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
