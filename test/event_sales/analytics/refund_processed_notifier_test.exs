defmodule EventSales.Analytics.RefundProcessedNotifierTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Analytics.DashboardPubSub
  alias EventSales.Analytics.RefundProcessedNotifier
  alias EventSales.Analytics.Resources.EventSourceFreshnessSnapshot
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem, Refund}
  alias EventSales.Telemetry
  alias EventSales.TestSupport.SalesHelpers

  setup do
    Application.put_env(:event_sales, :refund_processed_notifier_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:event_sales, :refund_processed_notifier_test_pid)
    end)

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{name: "Refund Event", slug: unique_slug("refund")})

    other_event =
      SalesHelpers.create_event!(source, %{name: "Other Refund Event", slug: unique_slug("other")})

    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "VIP"})
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)

    %{
      source: source,
      event: event,
      other_event: other_event,
      ticket: ticket,
      other_ticket: other_ticket,
      order: order
    }
  end

  test "active refund with source-created time advances its bound order's mapped event", %{
    source: source,
    order: order,
    event: event,
    ticket: ticket
  } do
    source_created_at = ~U[2026-08-18 10:00:00.123456Z]
    refund = create_refund!(source, order, %{source_created_at: source_created_at})
    create_item!(order, event, ticket, 1)

    assert :ok = DashboardPubSub.subscribe_event(event.id)
    assert :ok = RefundProcessedNotifier.notify_refund_applied(refund)

    assert_receive {:source_freshness_updated, event_id}
    assert event_id == event.id
    assert {:ok, snapshot} = read_snapshot(event.id)
    assert snapshot.refund_source_watermark_at == source_created_at
  end

  test "multiple mapped ticket items for one event trigger one logical advance", %{
    source: source,
    order: order,
    event: event,
    ticket: ticket
  } do
    refund = create_refund!(source, order, %{source_created_at: ~U[2026-08-18 10:00:00Z]})
    create_item!(order, event, ticket, 2)
    create_item!(order, event, ticket, 3)

    assert :ok =
             RefundProcessedNotifier.notify_refund_applied(refund,
               source_freshness: __MODULE__.CountingSourceFreshness
             )

    assert_receive {:refund_source_advance, event_id, _source_created_at}
    assert event_id == event.id
    refute_receive {:refund_source_advance, _event_id, _source_created_at}, 0
  end

  test "distinct mapped events are each advanced once", %{
    source: source,
    order: order,
    event: event,
    other_event: other_event,
    ticket: ticket,
    other_ticket: other_ticket
  } do
    refund = create_refund!(source, order, %{source_created_at: ~U[2026-08-18 10:00:00Z]})
    create_item!(order, event, ticket, 4)
    create_item!(order, event, ticket, 5)
    create_item!(order, other_event, other_ticket, 6)

    assert :ok =
             RefundProcessedNotifier.notify_refund_applied(refund,
               source_freshness: __MODULE__.CountingSourceFreshness
             )

    received_event_ids =
      for _ <- 1..2 do
        assert_receive {:refund_source_advance, event_id, _source_created_at}
        event_id
      end

    assert Enum.sort(received_event_ids) == Enum.sort([event.id, other_event.id])
    refute_receive {:refund_source_advance, _event_id, _source_created_at}, 0
  end

  test "voided refund does not advance freshness", %{
    source: source,
    order: order,
    event: event,
    ticket: ticket
  } do
    refund =
      create_refund!(source, order, %{
        source_state: :voided,
        source_created_at: ~U[2026-08-18 10:00:00Z],
        voided_at: ~U[2026-08-18 11:00:00Z]
      })

    create_item!(order, event, ticket, 7)

    handler_id = telemetry_handler_id()
    attach_failure_handler(handler_id)
    assert :ok = RefundProcessedNotifier.notify_refund_applied(refund)
    assert {:ok, nil} = read_snapshot(event.id)
    refute_receive {:source_freshness_updated, _event_id}, 0
    refute_receive {:source_freshness_failure, _event, _measurements, _metadata}, 0
  end

  test "missing source-created time does not advance freshness", %{
    source: source,
    order: order,
    event: event,
    ticket: ticket
  } do
    refund = create_refund!(source, order, %{source_created_at: nil})
    create_item!(order, event, ticket, 8)

    handler_id = telemetry_handler_id()
    attach_failure_handler(handler_id)
    assert :ok = RefundProcessedNotifier.notify_refund_applied(refund)
    assert {:ok, nil} = read_snapshot(event.id)
    refute_receive {:source_freshness_updated, _event_id}, 0
    refute_receive {:source_freshness_failure, _event, _measurements, _metadata}, 0
  end

  test "unbound refund does not advance freshness", %{
    source: source,
    order: order,
    event: event,
    ticket: ticket
  } do
    refund =
      create_refund!(source, order, %{
        order_id: nil,
        source_created_at: ~U[2026-08-18 10:00:00Z]
      })

    create_item!(order, event, ticket, 9)

    handler_id = telemetry_handler_id()
    attach_failure_handler(handler_id)
    assert :ok = RefundProcessedNotifier.notify_refund_applied(refund)
    assert {:ok, nil} = read_snapshot(event.id)
    refute_receive {:source_freshness_updated, _event_id}, 0
    refute_receive {:source_freshness_failure, _event, _measurements, _metadata}, 0
  end

  test "zero mapped ticket events do not advance freshness", %{
    source: source,
    order: order,
    event: event,
    ticket: ticket
  } do
    refund = create_refund!(source, order, %{source_created_at: ~U[2026-08-18 10:00:00Z]})

    create_item!(order, event, ticket, 10, %{
      mapping_status: :pending_mapping_resolution,
      item_kind: :unknown
    })

    create_item!(order, event, ticket, 11, %{
      mapping_status: :non_ticket,
      item_kind: :non_ticket
    })

    handler_id = telemetry_handler_id()
    attach_failure_handler(handler_id)
    assert :ok = RefundProcessedNotifier.notify_refund_applied(refund)
    assert {:ok, nil} = read_snapshot(event.id)
    refute_receive {:source_freshness_updated, _event_id}, 0
    refute_receive {:refund_source_advance, _event_id, _source_created_at}, 0
    refute_receive {:source_freshness_failure, _event, _measurements, _metadata}, 0
  end

  test "projection errors emit low-cardinality telemetry and return ok", %{
    source: source,
    order: order,
    event: event,
    ticket: ticket
  } do
    refund = create_refund!(source, order, %{source_created_at: ~U[2026-08-18 10:00:00Z]})
    create_item!(order, event, ticket, 12)
    handler_id = telemetry_handler_id()
    attach_failure_handler(handler_id)

    assert :ok =
             RefundProcessedNotifier.notify_refund_applied(refund,
               source_freshness: __MODULE__.FailingSourceFreshness
             )

    assert_receive {:source_freshness_failure, [:event_sales, :source_freshness, :advance_failed],
                    %{count: 1}, metadata}

    assert metadata == %{
             component: :refund,
             source: :refund_sync,
             stage: :projection_write
           }

    refute_receive {:source_freshness_updated, _event_id}, 0
  end

  test "source-freshness exceptions are isolated and reported", %{
    source: source,
    order: order,
    event: event,
    ticket: ticket
  } do
    refund = create_refund!(source, order, %{source_created_at: ~U[2026-08-18 10:00:00Z]})
    create_item!(order, event, ticket, 13)
    handler_id = telemetry_handler_id()
    attach_failure_handler(handler_id)

    assert :ok =
             RefundProcessedNotifier.notify_refund_applied(refund,
               source_freshness: __MODULE__.RaisingSourceFreshness
             )

    assert_receive {:source_freshness_failure, [:event_sales, :source_freshness, :advance_failed],
                    %{count: 1}, metadata}

    assert metadata == %{
             component: :refund,
             source: :refund_sync,
             stage: :projection_write
           }
  end

  defmodule CountingSourceFreshness do
    @moduledoc false

    def advance_refund(event_id, source_created_at) do
      Application.fetch_env!(:event_sales, :refund_processed_notifier_test_pid)
      |> send({:refund_source_advance, event_id, source_created_at})

      :ok
    end
  end

  defmodule FailingSourceFreshness do
    @moduledoc false

    def advance_refund(_event_id, _source_created_at), do: {:error, :db_unavailable}
  end

  defmodule RaisingSourceFreshness do
    @moduledoc false

    def advance_refund(_event_id, _source_created_at), do: raise("projection unavailable")
  end

  defp create_refund!(source, %Order{} = order, overrides) do
    attrs =
      Map.merge(
        %{
          source_system_id: source.id,
          order_id: order.id,
          woo_order_id: order.woo_order_id,
          woo_refund_id: System.unique_integer([:positive]),
          source_state: :active,
          detail_status: :complete,
          source_created_at: ~U[2026-08-18 10:00:00Z]
        },
        Map.new(overrides)
      )

    Ash.create!(Refund, attrs, action: :create_normalized, domain: Sales)
  end

  defp create_item!(order, %Event{} = event, %TicketType{} = ticket, line_id, overrides \\ %{}) do
    defaults = %{
      order_id: order.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_line_item_id: line_id,
      woo_product_id: line_id + 100,
      woo_variation_id: nil,
      name: "Refund Ticket",
      quantity: 1,
      line_subtotal: Decimal.new("450.00"),
      line_total: Decimal.new("450.00"),
      discount_total: Decimal.new("0"),
      item_kind: :ticket,
      mapping_status: :mapped
    }

    Ash.create!(OrderItem, Map.merge(defaults, Map.new(overrides)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp read_snapshot(event_id) do
    EventSourceFreshnessSnapshot
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.read_one(domain: EventSales.Analytics)
  end

  defp attach_failure_handler(handler_id) do
    :telemetry.attach(
      handler_id,
      Telemetry.source_freshness_advance_failed(),
      fn event, measurements, metadata, pid ->
        send(pid, {:source_freshness_failure, event, measurements, metadata})
      end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp telemetry_handler_id do
    "refund-freshness-#{System.unique_integer([:positive])}"
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
