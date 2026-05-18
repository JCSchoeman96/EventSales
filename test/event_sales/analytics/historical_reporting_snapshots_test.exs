defmodule EventSales.Analytics.HistoricalReportingSnapshotsTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Analytics.{DashboardCache, SnapshotReader, SnapshotRefresh}
  alias EventSales.Analytics.Resources.{DailySalesAggregateSnapshot, EventAggregateSnapshot}
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers

  setup do
    DashboardCache.ensure_table!()
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{name: "Snapshot Event", slug: unique_slug("snapshot")})

    other_event =
      SalesHelpers.create_event!(source, %{name: "Other Event", slug: unique_slug("other")})

    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other GA"})

    %{
      source: source,
      event: event,
      other_event: other_event,
      ticket: ticket,
      other_ticket: other_ticket
    }
  end

  test "event refresh is idempotent and stores completed-only totals", %{
    source: source,
    event: event,
    other_event: other_event,
    ticket: ticket,
    other_ticket: other_ticket
  } do
    create_metric_rows!(source, event, other_event, ticket, other_ticket)

    assert {:ok, first} =
             SnapshotRefresh.refresh_event(event.id,
               now: ~U[2026-05-17 10:00:00.000000Z],
               refreshed_at: ~U[2026-05-18 08:00:00.000000Z]
             )

    assert {:ok, second} =
             SnapshotRefresh.refresh_event(event.id,
               now: ~U[2026-05-17 10:00:00.000000Z],
               refreshed_at: ~U[2026-05-18 08:05:00.000000Z]
             )

    assert first.id == second.id
    assert count_event_snapshots(event.id) == 1
    assert second.total_sold == 2
    assert second.total_revenue == Decimal.new("900.00")
    assert second.today_sold == 2
    assert second.today_revenue == Decimal.new("900.00")

    assert second.status_breakdown == %{
             "cancelled" => 1,
             "completed" => 3,
             "pending" => 1,
             "refunded" => 1
           }

    assert second.currency == "ZAR"
    assert second.business_timezone == "Africa/Johannesburg"
    assert second.source_row_count == 6
    assert second.source_watermark_at == ~U[2026-05-17 08:03:00.000000Z]
    assert second.snapshot_version == 1
  end

  test "daily refresh is idempotent and scoped by event date and timezone", %{
    source: source,
    event: event,
    other_event: other_event,
    ticket: ticket,
    other_ticket: other_ticket
  } do
    create_metric_rows!(source, event, other_event, ticket, other_ticket)
    business_date = ~D[2026-05-17]

    assert {:ok, first} =
             SnapshotRefresh.refresh_daily(event.id, business_date,
               refreshed_at: ~U[2026-05-18 08:00:00.000000Z]
             )

    assert {:ok, second} =
             SnapshotRefresh.refresh_daily(event.id, business_date,
               refreshed_at: ~U[2026-05-18 08:05:00.000000Z]
             )

    assert first.id == second.id
    assert count_daily_snapshots(event.id, business_date, "Africa/Johannesburg") == 1
    assert count_daily_snapshots(other_event.id, business_date, "Africa/Johannesburg") == 0
    assert second.total_sold == 2
    assert second.total_revenue == Decimal.new("900.00")
    assert second.today_sold == 2
    assert second.today_revenue == Decimal.new("900.00")

    assert second.status_breakdown == %{
             "cancelled" => 1,
             "completed" => 3,
             "refunded" => 1
           }

    assert second.source_row_count == 5
    assert second.source_watermark_at == ~U[2026-05-17 08:03:00.000000Z]
  end

  test "refresh invalidates dashboard cache for touched event", %{event: event} do
    assert :ok = DashboardCache.put_event_summary(event.id, %{total_sold: 99})

    assert {:ok, _snapshot} =
             SnapshotRefresh.refresh_event(event.id,
               now: ~U[2026-05-17 10:00:00.000000Z],
               refreshed_at: ~U[2026-05-18 08:00:00.000000Z]
             )

    assert :miss = DashboardCache.get_event_summary(event.id)
  end

  test "snapshot reader returns stored values only until refresh runs again", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    create_completed_sale!(source, event, ticket,
      woo_order_id: 95_001,
      woo_line_item_id: 1,
      quantity: 1,
      line_total: Decimal.new("450.00"),
      completed_at: ~U[2026-05-17 08:00:00.000000Z],
      updated_at_source: ~U[2026-05-17 08:00:00.000000Z]
    )

    assert {:ok, _snapshot} =
             SnapshotRefresh.refresh_event(event.id, now: ~U[2026-05-17 10:00:00.000000Z])

    create_completed_sale!(source, event, ticket,
      woo_order_id: 95_002,
      woo_line_item_id: 2,
      quantity: 10,
      line_total: Decimal.new("4500.00"),
      completed_at: ~U[2026-05-17 09:00:00.000000Z],
      updated_at_source: ~U[2026-05-17 09:00:00.000000Z]
    )

    assert {:ok, summary} = SnapshotReader.summary_for_event(event.id)
    assert summary.total_sold == 1
    assert summary.total_revenue == Decimal.new("450.00")
  end

  test "snapshot reader returns daily snapshot values", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    create_completed_sale!(source, event, ticket,
      woo_order_id: 96_001,
      woo_line_item_id: 1,
      quantity: 3,
      line_total: Decimal.new("1350.00"),
      completed_at: ~U[2026-05-17 08:00:00.000000Z],
      updated_at_source: ~U[2026-05-17 08:00:00.000000Z]
    )

    assert {:ok, _snapshot} = SnapshotRefresh.refresh_daily(event.id, ~D[2026-05-17])
    assert {:ok, summary} = SnapshotReader.daily_summary_for_event(event.id, ~D[2026-05-17])
    assert summary.total_sold == 3
    assert summary.total_revenue == Decimal.new("1350.00")
    assert summary.business_date == ~D[2026-05-17]
  end

  defp create_metric_rows!(source, event, other_event, ticket, other_ticket) do
    completed =
      create_order!(source, :completed,
        woo_order_id: 90_001,
        completed_at: ~U[2026-05-16 22:30:00.000000Z],
        updated_at_source: ~U[2026-05-17 08:00:00.000000Z]
      )

    pending =
      create_order!(source, :pending,
        woo_order_id: 90_002,
        completed_at: nil,
        updated_at_source: ~U[2026-05-17 08:01:00.000000Z]
      )

    refunded =
      create_order!(source, :refunded,
        woo_order_id: 90_003,
        updated_at_source: ~U[2026-05-17 08:02:00.000000Z]
      )

    cancelled =
      create_order!(source, :cancelled,
        woo_order_id: 90_004,
        updated_at_source: ~U[2026-05-17 08:03:00.000000Z]
      )

    other_order =
      create_order!(source, :completed,
        woo_order_id: 90_005,
        updated_at_source: ~U[2026-05-17 08:04:00.000000Z]
      )

    create_item!(completed, event, ticket,
      woo_line_item_id: 1,
      quantity: 2,
      line_total: Decimal.new("900.00")
    )

    create_item!(completed, event, ticket, woo_line_item_id: 2, mapping_status: :unmapped)

    create_item!(completed, event, ticket,
      woo_line_item_id: 3,
      item_kind: :non_ticket,
      mapping_status: :non_ticket
    )

    create_item!(pending, event, ticket, woo_line_item_id: 4, line_total: Decimal.new("500.00"))
    create_item!(refunded, event, ticket, woo_line_item_id: 5)
    create_item!(cancelled, event, ticket, woo_line_item_id: 6)
    create_item!(other_order, other_event, other_ticket, woo_line_item_id: 7, quantity: 9)
  end

  defp create_completed_sale!(source, event, ticket, attrs) do
    {order_attrs, item_attrs} = split_completed_sale_attrs(attrs)
    order = create_order!(source, :completed, order_attrs)
    create_item!(order, event, ticket, item_attrs)
    order
  end

  defp split_completed_sale_attrs(attrs) do
    attrs = Keyword.new(attrs)

    item_keys = [
      :woo_line_item_id,
      :woo_product_id,
      :woo_variation_id,
      :name,
      :quantity,
      :line_subtotal,
      :line_total,
      :discount_total,
      :item_kind,
      :mapping_status
    ]

    {item_attrs, order_attrs} = Keyword.split(attrs, item_keys)
    {order_attrs, item_attrs}
  end

  defp create_order!(source, status, attrs) do
    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "SNAP-#{System.unique_integer([:positive])}",
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
      name: "Snapshot Ticket",
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

  defp count_event_snapshots(event_id) do
    EventAggregateSnapshot
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.read!(domain: EventSales.Analytics)
    |> length()
  end

  defp count_daily_snapshots(event_id, business_date, timezone) do
    DailySalesAggregateSnapshot
    |> Ash.Query.filter(
      event_id == ^event_id and business_date == ^business_date and business_timezone == ^timezone
    )
    |> Ash.read!(domain: EventSales.Analytics)
    |> length()
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
