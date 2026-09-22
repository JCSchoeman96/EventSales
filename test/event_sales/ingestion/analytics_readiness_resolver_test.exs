defmodule EventSales.Ingestion.AnalyticsReadinessResolverTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Ingestion
  alias EventSales.Ingestion.AnalyticsReadinessResolver
  alias EventSales.Ingestion.FinancialReconciliationRuns
  alias EventSales.Ingestion.Resources.FinancialReconciliationRun
  alias EventSales.Repo
  alias EventSales.TestSupport.{FinancialReconciliationHelpers, SalesHelpers}

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Analytics Readiness"})
    sync_run = FinancialReconciliationHelpers.certified_run!(event)

    {:ok, source: source, event: event, sync_run: sync_run}
  end

  test "rejects a malformed Event UUID" do
    assert {:error, :invalid_event_id} = AnalyticsReadinessResolver.resolve("not-a-uuid")
  end

  test "returns a not-ready result when there is no current M3 certificate", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "No Certificate"})

    assert {:ok, result} = AnalyticsReadinessResolver.resolve(event.id)
    assert result.analytics_ready? == false
    assert result.blocking_reason == :historical_coverage_not_current
    assert result.event_id == event.id
    assert result.historical_sync_run_id == nil
    assert result.financial_reconciliation_run_id == nil
  end

  test "returns pending when no terminal reconciliation exists", %{
    event: event,
    sync_run: sync_run
  } do
    assert {:ok, result} = AnalyticsReadinessResolver.resolve(event.id)

    assert result.analytics_ready? == false
    assert result.blocking_reason == :financial_reconciliation_pending
    assert result.historical_sync_run_id == sync_run.id
    assert result.financial_reconciliation_run_id == nil
    assert result.coverage_start == sync_run.coverage_start
    assert result.sales_covered_through == sync_run.sales_covered_through
    assert result.refunds_covered_through == sync_run.refunds_covered_through
  end

  test "queued and running reconciliations remain pending", %{event: event} do
    run = queue_run!(event)

    assert {:ok, queued} = AnalyticsReadinessResolver.resolve(event.id)
    assert queued.blocking_reason == :financial_reconciliation_pending

    assert {:ok, _running} = FinancialReconciliationRuns.mark_started(run, internal?: true)

    assert {:ok, running} = AnalyticsReadinessResolver.resolve(event.id)
    assert running.analytics_ready? == false
    assert running.blocking_reason == :financial_reconciliation_pending
  end

  test "returns ready for the newest exact terminal PASS", %{event: event, sync_run: sync_run} do
    run = terminal_run!(event, :matched)

    assert {:ok, result} = AnalyticsReadinessResolver.resolve(event.id)
    assert result.analytics_ready? == true
    assert result.blocking_reason == nil
    assert result.event_id == event.id
    assert result.historical_sync_run_id == sync_run.id
    assert result.financial_reconciliation_run_id == run.id
    assert result.coverage_start == sync_run.coverage_start
    assert result.sales_covered_through == sync_run.sales_covered_through
    assert result.refunds_covered_through == sync_run.refunds_covered_through
  end

  test "an active recheck does not erase a terminal PASS", %{event: event} do
    passed = terminal_run!(event, :matched)
    _active = queue_run!(event)

    assert {:ok, result} = AnalyticsReadinessResolver.resolve(event.id)
    assert result.analytics_ready? == true
    assert result.financial_reconciliation_run_id == passed.id
  end

  test "ignores a terminal reconciliation bound to an older M3 certificate", %{
    event: event,
    sync_run: older_sync_run
  } do
    older_run = terminal_run!(event, :matched, older_sync_run)
    newer_sync_run = FinancialReconciliationHelpers.certified_run!(event)

    assert {:ok, result} = AnalyticsReadinessResolver.resolve(event.id)
    assert result.analytics_ready? == false
    assert result.blocking_reason == :financial_reconciliation_pending
    assert result.historical_sync_run_id == newer_sync_run.id
    assert result.financial_reconciliation_run_id == nil
    assert older_run.historical_sync_run_id != newer_sync_run.id
  end

  test "ignores a terminal reconciliation for another Event", %{source: source, event: event} do
    other_event = SalesHelpers.create_event!(source, %{name: "Other Readiness Event"})
    other_sync_run = FinancialReconciliationHelpers.certified_run!(other_event)
    other_run = terminal_run!(other_event, :matched, other_sync_run)

    assert {:ok, result} = AnalyticsReadinessResolver.resolve(event.id)
    assert result.analytics_ready? == false
    assert result.blocking_reason == :financial_reconciliation_pending
    assert result.financial_reconciliation_run_id == nil
    assert other_run.event_id == other_event.id
  end

  for {status, reason} <- [
        {:mismatched, :financial_reconciliation_failed},
        {:failed, :financial_reconciliation_failed},
        {:superseded, :financial_reconciliation_failed},
        {:cancelled, :financial_reconciliation_pending}
      ] do
    test "maps latest #{status} terminal evidence without an older PASS fallback", %{
      event: event
    } do
      passed = terminal_run!(event, :matched)
      newer = terminal_run!(event, unquote(status))

      set_finished_at!(passed, ~U[2026-09-21 10:00:00.000000Z])
      set_finished_at!(newer, ~U[2026-09-21 11:00:00.000000Z])

      assert {:ok, result} = AnalyticsReadinessResolver.resolve(event.id)
      assert result.analytics_ready? == false
      assert result.blocking_reason == unquote(reason)
      assert result.financial_reconciliation_run_id == newer.id
    end
  end

  test "uses the newest terminal row before inspecting its status", %{event: event} do
    passed = terminal_run!(event, :matched)
    mismatched = terminal_run!(event, :mismatched)

    set_finished_at!(passed, ~U[2026-09-21 10:00:00.000000Z])
    set_finished_at!(mismatched, ~U[2026-09-21 11:00:00.000000Z])

    assert {:ok, result} = AnalyticsReadinessResolver.resolve(event.id)
    assert result.analytics_ready? == false
    assert result.blocking_reason == :financial_reconciliation_failed
    assert result.financial_reconciliation_run_id == mismatched.id
  end

  test "refines mismatch reasons from selected-run findings", %{event: event, sync_run: sync_run} do
    for {category, reason} <- [
          {:currency_conflict, :currency_conflict},
          {:timestamp_incomplete, :effective_time_incomplete},
          {:financial_primitive_incomplete, :financial_primitive_incomplete},
          {:unresolved_attribution, :attribution_incomplete}
        ] do
      run = terminal_run!(event, :mismatched, sync_run, [category])

      assert {:ok, result} = AnalyticsReadinessResolver.resolve(event.id)
      assert result.analytics_ready? == false
      assert result.blocking_reason == reason
      assert result.financial_reconciliation_run_id == run.id

      set_finished_at!(run, DateTime.add(DateTime.utc_now(), -1, :second))
    end
  end

  test "uses an explicit priority when multiple refinable findings exist", %{
    event: event,
    sync_run: sync_run
  } do
    run =
      terminal_run!(
        event,
        :mismatched,
        sync_run,
        [:unresolved_attribution, :currency_conflict, :timestamp_incomplete]
      )

    assert {:ok, result} = AnalyticsReadinessResolver.resolve(event.id)
    assert result.blocking_reason == :currency_conflict
    assert result.financial_reconciliation_run_id == run.id
  end

  test "fails closed when a passed run has a structural finding", %{
    event: event,
    sync_run: sync_run
  } do
    run = terminal_run!(event, :matched, sync_run, [:currency_conflict])

    assert {:ok, result} = AnalyticsReadinessResolver.resolve(event.id)
    assert result.analytics_ready? == false
    assert result.blocking_reason == :financial_reconciliation_evidence_invalid
    assert result.financial_reconciliation_run_id == run.id
  end

  test "fails closed when the selected terminal run copies a different M3 scope", %{
    event: event
  } do
    run = terminal_run!(event, :matched)

    Repo.query!(
      "UPDATE ingestion_financial_reconciliation_runs SET coverage_start = coverage_start - interval '1 day' WHERE id = $1",
      [Ecto.UUID.dump!(run.id)]
    )

    assert {:ok, result} = AnalyticsReadinessResolver.resolve(event.id)
    assert result.analytics_ready? == false
    assert result.blocking_reason == :financial_reconciliation_evidence_invalid
    assert result.financial_reconciliation_run_id == run.id
  end

  test "fails closed when terminal evidence has no finished_at", %{event: event} do
    run = terminal_run!(event, :matched)

    Repo.query!(
      "UPDATE ingestion_financial_reconciliation_runs SET finished_at = NULL WHERE id = $1",
      [Ecto.UUID.dump!(run.id)]
    )

    assert {:ok, result} = AnalyticsReadinessResolver.resolve(event.id)
    assert result.analytics_ready? == false
    assert result.blocking_reason == :financial_reconciliation_evidence_invalid
    assert result.financial_reconciliation_run_id == run.id
  end

  test "performs no writes while resolving", %{event: event, sync_run: sync_run} do
    run = terminal_run!(event, :matched, sync_run)
    before_run = Ash.get!(FinancialReconciliationRun, run.id, domain: Ingestion)

    before_sync_run =
      Ash.get!(EventSales.Ingestion.Resources.SyncRun, sync_run.id, domain: Ingestion)

    assert {:ok, result} = AnalyticsReadinessResolver.resolve(event.id)
    assert result.analytics_ready? == true

    assert Ash.get!(FinancialReconciliationRun, run.id, domain: Ingestion) == before_run

    assert Ash.get!(EventSales.Ingestion.Resources.SyncRun, sync_run.id, domain: Ingestion) ==
             before_sync_run
  end

  defp queue_run!(event) do
    {:ok, %{financial_reconciliation_run: run}} =
      FinancialReconciliationRuns.queue_system_for_event(event.id,
        internal?: true,
        oban_insert: fn _job -> {:ok, %{id: System.unique_integer([:positive])}} end
      )

    run
  end

  defp terminal_run!(event, status, sync_run \\ nil, categories \\ []) do
    run = queue_run!(event)

    sync_run =
      sync_run ||
        Ash.get!(EventSales.Ingestion.Resources.SyncRun, run.historical_sync_run_id,
          domain: Ingestion
        )

    {:ok, running} = FinancialReconciliationRuns.mark_started(run, internal?: true)

    case status do
      :matched ->
        finalize!(running, :matched, sync_run, categories)

      :mismatched ->
        finalize!(running, :mismatched, sync_run, categories)

      :failed ->
        finalize!(running, :failed, sync_run, categories)

      :superseded ->
        finalize!(running, :superseded, sync_run, categories)

      :cancelled ->
        {:ok, cancelled} = FinancialReconciliationRuns.cancel(running, internal?: true)
        cancelled
    end
  end

  defp finalize!(running, disposition, sync_run, categories) do
    findings =
      case {disposition, categories} do
        {:superseded, []} ->
          [
            %{
              category: :invalid_scope,
              origin: :local,
              scope: FinancialReconciliationHelpers.scope_map(sync_run),
              details: %{reason: :historical_certificate_not_current}
            }
          ]

        {_, categories} ->
          Enum.map(categories, fn category ->
            %{
              category: category,
              origin: :local,
              scope: FinancialReconciliationHelpers.scope_map(sync_run),
              details: %{test: Atom.to_string(category)}
            }
          end)
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

  defp set_finished_at!(run, finished_at) do
    Repo.query!(
      "UPDATE ingestion_financial_reconciliation_runs SET finished_at = $2 WHERE id = $1",
      [Ecto.UUID.dump!(run.id), finished_at]
    )
  end
end
