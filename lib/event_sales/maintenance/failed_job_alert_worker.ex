defmodule EventSales.Maintenance.FailedJobAlertWorker do
  @moduledoc """
  Read-only failed Oban job alert foundation.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [
      period: 300,
      fields: [:worker],
      states: ~w(available scheduled executing retryable)a
    ]

  import Ecto.Query
  require Logger

  alias EventSales.Repo
  alias EventSales.Telemetry

  @default_threshold 1
  @default_stale_minutes 15

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    started_at = System.monotonic_time()

    with {:ok, threshold} <- positive_config(:failed_job_alert_threshold, @default_threshold),
         {:ok, stale_minutes} <-
           positive_config(:failed_job_alert_stale_after_minutes, @default_stale_minutes) do
      cutoff_at = DateTime.add(DateTime.utc_now(), -stale_minutes, :minute)

      Telemetry.emit(Telemetry.maintenance_failed_job_alert_start(), %{count: 1}, %{
        worker: :failed_job_alert_worker,
        cutoff_at: cutoff_at,
        threshold: threshold
      })

      discarded_count = count_state("discarded", cutoff_at)
      cancelled_count = count_state("cancelled", cutoff_at)
      reason = if discarded_count >= threshold, do: :threshold_exceeded, else: :below_threshold

      if reason == :threshold_exceeded do
        Logger.warning(
          "maintenance_failed_jobs_detected discarded_count=#{discarded_count} " <>
            "cancelled_count=#{cancelled_count} threshold=#{threshold}"
        )
      end

      Telemetry.emit(
        Telemetry.maintenance_failed_job_alert_stop(),
        %{count: discarded_count, duration: System.monotonic_time() - started_at},
        %{
          worker: :failed_job_alert_worker,
          cutoff_at: cutoff_at,
          affected_count: discarded_count,
          cancelled_count: cancelled_count,
          threshold: threshold,
          reason: reason
        }
      )

      :ok
    else
      {:error, reason} ->
        emit_exception(reason)
        {:error, reason}
    end
  rescue
    error ->
      emit_exception(error)
      {:error, error}
  end

  defp count_state(state, cutoff_at) do
    Oban.Job
    |> where([job], job.state == ^state)
    |> where(
      [job],
      (not is_nil(job.discarded_at) and job.discarded_at < ^cutoff_at) or
        (not is_nil(job.cancelled_at) and job.cancelled_at < ^cutoff_at) or
        (not is_nil(job.completed_at) and job.completed_at < ^cutoff_at) or
        (not is_nil(job.attempted_at) and job.attempted_at < ^cutoff_at)
    )
    |> Repo.aggregate(:count)
  end

  defp positive_config(key, default) do
    value =
      :event_sales
      |> Application.get_env(:maintenance, [])
      |> Keyword.get(key, default)

    if is_integer(value) and value > 0, do: {:ok, value}, else: {:error, {:invalid_config, key}}
  end

  defp emit_exception(reason) do
    Telemetry.emit(Telemetry.maintenance_failed_job_alert_exception(), %{count: 1}, %{
      worker: :failed_job_alert_worker,
      reason: low_cardinality_reason(reason)
    })
  end

  defp low_cardinality_reason({reason, _detail}) when is_atom(reason), do: reason
  defp low_cardinality_reason(%module{}), do: module
end
