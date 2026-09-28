defmodule EventSales.Analytics.HistoricalCatchupFreshnessNotifierTest do
  use ExUnit.Case, async: false

  alias EventSales.Analytics.HistoricalCatchupFreshnessNotifier
  alias EventSales.Ingestion.HistoricalCatchupEvidence
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}

  @failure_event [:event_sales, :source_freshness, :advance_failed]
  @date_to ~U[2026-08-10 10:00:00.000000Z]
  @sales_covered_through @date_to
  @refunds_covered_through ~U[2026-08-11 11:00:00.000000Z]
  @finished_at ~U[2026-08-12 12:00:00.000000Z]
  @source_observed_at ~U[2026-08-13 13:00:00.000000Z]

  defmodule SourceFreshnessRecorder do
    def advance_sync_source_observed(event_id, source_observed_at) do
      send(
        Process.get(:source_freshness_test_pid),
        {:sync_freshness_advance, event_id, source_observed_at}
      )

      case Process.get(:source_freshness_test_result, :ok) do
        :raise -> raise "source freshness projection failed"
        result -> result
      end
    end
  end

  setup do
    Process.put(:source_freshness_test_pid, self())

    handler_id = "catchup-freshness-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        @failure_event,
        fn event, measurements, metadata, _config ->
          send(test_pid, {:source_freshness_advance_failed, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "completed catch-up projects only terminal evidence source_observed_at" do
    event_id = Ecto.UUID.generate()
    {run, cursor} = completed_pair(event_id)

    assert run.date_to == @date_to
    assert run.sales_covered_through == @sales_covered_through
    assert run.refunds_covered_through == @refunds_covered_through
    assert run.finished_at == @finished_at

    assert :ok = notify(run, cursor)

    assert_receive {:sync_freshness_advance, ^event_id, @source_observed_at}
    refute_receive {:source_freshness_advance_failed, _, _, _}, 0
  end

  test "running run does not advance freshness" do
    {run, cursor} = completed_pair(Ecto.UUID.generate())

    assert :ok = notify(%{run | status: :running}, cursor)
    refute_receive {:sync_freshness_advance, _, _}, 0
  end

  test "failed run does not advance freshness" do
    {run, cursor} = completed_pair(Ecto.UUID.generate())

    assert :ok = notify(%{run | status: :failed}, cursor)
    refute_receive {:sync_freshness_advance, _, _}, 0
  end

  test "paused and cancelled runs do not advance freshness" do
    for status <- [:paused, :cancelled] do
      {run, cursor} = completed_pair(Ecto.UUID.generate())
      assert :ok = notify(%{run | status: status}, cursor)
    end

    refute_receive {:sync_freshness_advance, _, _}, 0
  end

  test "non-historical run does not advance freshness" do
    {run, cursor} = completed_pair(Ecto.UUID.generate())

    assert :ok = notify(%{run | sync_type: :reconciliation}, cursor)
    refute_receive {:sync_freshness_advance, _, _}, 0
  end

  test "active cursor does not advance freshness" do
    {run, cursor} = completed_pair(Ecto.UUID.generate())

    assert :ok = notify(run, %{cursor | status: :active})
    refute_receive {:sync_freshness_advance, _, _}, 0
    assert_receive_terminal_evidence_failure()
  end

  test "cursor for a different run does not advance freshness" do
    {run, cursor} = completed_pair(Ecto.UUID.generate())

    assert :ok = notify(run, %{cursor | sync_run_id: Ecto.UUID.generate()})
    refute_receive {:sync_freshness_advance, _, _}, 0
    assert_receive_terminal_evidence_failure()
  end

  test "in-progress catch-up evidence does not advance freshness" do
    {run, cursor} = completed_pair(Ecto.UUID.generate())
    evidence = evidence()
    metadata = HistoricalCatchupEvidence.in_progress_metadata(evidence, "next.cursor")

    assert :ok = notify(run, %{cursor | metadata: metadata})
    refute_receive {:sync_freshness_advance, _, _}, 0
    assert_receive_terminal_evidence_failure()
  end

  test "pending first page evidence does not advance freshness" do
    {run, cursor} = completed_pair(Ecto.UUID.generate())

    assert :ok = notify(run, %{cursor | metadata: HistoricalCatchupEvidence.metadata(evidence())})
    refute_receive {:sync_freshness_advance, _, _}, 0
    assert_receive_terminal_evidence_failure()
  end

  test "corrupt terminal evidence is withheld and emits bounded telemetry" do
    {run, cursor} = completed_pair(Ecto.UUID.generate())
    metadata = cursor.metadata
    namespace = Map.fetch!(metadata, "historical_catchup")
    corrupt_metadata = put_in(metadata, ["historical_catchup", "source_observed_at_gmt"], "bad")

    assert namespace["state"] == "catchup_terminal"
    assert :ok = notify(run, %{cursor | metadata: corrupt_metadata})

    refute_receive {:sync_freshness_advance, _, _}, 0
    assert_receive_terminal_evidence_failure()
  end

  test "invalid event id withholds terminal freshness" do
    {run, cursor} = completed_pair("not-a-uuid")

    assert :ok = notify(run, cursor)
    refute_receive {:sync_freshness_advance, _, _}, 0
    assert_receive_terminal_evidence_failure()
  end

  test "projection error is isolated and emits bounded telemetry" do
    {run, cursor} = completed_pair(Ecto.UUID.generate())
    event_id = run.event_id
    Process.put(:source_freshness_test_result, {:error, :database_failure})

    assert :ok = notify(run, cursor)
    assert_receive {:sync_freshness_advance, ^event_id, @source_observed_at}
    assert_receive_projection_write_failure()
  end

  test "projection exception is isolated and emits bounded telemetry" do
    {run, cursor} = completed_pair(Ecto.UUID.generate())
    event_id = run.event_id
    Process.put(:source_freshness_test_result, :raise)

    assert :ok = notify(run, cursor)
    assert_receive {:sync_freshness_advance, ^event_id, @source_observed_at}
    assert_receive_projection_write_failure()
  end

  defp notify(run, cursor) do
    HistoricalCatchupFreshnessNotifier.notify_terminal_success(run, cursor,
      source_freshness: SourceFreshnessRecorder
    )
  end

  defp completed_pair(event_id) do
    run = %SyncRun{
      id: Ecto.UUID.generate(),
      event_id: event_id,
      sync_type: :historical_backfill,
      status: :completed,
      date_to: @date_to,
      sales_covered_through: @sales_covered_through,
      refunds_covered_through: @refunds_covered_through,
      finished_at: @finished_at
    }

    cursor = %SyncCursor{
      sync_run_id: run.id,
      status: :done,
      metadata: terminal_metadata()
    }

    {run, cursor}
  end

  defp terminal_metadata do
    HistoricalCatchupEvidence.terminal_metadata(evidence(), "terminal-proof")
  end

  defp evidence do
    %HistoricalCatchupEvidence{
      schema_version: "2026-08-13.catchup.v1",
      phase: "catch_up",
      boundary_token: "catchup-token",
      manifest_hash: String.duplicate("a", 64),
      manifest_expires_at: ~U[2026-08-14 12:00:00.000000Z],
      source_observed_at: @source_observed_at,
      state: "pending_first_page"
    }
  end

  defp assert_receive_terminal_evidence_failure do
    assert_receive {
      :source_freshness_advance_failed,
      @failure_event,
      %{count: 1},
      metadata
    }

    assert metadata == %{
             component: :sync,
             source: :historical_catchup,
             stage: :terminal_evidence
           }
  end

  defp assert_receive_projection_write_failure do
    assert_receive {
      :source_freshness_advance_failed,
      @failure_event,
      %{count: 1},
      metadata
    }

    assert metadata == %{
             component: :sync,
             source: :historical_catchup,
             stage: :projection_write
           }
  end
end
