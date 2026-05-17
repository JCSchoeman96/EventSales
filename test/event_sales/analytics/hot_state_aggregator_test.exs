defmodule EventSales.Analytics.HotStateAggregatorTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.HotStateAggregator
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Sales
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
    event = SalesHelpers.create_event!(source, %{name: "Hot Event", slug: "hot-event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    %{source: source, event: event, ticket: ticket}
  end

  test "starts under supervision" do
    assert pid = Process.whereis(HotStateAggregator)
    assert Process.alive?(pid)
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
