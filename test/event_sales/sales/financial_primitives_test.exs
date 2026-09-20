defmodule EventSales.Sales.FinancialPrimitivesTest do
  use ExUnit.Case, async: true

  alias EventSales.Sales.FinancialPrimitives

  @zero Decimal.new("0")

  test "historically_recognised_order? accepts completed status or completion timestamp" do
    assert FinancialPrimitives.historically_recognised_order?(:completed, nil)
    refute FinancialPrimitives.historically_recognised_order?(:processing, nil)

    assert FinancialPrimitives.historically_recognised_order?(
             :processing,
             ~U[2026-08-01 10:00:00.000000Z]
           )
  end

  test "historically_recognised_source_order? accepts Woo completed status or completion timestamp" do
    assert FinancialPrimitives.historically_recognised_source_order?("completed", nil)
    refute FinancialPrimitives.historically_recognised_source_order?("processing", nil)

    assert FinancialPrimitives.historically_recognised_source_order?(
             "processing",
             ~U[2026-08-01 10:00:00.000000Z]
           )
  end

  test "primitive arithmetic derives net without clamping" do
    gross =
      FinancialPrimitives.empty_totals()
      |> Map.put(:gross_ticket_quantity, Decimal.new("3"))
      |> Map.put(:gross_ticket_value, Decimal.new("300"))
      |> Map.put(:refund_ticket_quantity, Decimal.new("1"))
      |> Map.put(:refund_ticket_value, Decimal.new("50"))

    totals = FinancialPrimitives.derive_net_totals(gross)

    assert Decimal.equal?(totals.net_ticket_quantity, Decimal.new("2"))
    assert Decimal.equal?(totals.net_ticket_value, Decimal.new("250"))
  end

  test "add_totals sums each primitive independently" do
    left =
      %{gross_ticket_quantity: Decimal.new("2"), gross_ticket_value: Decimal.new("20")}
      |> Map.merge(FinancialPrimitives.empty_totals(), fn _k, l, r -> l || r end)

    right =
      %{gross_ticket_quantity: Decimal.new("1"), gross_ticket_value: Decimal.new("10")}
      |> Map.merge(FinancialPrimitives.empty_totals(), fn _k, l, r -> l || r end)

    totals = FinancialPrimitives.add_totals(left, right)

    assert Decimal.equal?(totals.gross_ticket_quantity, Decimal.new("3"))
    assert Decimal.equal?(totals.gross_ticket_value, Decimal.new("30"))
    assert Decimal.equal?(totals.refund_ticket_quantity, @zero)
  end

  test "gross and refund helpers ignore non-positive quantities" do
    assert Decimal.equal?(FinancialPrimitives.gross_ticket_quantity(0), @zero)
    assert Decimal.equal?(FinancialPrimitives.refund_ticket_quantity(nil), @zero)
  end

  test "integral_quantity? accepts non-negative whole numbers" do
    assert FinancialPrimitives.integral_quantity?(Decimal.new("0"))
    assert FinancialPrimitives.integral_quantity?(Decimal.new("4"))
    refute FinancialPrimitives.integral_quantity?(Decimal.new("1.5"))
    refute FinancialPrimitives.integral_quantity?(Decimal.new("-1"))
  end
end
