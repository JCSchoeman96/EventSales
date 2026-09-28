defmodule EventSales.Analytics.OrderProcessedNotifierTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Analytics.{
    DashboardCache,
    DashboardPubSub,
    HotStateAggregator,
    OrderProcessedNotifier
  }

  alias EventSales.Analytics.Resources.EventSourceFreshnessSnapshot

  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Ingestion.Resources.{SyncRun, WebhookEvent}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.Telemetry
  alias EventSales.TestSupport.SalesHelpers

  setup do
    HotStateAggregator.reset_for_test!()
    Application.put_env(:event_sales, :order_processed_notifier_test_pid, self())

    on_exit(fn ->
      HotStateAggregator.reset_for_test!()
      Application.delete_env(:event_sales, :order_processed_notifier_test_pid)
    end)

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{name: "Notifier Event", slug: unique_slug("notifier")})

    other_event =
      SalesHelpers.create_event!(source, %{name: "Other Event", slug: unique_slug("other")})

    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "VIP"})
    order = create_order!(source)

    %{
      source: source,
      event: event,
      other_event: other_event,
      ticket: ticket,
      other_ticket: other_ticket,
      order: order
    }
  end

  test "invalidates only affected event cache and applies hot state", %{
    order: order,
    event: event,
    other_event: other_event,
    ticket: ticket
  } do
    create_item!(order, event, ticket, %{woo_line_item_id: 1})

    assert :ok = DashboardCache.put_event_summary(event.id, summary(%{total_sold: 1}))
    assert :ok = DashboardCache.put_event_summary(other_event.id, summary(%{total_sold: 2}))

    assert :ok =
             OrderProcessedNotifier.notify_order_processed(order, webhook_event(order),
               hot_state_aggregator: __MODULE__.FakeHotState
             )

    assert :miss = DashboardCache.get_event_summary(event.id)
    assert {:ok, %{total_sold: 2}} = DashboardCache.get_event_summary(other_event.id)

    assert_receive {:apply_event,
                    %{
                      event_id: event_id,
                      reason: :order_processed,
                      source_system_id: source_system_id,
                      order_id: order_id,
                      payload_hash: "payload-hash"
                    }},
                   500

    assert event_id == event.id
    assert source_system_id == order.source_system_id
    assert order_id == order.id
  end

  test "applies hot state once per distinct mapped ticket event", %{
    order: order,
    event: event,
    other_event: other_event,
    ticket: ticket,
    other_ticket: other_ticket
  } do
    create_item!(order, event, ticket, %{woo_line_item_id: 1})
    create_item!(order, event, ticket, %{woo_line_item_id: 2})
    create_item!(order, other_event, other_ticket, %{woo_line_item_id: 3})

    assert :ok =
             OrderProcessedNotifier.notify_order_processed(order, webhook_event(order),
               hot_state_aggregator: __MODULE__.FakeHotState
             )

    assert_receive {:apply_event, %{event_id: first_event_id}}, 500
    assert_receive {:apply_event, %{event_id: second_event_id}}, 500
    refute_receive {:apply_event, _attrs}, 100

    assert Enum.sort([first_event_id, second_event_id]) == Enum.sort([event.id, other_event.id])
  end

  test "unmapped and non-ticket-only orders do not trigger hot-state apply", %{
    order: order,
    event: event,
    ticket: ticket
  } do
    create_item!(order, event, ticket, %{
      woo_line_item_id: 1,
      mapping_status: :pending_mapping_resolution,
      item_kind: :unknown
    })

    create_item!(order, event, ticket, %{
      woo_line_item_id: 2,
      mapping_status: :non_ticket,
      item_kind: :non_ticket
    })

    assert :ok =
             OrderProcessedNotifier.notify_order_processed(order, webhook_event(order),
               hot_state_aggregator: __MODULE__.FakeHotState
             )

    refute_receive {:apply_event, _attrs}, 100
  end

  test "notifier does not broadcast directly", %{order: order, event: event, ticket: ticket} do
    create_item!(order, event, ticket, %{woo_line_item_id: 1})
    DashboardPubSub.subscribe_event(event.id)

    assert :ok =
             OrderProcessedNotifier.notify_order_processed(order, webhook_event(order),
               hot_state_aggregator: __MODULE__.FakeHotState
             )

    refute_receive {:hot_state_updated, _event_id, _updated_at}, 100
  end

  test "source-applied notification advances each mapped ticket event using the order source clock",
       %{
         source: source,
         event: event,
         other_event: other_event,
         ticket: ticket,
         other_ticket: other_ticket
       } do
    watermark = ~U[2026-05-17 08:23:41.123456Z]
    order = create_order!(source, %{updated_at_source: watermark})
    create_item!(order, event, ticket, %{woo_line_item_id: 11})
    create_item!(order, other_event, other_ticket, %{woo_line_item_id: 12})

    assert :ok = DashboardPubSub.subscribe_event(event.id)
    assert :ok = DashboardPubSub.subscribe_event(other_event.id)

    assert :ok = OrderProcessedNotifier.notify_order_source_applied(order)

    received_event_ids =
      for _ <- 1..2 do
        assert_receive {:source_freshness_updated, event_id}, 500
        event_id
      end

    assert Enum.sort(received_event_ids) == Enum.sort([event.id, other_event.id])

    for event_id <- [event.id, other_event.id] do
      assert {:ok, snapshot} = read_freshness_snapshot(event_id)
      assert snapshot.order_source_watermark_at == watermark
    end

    refute_receive {:source_freshness_updated, _event_id}, 0
  end

  test "multiple line items for one event advance that event once", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    event_id = event.id
    watermark = ~U[2026-05-17 08:23:41.123456Z]
    order = create_order!(source, %{updated_at_source: watermark})
    create_item!(order, event, ticket, %{woo_line_item_id: 21})
    create_item!(order, event, ticket, %{woo_line_item_id: 22})

    assert :ok =
             OrderProcessedNotifier.notify_order_source_applied(order,
               source_freshness: __MODULE__.CountingSourceFreshness
             )

    assert_receive {:order_source_advance, ^event_id, ^watermark}, 500
    refute_receive {:order_source_advance, _event_id, _watermark}, 0
  end

  test "duplicate source-applied notifier calls leave the projection unchanged", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    event_id = event.id
    watermark = ~U[2026-05-17 08:23:41.123456Z]
    order = create_order!(source, %{updated_at_source: watermark})
    create_item!(order, event, ticket, %{woo_line_item_id: 31})
    assert :ok = DashboardPubSub.subscribe_event(event_id)

    assert :ok = OrderProcessedNotifier.notify_order_source_applied(order)
    assert_receive {:source_freshness_updated, ^event_id}, 500
    assert {:ok, first_snapshot} = read_freshness_snapshot(event_id)

    assert :ok = OrderProcessedNotifier.notify_order_source_applied(order)
    assert {:ok, replayed_snapshot} = read_freshness_snapshot(event_id)

    assert replayed_snapshot.order_source_watermark_at == first_snapshot.order_source_watermark_at
    assert replayed_snapshot.projection_refreshed_at == first_snapshot.projection_refreshed_at
    refute_receive {:source_freshness_updated, _event_id}, 0
  end

  test "reconciliation advances only its supplied event id", %{
    source: source,
    event: event,
    other_event: other_event,
    other_ticket: other_ticket
  } do
    event_id = event.id
    watermark = ~U[2026-05-17 08:23:41.123456Z]
    order = create_order!(source, %{updated_at_source: watermark})
    create_item!(order, other_event, other_ticket, %{woo_line_item_id: 41})
    sync_run = %SyncRun{id: Ecto.UUID.generate()}
    assert :ok = DashboardPubSub.subscribe_event(event_id)
    assert :ok = DashboardPubSub.subscribe_event(other_event.id)

    assert :ok =
             OrderProcessedNotifier.notify_order_reconciled(order, sync_run, event_id,
               test_pid: self(),
               hot_state_aggregator: __MODULE__.FakeHotState
             )

    assert_receive {:source_freshness_updated, received_event_id}, 500
    assert received_event_id == event.id
    refute_receive {:source_freshness_updated, _event_id}, 0
    assert_receive {:notify_order_reconciled, order_id, sync_run_id, ^event_id}, 500
    assert order_id == order.id
    assert sync_run_id == sync_run.id
    assert_receive {:apply_event, %{event_id: applied_event_id}}, 500
    assert applied_event_id == event.id

    assert {:ok, target_snapshot} = read_freshness_snapshot(event.id)
    assert target_snapshot.order_source_watermark_at == watermark
    assert {:ok, nil} = read_freshness_snapshot(other_event.id)
  end

  test "source projection failure emits bounded telemetry and leaves freshness missing", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    order = create_order!(source, %{updated_at_source: ~U[2026-05-17 08:23:41.123456Z]})
    create_item!(order, event, ticket, %{woo_line_item_id: 51})
    assert :ok = DashboardPubSub.subscribe_event(event.id)

    handler_id = "source-freshness-failure-#{System.unique_integer([:positive])}"
    test_pid = self()
    failure_event = [:event_sales, :source_freshness, :advance_failed]

    :ok =
      :telemetry.attach(
        handler_id,
        failure_event,
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:source_freshness_failure, event_name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             OrderProcessedNotifier.notify_order_source_applied(order,
               source_freshness: __MODULE__.FailingSourceFreshness
             )

    assert_receive {:source_freshness_failure, ^failure_event, %{count: 1}, metadata}, 500
    assert metadata == %{component: :order, source: :webhook, stage: :projection_write}
    assert failure_event in Telemetry.event_names()
    assert {:ok, nil} = read_freshness_snapshot(event.id)
    refute_receive {:source_freshness_updated, _event_id}, 0
  end

  test "hot-state apply failure is non-fatal and emits bounded telemetry", %{
    order: order,
    event: event,
    ticket: ticket
  } do
    create_item!(order, event, ticket, %{woo_line_item_id: 1})

    handler_id = "notifier-failure-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        Telemetry.hot_state_event_ignored(),
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry, event_name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             OrderProcessedNotifier.notify_order_processed(order, webhook_event(order),
               hot_state_aggregator: __MODULE__.FailingHotState
             )

    assert_receive {:telemetry, [:event_sales, :hot_state, :event, :ignored], %{count: 1},
                    %{
                      reason: :notifier_apply_failed,
                      event_reason: :order_processed,
                      result: :ignored,
                      source: :webhook
                    }},
                   500
  end

  defmodule FakeHotState do
    @moduledoc false

    def apply_event(attrs) do
      :event_sales
      |> Application.fetch_env!(:order_processed_notifier_test_pid)
      |> send({:apply_event, attrs})

      :ok
    end
  end

  defmodule FailingHotState do
    @moduledoc false

    def apply_event(_attrs), do: {:error, :db_unavailable}
  end

  defmodule FailingSourceFreshness do
    @moduledoc false

    def advance_order(_event_id, _watermark), do: {:error, :db_unavailable}
  end

  defmodule CountingSourceFreshness do
    @moduledoc false

    def advance_order(event_id, watermark) do
      :event_sales
      |> Application.fetch_env!(:order_processed_notifier_test_pid)
      |> send({:order_source_advance, event_id, watermark})

      :ok
    end
  end

  defp create_order!(source, overrides \\ %{}) do
    Ash.create!(
      Order,
      Map.merge(
        %{
          source_system_id: source.id,
          woo_order_id: System.unique_integer([:positive]),
          order_number: "N-#{System.unique_integer([:positive])}",
          status: :completed,
          currency: "ZAR",
          completed_at: ~U[2026-05-17 08:00:00.000000Z],
          created_at_source: ~U[2026-05-17 07:00:00.000000Z],
          updated_at_source: ~U[2026-05-17 08:00:00.000000Z],
          raw_total: Decimal.new("0"),
          raw_discount_total: Decimal.new("0"),
          raw_tax_total: Decimal.new("0")
        },
        Map.new(overrides)
      ),
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
      name: "Notifier Ticket",
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

  defp webhook_event(order) do
    %WebhookEvent{
      id: Ecto.UUID.generate(),
      source_system_id: order.source_system_id,
      resource_id: Integer.to_string(order.woo_order_id),
      payload_hash: "payload-hash",
      source_updated_at: ~U[2026-05-17 08:00:00.000000Z]
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

  defp read_freshness_snapshot(event_id) do
    EventSourceFreshnessSnapshot
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.read_one(domain: EventSales.Analytics)
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
