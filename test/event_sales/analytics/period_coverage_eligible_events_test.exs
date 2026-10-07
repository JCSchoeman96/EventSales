defmodule EventSales.Analytics.PeriodCoverageEligibleEventsTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Analytics.PeriodCoverageEligibleEvents
  alias EventSales.Ingestion
  alias EventSales.Ingestion.AnalyticsReadinessResolver
  alias EventSales.Ingestion.FinancialReconciliationRuns
  alias EventSales.Ingestion.Resources.{FinancialReconciliationRun, SyncRun}
  alias EventSales.Repo
  alias EventSales.TestSupport.{FinancialReconciliationHelpers, SalesHelpers}

  test "includes only analytics-ready events and pages stably" do
    source = SalesHelpers.create_source_system!()
    ready_events = for i <- 1..3, do: ready_event!(source, "Ready #{i}")
    _not_ready = SalesHelpers.create_event!(source, %{name: "No cert"})

    assert Enum.all?(ready_events, fn event ->
             match?(
               {:ok, %{analytics_ready?: true}},
               AnalyticsReadinessResolver.resolve(event.id)
             )
           end)

    page1 = PeriodCoverageEligibleEvents.page_event_ids(nil, limit: 2)
    assert length(page1) == 2
    assert page1 == Enum.sort(page1)

    page2 = PeriodCoverageEligibleEvents.page_event_ids(List.last(page1), limit: 2)
    assert length(page2) >= 1
    refute Enum.any?(page2, &(&1 in page1))

    assert MapSet.new(page1 ++ page2)
           |> MapSet.subset?(MapSet.new(Enum.map(ready_events, & &1.id)))
  end

  test "excludes invalidated newest certificate" do
    source = SalesHelpers.create_source_system!()
    event = ready_event!(source, "Invalidated")
    sync_run = latest_cert!(event)

    Repo.query!(
      """
      UPDATE ingestion_sync_runs
      SET coverage_invalidated_at = NOW(),
          coverage_invalidation_reason = 'test_invalidation'
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(sync_run.id)]
    )

    refute event.id in PeriodCoverageEligibleEvents.page_event_ids(nil, limit: 100)
  end

  test "excludes incomplete certificate" do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Incomplete"})
    sync_run = FinancialReconciliationHelpers.certified_run!(event)

    Repo.query!(
      "UPDATE ingestion_sync_runs SET order_coverage_status = 'incomplete' WHERE id = $1",
      [Ecto.UUID.dump!(sync_run.id)]
    )

    refute event.id in PeriodCoverageEligibleEvents.page_event_ids(nil, limit: 100)
  end

  test "excludes when newest terminal reconciliation is failed after older passed" do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Failed newest"})
    sync_run = FinancialReconciliationHelpers.certified_run!(event)
    passed = terminal_run!(event, :matched, sync_run)
    failed = terminal_run!(event, :failed, sync_run)

    set_finished_at!(passed, ~U[2026-09-21 10:00:00.000000Z])
    set_finished_at!(failed, ~U[2026-09-21 11:00:00.000000Z])

    refute event.id in PeriodCoverageEligibleEvents.page_event_ids(nil, limit: 100)
  end

  test "excludes passed reconciliation with findings" do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Finding block"})
    sync_run = FinancialReconciliationHelpers.certified_run!(event)
    terminal_run!(event, :matched, sync_run, [:currency_conflict])

    refute event.id in PeriodCoverageEligibleEvents.page_event_ids(nil, limit: 100)
  end

  test "excludes scope-mismatched reconciliation" do
    source = SalesHelpers.create_source_system!()
    event = ready_event!(source, "Scope mismatch")
    run = terminal_run!(event, :matched)

    Repo.query!(
      "UPDATE ingestion_financial_reconciliation_runs SET coverage_start = coverage_start - interval '1 day' WHERE id = $1",
      [Ecto.UUID.dump!(run.id)]
    )

    refute event.id in PeriodCoverageEligibleEvents.page_event_ids(nil, limit: 100)
  end

  defp ready_event!(source, name) do
    event = SalesHelpers.create_event!(source, %{name: name})
    sync_run = FinancialReconciliationHelpers.certified_run!(event)
    terminal_run!(event, :matched, sync_run)
    event
  end

  defp latest_cert!(event) do
    SyncRun
    |> Ash.Query.filter(
      event_id == ^event.id and sync_type == :historical_backfill and
        not is_nil(coverage_certified_at)
    )
    |> Ash.Query.sort(coverage_certified_at: :desc, finished_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(domain: Ingestion)
  end

  defp terminal_run!(event, status, sync_run \\ nil, categories \\ []) do
    {:ok, %{financial_reconciliation_run: run}} =
      FinancialReconciliationRuns.queue_system_for_event(event.id,
        internal?: true,
        oban_insert: fn _job -> {:ok, %{id: System.unique_integer([:positive])}} end
      )

    sync_run =
      sync_run ||
        Ash.get!(SyncRun, run.historical_sync_run_id, domain: Ingestion)

    {:ok, running} = FinancialReconciliationRuns.mark_started(run, internal?: true)

    findings =
      Enum.map(categories, fn category ->
        %{
          category: category,
          origin: :local,
          scope: FinancialReconciliationHelpers.scope_map(sync_run),
          details: %{test: Atom.to_string(category)}
        }
      end)

    disposition =
      case status do
        :matched -> :matched
        :mismatched -> :mismatched
        :failed -> :failed
      end

    {:ok, finalized} =
      FinancialReconciliationRuns.finalize_evidence(
        running,
        %{
          disposition: disposition,
          comparisons: [],
          metric_mismatches: [],
          structural_findings: findings
        },
        internal?: true
      )

    finalized
  end

  defp set_finished_at!(%FinancialReconciliationRun{} = run, finished_at) do
    Repo.query!(
      "UPDATE ingestion_financial_reconciliation_runs SET finished_at = $2 WHERE id = $1",
      [Ecto.UUID.dump!(run.id), finished_at]
    )
  end
end
