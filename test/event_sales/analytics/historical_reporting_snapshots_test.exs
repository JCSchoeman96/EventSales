defmodule EventSales.Analytics.HistoricalReportingSnapshotsTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Analytics.Aggregators.EventAggregator
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

    assert {:ok, [first | _]} =
             SnapshotRefresh.refresh_event(event.id,
               now: ~U[2026-05-17 10:00:00.000000Z],
               refreshed_at: ~U[2026-05-18 08:00:00.000000Z]
             )

    assert {:ok, [second | _]} =
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
    assert second.snapshot_version == 2

    assert {:ok, canonical} = EventAggregator.financial_summaries_for_event(event.id)
    zar = canonical["ZAR"]

    assert second.gross_ticket_quantity ==
             decimal_to_int!(zar.gross_ticket_quantity)

    assert second.refund_ticket_quantity ==
             decimal_to_int!(zar.refund_ticket_quantity)

    assert Decimal.equal?(second.gross_ticket_value, zar.gross_ticket_value)
    assert Decimal.equal?(second.refund_ticket_value, zar.refund_ticket_value)
    assert second.recognised_order_count == zar.recognised_order_count
  end

  test "event snapshot identity allows one projection per currency", %{
    event: event,
    other_event: other_event
  } do
    assert {:ok, zar} = create_event_snapshot(event.id, %{currency: "ZAR"})
    assert {:ok, usd} = create_event_snapshot(event.id, %{currency: "USD"})

    assert zar.currency == "ZAR"
    assert usd.currency == "USD"
    assert count_event_snapshots(event.id) == 2

    assert {:error, _reason} = create_event_snapshot(event.id, %{currency: "ZAR"})
    assert count_event_snapshots(event.id) == 2

    assert {:ok, other_event_snapshot} =
             create_event_snapshot(other_event.id, %{currency: "ZAR"})

    assert other_event_snapshot.event_id == other_event.id
    assert count_event_snapshots(other_event.id) == 1
  end

  test "event snapshot v2 stores canonical additive financial primitives", %{event: event} do
    expected = %{
      gross_ticket_quantity: 7,
      refund_ticket_quantity: 2,
      gross_ticket_value: Decimal.new("1234.56"),
      refund_ticket_value: Decimal.new("210.45"),
      recognised_order_count: 3
    }

    assert {:ok, snapshot} =
             create_event_snapshot(event.id, Map.merge(expected, %{snapshot_version: 2}))

    assert snapshot.snapshot_version == 2
    assert Map.take(Map.from_struct(snapshot), Map.keys(expected)) == expected
  end

  test "event snapshot v2 requires every canonical primitive explicitly", %{event: event} do
    primitives = %{
      gross_ticket_quantity: 0,
      refund_ticket_quantity: 0,
      gross_ticket_value: Decimal.new("0"),
      refund_ticket_value: Decimal.new("0"),
      recognised_order_count: 0
    }

    Enum.each(primitives, fn {omitted_field, _value} ->
      attrs = primitives |> Map.delete(omitted_field) |> Map.put(:snapshot_version, 2)

      assert {:error, _reason} = create_event_snapshot(event.id, attrs),
             "expected snapshot_version 2 to reject omitted #{omitted_field}"
    end)
  end

  test "a v1 snapshot cannot be promoted to v2 from compatibility defaults alone", %{
    event: event
  } do
    assert {:ok, legacy} = create_event_snapshot(event.id, %{snapshot_version: 1})
    assert legacy.snapshot_version == 1

    assert {:error, _reason} =
             Ash.update(legacy, %{snapshot_version: 2},
               action: :update_snapshot,
               domain: EventSales.Analytics
             )

    assert {:ok, persisted} =
             Ash.get(EventAggregateSnapshot, legacy.id, domain: EventSales.Analytics)

    assert persisted.snapshot_version == 1
  end

  test "event snapshot schema does not persist derived net or average fields" do
    attributes =
      EventAggregateSnapshot
      |> Ash.Resource.Info.attributes()
      |> Enum.map(& &1.name)

    refute :net_ticket_quantity in attributes
    refute :net_ticket_value in attributes
    refute :average_ticket_value in attributes
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

    assert {:ok, _snapshots} =
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

    assert {:ok, _snapshots} =
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

  test "event refresh writes one v2 projection per canonical currency", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    zar_order =
      create_order!(source, :completed,
        woo_order_id: 91_001,
        currency: "ZAR",
        completed_at: ~U[2026-05-17 08:00:00.000000Z]
      )

    usd_order =
      create_order!(source, :completed,
        woo_order_id: 91_002,
        currency: "USD",
        completed_at: ~U[2026-05-17 08:00:00.000000Z]
      )

    create_item!(zar_order, event, ticket,
      woo_line_item_id: 1,
      quantity: 2,
      line_total: Decimal.new("900.00"),
      line_total_tax: Decimal.new("135.00")
    )

    create_item!(usd_order, event, ticket,
      woo_line_item_id: 2,
      quantity: 1,
      line_total: Decimal.new("50.00"),
      line_total_tax: Decimal.new("7.50")
    )

    assert {:ok, canonical} = EventAggregator.financial_summaries_for_event(event.id)
    assert Map.keys(canonical) |> Enum.sort() == ["USD", "ZAR"]

    assert {:ok, snapshots} = SnapshotRefresh.refresh_event(event.id)
    assert length(snapshots) == 2
    assert Enum.map(snapshots, & &1.currency) |> Enum.sort() == ["USD", "ZAR"]

    assert {:ok, reader} = SnapshotReader.financial_summaries_for_event(event.id)
    assert Map.keys(reader) |> Enum.sort() == ["USD", "ZAR"]
    assert reader["ZAR"].gross_ticket_quantity == canonical["ZAR"].gross_ticket_quantity
    assert reader["USD"].gross_ticket_quantity == canonical["USD"].gross_ticket_quantity
  end

  test "mixed-currency refresh preserves operational status breakdown on v2 rows", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    zar_order =
      create_order!(source, :completed,
        woo_order_id: 91_050,
        currency: "ZAR",
        completed_at: ~U[2026-05-17 08:00:00.000000Z]
      )

    usd_order =
      create_order!(source, :completed,
        woo_order_id: 91_051,
        currency: "USD",
        completed_at: ~U[2026-05-17 08:00:00.000000Z]
      )

    pending = create_order!(source, :pending, woo_order_id: 91_052, completed_at: nil)

    create_item!(zar_order, event, ticket,
      woo_line_item_id: 50,
      quantity: 1,
      line_total: Decimal.new("450.00"),
      line_total_tax: Decimal.new("67.50")
    )

    create_item!(usd_order, event, ticket,
      woo_line_item_id: 51,
      quantity: 1,
      line_total: Decimal.new("50.00"),
      line_total_tax: Decimal.new("7.50")
    )

    create_item!(pending, event, ticket, woo_line_item_id: 52, line_total_tax: Decimal.new("0"))

    assert {:ok, expected_breakdown} =
             EventAggregator.operational_status_breakdown_for_event(event.id)

    assert {:ok, snapshots} = SnapshotRefresh.refresh_event(event.id)
    assert length(snapshots) == 2

    Enum.each(snapshots, fn snapshot ->
      assert snapshot.status_breakdown == stringify_status_breakdown(expected_breakdown)
    end)

    assert {:error, :mixed_currency} = SnapshotReader.summary_for_event(event.id)
  end

  test "existing v1 zar projection is promoted to v2 with explicit canonical primitives", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    assert {:ok, legacy} =
             create_event_snapshot(event.id, %{
               snapshot_version: 1,
               total_sold: 1,
               total_revenue: Decimal.new("450.00")
             })

    order =
      create_order!(source, :completed,
        woo_order_id: 91_010,
        completed_at: ~U[2026-05-17 08:00:00.000000Z]
      )

    create_item!(order, event, ticket,
      woo_line_item_id: 10,
      quantity: 2,
      line_total: Decimal.new("900.00"),
      line_total_tax: Decimal.new("135.00")
    )

    assert {:ok, [promoted]} = SnapshotRefresh.refresh_event(event.id)
    assert promoted.id == legacy.id
    assert promoted.snapshot_version == 2
    assert promoted.gross_ticket_quantity == 2
    assert promoted.recognised_order_count == 1
  end

  test "obsolete v2 currency rows are removed on refresh", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    assert {:ok, _usd} =
             create_event_snapshot(event.id, %{
               currency: "USD",
               snapshot_version: 2,
               gross_ticket_quantity: 1,
               refund_ticket_quantity: 0,
               gross_ticket_value: Decimal.new("10"),
               refund_ticket_value: Decimal.new("0"),
               recognised_order_count: 1
             })

    order =
      create_order!(source, :completed,
        woo_order_id: 91_020,
        currency: "ZAR",
        completed_at: ~U[2026-05-17 08:00:00.000000Z]
      )

    create_item!(order, event, ticket,
      woo_line_item_id: 20,
      quantity: 1,
      line_total: Decimal.new("450.00"),
      line_total_tax: Decimal.new("67.50")
    )

    assert {:ok, snapshots} = SnapshotRefresh.refresh_event(event.id)
    assert snapshots |> Enum.map(& &1.currency) == ["ZAR"]
    assert count_event_snapshots(event.id) == 1
  end

  test "canonical reader treats v1 rows as a non-authoritative miss", %{event: event} do
    assert {:ok, _v1} = create_event_snapshot(event.id, %{snapshot_version: 1, total_sold: 2})

    assert :miss = SnapshotReader.financial_summaries_for_event(event.id)
    assert :miss = SnapshotReader.financial_summary_for_event(event.id, "ZAR")
    assert {:ok, legacy} = SnapshotReader.summary_for_event(event.id)
    assert legacy.snapshot_version == 1
  end

  test "legacy reader fails closed when multiple v2 currencies exist", %{event: event} do
    assert {:ok, _zar} =
             create_event_snapshot(event.id, %{
               currency: "ZAR",
               snapshot_version: 2,
               gross_ticket_quantity: 1,
               refund_ticket_quantity: 0,
               gross_ticket_value: Decimal.new("10"),
               refund_ticket_value: Decimal.new("0"),
               recognised_order_count: 1
             })

    assert {:ok, _usd} =
             create_event_snapshot(event.id, %{
               currency: "USD",
               snapshot_version: 2,
               gross_ticket_quantity: 1,
               refund_ticket_quantity: 0,
               gross_ticket_value: Decimal.new("10"),
               refund_ticket_value: Decimal.new("0"),
               recognised_order_count: 1
             })

    assert {:ok, both} = SnapshotReader.financial_summaries_for_event(event.id)
    assert Map.keys(both) |> Enum.sort() == ["USD", "ZAR"]
    assert {:error, :mixed_currency} = SnapshotReader.summary_for_event(event.id)
  end

  test "legacy reader preserves single-currency v2 scalar fields", %{event: event} do
    assert {:ok, _snapshot} =
             create_event_snapshot(event.id, %{
               snapshot_version: 2,
               total_sold: 4,
               total_revenue: Decimal.new("1200.00"),
               today_sold: 1,
               today_revenue: Decimal.new("300.00"),
               gross_ticket_quantity: 4,
               refund_ticket_quantity: 0,
               gross_ticket_value: Decimal.new("1200.00"),
               refund_ticket_value: Decimal.new("0"),
               recognised_order_count: 2
             })

    assert {:ok, summary} = SnapshotReader.summary_for_event(event.id)
    assert summary.total_sold == 4
    assert summary.total_revenue == Decimal.new("1200.00")
    assert summary.today_sold == 1
    assert summary.snapshot_version == 2
  end

  test "empty canonical refresh removes v2 rows and does not resurrect stale v1 compatibility", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    assert {:ok, legacy} =
             create_event_snapshot(event.id, %{
               snapshot_version: 1,
               total_sold: 99,
               total_revenue: Decimal.new("9999.00")
             })

    pending = create_order!(source, :pending, woo_order_id: 91_040, completed_at: nil)
    create_item!(pending, event, ticket, woo_line_item_id: 40, line_total_tax: Decimal.new("0"))

    assert {:ok, []} = SnapshotRefresh.refresh_event(event.id)
    assert :miss = SnapshotReader.summary_for_event(event.id)
    assert :miss = SnapshotReader.financial_summaries_for_event(event.id)

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} =
             Ash.get(EventAggregateSnapshot, legacy.id, domain: EventSales.Analytics)
  end

  test "explicit currency canonical reader returns derived net and average ticket value", %{
    event: event
  } do
    assert {:ok, _snapshot} =
             create_event_snapshot(event.id, %{
               snapshot_version: 2,
               currency: "ZAR",
               gross_ticket_quantity: 4,
               refund_ticket_quantity: 1,
               gross_ticket_value: Decimal.new("400.00"),
               refund_ticket_value: Decimal.new("50.00"),
               recognised_order_count: 2
             })

    assert {:ok, summary} = SnapshotReader.financial_summary_for_event(event.id, "ZAR")
    assert summary.net_ticket_quantity == Decimal.new("3")
    assert Decimal.equal?(summary.net_ticket_value, Decimal.new("350.00"))
    assert Decimal.equal?(summary.average_ticket_value, Decimal.div(Decimal.new("350.00"), 3))
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
      line_total_tax: Decimal.new("0"),
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

  defp create_event_snapshot(event_id, attrs) do
    defaults = %{
      event_id: event_id,
      total_sold: 0,
      total_revenue: Decimal.new("0"),
      today_sold: 0,
      today_revenue: Decimal.new("0"),
      currency: "ZAR",
      business_timezone: "Africa/Johannesburg",
      refreshed_at: ~U[2026-05-18 08:00:00.000000Z],
      source_row_count: 0,
      snapshot_version: 1
    }

    Ash.create(
      EventAggregateSnapshot,
      Map.merge(defaults, attrs),
      action: :create_snapshot,
      domain: EventSales.Analytics
    )
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

  defp decimal_to_int!(%Decimal{} = value) do
    value |> Decimal.round(0) |> Decimal.to_integer()
  end

  defp stringify_status_breakdown(status_breakdown) when is_map(status_breakdown) do
    Map.new(status_breakdown, fn {key, value} -> {to_string(key), value} end)
  end
end
