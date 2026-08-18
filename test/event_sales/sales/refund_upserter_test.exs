defmodule EventSales.Sales.RefundUpserterTest do
  use EventSales.DataCase, async: false

  alias EventSales.Sales
  alias EventSales.Sales.RefundUpserter
  alias EventSales.Sales.Resources.Refund
  alias EventSales.TestSupport.SalesHelpers

  setup do
    {:ok, source: SalesHelpers.create_source_system!()}
  end

  test "creates one reference-only refund and replays it idempotently", %{source: source} do
    reference = %{
      woo_refund_id: 91_001,
      summary_total_amount: Decimal.new("45.00"),
      reason: "duplicate"
    }

    assert {:ok, first} = RefundUpserter.upsert_reference(source.id, 10_001, reference)
    assert {:ok, second} = RefundUpserter.upsert_reference(source.id, 10_001, reference)
    assert first.id == second.id
    assert second.detail_status == :reference_only
    assert second.source_state == :active
    assert Ash.count!(Refund, domain: Sales) == 1
  end

  test "rejects a reference without a positive refund identity", %{source: source} do
    assert {:error, {:invalid_refund_identity, :woo_refund_id}} =
             RefundUpserter.upsert_reference(source.id, 10_001, %{})

    assert Ash.count!(Refund, domain: Sales) == 0
  end
end
