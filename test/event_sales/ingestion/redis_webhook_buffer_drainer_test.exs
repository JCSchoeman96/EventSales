defmodule EventSales.Ingestion.RedisWebhookBufferDrainerTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  import Ecto.Query

  alias EventSales.Ingestion
  alias EventSales.Ingestion.RedisWebhookBuffer
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Ingestion.Workers.{ProcessWebhookWorker, RedisWebhookBufferDrainer}
  alias EventSales.Telemetry
  alias EventSales.TestSupport.FixtureHelpers
  alias EventSales.TestSupport.Ingestion.MemoryWebhookBufferAdapter
  alias EventSales.TestSupport.SalesHelpers
  alias EventSales.TestSupport.WooCommerceWebhookHelpers

  @secret "slice_1_5_webhook_secret"

  setup do
    from(j in Oban.Job) |> EventSales.Repo.delete_all()

    MemoryWebhookBufferAdapter.reset!()
    on_exit(fn -> MemoryWebhookBufferAdapter.reset!() end)
    source = SalesHelpers.create_source_system!()
    {:ok, source: source}
  end

  test "drains buffered entry to postgres and enqueues once", %{source: source} do
    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    delivery_id = unique_delivery_id()
    encoded = buffer_entry(source, raw_body, delivery_id)

    assert :ok = MemoryWebhookBufferAdapter.push(encoded)
    assert :ok = RedisWebhookBufferDrainer.perform(%Oban.Job{args: %{}})

    assert [
             %{
               accepted_via: :redis_buffer,
               delivery_id: ^delivery_id,
               status: :queued,
               id: event_id
             }
           ] =
             Ash.read!(WebhookEvent, domain: Ingestion)

    assert_enqueued(worker: ProcessWebhookWorker, args: %{"webhook_event_id" => event_id})
    assert length(process_webhook_jobs()) == 1
    assert RedisWebhookBuffer.depth() == 0
    assert RedisWebhookBuffer.processing_depth() == 0
  end

  test "duplicate drain is idempotent for events and jobs", %{source: source} do
    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    delivery_id = unique_delivery_id()
    encoded = buffer_entry(source, raw_body, delivery_id)

    assert :ok = MemoryWebhookBufferAdapter.push(encoded)
    assert :ok = RedisWebhookBufferDrainer.perform(%Oban.Job{args: %{}})
    assert :ok = RedisWebhookBufferDrainer.perform(%Oban.Job{args: %{}})

    assert length(Ash.read!(WebhookEvent, domain: Ingestion)) == 1
    assert length(process_webhook_jobs()) == 1
  end

  test "perform returns retry when ack fails and entry stays in processing", %{source: source} do
    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    delivery_id = unique_delivery_id()
    encoded = buffer_entry(source, raw_body, delivery_id)

    assert :ok = MemoryWebhookBufferAdapter.push(encoded)
    MemoryWebhookBufferAdapter.force_ack_unavailable!()

    handler_id = attach_backpressure_telemetry()

    assert {:error, :retry} = RedisWebhookBufferDrainer.perform(%Oban.Job{args: %{}})

    assert_receive {:telemetry_backpressure, %{count: 1},
                    %{reason: :ack_failed, adapter: adapter}}

    assert adapter == RedisWebhookBuffer.adapter_name()
    assert length(Ash.read!(WebhookEvent, domain: Ingestion)) == 1
    assert_enqueued(worker: ProcessWebhookWorker)
    assert RedisWebhookBuffer.depth() == 0
    assert RedisWebhookBuffer.processing_depth() == 1

    :telemetry.detach(handler_id)
  end

  test "enqueue once repairs missing job on duplicate drain", %{source: source} do
    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    delivery_id = unique_delivery_id()
    encoded = buffer_entry(source, raw_body, delivery_id)

    assert :ok = MemoryWebhookBufferAdapter.push(encoded)
    assert :ok = RedisWebhookBufferDrainer.perform(%Oban.Job{args: %{}})

    assert [%{id: event_id}] = Ash.read!(WebhookEvent, domain: Ingestion)

    assert length(process_webhook_jobs()) == 1

    EventSales.Repo.delete_all(Oban.Job)

    assert :ok = MemoryWebhookBufferAdapter.push(encoded)
    assert :ok = RedisWebhookBufferDrainer.perform(%Oban.Job{args: %{}})

    assert_enqueued(worker: ProcessWebhookWorker, args: %{"webhook_event_id" => event_id})
    assert length(process_webhook_jobs()) == 1
  end

  defp buffer_entry(source, raw_body, delivery_id) do
    headers =
      WooCommerceWebhookHelpers.signed_headers(raw_body,
        secret: @secret,
        delivery_id: delivery_id
      )

    payload = Jason.decode!(raw_body)
    incoming_hash = EventSales.Ingestion.Security.WebhookReplayGuard.payload_hash(raw_body)

    ctx = %{
      source_system: source,
      raw_body: raw_body,
      headers: headers,
      payload: payload,
      incoming_hash: incoming_hash,
      delivery_id: delivery_id,
      resource_type: "order",
      resource_id: to_string(payload["id"]),
      source_updated_at: nil
    }

    ctx
    |> RedisWebhookBuffer.entry_from_intake_context()
    |> Jason.encode!()
  end

  defp process_webhook_jobs do
    all_enqueued(worker: ProcessWebhookWorker)
  end

  defp unique_delivery_id do
    "delivery-#{System.unique_integer([:positive])}"
  end

  defp attach_backpressure_telemetry do
    handler_id = "webhook-drainer-backpressure-#{System.unique_integer()}"

    :ok =
      :telemetry.attach(
        handler_id,
        Telemetry.webhook_backpressure(),
        fn _event, measurements, metadata, _config ->
          send(self(), {:telemetry_backpressure, measurements, metadata})
        end,
        nil
      )

    handler_id
  end
end
