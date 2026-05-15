defmodule EventSales.Ingestion.Workers.ProcessWebhookWorker do
  @moduledoc """
  Async webhook processing entrypoint.

  Slice 5.0 enqueues only; Slice 6.0 implements order normalization and idempotency.
  """

  use Oban.Worker,
    queue: :webhooks,
    max_attempts: 3,
    unique: [
      period: 300,
      fields: [:args],
      keys: [:webhook_event_id],
      states: ~w(available scheduled executing retryable completed)a
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"webhook_event_id" => webhook_event_id}}) do
    case processor().process(webhook_event_id) do
      :ok -> :ok
      {:discard, :not_found} -> :discard
      {:error, {:transient, reason}} -> {:error, {:transient, reason}}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    base = trunc(:math.pow(2, max(attempt, 1))) * 15
    jitter = :rand.uniform(15)

    base + jitter
  end

  defp processor do
    Application.get_env(:event_sales, :webhook_processor, EventSales.Ingestion.WebhookProcessor)
  end
end
