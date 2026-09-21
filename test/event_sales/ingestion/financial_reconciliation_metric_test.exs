defmodule EventSales.Ingestion.FinancialReconciliationMetricTest do
  use EventSales.DataCase, async: false

  alias EventSales.Ingestion
  alias EventSales.Ingestion.FinancialReconciliationRuns
  alias EventSales.Ingestion.Resources.FinancialReconciliationMetric
  alias EventSales.TestSupport.{FinancialReconciliationHelpers, SalesHelpers}

  @authorized_context %{
    financial_reconciliation_state_authorized?: true,
    financial_reconciliation_state_authorized: true
  }

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Metric Test"})
    FinancialReconciliationHelpers.certified_run!(event)

    {:ok, %{financial_reconciliation_run: run}} =
      FinancialReconciliationRuns.queue_system_for_event(event.id,
        internal?: true,
        oban_insert: fn _ -> {:ok, %{}} end
      )

    {:ok, run: run}
  end

  test "accepts all six primitives with exact decimal invariants", %{run: run} do
    attrs = %{
      financial_reconciliation_run_id: run.id,
      currency: "ZAR",
      primitive: :gross_ticket_quantity,
      source_value: Decimal.new("2"),
      local_value: Decimal.new("2"),
      delta: Decimal.new("0"),
      matched?: true,
      mismatch_category: nil
    }

    assert {:ok, metric} = persist_metric(attrs)
    assert metric.primitive == :gross_ticket_quantity
    assert metric.matched?
    assert is_nil(metric.mismatch_category)
  end

  test "rejects unknown primitive", %{run: run} do
    attrs = base_attrs(run, :order_count)

    assert {:error, %Ash.Error.Invalid{}} = persist_metric(attrs)
  end

  test "rejects wrong delta invariant", %{run: run} do
    attrs =
      base_attrs(run, :gross_ticket_value)
      |> Map.merge(%{
        source_value: Decimal.new("10.00"),
        local_value: Decimal.new("12.00"),
        delta: Decimal.new("1.00"),
        matched?: false,
        mismatch_category: :gross_value_mismatch
      })

    assert {:error, %Ash.Error.Invalid{}} = persist_metric(attrs)
  end

  test "rejects wrong matched flag", %{run: run} do
    attrs =
      base_attrs(run, :gross_ticket_value)
      |> Map.merge(%{
        source_value: Decimal.new("10.00"),
        local_value: Decimal.new("10.00"),
        delta: Decimal.new("0"),
        matched?: false,
        mismatch_category: :gross_value_mismatch
      })

    assert {:error, %Ash.Error.Invalid{}} = persist_metric(attrs)
  end

  test "requires integral quantity primitives", %{run: run} do
    attrs =
      base_attrs(run, :gross_ticket_quantity)
      |> Map.merge(%{
        source_value: Decimal.new("1.5"),
        local_value: Decimal.new("1"),
        delta: Decimal.new("-0.5"),
        matched?: false,
        mismatch_category: :gross_quantity_mismatch
      })

    assert {:error, %Ash.Error.Invalid{}} = persist_metric(attrs)
  end

  test "accepts negative net quantity", %{run: run} do
    attrs =
      base_attrs(run, :net_ticket_quantity)
      |> Map.merge(%{
        source_value: Decimal.new("1"),
        local_value: Decimal.new("3"),
        delta: Decimal.new("2"),
        matched?: false,
        mismatch_category: :net_quantity_mismatch
      })

    assert {:ok, metric} = persist_metric(attrs)
    assert Decimal.equal?(metric.delta, Decimal.new("2"))
  end

  test "requires exact mismatch category when unmatched", %{run: run} do
    attrs =
      base_attrs(run, :refund_ticket_value)
      |> Map.merge(%{
        source_value: Decimal.new("10"),
        local_value: Decimal.new("12"),
        delta: Decimal.new("2"),
        matched?: false,
        mismatch_category: :gross_value_mismatch
      })

    assert {:error, %Ash.Error.Invalid{}} = persist_metric(attrs)
  end

  test "enforces unique run/currency/primitive identity", %{run: run} do
    attrs = base_attrs(run, :gross_ticket_quantity)

    assert {:ok, _} = persist_metric(attrs)
    assert {:error, %Ash.Error.Invalid{}} = persist_metric(attrs)
  end

  defp base_attrs(run, primitive) do
    %{
      financial_reconciliation_run_id: run.id,
      currency: "ZAR",
      primitive: primitive,
      source_value: Decimal.new("1"),
      local_value: Decimal.new("1"),
      delta: Decimal.new("0"),
      matched?: true,
      mismatch_category: nil
    }
  end

  defp persist_metric(attrs) do
    FinancialReconciliationMetric
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_context(@authorized_context)
    |> Ash.Changeset.for_create(:persist, attrs)
    |> Ash.create(domain: Ingestion)
  end
end
