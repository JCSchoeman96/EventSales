defmodule EventSales.Analytics.Workers.PeriodCoverageMaintenanceWorker do
  @moduledoc """
  Hourly maintenance that materializes missing period bucket intent for eligible
  analytics-ready events as UTC hours advance without source mutations.
  """

  use Oban.Worker,
    queue: :analytics_rebuilds,
    max_attempts: 3

  alias EventSales.Analytics.PeriodCoverage
  alias EventSales.Analytics.PeriodCoverageEligibleEvents
  alias EventSales.Telemetry

  @default_batch_size 50

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    batch_size = Map.get(args, "batch_size", @default_batch_size)
    after_id = Map.get(args, "after_event_id")
    captured_now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    event_ids = PeriodCoverageEligibleEvents.page_event_ids(after_id, limit: batch_size)

    {examined, changed, intents, enqueues, failures} =
      Enum.reduce(event_ids, {0, 0, 0, 0, 0}, fn event_id,
                                                 {examined, changed, intents, enqueues, failures} ->
        examined = examined + 1

        case PeriodCoverage.ensure_event_buckets(event_id, captured_now, enqueue_refresh?: true) do
          {:ok, %{bucket_intents_created: created, refresh_enqueued?: enqueued?}} ->
            {
              examined,
              if(created > 0, do: changed + 1, else: changed),
              intents + created,
              if(enqueued?, do: enqueues + 1, else: enqueues),
              failures
            }

          {:error, _reason} ->
            {examined, changed, intents, enqueues, failures + 1}
        end
      end)

    emit_batch_telemetry(examined, changed, intents, enqueues, failures)

    schedule_next_batch(event_ids, batch_size, after_id)

    :ok
  end

  defp schedule_next_batch(event_ids, batch_size, _after_id) when length(event_ids) < batch_size,
    do: :ok

  defp schedule_next_batch(event_ids, _batch_size, _after_id) when event_ids == [], do: :ok

  defp schedule_next_batch(event_ids, batch_size, _after_id) do
    last_id = List.last(event_ids)

    __MODULE__.new(%{"after_event_id" => last_id, "batch_size" => batch_size})
    |> Oban.insert()
  end

  defp emit_batch_telemetry(examined, changed, intents, enqueues, failures) do
    Telemetry.emit(
      [:event_sales, :analytics, :period_coverage, :maintenance],
      %{
        events_examined: examined,
        events_changed: changed,
        bucket_intents_created: intents,
        refresh_enqueues: enqueues,
        failures: failures
      },
      %{component: :period_coverage}
    )
  end
end
