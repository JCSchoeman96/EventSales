defmodule EventSales.TestSupport.EventDetailCertificationHelpers do
  @moduledoc false

  require Ash

  alias EventSales.Ingestion.AnalyticsReadinessResolver
  alias EventSales.Ingestion.FinancialReconciliationRuns
  alias EventSales.TestSupport.FinancialReconciliationHelpers

  @doc """
  Certifies M3 coverage and a terminal matched M4 reconciliation for `event`.

  Call only after final sales facts exist and `SnapshotRefresh.refresh_event/1`
  has persisted projections for those facts.
  """
  def certify_analytics_ready!(event) do
    _sync_run = FinancialReconciliationHelpers.certified_run!(event)
    finalize_matched_reconciliation!(event)

    case AnalyticsReadinessResolver.resolve(event.id) do
      {:ok, %{analytics_ready?: true}} ->
        :ok

      {:ok, other} ->
        raise "expected analytics ready, got: #{inspect(other)}"

      other ->
        raise "readiness resolve failed: #{inspect(other)}"
    end
  end

  def finalize_matched_reconciliation!(event) do
    {:ok, %{financial_reconciliation_run: run}} =
      FinancialReconciliationRuns.queue_system_for_event(event.id,
        internal?: true,
        oban_insert: fn _job -> {:ok, %{id: System.unique_integer([:positive])}} end
      )

    {:ok, running} = FinancialReconciliationRuns.mark_started(run, internal?: true)

    sync_run =
      Ash.get!(EventSales.Ingestion.Resources.SyncRun, running.historical_sync_run_id,
        domain: EventSales.Ingestion
      )

    {:ok, _finalized} =
      FinancialReconciliationRuns.finalize_evidence(
        running,
        %{
          disposition: :matched,
          comparisons: [],
          metric_mismatches: [],
          structural_findings: []
        },
        internal?: true
      )

    sync_run
  end
end
