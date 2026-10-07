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

    stats =
      Enum.reduce(
        event_ids,
        %{examined: 0, changed: 0, intents: 0, enqueues: 0, failures: 0},
        fn event_id, acc ->
          acc = Map.update!(acc, :examined, &(&1 + 1))
          apply_event_coverage(acc, event_id, captured_now)
        end
      )

    {examined, changed, intents, enqueues, failures} =
      {stats.examined, stats.changed, stats.intents, stats.enqueues, stats.failures}

    emit_batch_telemetry(examined, changed, intents, enqueues, failures)

    schedule_next_batch(event_ids, batch_size, after_id)

    :ok
  end

  defp apply_event_coverage(acc, event_id, captured_now) do
    case PeriodCoverage.ensure_event_buckets(event_id, captured_now, enqueue_refresh?: true) do
      {:ok, %{bucket_intents_created: created, refresh_enqueued?: enqueued?}} ->
        acc
        |> Map.update!(:changed, &if(created > 0, do: &1 + 1, else: &1))
        |> Map.update!(:intents, &(&1 + created))
        |> Map.update!(:enqueues, &if(enqueued?, do: &1 + 1, else: &1))

      {:error, _reason} ->
        Map.update!(acc, :failures, &(&1 + 1))
    end
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
