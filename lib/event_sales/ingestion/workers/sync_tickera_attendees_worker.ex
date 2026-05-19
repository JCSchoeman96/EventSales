defmodule EventSales.Ingestion.Workers.SyncTickeraAttendeesWorker do
  @moduledoc """
  Oban worker that drives Tickera attendee sync for a `TickeraAttendeeSyncRun`.

  Fetches at most one Tickera page per job. Sync telemetry is emitted only by
  `EventSales.Ingestion.TickeraAttendeeSync`.
  """

  use Oban.Worker,
    queue: :tickera_sync,
    max_attempts: 25,
    unique: [
      period: :infinity,
      fields: [:args],
      keys: [:sync_run_id],
      states: ~w(available scheduled executing retryable)a
    ]

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraAttendeeSyncRun
  alias EventSales.Ingestion.TickeraAttendeeSync
  alias EventSales.Ingestion.TickeraAttendeeSyncRuns

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"sync_run_id" => sync_run_id}}) when is_binary(sync_run_id) do
    case load_run(sync_run_id) do
      :discard ->
        :discard

      {:error, reason} ->
        {:error, reason}

      {:ok, run} ->
        perform_loaded_run(run)
    end
  end

  def perform(%Oban.Job{args: _args}), do: :discard

  defp perform_loaded_run(run) do
    case check_future_paused(run) do
      {:snooze, seconds} ->
        {:snooze, seconds}

      :ok ->
        with {:ok, run} <- maybe_start_or_resume(run) do
          run
          |> TickeraAttendeeSync.run_step(worker_opts())
          |> handle_result()
        end
    end
  end

  defp load_run(sync_run_id) do
    case Ash.get(TickeraAttendeeSyncRun, sync_run_id, domain: Ingestion) do
      {:ok, %TickeraAttendeeSyncRun{status: status}}
      when status in [:completed, :failed, :cancelled] ->
        :discard

      {:ok, %TickeraAttendeeSyncRun{} = run} ->
        {:ok, run}

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        :discard

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_future_paused(%TickeraAttendeeSyncRun{status: :paused, paused_until: %DateTime{} = paused_until}) do
    snooze_if_future(paused_until)
  end

  defp check_future_paused(%TickeraAttendeeSyncRun{paused_until: %DateTime{} = paused_until}) do
    snooze_if_future(paused_until)
  end

  defp check_future_paused(_run), do: :ok

  defp snooze_if_future(paused_until) do
    seconds = DateTime.diff(paused_until, DateTime.utc_now(), :second)

    if seconds > 0 do
      {:snooze, max(seconds, 1)}
    else
      :ok
    end
  end

  defp maybe_start_or_resume(%TickeraAttendeeSyncRun{status: :queued} = run) do
    TickeraAttendeeSyncRuns.mark_started(run, internal?: true)
  end

  defp maybe_start_or_resume(%TickeraAttendeeSyncRun{status: :paused} = run) do
    TickeraAttendeeSyncRuns.mark_resumed(run, internal?: true)
  end

  defp maybe_start_or_resume(%TickeraAttendeeSyncRun{} = run), do: {:ok, run}

  defp handle_result({:pause, _run, _pause_reason, seconds}), do: {:snooze, seconds}

  defp handle_result({:continue, _run}), do: {:snooze, 1}

  defp handle_result({:complete, _run}), do: :ok

  defp handle_result({:error, {:failed, _run, _reason}}), do: :ok

  defp handle_result({:error, reason}), do: {:error, reason}

  defp worker_opts do
    [
      tickera_client:
        Application.get_env(
          :event_sales,
          :tickera_attendee_client,
          EventSales.Ingestion.Clients.TickeraAttendeeClient
        )
    ]
  end
end
