defmodule EventSales.Analytics.AdminDashboardTest.SourceFreshnessRecorder do
  def for_events(event_ids, opts) do
    report({:for_events, event_ids, opts})

    Process.get(
      {__MODULE__, :for_events_result},
      {:ok, Map.new(event_ids, &{&1, {:error, :missing_source_freshness_anchor}})}
    )
  end

  def for_event(event_id, opts) do
    report({:for_event, event_id, opts})
    Process.get({__MODULE__, :for_event_result}, {:error, :missing_source_freshness_anchor})
  end

  defp report(message) do
    case Process.get({__MODULE__, :test_pid}) do
      pid when is_pid(pid) -> send(pid, message)
      _ -> :ok
    end
  end
end

defmodule EventSales.Analytics.AdminDashboardTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Analytics.{
    AdminDashboard,
    DashboardCache,
    HotStateAggregator,
    SnapshotRefresh,
    SourceFreshness
  }

  alias EventSales.Analytics.Resources.EventSourceFreshnessSnapshot
  alias EventSales.Analytics.Workers.RebuildHotStateWorker
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers

  alias EventSales.Analytics.AdminDashboardTest.SourceFreshnessRecorder

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

  test "event row keeps hot today metrics when daily v1 snapshot disagrees on sale-effective time",
       %{
         source: source,
         event: event,
         ga: ga
       } do
    now = ~U[2026-06-01 12:00:00.000000Z]
    business_date = ~D[2026-06-01]

    completed =
      create_order!(source, :completed,
        woo_order_id: 111,
        paid_at: ~U[2026-06-01 10:00:00.000000Z],
        completed_at: ~U[2026-05-31 10:00:00.000000Z]
      )

    create_item!(completed, event, ga,
      woo_line_item_id: 11,
      quantity: 1,
      line_total: Decimal.new("100.00")
    )

    assert {:ok, daily} = SnapshotRefresh.refresh_daily(event.id, business_date, now: now)
    assert daily.today_sold == 0
    assert Decimal.equal?(daily.today_revenue, Decimal.new("0"))

    DashboardCache.put_event_summary(event.id, %{
      total_sold: 1,
      total_revenue: Decimal.new("100.00"),
      today_sold: 1,
      today_revenue: Decimal.new("100.00"),
      status_breakdown: %{"completed" => 1},
      currency: "ZAR"
    })

    assert {:ok, row} = AdminDashboard.event_row(event.id, now: now)

    assert row.today_sold == 1
    assert Decimal.equal?(row.today_revenue, Decimal.new("100.00"))
    assert row.total_sold == 1
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
    assert row.source_freshness == {:error, :missing_source_freshness_anchor}
  end

  test "event_row propagates unexpected source freshness read errors", %{event: event} do
    Process.put({SourceFreshnessRecorder, :test_pid}, self())
    Process.put({SourceFreshnessRecorder, :for_event_result}, {:error, :projection_unavailable})

    assert {:error, :projection_unavailable} =
             AdminDashboard.event_row(event.id, source_freshness: SourceFreshnessRecorder)

    assert_receive {:for_event, event_id, _opts}
    assert event_id == event.id
  end

  test "snapshot uses one batch freshness call for the bounded event set", %{
    event: event,
    other_event: other_event
  } do
    Process.put({SourceFreshnessRecorder, :test_pid}, self())

    assert {:ok, snapshot} =
             AdminDashboard.snapshot(
               now: ~U[2026-05-17 10:00:00Z],
               source_freshness: SourceFreshnessRecorder
             )

    assert_receive {:for_events, event_ids, [now: ~U[2026-05-17 10:00:00Z]]}
    assert Enum.sort(event_ids) == Enum.sort([event.id, other_event.id])
    refute_receive {:for_events, _, _}, 0
    refute_receive {:for_event, _, _}, 0
    assert snapshot.source_freshness.result == {:error, :missing_source_freshness_anchor}
    assert snapshot.source_freshness.counts.missing == 2
  end

  test "normal newer anchor does not hide an older stale event", %{
    event: event,
    other_event: other_event
  } do
    now = ~U[2026-05-17 12:00:00.000000Z]
    normal_anchor = DateTime.add(now, -1, :minute)

    assert :ok = SourceFreshness.advance_order(event.id, normal_anchor)
    assert :ok = SourceFreshness.advance_order(other_event.id, DateTime.add(now, -30, :minute))

    assert {:ok, snapshot} = AdminDashboard.snapshot(now: now)

    assert {:ok, %{classification: :stale, portfolio_anchor_at: ^normal_anchor}} =
             snapshot.source_freshness.result

    assert snapshot.source_freshness.counts == %{normal: 1, aging: 0, stale: 1, missing: 0}
  end

  test "missing evidence is counted without changing the worst classified event", %{
    source: source,
    event: event,
    other_event: other_event
  } do
    missing =
      SalesHelpers.create_event!(source, %{name: "Missing Event", slug: unique_slug("missing")})

    now = ~U[2026-05-17 12:00:00Z]

    assert :ok = SourceFreshness.advance_order(event.id, DateTime.add(now, -1, :minute))
    assert :ok = SourceFreshness.advance_order(other_event.id, DateTime.add(now, -7, :minute))

    assert {:ok, snapshot} = AdminDashboard.snapshot(now: now)

    assert {:ok, %{classification: :aging}} = snapshot.source_freshness.result
    assert snapshot.source_freshness.counts == %{normal: 1, aging: 1, stale: 0, missing: 1}
    assert Enum.any?(snapshot.events, &(&1.event_id == missing.id))
  end

  test "all missing evidence returns the typed missing aggregate" do
    assert {:ok, snapshot} = AdminDashboard.snapshot()

    assert snapshot.source_freshness.result == {:error, :missing_source_freshness_anchor}
    assert snapshot.source_freshness.counts == %{normal: 0, aging: 0, stale: 0, missing: 2}
  end

  test "an empty displayed event set returns typed missing evidence with zero counts" do
    assert {:ok, snapshot} =
             AdminDashboard.snapshot(lifecycle: :past, now: ~U[2026-05-17 12:00:00Z])

    assert snapshot.events == []
    assert snapshot.source_freshness.result == {:error, :missing_source_freshness_anchor}
    assert snapshot.source_freshness.counts == %{normal: 0, aging: 0, stale: 0, missing: 0}
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
    aging_anchor = ~U[2026-05-17 11:53:00Z]
    normal_anchor = ~U[2026-05-17 11:59:00Z]

    snapshot = %{
      kpis: %{total_sold: 1, total_revenue: Decimal.new("100.00")},
      statuses: %{"completed" => 1},
      events: [
        row(event,
          total_sold: 1,
          total_revenue: Decimal.new("100.00"),
          source_freshness: freshness(:aging, aging_anchor, 420_000)
        ),
        row(other_event, %{
          total_sold: 2,
          total_revenue: Decimal.new("200.00"),
          status_breakdown: %{"pending" => 2},
          source_freshness: freshness(:normal, normal_anchor, 60_000)
        })
      ],
      ticket_types: [%{ticket_type_name: "GA"}],
      recent_orders: [%{order_number: "R-1"}],
      unmapped_alerts: [%{name: "Needs Mapping"}],
      read_model: %{lifecycle: :ready, generated_at: normal_anchor},
      source_freshness:
        aggregate(:aging, normal_anchor, %{normal: 1, aging: 1, stale: 0, missing: 0})
    }

    replacement =
      row(event, %{
        total_sold: 4,
        total_revenue: Decimal.new("400.00"),
        status_breakdown: %{"completed" => 4},
        source_freshness: freshness(:stale, ~U[2026-05-17 11:30:00Z], 1_800_000)
      })

    updated =
      with_repo_query_capture(fn ->
        assert {:ok, updated} = AdminDashboard.replace_event_row(snapshot, replacement)
        updated
      end)

    event_id = event.id
    other_event_id = other_event.id

    assert [
             %{event_id: ^event_id, total_sold: 4},
             %{event_id: ^other_event_id, total_sold: 2}
           ] = updated.events

    assert updated.kpis.total_sold == 6
    assert updated.kpis.total_revenue == Decimal.new("600.00")
    assert updated.statuses == %{"completed" => 4, "pending" => 2}

    assert updated.source_freshness ==
             aggregate(:stale, normal_anchor, %{normal: 1, aging: 0, stale: 1, missing: 0})

    assert updated.ticket_types == snapshot.ticket_types
    assert updated.recent_orders == snapshot.recent_orders
    assert updated.unmapped_alerts == snapshot.unmapped_alerts
    assert updated.read_model == snapshot.read_model
  end

  test "manual rebuild makes the read model ready without changing stale source freshness", %{
    event: event
  } do
    now = DateTime.utc_now()
    anchor = DateTime.add(now, -30, :minute)

    assert :ok = SourceFreshness.advance_order(event.id, anchor)

    assert {:ok, %{classification: :stale, anchor_at: ^anchor}} =
             SourceFreshness.for_event(event.id, now: now)

    projection_before = freshness_projection!(event.id)

    assert :ok = RebuildHotStateWorker.perform(%Oban.Job{args: %{"scope" => "hot_state"}})

    assert %{lifecycle: :ready, generated_at: %DateTime{}} = HotStateAggregator.status()
    assert {:ok, dashboard} = AdminDashboard.snapshot(now: now)
    assert dashboard.read_model.lifecycle == :ready

    assert {:ok, %{classification: :stale, portfolio_anchor_at: ^anchor}} =
             dashboard.source_freshness.result

    projection_after = freshness_projection!(event.id)

    assert Map.take(projection_after, [
             :order_source_watermark_at,
             :refund_source_watermark_at,
             :sync_source_observed_at,
             :projection_refreshed_at
           ]) ==
             Map.take(projection_before, [
               :order_source_watermark_at,
               :refund_source_watermark_at,
               :sync_source_observed_at,
               :projection_refreshed_at
             ])
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
      refreshed_at: nil,
      source_freshness: {:error, :missing_source_freshness_anchor}
    }

    Map.merge(defaults, Map.new(attrs))
  end

  defp freshness(classification, anchor_at, age_ms) do
    {:ok, %{classification: classification, anchor_at: anchor_at, age_ms: age_ms}}
  end

  defp aggregate(classification, portfolio_anchor_at, counts) do
    %{
      result: {:ok, %{classification: classification, portfolio_anchor_at: portfolio_anchor_at}},
      counts: counts
    }
  end

  defp freshness_projection!(event_id) do
    EventSourceFreshnessSnapshot
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.read_one!(domain: EventSales.Analytics)
  end

  defp with_repo_query_capture(fun) do
    handler_id = "admin-dashboard-query-capture-#{System.unique_integer([:positive])}"
    telemetry_prefix = Keyword.get(Repo.config(), :telemetry_prefix, [:event_sales, :repo])
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        telemetry_prefix ++ [:query],
        fn _event, _measurements, _metadata, pid -> send(pid, :repo_query) end,
        test_pid
      )

    try do
      Repo.query!("SELECT 1")
      assert_receive :repo_query, 500
      refute_receive :repo_query, 0

      result = fun.()
      refute_receive :repo_query, 0
      result
    after
      :telemetry.detach(handler_id)
    end
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
