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
  alias EventSales.Analytics.PeriodCoverageEligibleEvents.CandidatePage
  alias EventSales.Telemetry

  @default_batch_size 50

  @impl Oban.Worker
  def perform(%Oban.Job{} = job) do
    case perform_with_opts(job, []) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc false
  @spec perform_with_opts(Oban.Job.t(), keyword()) :: :ok | {:error, term()}
  def perform_with_opts(%Oban.Job{args: args} = _job, opts) do
    started_at = System.monotonic_time()
    batch_size = Map.get(args, "batch_size", @default_batch_size)
    after_id = Map.get(args, "after_event_id")
    captured_now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    coverage_opts = coverage_opts_from_args(args)
    continuation_inserter = Keyword.get(opts, :continuation_inserter, &Oban.insert/1)

    page = PeriodCoverageEligibleEvents.page_candidates(after_id, limit: batch_size)

    stats =
      Enum.reduce(
        page.event_ids,
        %{examined: 0, changed: 0, intents: 0, enqueues: 0, failures: 0},
        fn event_id, acc ->
          acc = Map.update!(acc, :examined, &(&1 + 1))
          apply_event_coverage(acc, event_id, captured_now, coverage_opts)
        end
      )

    {examined, changed, intents, enqueues, failures} =
      {stats.examined, stats.changed, stats.intents, stats.enqueues, stats.failures}

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - started_at, :native, :millisecond)

    emit_batch_telemetry(examined, changed, intents, enqueues, failures, duration_ms)

    schedule_continuation(page, batch_size, continuation_inserter)
  end

  defp apply_event_coverage(acc, event_id, captured_now, coverage_opts) do
    case PeriodCoverage.ensure_event_buckets(event_id, captured_now, coverage_opts) do
      {:ok, %{bucket_intents_created: created, refresh_enqueued?: enqueued?}} ->
        acc
        |> Map.update!(:changed, &if(created > 0, do: &1 + 1, else: &1))
        |> Map.update!(:intents, &(&1 + created))
        |> Map.update!(:enqueues, &if(enqueued?, do: &1 + 1, else: &1))

      {:error, _reason} ->
        Map.update!(acc, :failures, &(&1 + 1))
    end
  end

  @doc false
  @spec schedule_continuation(CandidatePage.t(), pos_integer(), (Oban.Job.changeset() -> term())) ::
          :ok | {:error, term()}
  def schedule_continuation(%CandidatePage{has_more?: false}, _batch_size, _inserter), do: :ok

  def schedule_continuation(%CandidatePage{has_more?: true, next_after_event_id: nil}, _, _),
    do: :ok

  def schedule_continuation(
        %CandidatePage{has_more?: true, next_after_event_id: after_event_id},
        batch_size,
        inserter
      )
      when is_binary(after_event_id) and is_function(inserter, 1) do
    job =
      __MODULE__.new(%{
        "after_event_id" => after_event_id,
        "batch_size" => batch_size
      })

    case inserter.(job) do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_continuation_insert_result, other}}
    end
  end

  defp coverage_opts_from_args(args) do
    case Map.get(args, "period_coverage_opts") do
      nil -> [enqueue_refresh?: true]
      opts when is_list(opts) -> Keyword.merge([enqueue_refresh?: true], opts)
      _other -> [enqueue_refresh?: true]
    end
  end

  defp emit_batch_telemetry(examined, changed, intents, enqueues, failures, duration_ms) do
    Telemetry.emit(
      [:event_sales, :analytics, :period_coverage, :maintenance],
      %{
        events_examined: examined,
        events_changed: changed,
        bucket_intents_created: intents,
        refresh_enqueues: enqueues,
        failures: failures,
        duration: duration_ms
      },
      %{component: :period_coverage}
    )
  end
end
