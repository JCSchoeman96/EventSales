defmodule EventSales.Sales.RefundUpserterTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Sales
  alias EventSales.Sales.RefundUpserter
  alias EventSales.Sales.Resources.{Refund, RefundLine}
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

  test "persists complete detail and binds a line to the exact parent order item", %{
    source: source
  } do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    source_line = order_line_fixture()
    order_item = SalesHelpers.create_order_item_from_line!(order, source_line)

    normalized =
      normalized_refund(92_001, [
        refund_line(88_101, order_item.woo_line_item_id)
      ])

    assert {:ok, refund} =
             RefundUpserter.upsert_normalized_refund(source.id, order.woo_order_id, normalized)

    assert refund.detail_status == :complete
    assert refund.order_id == order.id
    assert refund.currency == order.currency
    assert [persisted_line] = refund_lines(refund.id)
    assert persisted_line.order_item_id == order_item.id
    assert persisted_line.binding_reason == nil
    assert persisted_line.validation_reason == nil
  end

  test "keeps valid detail complete when the parent order is missing", %{source: source} do
    normalized =
      normalized_refund(92_002, [
        refund_line(88_102, 71_001)
      ])

    assert {:ok, refund} =
             RefundUpserter.upsert_normalized_refund(source.id, 10_001, normalized)

    assert refund.detail_status == :complete
    assert refund.order_id == nil
    assert refund.currency == nil
    assert refund.unresolved_reason == "parent_order_not_found"
    assert [persisted_line] = refund_lines(refund.id)
    assert persisted_line.order_item_id == nil
    assert persisted_line.binding_reason == "parent_order_not_found"
  end

  test "binds the same refund row after the parent order arrives", %{source: source} do
    normalized =
      normalized_refund(92_003, [
        refund_line(88_103, 71_001)
      ])

    assert {:ok, first} =
             RefundUpserter.upsert_normalized_refund(source.id, 10_001, normalized)

    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    order_item = SalesHelpers.create_order_item_from_line!(order, order_line_fixture())

    hydrated_line = refund_line(88_103, order_item.woo_line_item_id)

    assert {:ok, second} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(92_003, [hydrated_line])
             )

    assert second.id == first.id
    assert second.order_id == order.id
    assert second.currency == order.currency
    assert [%RefundLine{order_item_id: item_id}] = refund_lines(second.id)
    assert item_id == order_item.id
  end

  test "preserves parser binding reasons and never uses a fuzzy fallback", %{source: source} do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    order_item = SalesHelpers.create_order_item_from_line!(order, order_line_fixture())

    lines = [
      refund_line(88_104, nil, %{binding_reason: "missing_refunded_item_id"}),
      refund_line(88_105, 999_999, %{woo_product_id: order_item.woo_product_id})
    ]

    assert {:ok, refund} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(92_004, lines)
             )

    persisted = refund_lines(refund.id)
    assert [%RefundLine{} = missing, %RefundLine{} = unknown] = persisted
    assert missing.order_item_id == nil
    assert missing.binding_reason == "missing_refunded_item_id"
    assert unknown.order_item_id == nil
    assert unknown.binding_reason == "order_item_not_found"
  end

  test "keeps exact binding and records deterministic product and variation warnings", %{
    source: source
  } do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    order_item = SalesHelpers.create_order_item_from_line!(order, order_line_fixture())

    line =
      refund_line(order_item.woo_line_item_id + 10_000, order_item.woo_line_item_id, %{
        woo_product_id: 999_001,
        woo_variation_id: 999_002
      })

    assert {:ok, refund} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(92_005, [line])
             )

    assert [%RefundLine{} = persisted] = refund_lines(refund.id)
    assert persisted.order_item_id == order_item.id
    assert persisted.validation_reason == "product_id_mismatch|variation_id_mismatch"
  end

  test "persists a value-only refund without inventing refund lines", %{source: source} do
    normalized = normalized_refund(92_006, [])

    assert {:ok, refund} =
             RefundUpserter.upsert_normalized_refund(source.id, 10_001, normalized)

    assert refund.header_amount == Decimal.new("45.00")
    assert refund.detail_status == :complete
    assert refund_lines(refund.id) == []
  end

  defp normalized_refund(refund_id, line_items) do
    %{
      woo_refund_id: refund_id,
      header_amount: Decimal.new("45.00"),
      reason: "customer request",
      source_created_at: ~U[2026-05-01 10:00:00Z],
      line_items: line_items,
      shipping_refund_amount: nil,
      shipping_refund_tax: nil,
      fee_refund_amount: nil,
      fee_refund_tax: nil,
      unallocated_header_amount: Decimal.new("45.00")
    }
  end

  defp refund_line(line_id, refunded_item_id, attrs \\ %{}) do
    Map.merge(
      %{
        woo_refund_line_item_id: line_id,
        woo_refunded_item_id: refunded_item_id,
        woo_product_id: 501,
        woo_variation_id: 601,
        refunded_quantity: 1,
        refund_subtotal_amount: Decimal.new("40.00"),
        refund_total_amount: Decimal.new("45.00"),
        refund_total_tax: Decimal.new("5.00"),
        binding_reason: nil,
        validation_reason: nil
      },
      attrs
    )
  end

  defp order_line_fixture do
    %{
      "id" => 71_001,
      "product_id" => 501,
      "variation_id" => 601,
      "name" => "General Admission",
      "quantity" => 2,
      "subtotal" => "80.00",
      "total" => "80.00",
      "discount_total" => "0.00"
    }
  end

  defp refund_lines(refund_id) do
    RefundLine
    |> Ash.Query.filter(refund_id == ^refund_id)
    |> Ash.Query.sort(woo_refund_line_item_id: :asc)
    |> Ash.read!(domain: Sales)
  end
end
