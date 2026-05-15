defmodule EventSales.Ingestion.WebhookEnqueueTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  import Ecto.Query

  alias EventSales.Ingestion.WebhookEnqueue
  alias EventSales.Ingestion.WebhookEventStore
  alias EventSales.Ingestion.Workers.ProcessWebhookWorker
  alias EventSales.TestSupport.SalesHelpers

  setup do
    from(j in Oban.Job) |> EventSales.Repo.delete_all()

    source = SalesHelpers.create_source_system!()
    {:ok, event} = WebhookEventStore.create_receive(base_attrs(source))
    {:ok, event: event}
  end

  test "enqueue_processing_once inserts a single job", %{event: event} do
    assert :ok = WebhookEnqueue.enqueue_processing_once(event)
    assert_enqueued(worker: ProcessWebhookWorker, args: %{"webhook_event_id" => event.id})
    assert length(process_webhook_jobs(event.id)) == 1
  end

  test "enqueue_processing_once is idempotent", %{event: event} do
    assert :ok = WebhookEnqueue.enqueue_processing_once(event)
    assert :ok = WebhookEnqueue.enqueue_processing_once(event)
    assert length(process_webhook_jobs(event.id)) == 1
  end

  defp process_webhook_jobs(event_id) do
    all_enqueued(worker: ProcessWebhookWorker)
    |> Enum.filter(&(&1.args["webhook_event_id"] == event_id))
  end

  defp base_attrs(source) do
    now = DateTime.utc_now()

    %{
      source_system_id: source.id,
      topic: "order.updated",
      resource_type: "order",
      resource_id: "10_001",
      delivery_id: "delivery-#{System.unique_integer([:positive])}",
      payload: %{"id" => 10_001},
      payload_hash: "abc123",
      raw_body_size: 42,
      signature_validated_at: now,
      received_at: now,
      sanitized_headers_snapshot: %{}
    }
  end
end
