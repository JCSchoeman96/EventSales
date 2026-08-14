defmodule EventSales.Sales.OrderUpserterExactReconciliationTest do
  use EventSales.DataCase, async: true

  require Ash.Query

  alias EventSales.Sales
  alias EventSales.Sales.OrderUpserter
  alias EventSales.Sales.Resources.{CouponSnapshot, Order, OrderItem}
  alias EventSales.TestSupport.{FixtureHelpers, SalesHelpers}

  setup do
    source = SalesHelpers.create_source_system!()
    event_a = SalesHelpers.create_event!(source, %{name: "Exact Event A"})
    event_b = SalesHelpers.create_event!(source, %{name: "Exact Event B"})

    {:ok, source: source, event_a: event_a, event_b: event_b}
  end

  test "reconciles an exact raw subset while preserving full order fields", %{
    source: source,
    event_a: event
  } do
    payload = fixture(:order_completed)
    [line] = payload["line_items"]

    assert {:ok, order} =
             OrderUpserter.reconcile_event_order(source.id, event.id, payload, [line])

    assert order.status == :completed
    assert order.raw_total == Decimal.new("900.00")
    assert order.payment_method == "payfast"
    assert order.payment_gateway_transaction_id == "synthetic-txn-completed"

    assert [%OrderItem{event_id: event_id, woo_line_item_id: 70_001}] = order_items(order.id)
    assert event_id == event.id
    assert [%CouponSnapshot{code: "SYNTHETIC100"}] = coupons(order.id)
  end

  test "rejects a synthetic event line before any write or pruning", %{
    source: source,
    event_a: event
  } do
    payload = fixture(:order_completed)
    [line] = payload["line_items"]
    synthetic_line = Map.put(line, "product_id", 999_999)

    assert {:error, _reason} =
             OrderUpserter.reconcile_event_order(source.id, event.id, payload, [synthetic_line])

    assert Ash.count!(Order, domain: Sales) == 0
    assert Ash.count!(OrderItem, domain: Sales) == 0
    assert Ash.count!(CouponSnapshot, domain: Sales) == 0
  end

  test "rejects duplicate full source line ids", %{source: source, event_a: event} do
    payload = fixture(:order_completed)
    [line] = payload["line_items"]
    invalid_payload = Map.put(payload, "line_items", [line, line])

    assert {:error, _reason} =
             OrderUpserter.reconcile_event_order(source.id, event.id, invalid_payload, [line])

    assert Ash.count!(Order, domain: Sales) == 0
  end

  test "rejects duplicate event subset ids", %{source: source, event_a: event} do
    payload = fixture(:order_completed)
    [line] = payload["line_items"]

    assert {:error, _reason} =
             OrderUpserter.reconcile_event_order(source.id, event.id, payload, [line, line])

    assert Ash.count!(Order, domain: Sales) == 0
  end

  test "rejects invalid full order authority before any write", %{
    source: source,
    event_a: event
  } do
    payload = fixture(:order_completed)
    [line] = payload["line_items"]

    invalid_payloads = [
      [],
      Map.put(payload, "id", 0),
      Map.put(payload, "line_items", :not_a_list),
      Map.put(payload, "line_items", [Map.put(line, "id", 0)])
    ]

    for invalid_payload <- invalid_payloads do
      assert {:error, _reason} =
               OrderUpserter.reconcile_event_order(source.id, event.id, invalid_payload, [line])
    end

    assert {:error, _reason} =
             OrderUpserter.reconcile_event_order(source.id, event.id, payload, :not_a_list)

    assert Ash.count!(Order, domain: Sales) == 0
  end

  test "creates and updates the current event line through OrderUpserter", %{
    source: source,
    event_a: event
  } do
    payload = fixture(:order_completed)
    [line] = payload["line_items"]

    assert {:ok, order} =
             OrderUpserter.reconcile_event_order(source.id, event.id, payload, [line])

    updated_payload =
      payload
      |> Map.put("date_modified_gmt", "2026-05-01T08:10:00")
      |> put_in(["line_items", Access.at(0), "total"], "850.00")

    [updated_line] = updated_payload["line_items"]

    assert {:ok, updated_order} =
             OrderUpserter.reconcile_event_order(
               source.id,
               event.id,
               updated_payload,
               [updated_line]
             )

    assert updated_order.id == order.id
    assert [%OrderItem{event_id: event_id, line_total: total}] = order_items(order.id)
    assert event_id == event.id
    assert total == Decimal.new("850.00")
  end

  test "removes a previously persisted event line absent from the current subset", %{
    source: source,
    event_a: event
  } do
    payload = fixture(:order_completed)
    [line] = payload["line_items"]

    assert {:ok, order} =
             OrderUpserter.reconcile_event_order(source.id, event.id, payload, [line])

    current_payload = Map.put(payload, "date_modified_gmt", "2026-05-01T08:10:00")

    assert {:ok, _updated} =
             OrderUpserter.reconcile_event_order(source.id, event.id, current_payload, [])

    assert order_items(order.id) == []
  end

  test "removes a line whose product or variation moved away from the event subset", %{
    source: source,
    event_a: event
  } do
    payload = fixture(:order_completed)
    [line] = payload["line_items"]

    assert {:ok, order} =
             OrderUpserter.reconcile_event_order(source.id, event.id, payload, [line])

    moved_payload =
      payload
      |> Map.put("date_modified_gmt", "2026-05-01T08:10:00")
      |> put_in(["line_items", Access.at(0), "product_id"], 999_999)
      |> put_in(["line_items", Access.at(0), "variation_id"], 999_998)

    assert {:ok, _updated} =
             OrderUpserter.reconcile_event_order(source.id, event.id, moved_payload, [])

    assert order_items(order.id) == []
  end

  test "zero current event lines removes only that event's rows", %{
    source: source,
    event_a: event_a,
    event_b: event_b
  } do
    payload = fixture(:order_mixed_event)
    [line_a, line_b] = payload["line_items"]

    assert {:ok, order} =
             OrderUpserter.reconcile_event_order(source.id, event_a.id, payload, [line_a])

    assert {:ok, _same_order} =
             OrderUpserter.reconcile_event_order(source.id, event_b.id, payload, [line_b])

    current_payload = Map.put(payload, "date_modified_gmt", "2026-05-03T08:10:00")

    assert {:ok, _updated} =
             OrderUpserter.reconcile_event_order(source.id, event_a.id, current_payload, [])

    assert [%OrderItem{event_id: event_b_id, woo_line_item_id: 70_005}] = order_items(order.id)
    assert event_b_id == event_b.id
  end

  test "reverse mixed-event reconciliation preserves the other event", %{
    source: source,
    event_a: event_a,
    event_b: event_b
  } do
    payload = fixture(:order_mixed_event)
    [line_a, line_b] = payload["line_items"]

    assert {:ok, order} =
             OrderUpserter.reconcile_event_order(source.id, event_b.id, payload, [line_b])

    assert {:ok, _same_order} =
             OrderUpserter.reconcile_event_order(source.id, event_a.id, payload, [line_a])

    current_payload = Map.put(payload, "date_modified_gmt", "2026-05-03T08:10:00")

    assert {:ok, _updated} =
             OrderUpserter.reconcile_event_order(source.id, event_b.id, current_payload, [])

    assert [%OrderItem{event_id: event_a_id, woo_line_item_id: 70_004}] = order_items(order.id)
    assert event_a_id == event_a.id
  end

  test "does not remove nil-event rows", %{source: source, event_a: event} do
    payload = fixture(:order_completed)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, payload)

    current_payload = Map.put(payload, "date_modified_gmt", "2026-05-01T08:10:00")

    assert {:ok, _updated} =
             OrderUpserter.reconcile_event_order(source.id, event.id, current_payload, [])

    assert [%OrderItem{event_id: nil, woo_line_item_id: 70_001}] = order_items(order.id)
  end

  test "does not remove another order's event items", %{
    source: source,
    event_a: event_a,
    event_b: event_b
  } do
    payload_a = fixture(:order_completed)
    payload_b = fixture(:order_pending) |> Map.put("id", 10_003)
    [line_a] = payload_a["line_items"]
    [line_b] = payload_b["line_items"]

    assert {:ok, order_a} =
             OrderUpserter.reconcile_event_order(source.id, event_a.id, payload_a, [line_a])

    assert {:ok, order_b} =
             OrderUpserter.reconcile_event_order(source.id, event_b.id, payload_b, [line_b])

    current_payload = Map.put(payload_a, "date_modified_gmt", "2026-05-01T08:10:00")

    assert {:ok, _updated} =
             OrderUpserter.reconcile_event_order(source.id, event_a.id, current_payload, [])

    assert order_items(order_a.id) == []
    assert [%OrderItem{event_id: event_b_id, woo_line_item_id: 70_002}] = order_items(order_b.id)
    assert event_b_id == event_b.id
  end

  test "stale source version returns stale_noop without pruning items or coupons", %{
    source: source,
    event_a: event
  } do
    payload = fixture(:order_completed)
    [line] = payload["line_items"]

    assert {:ok, order} =
             OrderUpserter.reconcile_event_order(source.id, event.id, payload, [line])

    stale_payload =
      payload
      |> Map.put("date_modified_gmt", "2026-05-01T08:01:00")
      |> Map.put("coupon_lines", [])

    assert {:ok, :stale_noop} =
             OrderUpserter.reconcile_event_order(source.id, event.id, stale_payload, [])

    assert [%OrderItem{event_id: event_id}] = order_items(order.id)
    assert event_id == event.id
    assert [%CouponSnapshot{code: "SYNTHETIC100"}] = coupons(order.id)
  end

  test "equal source version is accepted and may prune absent children", %{
    source: source,
    event_a: event
  } do
    payload = fixture(:order_completed)
    [line] = payload["line_items"]

    assert {:ok, order} =
             OrderUpserter.reconcile_event_order(source.id, event.id, payload, [line])

    current_payload = Map.put(payload, "coupon_lines", [])

    assert {:ok, same_order} =
             OrderUpserter.reconcile_event_order(source.id, event.id, current_payload, [])

    assert same_order.id == order.id
    assert order_items(order.id) == []
    assert coupons(order.id) == []
  end

  test "newer source version may prune absent children", %{source: source, event_a: event} do
    payload = fixture(:order_completed)
    [line] = payload["line_items"]

    assert {:ok, order} =
             OrderUpserter.reconcile_event_order(source.id, event.id, payload, [line])

    newer_payload =
      payload
      |> Map.put("date_modified_gmt", "2026-05-01T08:10:00")
      |> Map.put("coupon_lines", [])

    assert {:ok, updated} =
             OrderUpserter.reconcile_event_order(source.id, event.id, newer_payload, [])

    assert updated.id == order.id
    assert order_items(order.id) == []
    assert coupons(order.id) == []
  end

  test "upserts current coupons and removes coupons absent from the full source order", %{
    source: source,
    event_a: event
  } do
    payload = fixture(:order_completed)
    [line] = payload["line_items"]

    assert {:ok, order} =
             OrderUpserter.reconcile_event_order(source.id, event.id, payload, [line])

    updated_coupon_payload =
      payload
      |> Map.put("date_modified_gmt", "2026-05-01T08:10:00")
      |> put_in(["coupon_lines", Access.at(0), "discount"], "50.00")

    assert {:ok, _updated} =
             OrderUpserter.reconcile_event_order(
               source.id,
               event.id,
               updated_coupon_payload,
               [line]
             )

    assert [%CouponSnapshot{discount_amount: discount}] = coupons(order.id)
    assert discount == Decimal.new("50.00")

    removed_coupon_payload =
      updated_coupon_payload
      |> Map.put("date_modified_gmt", "2026-05-01T08:11:00")
      |> Map.put("coupon_lines", [])

    assert {:ok, _updated} =
             OrderUpserter.reconcile_event_order(source.id, event.id, removed_coupon_payload, [
               line
             ])

    assert coupons(order.id) == []
  end

  test "does not remove another order's coupons", %{source: source, event_a: event} do
    payload_a = fixture(:order_completed)
    payload_b = fixture(:order_completed) |> Map.put("id", 10_003)
    [line_a] = payload_a["line_items"]
    [line_b] = payload_b["line_items"]

    assert {:ok, order_a} =
             OrderUpserter.reconcile_event_order(source.id, event.id, payload_a, [line_a])

    assert {:ok, order_b} =
             OrderUpserter.reconcile_event_order(source.id, event.id, payload_b, [line_b])

    current_payload =
      payload_a
      |> Map.put("date_modified_gmt", "2026-05-01T08:10:00")
      |> Map.put("coupon_lines", [])

    assert {:ok, _updated} =
             OrderUpserter.reconcile_event_order(source.id, event.id, current_payload, [line_a])

    assert coupons(order_a.id) == []
    assert [%CouponSnapshot{code: "SYNTHETIC100"}] = coupons(order_b.id)
  end

  test "returns cleanup errors and a retry converges after partial cleanup", %{
    source: source,
    event_a: event
  } do
    payload = fixture(:order_mixed_event)
    [line_a, line_b] = payload["line_items"]

    assert {:ok, order} =
             OrderUpserter.reconcile_event_order(source.id, event.id, payload, [line_a, line_b])

    assert Enum.map(order_items(order.id), & &1.woo_line_item_id) == [70_004, 70_005]
    assert Enum.map(order_items(order.id), & &1.event_id) == [event.id, event.id]

    assert {:ok, queried_items} =
             OrderItem
             |> Ash.Query.filter(order_id == ^order.id and event_id == ^event.id)
             |> Ash.read(domain: Sales)

    assert Enum.map(queried_items, & &1.woo_line_item_id) == [70_004, 70_005]

    current_payload = Map.put(payload, "date_modified_gmt", "2026-05-03T08:10:00")

    destroyer = fn item, _action, action_opts ->
      send(self(), {:destroy_called, item.woo_line_item_id})

      if item.woo_line_item_id == 70_004 do
        Ash.destroy(item, action_opts)
      else
        {:error, :synthetic_cleanup_failure}
      end
    end

    result =
      OrderUpserter.reconcile_event_order(
        source.id,
        event.id,
        current_payload,
        [],
        source_absent_destroyer: destroyer
      )

    assert_receive {:destroy_called, 70_004}
    assert_receive {:destroy_called, 70_005}
    assert result == {:error, :synthetic_cleanup_failure}

    assert [%OrderItem{woo_line_item_id: 70_005}] = order_items(order.id)

    assert {:ok, _updated} =
             OrderUpserter.reconcile_event_order(source.id, event.id, current_payload, [])

    assert order_items(order.id) == []
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
