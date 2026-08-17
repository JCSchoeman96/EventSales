defmodule EventSales.Sales.OrderUpserterTest do
  use EventSales.DataCase, async: true

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
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
    assert order.paid_at == nil

    assert [line] = order_items(order.id)
    assert line.woo_line_item_id == 70_001
    assert line.quantity == 2
    assert line.line_total == Decimal.new("900.00")
    assert line.line_total_tax == Decimal.new("0.00")
    assert line.mapping_status == :pending_mapping_resolution
    assert line.item_kind == :unknown

    assert [%CouponSnapshot{code: "SYNTHETIC100"}] = coupons(order.id)
  end

  test "creates order item with line-level source Tickera event id", %{source: source} do
    payload =
      :order_completed
      |> fixture()
      |> put_in(
        ["line_items", Access.at(0), "meta_data"],
        [%{"id" => 1, "key" => "tickera_event_id", "value" => "109120"}]
      )

    assert {:ok, order} = OrderUpserter.upsert_order(source.id, payload)
    assert [line] = order_items(order.id)
    assert line.source_tickera_event_id == 109_120
    assert line.attribution_status_reason == :source_event_not_found
  end

  test "maps pending order items after durable upsert when local mapping exists", %{
    source: source
  } do
    event = SalesHelpers.create_event!(source, %{name: "Mapped Event"})

    ticket =
      SalesHelpers.create_variation_ticket_type!(event, 501, 601, %{name: "General Admission"})

    create_mapping!(source, event, ticket, %{
      woo_product_id: 501,
      woo_variation_id: 601
    })

    assert {:ok, order} = OrderUpserter.upsert_order(source.id, fixture(:order_completed))

    assert [line] = order_items(order.id)
    assert line.mapping_status == :mapped
    assert line.item_kind == :ticket
    assert line.event_id == event.id
    assert line.ticket_type_id == ticket.id
  end

  test "defers on-hold mapping until a completed order update arrives", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Mapped Event"})

    ticket =
      SalesHelpers.create_variation_ticket_type!(event, 501, 601, %{name: "General Admission"})

    create_mapping!(source, event, ticket, %{
      woo_product_id: 501,
      woo_variation_id: 601
    })

    on_hold =
      :order_completed
      |> fixture()
      |> Map.put("status", "on-hold")
      |> Map.put("date_modified_gmt", "2026-05-01T09:05:00")

    assert {:ok, order} = OrderUpserter.upsert_order(source.id, on_hold)
    assert order.status == :on_hold

    assert [pending] = order_items(order.id)
    assert pending.mapping_status == :pending_mapping_resolution
    assert pending.event_id == nil
    assert pending.ticket_type_id == nil

    completed =
      on_hold
      |> Map.put("status", "completed")
      |> Map.put("date_modified_gmt", "2026-05-01T09:10:00")
      |> Map.put("date_completed_gmt", "2026-05-01T09:10:00")

    assert {:ok, updated} = OrderUpserter.upsert_order(source.id, completed)
    assert updated.status == :completed

    assert [mapped] = order_items(order.id)
    assert mapped.mapping_status == :mapped
    assert mapped.event_id == event.id
    assert mapped.ticket_type_id == ticket.id
  end

  test "unknown products stay pending mapping resolution after upsert", %{source: source} do
    payload =
      :order_completed
      |> fixture()
      |> put_in(["line_items", Access.at(0), "product_id"], 999_999)
      |> put_in(["line_items", Access.at(0), "variation_id"], 0)

    assert {:ok, order} = OrderUpserter.upsert_order(source.id, payload)

    assert [line] = order_items(order.id)
    assert line.mapping_status == :pending_mapping_resolution
    assert line.item_kind == :unknown
    assert line.event_id == nil
    assert line.ticket_type_id == nil
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
      |> Map.put("date_paid_gmt", "2026-05-01T09:09:00.123456")
      |> Map.put("total", "500.00")
      |> put_in(["line_items", Access.at(0), "total"], "500.00")
      |> put_in(["line_items", Access.at(0), "total_tax"], "10.25")

    assert {:ok, updated} = OrderUpserter.upsert_order(source.id, newer)

    assert updated.id == order.id
    assert updated.status == :completed
    assert updated.updated_at_source == ~U[2026-05-01 09:10:00.000000Z]
    assert updated.paid_at == ~U[2026-05-01 09:09:00.123456Z]
    assert updated.raw_total == Decimal.new("500.00")

    assert [line] = order_items(order.id)
    assert line.line_total == Decimal.new("500.00")
    assert line.line_total_tax == Decimal.new("10.25")
  end

  test "equal source replay hydrates only missing payment time", %{source: source} do
    initial =
      fixture(:order_pending)
      |> put_in(["line_items", Access.at(0), "total_tax"], nil)

    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial)
    assert order.paid_at == nil
    assert [%{line_total_tax: nil}] = order_items(order.id)

    replay =
      initial
      |> Map.put("date_paid_gmt", "2026-05-01T08:03:00.000000")
      |> Map.put("status", "completed")
      |> Map.put("number", "SHOULD-NOT-OVERWRITE")
      |> Map.put("total", "1.00")
      |> put_in(["line_items", Access.at(0), "total_tax"], "5.25")

    assert {:ok, hydrated} = OrderUpserter.upsert_order(source.id, replay)
    assert hydrated.id == order.id
    assert hydrated.paid_at == ~U[2026-05-01 08:03:00.000000Z]

    persisted = Ash.get!(Order, order.id, domain: Sales)
    assert persisted.paid_at == ~U[2026-05-01 08:03:00.000000Z]
    assert persisted.status == :pending
    assert persisted.order_number == initial["number"]
    assert persisted.raw_total == Decimal.new(initial["total"])
    assert [%{line_total_tax: line_total_tax}] = order_items(order.id)
    assert line_total_tax == Decimal.new("5.25")
  end

  test "equal source replay never clears or replaces an existing payment time", %{
    source: source
  } do
    initial = Map.put(fixture(:order_completed), "date_paid_gmt", "2026-05-01T08:03:00")
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial)

    cleared = Map.put(initial, "date_paid_gmt", nil)
    assert {:ok, replayed} = OrderUpserter.upsert_order(source.id, cleared)
    assert replayed.paid_at == ~U[2026-05-01 08:03:00.000000Z]

    replaced = Map.put(initial, "date_paid_gmt", "2026-05-01T08:04:00")
    assert {:ok, replayed_again} = OrderUpserter.upsert_order(source.id, replaced)
    assert replayed_again.paid_at == ~U[2026-05-01 08:03:00.000000Z]

    assert {:error, _error} =
             Ash.update(
               order,
               %{
                 paid_at: ~U[2026-05-01 08:05:00.000000Z],
                 expected_updated_at_source: order.updated_at_source
               },
               action: :hydrate_paid_at,
               domain: Sales
             )
  end

  test "equal-version payment hydration rejects a source-version race", %{source: source} do
    initial = fixture(:order_pending)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial)

    newer = Map.put(initial, "date_modified_gmt", "2026-05-01T09:10:00")
    assert {:ok, updated} = OrderUpserter.upsert_order(source.id, newer)
    assert updated.updated_at_source == ~U[2026-05-01 09:10:00.000000Z]
    assert updated.paid_at == nil

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             Ash.update(
               order,
               %{
                 paid_at: ~U[2026-05-01 08:03:00.000000Z],
                 expected_updated_at_source: order.updated_at_source
               },
               action: :hydrate_paid_at,
               domain: Sales
             )

    assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
    assert Ash.get!(Order, order.id, domain: Sales).paid_at == nil
  end

  test "ordinary sync does not clear source event metadata on mapped rows", %{source: source} do
    event =
      SalesHelpers.create_event!(source, %{
        name: "WR",
        external_event_id: 109_120,
        external_event_kind: :tickera_event
      })

    ticket =
      SalesHelpers.create_ticket_type!(event, %{
        name: "WR General",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 601,
        external_product_id: 501,
        external_variation_id: 601
      })

    create_mapping!(source, event, ticket, %{woo_product_id: 501, woo_variation_id: 601})

    initial =
      :order_completed
      |> fixture()
      |> put_in(
        ["line_items", Access.at(0), "meta_data"],
        [%{"id" => 1, "key" => "tickera_event_id", "value" => "109120"}]
      )

    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial)
    assert [mapped] = order_items(order.id)
    assert mapped.mapping_status == :mapped
    assert mapped.source_tickera_event_id == 109_120

    missing_event_id =
      initial
      |> Map.put("date_modified_gmt", "2026-05-01T09:10:00")
      |> put_in(["line_items", Access.at(0), "meta_data"], [])

    assert {:ok, _updated} = OrderUpserter.upsert_order(source.id, missing_event_id)
    assert [line] = order_items(order.id)
    assert line.event_id == event.id
    assert line.ticket_type_id == ticket.id
    assert line.source_tickera_event_id == 109_120
  end

  test "ordinary sync records conflict without reattributing mapped rows", %{source: source} do
    wr_event =
      SalesHelpers.create_event!(source, %{
        name: "WR",
        external_event_id: 109_120,
        external_event_kind: :tickera_event
      })

    wr_ticket =
      SalesHelpers.create_ticket_type!(wr_event, %{
        name: "WR General",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 601,
        external_product_id: 501,
        external_variation_id: 601
      })

    create_mapping!(source, wr_event, wr_ticket, %{woo_product_id: 501, woo_variation_id: 601})

    initial =
      :order_completed
      |> fixture()
      |> put_in(
        ["line_items", Access.at(0), "meta_data"],
        [%{"id" => 1, "key" => "tickera_event_id", "value" => "109120"}]
      )

    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial)

    conflicting =
      initial
      |> Map.put("date_modified_gmt", "2026-05-01T09:10:00")
      |> put_in(
        ["line_items", Access.at(0), "meta_data"],
        [%{"id" => 1, "key" => "tickera_event_id", "value" => "108658"}]
      )

    assert {:ok, _updated} = OrderUpserter.upsert_order(source.id, conflicting)
    assert [line] = order_items(order.id)
    assert line.event_id == wr_event.id
    assert line.ticket_type_id == wr_ticket.id
    assert line.source_tickera_event_id == 109_120
    assert line.attribution_status_reason == :source_event_identity_conflict
  end

  test "stale payload returns stale_noop before mutating order, items, or coupons", %{
    source: source
  } do
    newer =
      fixture(:order_completed)
      |> Map.put("date_paid_gmt", "2026-05-01T08:03:00")
      |> put_in(["line_items", Access.at(0), "total_tax"], "7.50")

    assert {:ok, order} = OrderUpserter.upsert_order(source.id, newer)

    stale =
      newer
      |> Map.put("date_modified_gmt", "2026-05-01T08:01:00")
      |> Map.put("date_paid_gmt", "2026-05-02T08:03:00")
      |> Map.put("status", "pending")
      |> Map.put("total", "1.00")
      |> put_in(["line_items", Access.at(0), "total"], "1.00")
      |> put_in(["line_items", Access.at(0), "total_tax"], "99.00")
      |> Map.put("coupon_lines", [
        %{"id" => 91_111, "code" => "STALE", "discount" => "999.00", "discount_tax" => "0.00"}
      ])

    assert {:ok, :stale_noop} = OrderUpserter.upsert_order(source.id, stale)

    persisted = Ash.get!(Order, order.id, domain: Sales)
    assert persisted.status == :completed
    assert persisted.raw_total == Decimal.new("900.00")
    assert persisted.paid_at == ~U[2026-05-01 08:03:00.000000Z]

    assert [line] = order_items(order.id)
    assert line.line_total == Decimal.new("900.00")
    assert line.line_total_tax == Decimal.new("7.50")

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

  test "pre-mapped normalized imports persist event and ticket mapping fields", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "CSV Upsert Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "CSV GA"})

    normalized = %{
      woo_order_id: 90_001,
      order_number: "CSV-90001",
      status: :completed,
      currency: "ZAR",
      completed_at: ~U[2026-05-21 10:00:00.000000Z],
      created_at_source: ~U[2026-05-21 09:55:00.000000Z],
      updated_at_source: ~U[2026-05-21 10:00:00.000000Z],
      customer_name: "Synthetic Import",
      customer_email: "synthetic.import@example.test",
      raw_total: Decimal.new("500.00"),
      raw_discount_total: Decimal.new("0"),
      raw_tax_total: Decimal.new("0"),
      payment_method: "payfast",
      payment_method_title: "Synthetic PayFast",
      payment_gateway_transaction_id: "csv-upsert-1",
      coupons: [],
      line_items: [
        %{
          woo_line_item_id: 80_001,
          woo_product_id: 501,
          woo_variation_id: 601,
          name: "CSV GA",
          quantity: 1,
          line_subtotal: Decimal.new("500.00"),
          line_total: Decimal.new("500.00"),
          discount_total: Decimal.new("0"),
          event_id: event.id,
          ticket_type_id: ticket.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      ]
    }

    assert {:ok, order} = OrderUpserter.upsert_normalized_order(source.id, normalized)
    assert [line] = order_items(order.id)
    assert line.event_id == event.id
    assert line.ticket_type_id == ticket.id
    assert line.item_kind == :ticket
    assert line.mapping_status == :mapped

    newer =
      put_in(
        normalized,
        [:line_items, Access.at(0), :line_total],
        Decimal.new("450.00")
      )
      |> Map.put(:updated_at_source, ~U[2026-05-21 10:01:00.000000Z])
      |> Map.put(:raw_total, Decimal.new("450.00"))

    assert {:ok, updated} = OrderUpserter.upsert_normalized_order(source.id, newer)
    assert updated.id == order.id
    assert [updated_line] = order_items(order.id)
    assert updated_line.line_total == Decimal.new("450.00")
    assert updated_line.event_id == event.id
    assert updated_line.ticket_type_id == ticket.id
    assert updated_line.item_kind == :ticket
    assert updated_line.mapping_status == :mapped
    assert Ash.count!(OrderItem, domain: Sales) == 1
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

  defp create_mapping!(source, event, ticket, attrs) do
    defaults = %{
      source_system_id: source.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_product_id: 1,
      woo_variation_id: nil,
      original_label: "Ticket",
      current_label: "Ticket",
      active: true
    }

    Ash.create!(ProductMapping, Map.merge(defaults, attrs), action: :create, domain: Catalog)
  end
end
