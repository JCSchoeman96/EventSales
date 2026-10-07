defmodule EventSales.Analytics.HistoricalCatchupPeriodCoverageNotifierTest do
  use ExUnit.Case, async: false

  alias EventSales.Analytics.HistoricalCatchupPeriodCoverageNotifier
  alias EventSales.Analytics.PeriodCoveragePlanner
  alias EventSales.Ingestion.HistoricalCatchupEvidence
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}

  @source_observed_at ~U[2026-05-17 10:59:00.000000Z]
  @coverage_now ~U[2026-05-17 11:01:00.000000Z]

  defmodule CoverageRecorder do
    def ensure_event_buckets(event_id, captured_now, _opts) do
      send(Process.get(:period_coverage_notifier_test_pid), {:ensure, event_id, captured_now})
      {:ok, %{bucket_intents_created: 0, refresh_enqueued?: false, currencies: []}}
    end
  end

  setup do
    Process.put(:period_coverage_notifier_test_pid, self())
    :ok
  end

  test "coverage anchor uses post-commit wall clock not terminal source_observed_at" do
    event_id = Ecto.UUID.generate()
    {run, cursor} = completed_pair(event_id, @source_observed_at)

    assert :ok =
             HistoricalCatchupPeriodCoverageNotifier.notify_terminal_success(run, cursor,
               now: @coverage_now,
               period_coverage: CoverageRecorder
             )

    assert_receive {:ensure, ^event_id, captured}
    assert captured == @coverage_now
    refute captured == @source_observed_at
  end

  test "planner horizon at coverage now includes the 11:00 UTC reader hour absent at source_observed_at" do
    {:ok, specs_now} = PeriodCoveragePlanner.required_bucket_specs(@coverage_now)
    {:ok, specs_source} = PeriodCoveragePlanner.required_bucket_specs(@source_observed_at)

    hour_11_start = ~U[2026-05-17 11:00:00.000000Z]

    assert Enum.any?(specs_now, fn spec ->
             spec.bucket_kind == :utc_hour and
               DateTime.compare(spec.bucket_start_utc, hour_11_start) == :eq
           end)

    refute Enum.any?(specs_source, fn spec ->
             spec.bucket_kind == :utc_hour and
               DateTime.compare(spec.bucket_start_utc, hour_11_start) == :eq
           end)
  end

  defp completed_pair(event_id, source_observed_at) do
    run = %SyncRun{
      id: Ecto.UUID.generate(),
      event_id: event_id,
      sync_type: :historical_backfill,
      status: :completed,
      date_to: ~U[2026-05-17 10:00:00.000000Z],
      sales_covered_through: ~U[2026-05-17 10:00:00.000000Z],
      refunds_covered_through: ~U[2026-05-17 10:00:00.000000Z],
      finished_at: ~U[2026-05-17 10:00:00.000000Z]
    }

    cursor = %SyncCursor{
      sync_run_id: run.id,
      status: :done,
      metadata: terminal_metadata(source_observed_at)
    }

    {run, cursor}
  end

  defp terminal_metadata(source_observed_at) do
    evidence = %HistoricalCatchupEvidence{
      schema_version: "2026-08-13.catchup.v1",
      phase: "catch_up",
      boundary_token: "catchup-token",
      manifest_hash: String.duplicate("a", 64),
      manifest_expires_at: ~U[2026-08-14 12:00:00.000000Z],
      source_observed_at: source_observed_at,
      state: "pending_first_page"
    }

    HistoricalCatchupEvidence.terminal_metadata(evidence, "terminal-proof")
  end
end
