defmodule EventSales.Ingestion.Parsers.WoocommerceRefundReferenceParserTest do
  use ExUnit.Case, async: true

  alias EventSales.Ingestion.Parsers.WoocommerceRefundReferenceParser

  test "normalizes refund references and deduplicates by source refund id" do
    payload = %{
      "refunds" => [
        %{"id" => 91_003, "reason" => "Synthetic refund", "total" => "-45.00"},
        %{"id" => 91_003, "reason" => "duplicate", "total" => "-99.00"},
        %{"id" => 91_004, "reason" => nil, "total" => "0.00"}
      ]
    }

    assert {:ok, [first, second]} = WoocommerceRefundReferenceParser.parse(payload)

    assert first == %{
             woo_refund_id: 91_003,
             reason: "Synthetic refund",
             summary_total_amount: Decimal.new("45.00")
           }

    assert second == %{
             woo_refund_id: 91_004,
             reason: nil,
             summary_total_amount: Decimal.new("0.00")
           }
  end

  test "missing refunds are an empty discovery result" do
    assert {:ok, []} = WoocommerceRefundReferenceParser.parse(%{})
    assert {:ok, []} = WoocommerceRefundReferenceParser.parse(%{"refunds" => nil})
  end

  test "rejects a malformed refund reference id" do
    assert {:error, {:invalid_refund_reference, :id, :required}} =
             WoocommerceRefundReferenceParser.parse(%{"refunds" => [%{"total" => "1.00"}]})

    assert {:error, {:invalid_refund_reference, :id, :must_be_positive}} =
             WoocommerceRefundReferenceParser.parse(%{"refunds" => [%{"id" => 0}]})
  end

  test "keeps missing totals nullable and rejects malformed totals" do
    assert {:ok, [%{summary_total_amount: nil}]} =
             WoocommerceRefundReferenceParser.parse(%{"refunds" => [%{"id" => 91_005}]})

    assert {:error, {:invalid_refund_reference, :total, :invalid}} =
             WoocommerceRefundReferenceParser.parse(%{
               "refunds" => [%{"id" => 91_005, "total" => "not-decimal"}]
             })
  end
end
