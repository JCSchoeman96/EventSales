defmodule EventSales.Maintenance.CacheCleanupWorker do
  @moduledoc """
  No-op-safe maintenance cache cleanup foundation.

  V1 intentionally does not delete ETS/Redis keys or rebuild hot state because
  no production-owned broad cache cleanup API exists yet.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 1

  alias EventSales.Telemetry

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    started_at = System.monotonic_time()

    Telemetry.emit(Telemetry.maintenance_cache_cleanup_start(), %{count: 1}, %{
      worker: :cache_cleanup_worker,
      reason: :no_owned_cleanup_api
    })

    Telemetry.emit(
      Telemetry.maintenance_cache_cleanup_stop(),
      %{count: 0, duration: System.monotonic_time() - started_at},
      %{
        worker: :cache_cleanup_worker,
        affected_count: 0,
        reason: :no_owned_cleanup_api
      }
    )

    :ok
  rescue
    error ->
      Telemetry.emit(Telemetry.maintenance_cache_cleanup_exception(), %{count: 1}, %{
        worker: :cache_cleanup_worker,
        reason: low_cardinality_reason(error)
      })

      {:error, error}
  end

  defp low_cardinality_reason(%module{}), do: module
end
