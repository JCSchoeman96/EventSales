defmodule EventSales.Ingestion.WebhookProcessorTest do
  use EventSales.DataCase, async: true

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Ingestion.WebhookEventStore
  alias EventSales.Ingestion.WebhookProcessor
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{CouponSnapshot, Order, OrderItem}
  alias EventSales.TestSupport.FixtureHelpers
  alias EventSales.TestSupport.SalesHelpers

  setup do
    source = SalesHelpers.create_source_system!()
    {:ok, source: source}
  end

  test "default handler normalizes a queued supported order event", %{source: source} do
    {:ok, event} =
      create_event(source, %{
        topic: "order.updated",
        resource_id: "10001",
        payload: FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed),
        source_updated_at: ~U[2026-05-01 08:05:00Z]
      })

    assert :ok = WebhookProcessor.process(event.id)

    processed = reload!(event.id)
    assert processed.status == :processed
    assert processed.processing_attempt_count == 1
    assert processed.processing_started_at
    assert processed.processed_at
    refute processed.failed_at
    refute processed.error_message
    refute processed.ignore_reason

    assert Ash.count!(Order, domain: Sales) == 1
    assert Ash.count!(OrderItem, domain: Sales) == 1
    assert Ash.count!(CouponSnapshot, domain: Sales) == 1
  end

  test "processing a terminal event again is a no-op", %{source: source} do
    {:ok, event} = create_event(source, %{topic: "order.updated"})
    assert :ok = WebhookProcessor.process(event.id, handler: fn _event -> :ok end)

    processed = reload!(event.id)

    assert :ok =
             WebhookProcessor.process(event.id,
               handler: fn _event -> flunk("terminal event is no-op") end
             )

    again = reload!(event.id)
    assert again.status == :processed
    assert again.processing_attempt_count == processed.processing_attempt_count
    assert again.processing_started_at == processed.processing_started_at
    assert again.processed_at == processed.processed_at
    assert again.failed_at == processed.failed_at
    assert again.ignore_reason == processed.ignore_reason
  end

  test "unsupported topics are ignored with an ignore reason", %{source: source} do
    {:ok, event} = create_event(source, %{topic: "product.updated"})

    assert :ok = WebhookProcessor.process(event.id)

    ignored = reload!(event.id)
    assert ignored.status == :ignored
    assert ignored.ignore_reason == :unsupported_topic
    assert ignored.processed_at
  end

  test "processed source resource hash duplicates are ignored", %{source: source} do
    attrs = %{
      topic: "order.updated",
      resource_id: "10001",
      payload_hash: "same-hash",
      source_updated_at: ~U[2026-05-01 08:05:00Z]
    }

    {:ok, first} = create_event(source, attrs)
    assert :ok = WebhookProcessor.process(first.id, handler: fn _event -> :ok end)

    {:ok, second} = create_event(source, Map.put(attrs, :delivery_id, unique_delivery_id()))

    assert :ok =
             WebhookProcessor.process(second.id,
               handler: fn _event -> flunk("duplicate event must not call handler") end
             )

    ignored = reload!(second.id)
    assert ignored.status == :ignored
    assert ignored.ignore_reason == :duplicate_resource_hash
  end

  test "queued or failed source resource hash matches do not cause duplicate ignore", %{
    source: source
  } do
    attrs = %{
      topic: "order.updated",
      resource_id: "10001",
      payload_hash: "same-hash",
      source_updated_at: ~U[2026-05-01 08:05:00Z]
    }

    {:ok, _queued} = create_event(source, attrs)

    {:ok, failed} = create_event(source, Map.put(attrs, :delivery_id, unique_delivery_id()))

    assert :ok =
             WebhookProcessor.process(failed.id,
               handler: fn _event -> {:error, {:permanent, "boom"}} end
             )

    {:ok, current} = create_event(source, Map.put(attrs, :delivery_id, unique_delivery_id()))
    assert :ok = WebhookProcessor.process(current.id, handler: fn _event -> :ok end)

    processed = reload!(current.id)
    assert processed.status == :processed
    refute processed.ignore_reason
  end

  test "older event is stale only when a processed newer source version exists", %{source: source} do
    newer_attrs = %{
      topic: "order.updated",
      resource_id: "10001",
      payload_hash: "newer-hash",
      source_updated_at: ~U[2026-05-01 08:10:00Z]
    }

    {:ok, newer} = create_event(source, newer_attrs)
    assert :ok = WebhookProcessor.process(newer.id, handler: fn _event -> :ok end)

    {:ok, older} =
      create_event(source, %{
        topic: "order.updated",
        resource_id: "10001",
        payload_hash: "older-hash",
        source_updated_at: ~U[2026-05-01 08:05:00Z]
      })

    assert :ok =
             WebhookProcessor.process(older.id,
               handler: fn _event -> flunk("stale event must not call handler") end
             )

    ignored = reload!(older.id)
    assert ignored.status == :ignored
    assert ignored.ignore_reason == :stale_source_version
  end

  test "queued newer source version does not make an older event stale", %{source: source} do
    {:ok, _queued_newer} =
      create_event(source, %{
        topic: "order.updated",
        resource_id: "10001",
        payload_hash: "newer-hash",
        source_updated_at: ~U[2026-05-01 08:10:00Z]
      })

    {:ok, older} =
      create_event(source, %{
        topic: "order.updated",
        resource_id: "10001",
        payload_hash: "older-hash",
        source_updated_at: ~U[2026-05-01 08:05:00Z]
      })

    assert :ok = WebhookProcessor.process(older.id, handler: fn _event -> :ok end)

    processed = reload!(older.id)
    assert processed.status == :processed
    refute processed.ignore_reason
  end

  test "permanent failures mark the event failed with bounded error_message", %{source: source} do
    {:ok, event} = create_event(source, %{topic: "order.updated"})
    long_reason = String.duplicate("failure-", 200)

    assert :ok =
             WebhookProcessor.process(event.id,
               handler: fn _event -> {:error, {:permanent, long_reason}} end
             )

    failed = reload!(event.id)
    assert failed.status == :failed
    assert failed.failed_at
    assert String.length(failed.error_message) == 512
  end

  test "transient failures return retryable error and leave event queued", %{source: source} do
    {:ok, event} = create_event(source, %{topic: "order.updated"})
    long_reason = String.duplicate("timeout-", 200)

    assert {:error, {:transient, ^long_reason}} =
             WebhookProcessor.process(event.id,
               handler: fn _event -> {:error, {:transient, long_reason}} end
             )

    queued = reload!(event.id)
    assert queued.status == :queued
    assert queued.processing_attempt_count == 1
    assert queued.processing_started_at
    assert String.length(queued.error_message) == 512
    refute queued.failed_at
  end

  test "missing event is discarded" do
    assert {:discard, :not_found} = WebhookProcessor.process(Ecto.UUID.generate())
  end

  defp create_event(source, attrs) do
    now = DateTime.utc_now()

    defaults = %{
      source_system_id: source.id,
      topic: "order.updated",
      resource_type: "order",
      resource_id: "10001",
      delivery_id: unique_delivery_id(),
      payload: %{"id" => 10_001},
      payload_hash: "hash-#{System.unique_integer([:positive])}",
      raw_body_size: 42,
      signature_validated_at: now,
      received_at: now,
      source_updated_at: ~U[2026-05-01 08:05:00Z],
      sanitized_headers_snapshot: %{}
    }

    WebhookEventStore.create_receive(Map.merge(defaults, attrs))
  end

  defp reload!(id) do
    WebhookEvent
    |> Ash.get!(id, domain: Ingestion)
  end

  defp unique_delivery_id do
    "delivery-#{System.unique_integer([:positive])}"
  end
end
