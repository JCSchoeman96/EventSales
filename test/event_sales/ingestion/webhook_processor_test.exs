defmodule EventSales.Ingestion.WebhookProcessorTest do
  use EventSales.DataCase, async: false

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Ingestion.WebhookEventStore
  alias EventSales.Ingestion.WebhookProcessor
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{CouponSnapshot, Order, OrderItem}
  alias EventSales.Telemetry
  alias EventSales.TestSupport.FixtureHelpers
  alias EventSales.TestSupport.SalesHelpers

  setup do
    source = SalesHelpers.create_source_system!()
    original_upserter = Application.get_env(:event_sales, :order_upserter)
    original_notifier = Application.get_env(:event_sales, :order_processed_notifier)
    Application.put_env(:event_sales, :webhook_processor_test_pid, self())

    on_exit(fn ->
      if original_upserter do
        Application.put_env(:event_sales, :order_upserter, original_upserter)
      else
        Application.delete_env(:event_sales, :order_upserter)
      end

      if original_notifier do
        Application.put_env(:event_sales, :order_processed_notifier, original_notifier)
      else
        Application.delete_env(:event_sales, :order_processed_notifier)
      end

      Application.delete_env(:event_sales, :webhook_processor_test_pid)
    end)

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

  test "default handler treats Ash validation upsert errors as permanent", %{source: source} do
    Application.put_env(:event_sales, :order_upserter, __MODULE__.InvalidUpserter)

    {:ok, event} =
      create_event(source, %{
        topic: "order.updated",
        payload: FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed),
        source_updated_at: ~U[2026-05-01 08:05:00Z]
      })

    assert :ok = WebhookProcessor.process(event.id)

    failed = reload!(event.id)
    assert failed.status == :failed
    assert failed.failed_at
    assert failed.processing_attempt_count == 1
    assert String.length(failed.error_message) <= 512
    assert failed.error_message =~ "InvalidAttribute"
  end

  test "default handler treats DB connection upsert errors as transient", %{source: source} do
    Application.put_env(:event_sales, :order_upserter, __MODULE__.TransientUpserter)

    {:ok, event} =
      create_event(source, %{
        topic: "order.updated",
        payload: FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed),
        source_updated_at: ~U[2026-05-01 08:05:00Z]
      })

    assert {:error, {:transient, %DBConnection.ConnectionError{}}} =
             WebhookProcessor.process(event.id)

    queued = reload!(event.id)
    assert queued.status == :queued
    assert queued.processing_attempt_count == 1
    refute queued.failed_at
    assert queued.error_message
  end

  test "default handler calls notifier after successful durable order upsert", %{source: source} do
    order = create_order!(source)
    Application.put_env(:event_sales, :order_upserter, __MODULE__.SuccessfulUpserter)
    Application.put_env(:event_sales, :order_processed_notifier, __MODULE__.Notifier)
    Application.put_env(:event_sales, :webhook_processor_test_order, order)

    {:ok, event} = create_event(source, %{topic: "order.updated"})

    assert :ok = WebhookProcessor.process(event.id)

    assert_receive {:notified, notified_order_id, notified_event_id}, 500
    assert notified_order_id == order.id
    assert notified_event_id == event.id

    processed = reload!(event.id)
    assert processed.status == :processed
  end

  test "default handler does not notify after stale noop", %{source: source} do
    Application.put_env(:event_sales, :order_upserter, __MODULE__.StaleNoopUpserter)
    Application.put_env(:event_sales, :order_processed_notifier, __MODULE__.Notifier)

    {:ok, event} = create_event(source, %{topic: "order.updated"})

    assert :ok = WebhookProcessor.process(event.id)

    refute_receive {:notified, _order_id, _event_id}, 100

    processed = reload!(event.id)
    assert processed.status == :processed
  end

  test "notifier failure does not prevent processed status", %{source: source} do
    order = create_order!(source)
    Application.put_env(:event_sales, :order_upserter, __MODULE__.SuccessfulUpserter)
    Application.put_env(:event_sales, :order_processed_notifier, __MODULE__.FailingNotifier)
    Application.put_env(:event_sales, :webhook_processor_test_order, order)

    handler_id = "webhook-processor-notifier-failure-#{System.unique_integer([:positive])}"
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

    {:ok, event} = create_event(source, %{topic: "order.updated"})

    assert :ok = WebhookProcessor.process(event.id)

    processed = reload!(event.id)
    assert processed.status == :processed
    assert processed.processed_at
    refute processed.failed_at

    assert_receive {:telemetry, [:event_sales, :hot_state, :event, :ignored], %{count: 1},
                    %{
                      reason: :notifier_failed,
                      event_reason: :order_processed,
                      result: :ignored,
                      source: :webhook
                    }},
                   500
  end

  test "missing event is discarded" do
    assert {:discard, :not_found} = WebhookProcessor.process(Ecto.UUID.generate())
  end

  defmodule InvalidUpserter do
    @moduledoc false

    def upsert_from_webhook_event(_event) do
      {:error,
       %Ash.Error.Invalid{
         errors: [
           %Ash.Error.Changes.InvalidAttribute{
             field: :quantity,
             message: String.duplicate("bad quantity ", 80)
           }
         ]
       }}
    end
  end

  defmodule TransientUpserter do
    @moduledoc false

    def upsert_from_webhook_event(_event) do
      {:error, %DBConnection.ConnectionError{message: "connection not available"}}
    end
  end

  defmodule SuccessfulUpserter do
    @moduledoc false

    def upsert_from_webhook_event(_event) do
      {:ok, Application.fetch_env!(:event_sales, :webhook_processor_test_order)}
    end
  end

  defmodule StaleNoopUpserter do
    @moduledoc false

    def upsert_from_webhook_event(_event), do: {:ok, :stale_noop}
  end

  defmodule Notifier do
    @moduledoc false

    def notify_order_processed(order, event) do
      :event_sales
      |> Application.fetch_env!(:webhook_processor_test_pid)
      |> send({:notified, order.id, event.id})

      :ok
    end
  end

  defmodule FailingNotifier do
    @moduledoc false

    def notify_order_processed(_order, _event), do: raise("notifier unavailable")
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

  defp create_order!(source) do
    Ash.create!(
      Order,
      %{
        source_system_id: source.id,
        woo_order_id: System.unique_integer([:positive]),
        order_number: "WP-#{System.unique_integer([:positive])}",
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
  end
end
