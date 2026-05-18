defmodule EventSales.Analytics.RefreshSnapshotWorkerTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.Resources.{DailySalesAggregateSnapshot, EventAggregateSnapshot}
  alias EventSales.Analytics.Workers.RefreshSnapshotWorker
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.Telemetry
  alias EventSales.TestSupport.SalesHelpers

  setup do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        name: "Worker Snapshot Event",
        slug: unique_slug("worker")
      })

    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    create_completed_sale!(source, event, ticket)
    %{source: source, event: event, ticket: ticket}
  end

  test "uses analytics rebuild queue and unique scope event date keys" do
    assert RefreshSnapshotWorker.__opts__() |> Keyword.fetch!(:queue) == :analytics_rebuilds
    assert RefreshSnapshotWorker.__opts__() |> Keyword.fetch!(:max_attempts) == 3

    unique = RefreshSnapshotWorker.__opts__() |> Keyword.fetch!(:unique)
    assert Keyword.fetch!(unique, :keys) == [:scope, :event_id, :business_date]
  end

  test "refreshes event snapshots for valid event args", %{event: event} do
    assert :ok =
             RefreshSnapshotWorker.perform(%Oban.Job{
               args: %{"scope" => "event", "event_id" => event.id}
             })

    assert {:ok, %EventAggregateSnapshot{total_sold: 1}} =
             Ash.read_one(EventAggregateSnapshot, domain: EventSales.Analytics)
  end

  test "refreshes daily snapshots for valid daily args", %{event: event} do
    assert :ok =
             RefreshSnapshotWorker.perform(%Oban.Job{
               args: %{
                 "scope" => "daily",
                 "event_id" => event.id,
                 "business_date" => "2026-05-17"
               }
             })

    assert {:ok, %DailySalesAggregateSnapshot{total_sold: 1}} =
             Ash.read_one(DailySalesAggregateSnapshot, domain: EventSales.Analytics)
  end

  test "discards invalid args" do
    assert :discard = RefreshSnapshotWorker.perform(%Oban.Job{args: %{"scope" => "daily"}})
    assert :discard = RefreshSnapshotWorker.perform(%Oban.Job{args: %{"scope" => "bogus"}})

    assert :discard =
             RefreshSnapshotWorker.perform(%Oban.Job{
               args: %{"scope" => "event", "event_id" => "not-a-uuid"}
             })

    assert :discard =
             RefreshSnapshotWorker.perform(%Oban.Job{
               args: %{
                 "scope" => "daily",
                 "event_id" => Ecto.UUID.generate(),
                 "business_date" => "not-a-date"
               }
             })
  end

  test "returns errors for retryable refresh failures and emits exception telemetry" do
    handler_id = "refresh-snapshot-worker-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      [Telemetry.snapshot_refresh_start(), Telemetry.snapshot_refresh_exception()],
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:error, _reason} =
             RefreshSnapshotWorker.perform(%Oban.Job{
               args: %{"scope" => "event", "event_id" => Ecto.UUID.generate()}
             })

    assert_receive {:telemetry, [:event_sales, :snapshots, :refresh, :start], %{count: 1},
                    %{scope: :event, source: :postgres}},
                   500

    assert_receive {:telemetry, [:event_sales, :snapshots, :refresh, :exception], %{count: 1},
                    %{scope: :event, source: :postgres}},
                   500
  end

  defp create_completed_sale!(source, %Event{} = event, %TicketType{} = ticket) do
    order =
      Ash.create!(
        Order,
        %{
          source_system_id: source.id,
          woo_order_id: System.unique_integer([:positive]),
          order_number: "RSW-#{System.unique_integer([:positive])}",
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
        name: "Snapshot Ticket",
        quantity: 1,
        line_subtotal: Decimal.new("450.00"),
        line_total: Decimal.new("450.00"),
        discount_total: Decimal.new("0"),
        item_kind: :ticket,
        mapping_status: :mapped
      },
      action: :create_normalized,
      domain: Sales
    )
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
