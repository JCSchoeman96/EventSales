defmodule EventSales.Sales.Resources.RefundLineTest do
  use EventSales.DataCase, async: false

  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Refund, RefundLine}
  alias EventSales.TestSupport.SalesHelpers

  test "uses the refund-local line identity and keeps the original OrderItem binding nullable" do
    source = SalesHelpers.create_source_system!()
    refund = create_refund!(source)

    first =
      create_line!(refund, %{
        woo_refund_line_item_id: 88_001,
        refunded_quantity: 0,
        refund_total_amount: Decimal.new("0.00"),
        refund_total_tax: Decimal.new("0.00")
      })

    assert first.refund_id == refund.id
    assert first.order_item_id == nil
    assert first.refunded_quantity == 0
    assert first.refund_total_tax == Decimal.new("0.00")

    assert_raise Ash.Error.Invalid, fn ->
      create_line!(refund, %{woo_refund_line_item_id: 88_001})
    end
  end

  test "distinguishes unknown quantity and tax from explicit zero" do
    source = SalesHelpers.create_source_system!()
    refund = create_refund!(source, %{woo_refund_id: 91_011})

    missing =
      create_line!(refund, %{
        woo_refund_line_item_id: 88_011,
        refunded_quantity: nil,
        refund_total_tax: nil
      })

    positive =
      create_line!(refund, %{
        woo_refund_line_item_id: 88_012,
        refunded_quantity: 2,
        refund_total_amount: Decimal.new("12.00")
      })

    assert missing.refunded_quantity == nil
    assert missing.refund_total_tax == nil
    assert positive.refunded_quantity == 2
  end

  test "rejects negative durable quantity and money magnitudes" do
    source = SalesHelpers.create_source_system!()
    refund = create_refund!(source, %{woo_refund_id: 91_012})

    assert_raise Ash.Error.Invalid, fn ->
      create_line!(refund, %{woo_refund_line_item_id: 88_013, refunded_quantity: -1})
    end

    assert_raise Ash.Error.Invalid, fn ->
      create_line!(refund, %{
        woo_refund_line_item_id: 88_014,
        refund_total_amount: Decimal.new("-1.00")
      })
    end
  end

  defp create_refund!(source, attrs \\ %{}) do
    defaults = %{source_system_id: source.id, woo_order_id: 10_001, woo_refund_id: 91_010}

    Ash.create!(Refund, Map.merge(defaults, attrs), action: :create_reference, domain: Sales)
  end

  defp create_line!(refund, attrs) do
    defaults = %{refund_id: refund.id, woo_refund_line_item_id: 88_000}

    Ash.create!(RefundLine, Map.merge(defaults, attrs), action: :create_normalized, domain: Sales)
  end
end
