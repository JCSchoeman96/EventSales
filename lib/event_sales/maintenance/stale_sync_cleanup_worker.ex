defmodule EventSales.Maintenance.StaleSyncCleanupWorker do
  @moduledoc """
  Fails stale reconciliation sync runs without retrying or calling external APIs.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 2,
    unique: [
      period: 300,
      fields: [:worker],
      states: ~w(available scheduled executing retryable)a
    ]

  require Ash.Query
  import Ash.Expr

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Telemetry

  @default_running_minutes 60
  @default_paused_hours 24
  @default_batch_size 100

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when is_map(args) do
    started_at = System.monotonic_time()

    with {:ok, now} <- now_from_args(args),
         {:ok, running_minutes} <-
           positive_config(:running_sync_stale_after_minutes, @default_running_minutes),
         {:ok, paused_hours} <-
           positive_config(:paused_sync_stale_after_hours, @default_paused_hours),
         {:ok, batch_size} <- positive_config(:stale_sync_cleanup_batch_size, @default_batch_size) do
      running_cutoff_at = DateTime.add(now, -running_minutes, :minute)
      paused_cutoff_at = DateTime.add(now, -paused_hours, :hour)

      start_metadata = %{
        worker: :stale_sync_cleanup_worker,
        running_cutoff_at: running_cutoff_at,
        paused_cutoff_at: paused_cutoff_at,
        batch_size: batch_size
      }

      Telemetry.emit(
        Telemetry.maintenance_stale_sync_cleanup_start(),
        %{count: 1},
        start_metadata
      )

      case cleanup(running_cutoff_at, paused_cutoff_at, batch_size) do
        {:ok, %{running_count: running_count, paused_count: paused_count}} ->
          affected_count = running_count + paused_count

          Telemetry.emit(
            Telemetry.maintenance_stale_sync_cleanup_stop(),
            %{count: affected_count, duration: System.monotonic_time() - started_at},
            Map.merge(start_metadata, %{
              affected_count: affected_count,
              running_count: running_count,
              paused_count: paused_count
            })
          )

          :ok

        {:error, reason} ->
          emit_exception(reason, start_metadata)
          {:error, reason}
      end
    else
      {:error, reason} ->
        emit_exception(reason, %{worker: :stale_sync_cleanup_worker})
        {:error, reason}
    end
  rescue
    error ->
      emit_exception(error, %{worker: :stale_sync_cleanup_worker})
      {:error, error}
  end

  def perform(%Oban.Job{}), do: :discard

  defp cleanup(running_cutoff_at, paused_cutoff_at, batch_size) do
    with {:ok, running_count} <- fail_running(running_cutoff_at, batch_size),
         {:ok, paused_count} <- fail_paused(paused_cutoff_at, max(batch_size - running_count, 0)) do
      {:ok, %{running_count: running_count, paused_count: paused_count}}
    end
  end

  defp fail_running(_cutoff_at, 0), do: {:ok, 0}

  defp fail_running(cutoff_at, limit) do
    SyncRun
    |> Ash.Query.filter(expr(status == :running and started_at < ^cutoff_at))
    |> Ash.Query.sort(started_at: :asc, id: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.read(domain: Ingestion)
    |> update_runs(:fail, "maintenance_stale_running_sync")
  end

  defp fail_paused(_cutoff_at, 0), do: {:ok, 0}

  defp fail_paused(cutoff_at, limit) do
    SyncRun
    |> Ash.Query.filter(expr(status == :paused and updated_at < ^cutoff_at))
    |> Ash.Query.sort(updated_at: :asc, id: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.read(domain: Ingestion)
    |> update_runs(:fail_paused, "maintenance_stale_paused_sync")
  end

  defp update_runs({:ok, runs}, action, last_error) do
    Enum.reduce_while(runs, {:ok, 0}, fn run, {:ok, count} ->
      case Ash.update(run, %{last_error: last_error}, action: action, domain: Ingestion) do
        {:ok, _run} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp update_runs({:error, reason}, _action, _last_error), do: {:error, reason}

  defp now_from_args(%{"now" => now}) when is_binary(now) do
    case DateTime.from_iso8601(now) do
      {:ok, now, _offset} -> {:ok, now}
      {:error, _reason} -> {:error, :invalid_now}
    end
  end

  defp now_from_args(_args), do: {:ok, DateTime.utc_now()}

  defp positive_config(key, default) do
    value =
      :event_sales
      |> Application.get_env(:maintenance, [])
      |> Keyword.get(key, default)

    if is_integer(value) and value > 0, do: {:ok, value}, else: {:error, {:invalid_config, key}}
  end

  defp emit_exception(reason, metadata) do
    Telemetry.emit(Telemetry.maintenance_stale_sync_cleanup_exception(), %{count: 1}, %{
      worker: Map.get(metadata, :worker, :stale_sync_cleanup_worker),
      running_cutoff_at: Map.get(metadata, :running_cutoff_at),
      paused_cutoff_at: Map.get(metadata, :paused_cutoff_at),
      batch_size: Map.get(metadata, :batch_size),
      reason: low_cardinality_reason(reason)
    })
  end

  defp low_cardinality_reason(reason) when is_atom(reason), do: reason
  defp low_cardinality_reason({reason, _detail}) when is_atom(reason), do: reason
  defp low_cardinality_reason(%module{}), do: module
  defp low_cardinality_reason(_reason), do: :error
end
