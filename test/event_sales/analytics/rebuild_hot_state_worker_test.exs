defmodule EventSales.Analytics.RebuildHotStateWorkerTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.{DashboardCache, HotStateAggregator}
  alias EventSales.Analytics.Workers.RebuildHotStateWorker
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.Telemetry
  alias EventSales.TestSupport.Analytics.MemorySnapshotStoreAdapter
  alias EventSales.TestSupport.SalesHelpers

  setup do
    HotStateAggregator.reset_for_test!()
    MemorySnapshotStoreAdapter.reset!()

    on_exit(fn ->
      HotStateAggregator.reset_for_test!()
      MemorySnapshotStoreAdapter.reset!()
    end)

    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Worker Event", slug: "worker-event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    %{source: source, event: event, ticket: ticket}
  end

  test "uses analytics_rebuilds queue and active unique rebuild job" do
    assert RebuildHotStateWorker.__opts__() |> Keyword.fetch!(:queue) == :analytics_rebuilds

    unique = RebuildHotStateWorker.__opts__() |> Keyword.fetch!(:unique)
    assert Keyword.fetch!(unique, :keys) == [:scope]
    assert :executing in Keyword.fetch!(unique, :states)
  end

  test "writes summaries through DashboardCache and warm snapshot adapter from durable rows", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    create_completed_sale!(source, event, ticket, %{
      quantity: 2,
      line_total: Decimal.new("900.00")
    })

    assert :ok = perform()

    assert {:ok, %{total_sold: 2, total_revenue: total_revenue}} =
             DashboardCache.get_event_summary(event.id)

    assert total_revenue == Decimal.new("900.00")
    assert [%{summary: %{total_sold: 2}}] = MemorySnapshotStoreAdapter.writes()
    assert %{state: :ready, rebuild_in_flight?: false} = HotStateAggregator.status()
  end

  test "emits start stop and exception telemetry", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    create_completed_sale!(source, event, ticket, %{
      quantity: 1,
      line_total: Decimal.new("450.00")
    })

    handler_id = "rebuild-hot-state-worker-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      [
        Telemetry.hot_state_rebuild_start(),
        Telemetry.hot_state_rebuild_stop(),
        Telemetry.hot_state_rebuild_exception()
      ],
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = perform()

    assert_receive {:telemetry, [:event_sales, :hot_state, :rebuild, :start], %{count: 1},
                    %{source: :postgres}},
                   500

    assert_receive {:telemetry, [:event_sales, :hot_state, :rebuild, :stop],
                    %{duration: duration}, %{source: :postgres, result: :ok, rebuilt_count: 1}},
                   500

    assert is_integer(duration)

    EventSales.TestSupport.Analytics.SelectiveEventAggregator.reset!()

    EventSales.TestSupport.Analytics.SelectiveEventAggregator.fail_event!(
      event.id,
      :db_unavailable
    )

    original = Application.get_env(:event_sales, :hot_state_aggregator)

    Application.put_env(
      :event_sales,
      :hot_state_aggregator,
      Keyword.put(
        original,
        :event_aggregator,
        EventSales.TestSupport.Analytics.SelectiveEventAggregator
      )
    )

    try do
      assert :ok = perform()

      assert_receive {:telemetry, [:event_sales, :hot_state, :rebuild, :exception], %{count: 1},
                      %{source: :postgres, scope: :event, reason: :db_unavailable}},
                     500
    after
      Application.put_env(:event_sales, :hot_state_aggregator, original)
      EventSales.TestSupport.Analytics.SelectiveEventAggregator.reset!()
    end
  end

  test "continues across individual event summary failures and reports failed count", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    create_completed_sale!(source, event, ticket, %{
      quantity: 1,
      line_total: Decimal.new("450.00")
    })

    failed_event =
      SalesHelpers.create_event!(source, %{
        name: "Broken Worker Event",
        slug: "broken-worker-event"
      })

    failed_ticket = SalesHelpers.create_ticket_type!(failed_event, %{name: "Broken GA"})

    create_completed_sale!(source, failed_event, failed_ticket, %{
      quantity: 1,
      line_total: Decimal.new("100.00")
    })

    EventSales.TestSupport.Analytics.SelectiveEventAggregator.reset!()

    EventSales.TestSupport.Analytics.SelectiveEventAggregator.fail_event!(
      failed_event.id,
      :db_unavailable
    )

    original = Application.get_env(:event_sales, :hot_state_aggregator)

    Application.put_env(
      :event_sales,
      :hot_state_aggregator,
      Keyword.put(
        original,
        :event_aggregator,
        EventSales.TestSupport.Analytics.SelectiveEventAggregator
      )
    )

    try do
      assert :ok = perform()

      assert {:ok, %{total_sold: 1}} = DashboardCache.get_event_summary(event.id)
      assert :miss = DashboardCache.get_event_summary(failed_event.id)

      assert %{state: :stale, last_failure: :partial_rebuild} = HotStateAggregator.status()
    after
      Application.put_env(:event_sales, :hot_state_aggregator, original)
      EventSales.TestSupport.Analytics.SelectiveEventAggregator.reset!()
    end
  end

  defp perform do
    RebuildHotStateWorker.perform(%Oban.Job{args: %{"scope" => "hot_state"}})
  end

  defp create_completed_sale!(source, %Event{} = event, %TicketType{} = ticket, attrs) do
    order =
      Ash.create!(
        Order,
        %{
          source_system_id: source.id,
          woo_order_id: System.unique_integer([:positive]),
          order_number: "R-#{System.unique_integer([:positive])}",
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
        domain: EventSales.Sales
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
      domain: EventSales.Sales
    )

    order
  end
end
