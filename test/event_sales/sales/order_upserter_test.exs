defmodule EventSales.Sales.OrderUpserterTest do
  use EventSales.DataCase, async: true

  require Ash.Query

  alias EventSales.Ingestion.Parsers.WoocommerceOrderParser
  alias EventSales.Sales
  alias EventSales.Sales.OrderUpserter
  alias EventSales.Sales.Resources.{CouponSnapshot, Order, OrderItem}
  alias EventSales.TestSupport.{FixtureHelpers, SalesHelpers}

  setup do
    source = SalesHelpers.create_source_system!()
    {:ok, source: source}
  end

  test "creates order, items, and coupons from a valid payload", %{source: source} do
    payload = fixture(:order_completed)

    assert {:ok, order} = OrderUpserter.upsert_order(source.id, payload)

    assert order.woo_order_id == 10_001
    assert order.status == :completed
    assert order.payment_gateway_transaction_id == "synthetic-txn-completed"

    assert [line] = order_items(order.id)
    assert line.woo_line_item_id == 70_001
    assert line.quantity == 2
    assert line.line_total == Decimal.new("900.00")
    assert line.mapping_status == :pending_mapping_resolution
    assert line.item_kind == :unknown

    assert [%CouponSnapshot{code: "SYNTHETIC100"}] = coupons(order.id)
  end

  test "rerunning the same payload is idempotent", %{source: source} do
    payload = fixture(:order_completed)

    assert {:ok, first} = OrderUpserter.upsert_order(source.id, payload)
    assert {:ok, second} = OrderUpserter.upsert_order(source.id, payload)

    assert first.id == second.id
    assert Ash.count!(Order, domain: Sales) == 1
    assert Ash.count!(OrderItem, domain: Sales) == 1
    assert Ash.count!(CouponSnapshot, domain: Sales) == 1
  end

  test "newer payload updates existing order and upserts child rows", %{source: source} do
    payload = fixture(:order_pending)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, payload)

    newer =
      payload
      |> Map.put("status", "completed")
      |> Map.put("date_modified_gmt", "2026-05-01T09:10:00")
      |> Map.put("date_completed_gmt", "2026-05-01T09:10:00")
      |> Map.put("total", "500.00")
      |> put_in(["line_items", Access.at(0), "total"], "500.00")

    assert {:ok, updated} = OrderUpserter.upsert_order(source.id, newer)

    assert updated.id == order.id
    assert updated.status == :completed
    assert updated.updated_at_source == ~U[2026-05-01 09:10:00.000000Z]
    assert updated.raw_total == Decimal.new("500.00")

    assert [line] = order_items(order.id)
    assert line.line_total == Decimal.new("500.00")
  end

  test "stale payload returns stale_noop before mutating order, items, or coupons", %{
    source: source
  } do
    newer = fixture(:order_completed)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, newer)

    stale =
      newer
      |> Map.put("date_modified_gmt", "2026-05-01T08:01:00")
      |> Map.put("status", "pending")
      |> Map.put("total", "1.00")
      |> put_in(["line_items", Access.at(0), "total"], "1.00")
      |> Map.put("coupon_lines", [
        %{"id" => 91_111, "code" => "STALE", "discount" => "999.00", "discount_tax" => "0.00"}
      ])

    assert {:ok, :stale_noop} = OrderUpserter.upsert_order(source.id, stale)

    persisted = Ash.get!(Order, order.id, domain: Sales)
    assert persisted.status == :completed
    assert persisted.raw_total == Decimal.new("900.00")

    assert [line] = order_items(order.id)
    assert line.line_total == Decimal.new("900.00")

    assert [%CouponSnapshot{code: "SYNTHETIC100"}] = coupons(order.id)
  end

  test "missing child rows in a newer payload are not deleted", %{source: source} do
    mixed = fixture(:order_mixed_event)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, mixed)
    assert length(order_items(order.id)) == 2
    assert length(coupons(order.id)) == 1

    newer_missing_children =
      mixed
      |> Map.put("date_modified_gmt", "2026-05-03T08:10:00")
      |> Map.put("line_items", [hd(mixed["line_items"])])
      |> Map.put("coupon_lines", [])

    assert {:ok, _updated} = OrderUpserter.upsert_order(source.id, newer_missing_children)

    assert length(order_items(order.id)) == 2
    assert length(coupons(order.id)) == 1
  end

  test "parse result can be persisted without re-parsing", %{source: source} do
    assert {:ok, normalized} = WoocommerceOrderParser.parse(fixture(:order_completed))

    assert {:ok, order} = OrderUpserter.upsert_normalized_order(source.id, normalized)

    assert order.woo_order_id == normalized.woo_order_id
  end

  defp fixture(name), do: FixtureHelpers.decode_json_fixture!(:woocommerce, name)

  defp order_items(order_id) do
    OrderItem
    |> Ash.Query.filter(order_id == ^order_id)
    |> Ash.read!(domain: Sales)
    |> Enum.sort_by(& &1.woo_line_item_id)
  end

  defp coupons(order_id) do
    CouponSnapshot
    |> Ash.Query.filter(order_id == ^order_id)
    |> Ash.read!(domain: Sales)
    |> Enum.sort_by(& &1.code)
  end
end
