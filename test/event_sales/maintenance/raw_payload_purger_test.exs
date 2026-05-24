defmodule EventSales.Maintenance.RawPayloadPurgerTest do
  use EventSales.DataCase, async: false

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Ingestion.WebhookEventStore
  alias EventSales.Maintenance.RawPayloadPurger
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.Telemetry
  alias EventSales.TestSupport.SalesHelpers

  setup do
    original = Application.get_env(:event_sales, :maintenance)

    Application.put_env(:event_sales, :maintenance,
      raw_payload_retention_days: 90,
      raw_payload_purge_batch_size: 500
    )

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:event_sales, :maintenance)
        value -> Application.put_env(:event_sales, :maintenance, value)
      end
    end)

    %{source: SalesHelpers.create_source_system!()}
  end

  test "redacts old raw payloads and keeps metadata", %{source: source} do
    old_received_at = ~U[2026-01-01 00:00:00.000000Z]

    {:ok, event} =
      create_event(source, %{
        received_at: old_received_at,
        payload: %{"billing" => %{"email" => "private@example.test"}, "id" => 123},
        payload_hash: "hash-to-preserve",
        sanitized_headers_snapshot: %{"x-safe" => "present"}
      })

    assert {:ok, %{affected_count: 1, retention_days: 90, batch_size: 500}} =
             RawPayloadPurger.purge(now: ~U[2026-05-01 00:00:00.000000Z])

    updated = Ash.get!(WebhookEvent, event.id, domain: Ingestion)

    assert updated.payload["redacted"] == true
    assert updated.payload["redacted_reason"] == "raw_payload_retention"
    assert is_binary(updated.payload["redacted_at"])
    refute inspect(updated.payload) =~ "private@example.test"
    refute inspect(updated.payload) =~ "123"

    assert updated.payload_hash == "hash-to-preserve"
    assert updated.delivery_id == event.delivery_id
    assert updated.resource_type == event.resource_type
    assert updated.resource_id == event.resource_id
    assert updated.received_at == old_received_at
    assert updated.status == :queued
    assert updated.sanitized_headers_snapshot == %{"x-safe" => "present"}
  end

  test "keeps recent payloads", %{source: source} do
    {:ok, event} =
      create_event(source, %{
        received_at: ~U[2026-04-15 00:00:00.000000Z],
        payload: %{"billing" => %{"email" => "recent@example.test"}}
      })

    assert {:ok, %{affected_count: 0}} =
             RawPayloadPurger.purge(now: ~U[2026-05-01 00:00:00.000000Z])

    updated = Ash.get!(WebhookEvent, event.id, domain: Ingestion)
    assert updated.payload["billing"]["email"] == "recent@example.test"
  end

  test "purge is idempotent and does not re-redact already redacted payloads", %{source: source} do
    redacted_at = "2026-01-02T00:00:00Z"

    {:ok, event} =
      create_event(source, %{
        received_at: ~U[2026-01-01 00:00:00.000000Z],
        payload: %{
          "redacted" => true,
          "redacted_reason" => "raw_payload_retention",
          "redacted_at" => redacted_at
        }
      })

    assert {:ok, %{affected_count: 0}} =
             RawPayloadPurger.purge(now: ~U[2026-05-01 00:00:00.000000Z])

    assert Ash.get!(WebhookEvent, event.id, domain: Ingestion).payload["redacted_at"] ==
             redacted_at
  end

  test "does not delete or mutate normalized sales truth", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Maintenance", slug: "maintenance"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    order = create_order!(source)
    item = create_item!(order, event, ticket)

    {:ok, _webhook} =
      create_event(source, %{
        received_at: ~U[2026-01-01 00:00:00.000000Z],
        payload: %{"billing" => %{"email" => "sales-truth@example.test"}}
      })

    assert {:ok, %{affected_count: 1}} =
             RawPayloadPurger.purge(now: ~U[2026-05-01 00:00:00.000000Z])

    reloaded_order = Ash.get!(Order, order.id, domain: Sales)
    reloaded_item = Ash.get!(OrderItem, item.id, domain: Sales)

    assert reloaded_order.status == order.status
    assert reloaded_order.order_number == order.order_number
    assert reloaded_order.updated_at == order.updated_at
    assert reloaded_item.mapping_status == item.mapping_status
    assert reloaded_item.quantity == item.quantity
    assert reloaded_item.updated_at == item.updated_at
  end

  test "emits maintenance telemetry", %{source: source} do
    {:ok, _event} =
      create_event(source, %{
        received_at: ~U[2026-01-01 00:00:00.000000Z],
        payload: %{"billing" => %{"email" => "telemetry@example.test"}}
      })

    handler_id = "raw-payload-purger-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      [
        Telemetry.maintenance_raw_payload_purge_start(),
        Telemetry.maintenance_raw_payload_purge_stop()
      ],
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %{affected_count: 1}} =
             RawPayloadPurger.purge(now: ~U[2026-05-01 00:00:00.000000Z])

    assert_receive {:telemetry, [:event_sales, :maintenance, :raw_payload_purge, :start],
                    %{count: 1}, %{worker: :raw_payload_purger, retention_days: 90}},
                   500

    assert_receive {:telemetry, [:event_sales, :maintenance, :raw_payload_purge, :stop],
                    %{count: 1, duration: duration},
                    %{worker: :raw_payload_purger, affected_count: 1}},
                   500

    assert is_integer(duration)
  end

  defp create_event(source, attrs) do
    now = DateTime.utc_now()

    defaults = %{
      source_system_id: source.id,
      topic: "order.updated",
      resource_type: "order",
      resource_id: "10001",
      delivery_id: "maintenance-delivery-#{System.unique_integer([:positive])}",
      payload: %{"id" => 10_001},
      payload_hash: "maintenance-hash-#{System.unique_integer([:positive])}",
      raw_body_size: 42,
      signature_validated_at: now,
      received_at: now,
      source_updated_at: ~U[2026-05-01 08:05:00Z],
      sanitized_headers_snapshot: %{}
    }

    WebhookEventStore.create_receive(Map.merge(defaults, attrs))
  end

  defp create_order!(source) do
    Ash.create!(
      Order,
      %{
        source_system_id: source.id,
        woo_order_id: System.unique_integer([:positive]),
        order_number: "MNT-#{System.unique_integer([:positive])}",
        status: :completed,
        currency: "ZAR",
        completed_at: ~U[2026-05-17 08:00:00.000000Z],
        created_at_source: ~U[2026-05-17 07:00:00.000000Z],
        updated_at_source: ~U[2026-05-17 08:00:00.000000Z],
        raw_total: Decimal.new("450.00"),
        raw_discount_total: Decimal.new("0"),
        raw_tax_total: Decimal.new("0")
      },
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_item!(order, event, ticket) do
    Ash.create!(
      OrderItem,
      %{
        order_id: order.id,
        event_id: event.id,
        ticket_type_id: ticket.id,
        woo_line_item_id: System.unique_integer([:positive]),
        woo_product_id: System.unique_integer([:positive]),
        name: "Maintenance Ticket",
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
end
