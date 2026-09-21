defmodule EventSales.Ingestion.FinancialReconciliation.OrchestratorTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Ingestion
  alias EventSales.Ingestion.FinancialReconciliation.Orchestrator
  alias EventSales.Ingestion.FinancialReconciliationRuns

  alias EventSales.Ingestion.Resources.{
    FinancialReconciliationFinding,
    FinancialReconciliationMetric
  }

  alias EventSales.Repo
  alias EventSales.TestSupport.{FinancialReconciliationHelpers, SalesHelpers}

  defmodule SourceStub do
    def extract_for_run(_sync_run, _event, _source, _opts),
      do: Application.get_env(:event_sales, :orchestrator_source_result)
  end

  defmodule LocalStub do
    def extract_for_run(_sync_run, _event, _source, _opts),
      do: Application.get_env(:event_sales, :orchestrator_local_result)
  end

  setup do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        external_event_id: 905_001,
        external_event_kind: :tickera_event
      })

    event =
      Ash.update!(event, %{source_created_at: FinancialReconciliationHelpers.coverage_start()},
        action: :capture_source_created_at,
        domain: Catalog,
        context: %{
          event_sales_backfill_start_capture_authority:
            {EventSales.Catalog.Resources.Event, :verified}
        }
      )

    sync_run = FinancialReconciliationHelpers.certified_run!(event)

    {:ok, %{financial_reconciliation_run: run}} =
      FinancialReconciliationRuns.queue_system_for_event(event.id,
        internal?: true,
        oban_insert: fn _ -> {:ok, %{}} end
      )

    on_exit(fn ->
      Application.delete_env(:event_sales, :orchestrator_source_result)
      Application.delete_env(:event_sales, :orchestrator_local_result)
    end)

    %{
      source: source,
      event: event,
      sync_run: sync_run,
      run: run
    }
  end

  test "matched flow persists all comparison rows and passes", %{
    run: run,
    sync_run: sync_run
  } do
    set_stubs!({:ok, successful_result(sync_run)}, {:ok, successful_result(sync_run)})

    assert {:ok, finalized} = run_orchestrator(run)
    assert finalized.status == :passed

    metrics = list_metrics(run.id)
    assert length(metrics) == 6
    assert Enum.all?(metrics, & &1.matched?)
    assert list_findings(run.id) == []
  end

  test "numeric mismatch flow persists all rows with mismatch categories", %{
    run: run,
    sync_run: sync_run
  } do
    source =
      successful_result(sync_run, "ZAR", %{
        gross_ticket_value: Decimal.new("100.00"),
        net_ticket_value: Decimal.new("100.00")
      })

    local =
      successful_result(sync_run, "ZAR", %{
        gross_ticket_value: Decimal.new("90.00"),
        net_ticket_value: Decimal.new("90.00")
      })

    set_stubs!({:ok, source}, {:ok, local})

    assert {:ok, finalized} = run_orchestrator(run)
    assert finalized.status == :mismatched

    metrics = list_metrics(run.id)
    assert length(metrics) == 6

    gross_value =
      Enum.find(metrics, &(&1.primitive == :gross_ticket_value and &1.currency == "ZAR"))

    assert gross_value.matched? == false
    assert gross_value.mismatch_category == :gross_value_mismatch
    assert list_findings(run.id) == []
  end

  test "source failure persists structural finding and fails without local/comparator", %{
    run: run
  } do
    set_stubs!({:error, {:missing_source_fact, %{kind: :order}}}, {:ok, %{}})

    assert {:ok, finalized} = run_orchestrator(run)
    assert finalized.status == :failed
    assert list_metrics(run.id) == []

    findings = list_findings(run.id)
    assert length(findings) == 1
    assert findings |> hd() |> Map.fetch!(:category) == :missing_source_fact
  end

  test "source superseded flow transitions to superseded", %{run: run} do
    set_stubs!({:error, {:source_snapshot_stale, %{}}}, {:ok, %{}})

    assert {:ok, finalized} = run_orchestrator(run)
    assert finalized.status == :superseded
    assert hd(list_findings(run.id)).category == :source_snapshot_stale
  end

  test "local failure does not call comparator", %{run: run, sync_run: sync_run} do
    set_stubs!(
      {:ok, successful_result(sync_run)},
      {:error, {:missing_local_fact, %{kind: :order}}}
    )

    assert {:ok, finalized} = run_orchestrator(run)
    assert finalized.status == :failed
    assert list_metrics(run.id) == []
    assert hd(list_findings(run.id)).category == :missing_local_fact
  end

  test "currency set mismatch transitions to mismatched with structural finding only", %{
    run: run,
    sync_run: sync_run
  } do
    source = successful_result(sync_run, "ZAR", %{})
    local = successful_result(sync_run, "USD", %{})

    set_stubs!({:ok, source}, {:ok, local})

    assert {:ok, finalized} = run_orchestrator(run)
    assert finalized.status == :mismatched
    assert list_metrics(run.id) == []
    assert hd(list_findings(run.id)).category == :currency_conflict
  end

  test "source extraction is never called inside a repo transaction", %{
    run: run,
    sync_run: sync_run
  } do
    source = successful_result(sync_run)
    local = successful_result(sync_run)

    transaction_probe = fn sync_run_arg, event, source_arg, opts ->
      refute Repo.in_transaction?()
      SourceStub.extract_for_run(sync_run_arg, event, source_arg, opts)
    end

    set_stubs!({:ok, source}, {:ok, local})

    assert {:ok, _finalized} =
             Orchestrator.run(run,
               source_extractor: transaction_probe,
               local_totals: LocalStub
             )
  end

  test "finalize rolls back all evidence when metric persistence fails", %{run: run} do
    {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)

    invalid_row = %{
      currency: "ZAR",
      primitive: :gross_ticket_quantity,
      source_value: Decimal.new("1.5"),
      local_value: Decimal.new("2"),
      matched?: false
    }

    assert {:error, _} =
             FinancialReconciliationRuns.finalize_evidence(
               started,
               %{
                 disposition: :mismatched,
                 comparisons: [invalid_row],
                 metric_mismatches: [
                   %{
                     category: :gross_quantity_mismatch,
                     currency: "ZAR",
                     primitive: :gross_ticket_quantity,
                     source_value: Decimal.new("1.5"),
                     local_value: Decimal.new("2"),
                     delta: Decimal.new("0.5")
                   }
                 ],
                 structural_findings: []
               },
               internal?: true
             )

    assert list_metrics(run.id) == []

    reloaded =
      Ash.get!(EventSales.Ingestion.Resources.FinancialReconciliationRun, run.id,
        domain: Ingestion
      )

    assert reloaded.status == :running
  end

  test "orchestrator source does not reference HistoricalCoverageFence" do
    source =
      File.read!(
        Path.join([
          File.cwd!(),
          "lib/event_sales/ingestion/financial_reconciliation/orchestrator.ex"
        ])
      )

    refute source =~ "HistoricalCoverageFence"
  end

  defp run_orchestrator(run) do
    Orchestrator.run(run, source_extractor: SourceStub, local_totals: LocalStub)
  end

  defp set_stubs!(source, local) do
    Application.put_env(:event_sales, :orchestrator_source_result, source)
    Application.put_env(:event_sales, :orchestrator_local_result, local)
  end

  defp successful_result(sync_run, currency \\ "ZAR", overrides \\ %{}) do
    FinancialReconciliationHelpers.successful_result(sync_run, currency, overrides)
  end

  defp list_metrics(run_id) do
    FinancialReconciliationMetric
    |> Ash.Query.filter(financial_reconciliation_run_id == ^run_id)
    |> Ash.read!(domain: Ingestion)
  end

  defp list_findings(run_id) do
    FinancialReconciliationFinding
    |> Ash.Query.filter(financial_reconciliation_run_id == ^run_id)
    |> Ash.read!(domain: Ingestion)
  end
end
