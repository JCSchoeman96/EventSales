defmodule EventSales.Ingestion.Parsers.WoocommerceRefundParserTest do
  use ExUnit.Case, async: true

  alias EventSales.Ingestion.Parsers.WoocommerceRefundParser

  test "normalizes full refund detail without changing independent quantity and money" do
    payload = %{
      "id" => 91_003,
      "amount" => "52.00",
      "reason" => "Synthetic refund",
      "date_created_gmt" => "2026-05-01T09:00:00.123456",
      "line_items" => [
        %{
          "id" => 88_001,
          "product_id" => 501,
          "variation_id" => 601,
          "quantity" => -1,
          "subtotal" => "-50.00",
          "total" => "-45.00",
          "total_tax" => "-4.50",
          "meta_data" => [%{"key" => "_refunded_item_id", "value" => "70001"}]
        }
      ],
      "shipping_lines" => [%{"total" => "-5.00", "total_tax" => "-0.50"}],
      "fee_lines" => [%{"total" => "-2.00", "total_tax" => "-0.20"}],
      "tax_lines" => [%{"rate_id" => 1, "tax_total" => "-4.50"}]
    }

    assert {:ok, refund} = WoocommerceRefundParser.parse(payload)
    assert refund.woo_refund_id == 91_003
    assert refund.header_amount == Decimal.new("52.00")
    assert refund.reason == "Synthetic refund"
    assert refund.source_created_at == ~U[2026-05-01 09:00:00.123456Z]
    assert refund.shipping_refund_amount == Decimal.new("5.00")
    assert refund.shipping_refund_tax == Decimal.new("0.50")
    assert refund.fee_refund_amount == Decimal.new("2.00")
    assert refund.fee_refund_tax == Decimal.new("0.20")

    assert [line] = refund.line_items
    assert line.woo_refund_line_item_id == 88_001
    assert line.woo_refunded_item_id == 70_001
    assert line.woo_product_id == 501
    assert line.woo_variation_id == 601
    assert line.refunded_quantity == 1
    assert line.refund_subtotal_amount == Decimal.new("50.00")
    assert line.refund_total_amount == Decimal.new("45.00")
    assert line.refund_total_tax == Decimal.new("4.50")
  end

  test "supports value-only refunds and does not invent source timestamp" do
    assert {:ok, refund} =
             WoocommerceRefundParser.parse(%{
               "id" => 91_006,
               "amount" => "12.50",
               "line_items" => [],
               "shipping_lines" => [],
               "fee_lines" => []
             })

    assert refund.line_items == []
    assert refund.header_amount == Decimal.new("12.50")
    assert refund.source_created_at == nil
  end

  test "keeps absent quantity and tax distinct from explicit zero" do
    payload = %{
      "id" => 91_007,
      "amount" => "2.00",
      "line_items" => [
        %{"id" => 88_007, "quantity" => nil, "subtotal" => "0.00", "total" => "0.00"},
        %{
          "id" => 88_008,
          "quantity" => 0,
          "subtotal" => "0.00",
          "total" => "0.00",
          "total_tax" => "0.00"
        }
      ]
    }

    assert {:ok, %{line_items: [missing, explicit_zero]}} = WoocommerceRefundParser.parse(payload)
    assert missing.refunded_quantity == nil
    assert missing.refund_total_tax == nil
    assert explicit_zero.refunded_quantity == 0
    assert explicit_zero.refund_total_tax == Decimal.new("0.00")
  end

  test "missing or malformed binders remain unbound without fuzzy fallback" do
    payload = %{
      "id" => 91_008,
      "amount" => "3.00",
      "line_items" => [
        %{"id" => 88_009, "name" => "same name", "product_id" => 501},
        %{
          "id" => 88_010,
          "product_id" => 501,
          "meta_data" => [%{"key" => "_refunded_item_id", "value" => "not-an-id"}]
        }
      ]
    }

    assert {:ok, %{line_items: [missing, malformed]}} = WoocommerceRefundParser.parse(payload)
    assert missing.woo_refunded_item_id == nil
    assert missing.binding_reason == "missing_refunded_item_id"
    assert malformed.woo_refunded_item_id == nil
    assert malformed.binding_reason == "invalid_refunded_item_id"
  end

  test "rejects malformed required detail and timestamp values" do
    assert {:error, {:invalid_refund_payload, :id, :must_be_positive}} =
             WoocommerceRefundParser.parse(%{"id" => 0, "amount" => "1.00"})

    assert {:error, {:invalid_refund_payload, :amount, :invalid}} =
             WoocommerceRefundParser.parse(%{"id" => 91_009, "amount" => "not-decimal"})

    assert {:error, {:invalid_refund_payload, :date_created_gmt, :invalid}} =
             WoocommerceRefundParser.parse(%{
               "id" => 91_009,
               "amount" => "1.00",
               "date_created_gmt" => "not-a-datetime"
             })
  end
end
