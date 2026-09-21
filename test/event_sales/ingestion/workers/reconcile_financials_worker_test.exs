defmodule EventSales.Ingestion.Workers.ReconcileFinancialsWorkerTest do
  use EventSales.DataCase, async: false

  alias EventSales.Ingestion.FinancialReconciliationRuns
  alias EventSales.Ingestion.Workers.ReconcileFinancialsWorker
  alias EventSales.TestSupport.{FinancialReconciliationHelpers, SalesHelpers}

  defmodule EngineStub do
    def run(run), do: {:ok, run}
  end

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Financial Worker"})
    FinancialReconciliationHelpers.certified_run!(event)

    {:ok, %{financial_reconciliation_run: run}} =
      FinancialReconciliationRuns.queue_system_for_event(event.id,
        internal?: true,
        oban_insert: fn _ -> {:ok, %{}} end
      )

    Application.put_env(:event_sales, :financial_reconciliation_engine, EngineStub)

    on_exit(fn ->
      Application.delete_env(:event_sales, :financial_reconciliation_engine)
    end)

    {:ok, run: run}
  end

  test "discards terminal runs", %{run: run} do
    {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)

    {:ok, passed} =
      FinancialReconciliationRuns.finalize_evidence(
        started,
        %{disposition: :matched, comparisons: [], metric_mismatches: [], structural_findings: []},
        internal?: true
      )

    assert :discard =
             ReconcileFinancialsWorker.perform(%Oban.Job{
               args: %{"financial_reconciliation_run_id" => passed.id}
             })
  end

  test "executes queued runs through configured engine", %{run: run} do
    assert :ok =
             ReconcileFinancialsWorker.perform(%Oban.Job{
               args: %{"financial_reconciliation_run_id" => run.id}
             })
  end

  test "discards invalid args" do
    assert :discard = ReconcileFinancialsWorker.perform(%Oban.Job{args: %{}})
  end
end
