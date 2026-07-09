defmodule EventSales.Ingestion.Parsers.WoocommerceOrderParserTest do
  use ExUnit.Case, async: true

  alias EventSales.Ingestion.Parsers.WoocommerceOrderParser
  alias EventSales.TestSupport.FixtureHelpers

  describe "parse/1" do
    test "parses a completed order payload" do
      payload = fixture(:order_completed)

      assert {:ok, order} = WoocommerceOrderParser.parse(payload)

      assert order.woo_order_id == 10_001
      assert order.order_number == "ES-10001"
      assert order.status == :completed
      assert order.currency == "ZAR"
      assert DateTime.compare(order.completed_at, ~U[2026-05-01 08:05:00Z]) == :eq
      assert DateTime.compare(order.created_at_source, ~U[2026-05-01 08:00:00Z]) == :eq
      assert DateTime.compare(order.updated_at_source, ~U[2026-05-01 08:05:00Z]) == :eq
      assert order.customer_name == "Synthetic Buyer"
      assert order.customer_email == "synthetic.completed@example.test"
      assert order.raw_total == Decimal.new("900.00")
      assert order.raw_discount_total == Decimal.new("100.00")
      assert order.raw_tax_total == Decimal.new("0.00")
      assert order.payment_method == "payfast"
      assert order.payment_method_title == "Synthetic PayFast"
      assert order.payment_gateway_transaction_id == "synthetic-txn-completed"
    end

    test "parses pending, refunded, and cancelled statuses with explicit mapping" do
      pending = fixture(:order_pending)
      refunded = fixture(:order_refunded)
      cancelled = Map.put(pending, "status", "cancelled")

      assert {:ok, %{status: :pending, completed_at: nil}} =
               WoocommerceOrderParser.parse(pending)

      assert {:ok, %{status: :refunded}} = WoocommerceOrderParser.parse(refunded)
      assert {:ok, %{status: :cancelled}} = WoocommerceOrderParser.parse(cancelled)
    end

    test "parses line item quantity, product ids, variation ids, totals, and coupons" do
      payload = fixture(:order_completed)

      assert {:ok, order} = WoocommerceOrderParser.parse(payload)
      assert [line] = order.line_items

      assert line.woo_line_item_id == 70_001
      assert line.woo_product_id == 501
      assert line.woo_variation_id == 601
      assert line.quantity == 2
      assert line.name == "Synthetic General Admission"
      assert line.line_subtotal == Decimal.new("1000.00")
      assert line.line_total == Decimal.new("900.00")
      assert line.discount_total == Decimal.new("100.00")

      assert [
               %{
                 code: "SYNTHETIC100",
                 discount_amount: discount_amount,
                 discount_tax: discount_tax
               }
             ] =
               order.coupons

      assert discount_amount == Decimal.new("100.00")
      assert discount_tax == Decimal.new("0.00")
    end

    test "parses allowlisted line-level Tickera event id metadata" do
      payload =
        :order_completed
        |> fixture()
        |> put_in(
          ["line_items", Access.at(0), "meta_data"],
          [
            %{"id" => 1, "key" => "tickera_event_id", "value" => "109120"},
            %{"id" => 2, "key" => "tickera_event_name", "value" => "Display Only"}
          ]
        )

      assert {:ok, order} = WoocommerceOrderParser.parse(payload)
      assert [line] = order.line_items
      assert line.source_tickera_event_id == 109_120
      assert line.attribution_status_reason == nil
    end

    test "does not infer event id from display names" do
      payload =
        :order_completed
        |> fixture()
        |> put_in(["line_items", Access.at(0), "name"], "WR 109120 Display")
        |> put_in(
          ["line_items", Access.at(0), "meta_data"],
          [%{"id" => 1, "key" => "tickera_event_name", "value" => "WR 109120"}]
        )

      assert {:ok, order} = WoocommerceOrderParser.parse(payload)
      assert [line] = order.line_items
      assert line.source_tickera_event_id == nil
      assert line.attribution_status_reason == nil
    end

    test "invalid or conflicting line-level Tickera event ids become review reasons" do
      invalid =
        :order_completed
        |> fixture()
        |> put_in(
          ["line_items", Access.at(0), "meta_data"],
          [%{"id" => 1, "key" => "tickera_event_id", "value" => "not-an-id"}]
        )

      assert {:ok, %{line_items: [invalid_line]}} = WoocommerceOrderParser.parse(invalid)
      assert invalid_line.source_tickera_event_id == nil
      assert invalid_line.attribution_status_reason == :invalid_source_tickera_event_id

      conflicting =
        :order_completed
        |> fixture()
        |> put_in(
          ["line_items", Access.at(0), "meta_data"],
          [
            %{"id" => 1, "key" => "tickera_event_id", "value" => "109120"},
            %{"id" => 2, "key" => "tickera_event_id", "value" => 108_658}
          ]
        )

      assert {:ok, %{line_items: [conflict_line]}} =
               WoocommerceOrderParser.parse(conflicting)

      assert conflict_line.source_tickera_event_id == nil
      assert conflict_line.attribution_status_reason == :invalid_source_tickera_event_id
    end

    test "missing optional fields are safe" do
      payload =
        :order_pending
        |> fixture()
        |> Map.delete("billing")
        |> Map.delete("payment_method")
        |> Map.delete("payment_method_title")
        |> Map.delete("transaction_id")
        |> Map.delete("coupon_lines")

      assert {:ok, order} = WoocommerceOrderParser.parse(payload)

      assert order.customer_name == nil
      assert order.customer_email == nil
      assert order.payment_method == nil
      assert order.payment_method_title == nil
      assert order.payment_gateway_transaction_id == nil
      assert order.coupons == []
    end

    test "unsupported status returns a controlled error" do
      payload = Map.put(fixture(:order_completed), "status", "made-up")

      assert {:error, {:invalid_order_payload, :status, :unsupported}} =
               WoocommerceOrderParser.parse(payload)
    end

    test "malformed required fields return controlled errors" do
      payload = Map.put(fixture(:order_completed), "id", nil)

      assert {:error, {:invalid_order_payload, :id, :required}} =
               WoocommerceOrderParser.parse(payload)
    end
  end

  defp fixture(name), do: FixtureHelpers.decode_json_fixture!(:woocommerce, name)
end
