defmodule EventSales.Analytics.HotStateAggregatorTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.HotStateAggregator
  alias EventSales.Analytics.CacheKeys
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.Telemetry
  alias EventSales.TestSupport.Analytics.MemorySnapshotStoreAdapter
  alias EventSales.TestSupport.SalesHelpers

  setup do
    delete_rebuild_jobs!()
    HotStateAggregator.reset_for_test!()
    MemorySnapshotStoreAdapter.reset!()

    on_exit(fn ->
      delete_rebuild_jobs!()
      HotStateAggregator.reset_for_test!()
      MemorySnapshotStoreAdapter.reset!()
    end)

    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Hot Event", slug: "hot-event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    %{source: source, event: event, ticket: ticket}
  end

  test "starts under supervision" do
    assert pid = Process.whereis(HotStateAggregator)
    assert Process.alive?(pid)
  end

  test "init is lightweight and defers restore to handle_continue" do
    assert {:ok, state, {:continue, :restore_snapshots}} =
             HotStateAggregator.init(
               event_aggregator: EventSales.TestSupport.Analytics.ErrorEventAggregator
             )

    assert state.lifecycle == :warming
    assert state.rebuild_in_flight? == false
  end

  test "Redis snapshot restore populates DashboardCache and transitions ready", %{event: event} do
    summary =
      summary(%{
        total_sold: 4,
        total_revenue: Decimal.new("1200.00"),
        updated_at: DateTime.utc_now()
      })

    assert :ok = MemorySnapshotStoreAdapter.put(CacheKeys.redis_event_snapshot(event.id), summary)

    restart_hot_state_aggregator!()

    assert {:ok, %{total_sold: 4}} = HotStateAggregator.summary_for_event(event.id)
    assert %{state: :ready, restored_snapshot_count: 1} = HotStateAggregator.status()
    assert count_rebuild_jobs() == 0
  end

  test "malformed snapshots are skipped and restore remains bounded", %{event: event} do
    valid_summary = summary(%{total_sold: 2, updated_at: DateTime.utc_now()})

    for index <- 1..3 do
      key = CacheKeys.redis_event_snapshot("00000000-0000-0000-0000-00000000000#{index}")
      MemorySnapshotStoreAdapter.put_raw_snapshot_for_test!(key, "{")
    end

    assert :ok =
             MemorySnapshotStoreAdapter.put(
               CacheKeys.redis_event_snapshot(event.id),
               valid_summary
             )

    original = Application.get_env(:event_sales, :hot_state_aggregator)
    put_hot_state_config!(restore_max_snapshots: 4)

    try do
      restart_hot_state_aggregator!()

      assert :miss = HotStateAggregator.summary_for_event("00000000-0000-0000-0000-000000000001")
      assert {:ok, %{total_sold: 2}} = HotStateAggregator.summary_for_event(event.id)
      assert %{restored_snapshot_count: 1} = HotStateAggregator.status()
      assert Keyword.fetch!(MemorySnapshotStoreAdapter.last_list_opts(), :max_snapshots) == 4
    after
      Application.put_env(:event_sales, :hot_state_aggregator, original)
    end
  end

  test "missing snapshots schedule exactly one rebuild" do
    MemorySnapshotStoreAdapter.reset!()
    original = Application.get_env(:event_sales, :hot_state_aggregator)
    put_hot_state_config!(schedule_rebuild_on_boot?: true)

    try do
      restart_hot_state_aggregator!()

      assert %{state: :warming, rebuild_in_flight?: true} = HotStateAggregator.status()
      assert count_rebuild_jobs() == 1
    after
      Application.put_env(:event_sales, :hot_state_aggregator, original)
    end
  end

  test "repeated rebuild request is single-flight" do
    assert :ok = HotStateAggregator.request_rebuild(:manual_refresh)
    assert :already_running = HotStateAggregator.request_rebuild(:manual_refresh)

    assert count_rebuild_jobs() == 1
    assert %{rebuild_in_flight?: true} = HotStateAggregator.status()
  end

  test "restored summaries older than stale_after_ms report stale", %{event: event} do
    old_summary = summary(%{updated_at: DateTime.add(DateTime.utc_now(), -600, :second)})

    assert :ok =
             MemorySnapshotStoreAdapter.put(CacheKeys.redis_event_snapshot(event.id), old_summary)

    restart_hot_state_aggregator!()

    assert %{state: :stale, restored_snapshot_count: 1} = HotStateAggregator.status()
  end

  test "recomputes durable summary, writes hot and warm cache, and broadcasts", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    create_completed_sale!(source, event, ticket, %{
      quantity: 2,
      line_total: Decimal.new("900.00")
    })

    Phoenix.PubSub.subscribe(EventSales.PubSub, "analytics:event:#{event.id}")

    assert :ok = HotStateAggregator.apply_event(aggregate_event(event))

    assert {:ok, summary} = HotStateAggregator.summary_for_event(event.id)
    assert summary.total_sold == 2
    assert summary.total_revenue == Decimal.new("900.00")
    assert %DateTime{} = summary.updated_at

    assert [%{key: key, summary: warm_summary}] = MemorySnapshotStoreAdapter.writes()
    assert key == "eventsales:analytics:hot_state:v1:event:#{event.id}:summary"
    assert warm_summary.total_sold == 2

    assert_receive {:hot_state_updated, event_id, %DateTime{}}, 500
    assert event_id == event.id
  end

  test "recompute error writes no cache, no snapshot, and broadcasts nothing", %{event: event} do
    event_id = event.id
    Phoenix.PubSub.subscribe(EventSales.PubSub, "analytics:event:#{event.id}")

    assert {:error, :db_unavailable} =
             HotStateAggregator.apply_event(aggregate_event(event),
               event_aggregator: EventSales.TestSupport.Analytics.ErrorEventAggregator
             )

    assert :miss = HotStateAggregator.summary_for_event(event.id)
    assert [] = MemorySnapshotStoreAdapter.writes()
    refute_receive {:hot_state_updated, ^event_id, _updated_at}, 100
  end

  test "snapshot adapter failure keeps ETS write, broadcasts, and emits telemetry", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    event_id = event.id

    create_completed_sale!(source, event, ticket, %{
      quantity: 1,
      line_total: Decimal.new("450.00")
    })

    MemorySnapshotStoreAdapter.fail_writes!(:redis_unavailable)
    Phoenix.PubSub.subscribe(EventSales.PubSub, "analytics:event:#{event.id}")

    handler_id = "hot-state-snapshot-failure-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      Telemetry.hot_state_snapshot_write(),
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = HotStateAggregator.apply_event(aggregate_event(event))

    assert {:ok, %{total_sold: 1}} = HotStateAggregator.summary_for_event(event.id)
    assert_receive {:hot_state_updated, ^event_id, %DateTime{}}, 500

    assert_receive {:telemetry, [:event_sales, :hot_state, :snapshot, :write], %{count: 1},
                    %{result: :error, reason: :redis_unavailable, source: :redis}},
                   500
  end

  test "noop snapshot adapter keeps disabled Redis quiet", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    event_id = event.id

    create_completed_sale!(source, event, ticket, %{
      quantity: 1,
      line_total: Decimal.new("450.00")
    })

    Phoenix.PubSub.subscribe(EventSales.PubSub, "analytics:event:#{event.id}")

    handler_id = "hot-state-noop-snapshot-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      Telemetry.hot_state_snapshot_write(),
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             HotStateAggregator.apply_event(aggregate_event(event),
               snapshot_adapter: EventSales.Analytics.SnapshotStore.NoopAdapter
             )

    assert {:ok, %{total_sold: 1}} = HotStateAggregator.summary_for_event(event.id)
    assert_receive {:hot_state_updated, ^event_id, %DateTime{}}, 500

    refute_receive {:telemetry, [:event_sales, :hot_state, :snapshot, :write], _measurements,
                    _metadata},
                   100
  end

  test "duplicate event does not double count", %{source: source, event: event, ticket: ticket} do
    create_completed_sale!(source, event, ticket, %{
      quantity: 2,
      line_total: Decimal.new("900.00")
    })

    aggregate_event = aggregate_event(event)

    assert :ok = HotStateAggregator.apply_event(aggregate_event)
    assert :ok = HotStateAggregator.apply_event(aggregate_event)

    assert {:ok, %{total_sold: 2}} = HotStateAggregator.summary_for_event(event.id)
    assert [_one_write] = MemorySnapshotStoreAdapter.writes()
  end

  test "does not create or mutate durable sales rows", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    order =
      create_completed_sale!(source, event, ticket, %{
        quantity: 1,
        line_total: Decimal.new("450.00")
      })

    order_count_before = Sales.Resources.Order |> Ash.read!(domain: Sales) |> length()
    item_count_before = Sales.Resources.OrderItem |> Ash.read!(domain: Sales) |> length()

    assert :ok = HotStateAggregator.apply_event(aggregate_event(event))

    order_count_after = Sales.Resources.Order |> Ash.read!(domain: Sales) |> length()
    item_count_after = Sales.Resources.OrderItem |> Ash.read!(domain: Sales) |> length()

    reloaded_order = Ash.get!(Sales.Resources.Order, order.id, domain: Sales)

    assert order_count_after == order_count_before
    assert item_count_after == item_count_before
    assert reloaded_order.updated_at == order.updated_at
  end

  defp aggregate_event(%Event{} = event) do
    %{
      aggregate_event_id: "agg-#{System.unique_integer([:positive])}",
      event_id: event.id,
      reason: :order_processed,
      occurred_at: ~U[2026-05-17 10:00:00Z],
      source_updated_at: ~U[2026-05-17 10:00:00Z],
      payload_hash: "payload-hash"
    }
  end

  defp summary(overrides) do
    %{
      total_sold: 0,
      total_revenue: Decimal.new("0"),
      today_sold: 0,
      today_revenue: Decimal.new("0"),
      status_breakdown: %{},
      updated_at: ~U[2026-05-17 10:00:00Z]
    }
    |> Map.merge(overrides)
  end

  defp restart_hot_state_aggregator! do
    :ok = Supervisor.terminate_child(EventSales.Supervisor, HotStateAggregator)
    {:ok, _pid} = Supervisor.restart_child(EventSales.Supervisor, HotStateAggregator)
    wait_until(fn -> HotStateAggregator.status().restore_finished? end)
  end

  defp wait_until(fun, attempts \\ 20)

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(25)
      wait_until(fun, attempts - 1)
    end
  end

  defp wait_until(_fun, 0), do: flunk("condition was not met before timeout")

  defp delete_rebuild_jobs! do
    import Ecto.Query

    Repo.delete_all(
      from job in Oban.Job,
        where: job.worker == "EventSales.Analytics.Workers.RebuildHotStateWorker"
    )
  end

  defp count_rebuild_jobs do
    import Ecto.Query

    Repo.aggregate(
      from(job in Oban.Job,
        where: job.worker == "EventSales.Analytics.Workers.RebuildHotStateWorker"
      ),
      :count
    )
  end

  defp put_hot_state_config!(overrides) do
    current = Application.get_env(:event_sales, :hot_state_aggregator, [])
    Application.put_env(:event_sales, :hot_state_aggregator, Keyword.merge(current, overrides))
  end

  defp create_completed_sale!(source, %Event{} = event, %TicketType{} = ticket, attrs) do
    order =
      Ash.create!(
        Order,
        %{
          source_system_id: source.id,
          woo_order_id: System.unique_integer([:positive]),
          order_number: "H-#{System.unique_integer([:positive])}",
          status: :completed,
          currency: "ZAR",
          completed_at: ~U[2026-05-17 08:00:00.000000Z],
          created_at_source: ~U[2026-05-17 07:00:00.000000Z],
          updated_at_source: ~U[2026-05-17 08:00:00.000000Z],
          raw_total: Decimal.new("0"),
          raw_discount_total: Decimal.new("0"),
          raw_tax_total: Decimal.new("0")
        },
        action: :create_normalized,
        domain: Sales
      )

    Ash.create!(
      OrderItem,
      %{
        order_id: order.id,
        event_id: event.id,
        ticket_type_id: ticket.id,
        woo_line_item_id: System.unique_integer([:positive]),
        woo_product_id: System.unique_integer([:positive]),
        woo_variation_id: nil,
        name: "Hot Ticket",
        quantity: Map.fetch!(attrs, :quantity),
        line_subtotal: Map.fetch!(attrs, :line_total),
        line_total: Map.fetch!(attrs, :line_total),
        discount_total: Decimal.new("0"),
        item_kind: :ticket,
        mapping_status: :mapped
      },
      action: :create_normalized,
      domain: Sales
    )

    order
  end
end
