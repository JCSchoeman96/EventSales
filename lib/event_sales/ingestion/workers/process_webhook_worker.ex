defmodule EventSales.Ingestion.Workers.ProcessWebhookWorker do
  @moduledoc """
  Async webhook processing entrypoint.

  Slice 5.0 enqueues only; Slice 6.0 implements order normalization and idempotency.
  """

  use Oban.Worker, queue: :webhooks, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_event_id" => _webhook_event_id}}), do: :ok
end
