defmodule EventSales.Ingestion.FinancialReconciliationFindingTest do
  use EventSales.DataCase, async: false

  alias EventSales.Ingestion
  alias EventSales.Ingestion.FinancialReconciliation.FindingFingerprint
  alias EventSales.Ingestion.FinancialReconciliationRuns
  alias EventSales.Ingestion.Resources.FinancialReconciliationFinding
  alias EventSales.TestSupport.{FinancialReconciliationHelpers, SalesHelpers}

  @authorized_context %{
    financial_reconciliation_state_authorized?: true,
    financial_reconciliation_state_authorized: true
  }

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Finding Test"})
    run = queue_run!(event)

    {:ok, run: run}
  end

  test "accepts structural categories with deterministic fingerprint", %{run: run} do
    details = %{kind: :order, reason: "missing"}
    {:ok, fingerprint} = FindingFingerprint.compute(:missing_source_fact, :source, details)
    {:ok, normalized} = FindingFingerprint.normalize_details(details)

    assert {:ok, finding} =
             persist_finding(%{
               financial_reconciliation_run_id: run.id,
               category: :missing_source_fact,
               origin: :source,
               details: normalized,
               fingerprint: fingerprint
             })

    assert finding.category == :missing_source_fact
    assert finding.origin == :source
  end

  test "rejects numeric mismatch categories", %{run: run} do
    details = %{currency: "ZAR"}
    {:ok, fingerprint} = FindingFingerprint.compute(:gross_value_mismatch, :comparator, details)
    {:ok, normalized} = FindingFingerprint.normalize_details(details)

    assert {:error, %Ash.Error.Invalid{}} =
             persist_finding(%{
               financial_reconciliation_run_id: run.id,
               category: :gross_value_mismatch,
               origin: :comparator,
               details: normalized,
               fingerprint: fingerprint
             })
  end

  test "rejects details larger than 4096 bytes", %{run: run} do
    details = %{blob: String.duplicate("x", 5000)}
    {:ok, fingerprint} = FindingFingerprint.compute(:invalid_scope, :source, details)
    {:ok, normalized} = FindingFingerprint.normalize_details(details)

    assert {:error, %Ash.Error.Invalid{}} =
             persist_finding(%{
               financial_reconciliation_run_id: run.id,
               category: :invalid_scope,
               origin: :source,
               details: normalized,
               fingerprint: fingerprint
             })
  end

  test "enforces unique run/fingerprint identity", %{run: run} do
    details = %{kind: :order}
    {:ok, fingerprint} = FindingFingerprint.compute(:missing_source_fact, :source, details)
    {:ok, normalized} = FindingFingerprint.normalize_details(details)

    attrs = %{
      financial_reconciliation_run_id: run.id,
      category: :missing_source_fact,
      origin: :source,
      details: normalized,
      fingerprint: fingerprint
    }

    assert {:ok, _} = persist_finding(attrs)
    assert {:error, %Ash.Error.Invalid{}} = persist_finding(attrs)
  end

  defp persist_finding(attrs) do
    FinancialReconciliationFinding
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_context(@authorized_context)
    |> Ash.Changeset.for_create(:persist, attrs)
    |> Ash.create(domain: Ingestion)
  end

  defp queue_run!(event) do
    FinancialReconciliationHelpers.certified_run!(event)

    {:ok, %{financial_reconciliation_run: run}} =
      FinancialReconciliationRuns.queue_system_for_event(event.id,
        internal?: true,
        oban_insert: fn _ -> {:ok, %{}} end
      )

    run
  end
end
