defmodule EventSales.Analytics.PeriodCoverage do
  @moduledoc """
  Event-scoped period bucket coverage maintenance for M5-04 management reads.
  """

  alias EventSales.Analytics.PeriodCoverageMaterializer
  alias EventSales.Telemetry

  @doc "Materializes missing comparison bucket intent for one analytics-ready event."
  @spec ensure_event_buckets(Ecto.UUID.t() | String.t(), DateTime.t(), keyword()) ::
          {:ok, PeriodCoverageMaterializer.result()} | {:error, term()}
  def ensure_event_buckets(event_id, captured_now_utc, opts \\ []) do
    started_at = System.monotonic_time()

    result = PeriodCoverageMaterializer.materialize(event_id, captured_now_utc, opts)

    emit_maintenance_telemetry(result, started_at)
    result
  end

  defp emit_maintenance_telemetry({:ok, %{bucket_intents_created: created}}, started_at) do
    duration =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    Telemetry.emit(
      [:event_sales, :analytics, :period_coverage, :ensure],
      %{
        duration: duration,
        bucket_intents_created: created,
        events_changed: if(created > 0, do: 1, else: 0)
      },
      %{component: :period_coverage}
    )
  end

  defp emit_maintenance_telemetry({:error, _reason}, started_at) do
    duration =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    Telemetry.emit(
      [:event_sales, :analytics, :period_coverage, :ensure],
      %{duration: duration, failures: 1},
      %{component: :period_coverage}
    )
  end
end
