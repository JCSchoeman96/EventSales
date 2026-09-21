defmodule EventSales.Ingestion.FinancialReconciliationDbConstraintsTest do
  use EventSales.DataCase, async: false

  alias EventSales.Ingestion.FinancialReconciliationRuns
  alias EventSales.Repo
  alias EventSales.TestSupport.{FinancialReconciliationHelpers, SalesHelpers}

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "DB Constraint Event"})
    sync_run = FinancialReconciliationHelpers.certified_run!(event)

    {:ok, %{financial_reconciliation_run: run}} =
      FinancialReconciliationRuns.queue_system_for_event(event.id,
        internal?: true,
        oban_insert: fn _ -> {:ok, %{}} end
      )

    {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)

    %{
      event: event,
      sync_run: sync_run,
      run: started
    }
  end

  test "rejects invalid run status at database level", %{run: run} do
    assert {:error, %Postgrex.Error{}} =
             Repo.query(
               "UPDATE ingestion_financial_reconciliation_runs SET status = $1 WHERE id = $2",
               ["bogus", Ecto.UUID.dump!(run.id)]
             )
  end

  test "rejects invalid metric primitive at database level", %{run: run} do
    assert {:error, %Postgrex.Error{}} =
             insert_metric(run.id, %{primitive: "not_a_primitive"})
  end

  test "rejects wrong metric delta at database level", %{run: run} do
    assert {:error, %Postgrex.Error{}} =
             insert_metric(run.id, %{
               source_value: Decimal.new("10"),
               local_value: Decimal.new("12"),
               delta: Decimal.new("0"),
               matched?: false,
               mismatch_category: "gross_value_mismatch"
             })
  end

  test "rejects wrong matched flag at database level", %{run: run} do
    assert {:error, %Postgrex.Error{}} =
             insert_metric(run.id, %{
               source_value: Decimal.new("10"),
               local_value: Decimal.new("10"),
               matched?: false,
               mismatch_category: "gross_value_mismatch"
             })
  end

  test "rejects wrong mismatch category at database level", %{run: run} do
    assert {:error, %Postgrex.Error{}} =
             insert_metric(run.id, %{
               source_value: Decimal.new("10"),
               local_value: Decimal.new("12"),
               delta: Decimal.new("2"),
               matched?: false,
               mismatch_category: "gross_quantity_mismatch"
             })
  end

  test "rejects fractional quantity primitive at database level", %{run: run} do
    assert {:error, %Postgrex.Error{}} =
             insert_metric(run.id, %{
               primitive: "gross_ticket_quantity",
               source_value: Decimal.new("1.5"),
               local_value: Decimal.new("2"),
               delta: Decimal.new("0.5"),
               matched?: false,
               mismatch_category: "gross_quantity_mismatch"
             })
  end

  test "rejects invalid finding origin at database level", %{run: run} do
    assert {:error, %Postgrex.Error{}} =
             insert_finding(run.id, %{
               category: "missing_source_fact",
               origin: "upstream",
               details: %{},
               fingerprint: valid_fingerprint()
             })
  end

  test "rejects invalid finding category at database level", %{run: run} do
    assert {:error, %Postgrex.Error{}} =
             insert_finding(run.id, %{
               category: "gross_value_mismatch",
               origin: "source",
               details: %{},
               fingerprint: valid_fingerprint()
             })
  end

  test "rejects invalid fingerprint format at database level", %{run: run} do
    assert {:error, %Postgrex.Error{}} =
             insert_finding(run.id, %{
               category: "missing_source_fact",
               origin: "source",
               details: %{},
               fingerprint: "not-a-valid-fingerprint"
             })
  end

  defp insert_metric(run_id, attrs) do
    defaults = %{
      id: Ecto.UUID.generate(),
      currency: "ZAR",
      primitive: "gross_ticket_value",
      source_value: Decimal.new("1"),
      local_value: Decimal.new("1"),
      delta: Decimal.new("0"),
      matched?: true,
      mismatch_category: nil,
      financial_reconciliation_run_id: run_id,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    attrs = Map.merge(defaults, attrs)

    Repo.query(
      """
      INSERT INTO ingestion_financial_reconciliation_metrics
      (id, currency, primitive, source_value, local_value, delta, "matched?", mismatch_category, financial_reconciliation_run_id, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
      """,
      [
        Ecto.UUID.dump!(attrs.id),
        attrs.currency,
        attrs.primitive,
        attrs.source_value,
        attrs.local_value,
        attrs.delta,
        attrs[:matched?],
        attrs.mismatch_category,
        Ecto.UUID.dump!(attrs.financial_reconciliation_run_id),
        attrs.inserted_at,
        attrs.updated_at
      ]
    )
  end

  defp insert_finding(run_id, attrs) do
    defaults = %{
      id: Ecto.UUID.generate(),
      category: "missing_source_fact",
      origin: "source",
      details: %{},
      fingerprint: valid_fingerprint(),
      financial_reconciliation_run_id: run_id,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    attrs = Map.merge(defaults, attrs)

    Repo.query(
      """
      INSERT INTO ingestion_financial_reconciliation_findings
      (id, category, origin, details, fingerprint, financial_reconciliation_run_id, inserted_at, updated_at)
      VALUES ($1, $2, $3, $4::jsonb, $5, $6, $7, $8)
      """,
      [
        Ecto.UUID.dump!(attrs.id),
        attrs.category,
        attrs.origin,
        Jason.encode!(attrs.details),
        attrs.fingerprint,
        Ecto.UUID.dump!(attrs.financial_reconciliation_run_id),
        attrs.inserted_at,
        attrs.updated_at
      ]
    )
  end

  defp valid_fingerprint do
    :crypto.hash(:sha256, "fixture") |> Base.encode16(case: :lower)
  end
end
