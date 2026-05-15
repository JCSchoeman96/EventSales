defmodule EventSales.Ingestion.WebhookEnqueue do
  @moduledoc """
  Idempotent Oban enqueue for webhook processing jobs.
  """

  import Ecto.Query

  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Ingestion.Workers.ProcessWebhookWorker
  alias EventSales.Repo
  alias Oban.Job

  @active_states ~w(available scheduled executing retryable completed)

  @doc """
  Enqueues `ProcessWebhookWorker` at most once per `webhook_event_id`.
  """
  @spec enqueue_processing_once(WebhookEvent.t()) :: :ok | {:error, :enqueue_failed}
  def enqueue_processing_once(%WebhookEvent{id: webhook_event_id}) do
    if job_exists?(webhook_event_id) do
      :ok
    else
      case %{webhook_event_id: webhook_event_id}
           |> ProcessWebhookWorker.new()
           |> Oban.insert() do
        {:ok, %Job{conflict?: true}} -> :ok
        {:ok, %Job{}} -> :ok
        {:error, _reason} -> {:error, :enqueue_failed}
      end
    end
  end

  defp job_exists?(webhook_event_id) do
    worker = to_string(ProcessWebhookWorker)
    id = to_string(webhook_event_id)

    Repo.exists?(
      from(j in Job,
        where: j.worker == ^worker,
        where: j.state in ^@active_states,
        where: fragment("? @> ?", j.args, ^%{"webhook_event_id" => id})
      )
    )
  end
end
