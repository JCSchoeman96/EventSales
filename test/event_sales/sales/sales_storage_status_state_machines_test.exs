defmodule EventSales.Sales.SalesStorageStatusStateMachinesTest do
  use EventSales.DataCase, async: false

  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{CouponSnapshot, Order, OrderItem}
  alias EventSales.Sales.StatusRules
  alias EventSales.TestSupport.FixtureHelpers
  alias EventSales.TestSupport.SalesHelpers

  test "order unique by source_system_id and woo_order_id" do
    source = SalesHelpers.create_source_system!()
    attrs = SalesHelpers.normalized_order_attrs_from_fixture!(:order_completed, source)

    Ash.create!(Order, attrs, action: :create_normalized, domain: Sales)

    assert {:error, _} = Ash.create(Order, attrs, action: :create_normalized, domain: Sales)
  end

  test "order item unique by order_id and woo_line_item_id" do
    source = SalesHelpers.create_source_system!()
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    line = hd(FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed)["line_items"])

    attrs =
      %{
        order_id: order.id,
        woo_line_item_id: line["id"],
        woo_product_id: line["product_id"],
        woo_variation_id: line["variation_id"],
        name: line["name"],
        quantity: line["quantity"],
        line_subtotal: Decimal.new(line["subtotal"]),
        line_total: Decimal.new(line["total"]),
        discount_total: Decimal.new("0"),
        item_kind: :unknown,
        mapping_status: :pending_mapping_resolution
      }

    Ash.create!(OrderItem, attrs, action: :create_normalized, domain: Sales)

    assert {:error, _} = Ash.create(OrderItem, attrs, action: :create_normalized, domain: Sales)
  end

  test "quantity greater than one is preserved" do
    source = SalesHelpers.create_source_system!()
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    line = hd(FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed)["line_items"])

    item = SalesHelpers.create_order_item_from_line!(order, line)

    assert item.quantity == 2
  end

  test "mixed-event orders support multiple event_ids on one order" do
    source = SalesHelpers.create_source_system!()
    %{order: order, items: items} = SalesHelpers.create_mixed_event_order!(source)

    assert length(items) == 2
    event_ids = Enum.map(items, & &1.event_id) |> Enum.uniq()
    assert length(event_ids) == 2

    loaded = Ash.load!(order, :order_items, domain: Sales)
    assert length(loaded.order_items) == 2
  end

  test "apply_mapping rejects ticket type from a different event" do
    source = SalesHelpers.create_source_system!()
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    line = hd(FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed)["line_items"])

    item =
      SalesHelpers.create_order_item_from_line!(order, line, %{
        mapping_status: :pending_mapping_resolution
      })

    event_a = SalesHelpers.create_event!(source, %{name: "Event A", slug: "event-a"})
    event_b = SalesHelpers.create_event!(source, %{name: "Event B", slug: "event-b"})
    ticket_b = SalesHelpers.create_ticket_type!(event_b, %{name: "VIP"})

    assert {:error, _} =
             Ash.update(
               item,
               %{event_id: event_a.id, ticket_type_id: ticket_b.id},
               action: :apply_mapping,
               domain: Sales
             )

    reloaded = Ash.get!(OrderItem, item.id, domain: Sales)
    assert reloaded.mapping_status == :pending_mapping_resolution
  end

  test "apply_mapping without event_id is rejected and does not map" do
    source = SalesHelpers.create_source_system!()
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    line = hd(FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed)["line_items"])

    item =
      SalesHelpers.create_order_item_from_line!(order, line, %{
        mapping_status: :pending_mapping_resolution
      })

    event = SalesHelpers.create_event!(source, %{name: "Event Only", slug: "event-only"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    assert {:error, _} =
             Ash.update(item, %{ticket_type_id: ticket.id}, action: :apply_mapping, domain: Sales)

    reloaded = Ash.get!(OrderItem, item.id, domain: Sales)
    assert reloaded.mapping_status == :pending_mapping_resolution
    refute reloaded.item_kind == :ticket
  end

  test "apply_mapping without ticket_type_id is rejected and does not map" do
    source = SalesHelpers.create_source_system!()
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    line = hd(FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed)["line_items"])

    item =
      SalesHelpers.create_order_item_from_line!(order, line, %{
        mapping_status: :pending_mapping_resolution
      })

    event =
      SalesHelpers.create_event!(source, %{
        name: "Event Missing Ticket",
        slug: "event-missing-ticket"
      })

    assert {:error, _} =
             Ash.update(item, %{event_id: event.id}, action: :apply_mapping, domain: Sales)

    reloaded = Ash.get!(OrderItem, item.id, domain: Sales)
    assert reloaded.mapping_status == :pending_mapping_resolution
  end

  test "completed order status is stored" do
    source = SalesHelpers.create_source_system!()
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)

    assert order.status == :completed
    assert %Order{} = Ash.get!(Order, order.id, domain: Sales)
  end

  test "pending orders are visible but excluded from sold totals" do
    source = SalesHelpers.create_source_system!()
    order = SalesHelpers.create_order_from_fixture!(:order_pending, source)
    line = hd(FixtureHelpers.decode_json_fixture!(:woocommerce, :order_pending)["line_items"])

    event = SalesHelpers.create_event!(source, %{name: "Pending Event", slug: "pending-event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    item =
      SalesHelpers.create_order_item_from_line!(order, line, %{
        event_id: event.id,
        ticket_type_id: ticket.id,
        mapping_status: :mapped,
        item_kind: :ticket
      })

    assert StatusRules.visible_status?(order, item)
    refute StatusRules.counts_toward_sold_tickets?(order, item)
  end

  test "invalid internal transition mark_completed from pending is rejected" do
    source = SalesHelpers.create_source_system!()
    order = SalesHelpers.create_order_from_fixture!(:order_pending, source)

    assert {:error, _} = Ash.update(order, %{}, action: :mark_completed, domain: Sales)
    assert Ash.get!(Order, order.id, domain: Sales).status == :pending
  end

  test "sync_status_from_source mirrors newer woo truth" do
    source = SalesHelpers.create_source_system!()

    order =
      Ash.create!(
        Order,
        %{
          source_system_id: source.id,
          woo_order_id: 55_001,
          order_number: "ES-55001",
          status: :pending,
          currency: "ZAR",
          created_at_source: ~U[2026-05-01 08:00:00Z],
          updated_at_source: ~U[2026-05-01 08:00:00Z],
          raw_total: Decimal.new("100.00")
        },
        action: :create_normalized,
        domain: Sales
      )

    assert {:ok, updated} =
             Ash.update(
               order,
               %{
                 status: :completed,
                 updated_at_source: ~U[2026-05-01 09:00:00Z],
                 completed_at: ~U[2026-05-01 09:00:00Z]
               },
               action: :sync_status_from_source,
               domain: Sales
             )

    assert updated.status == :completed
    assert_datetime_equal(updated.updated_at_source, ~U[2026-05-01 09:00:00Z])
    assert_datetime_equal(updated.completed_at, ~U[2026-05-01 09:00:00Z])
  end

  test "stale sync_status_from_source returns error without mutating the order" do
    source = SalesHelpers.create_source_system!()

    order =
      Ash.create!(
        Order,
        %{
          source_system_id: source.id,
          woo_order_id: 55_002,
          order_number: "ES-55002",
          status: :processing,
          currency: "ZAR",
          created_at_source: ~U[2026-05-01 10:00:00Z],
          updated_at_source: ~U[2026-05-01 10:00:00Z],
          raw_total: Decimal.new("200.00")
        },
        action: :create_normalized,
        domain: Sales
      )

    assert {:error, _} =
             Ash.update(
               order,
               %{status: :completed, updated_at_source: ~U[2026-05-01 09:00:00Z]},
               action: :sync_status_from_source,
               domain: Sales
             )

    reloaded = Ash.get!(Order, order.id, domain: Sales)
    assert reloaded.status == :processing
    assert_datetime_equal(reloaded.updated_at_source, ~U[2026-05-01 10:00:00Z])
    assert is_nil(reloaded.completed_at)
  end

  test "completed_at is not invented when syncing non-completed status" do
    source = SalesHelpers.create_source_system!()

    order =
      Ash.create!(
        Order,
        %{
          source_system_id: source.id,
          woo_order_id: 55_003,
          order_number: "ES-55003",
          status: :completed,
          currency: "ZAR",
          completed_at: ~U[2026-05-01 11:00:00Z],
          created_at_source: ~U[2026-05-01 10:00:00Z],
          updated_at_source: ~U[2026-05-01 11:00:00Z],
          raw_total: Decimal.new("300.00")
        },
        action: :create_normalized,
        domain: Sales
      )

    assert {:ok, updated} =
             Ash.update(
               order,
               %{status: :pending, updated_at_source: ~U[2026-05-01 12:00:00Z]},
               action: :sync_status_from_source,
               domain: Sales
             )

    assert updated.status == :pending
    assert_datetime_equal(updated.completed_at, ~U[2026-05-01 11:00:00Z])
  end

  test "completed_at is stored when supplied for completed sync" do
    source = SalesHelpers.create_source_system!()

    order =
      Ash.create!(
        Order,
        %{
          source_system_id: source.id,
          woo_order_id: 55_004,
          order_number: "ES-55004",
          status: :processing,
          currency: "ZAR",
          created_at_source: ~U[2026-05-01 10:00:00Z],
          updated_at_source: ~U[2026-05-01 10:00:00Z],
          raw_total: Decimal.new("400.00")
        },
        action: :create_normalized,
        domain: Sales
      )

    completed_at = ~U[2026-05-01 13:00:00Z]

    assert {:ok, updated} =
             Ash.update(
               order,
               %{
                 status: :completed,
                 updated_at_source: ~U[2026-05-01 13:00:00Z],
                 completed_at: completed_at
               },
               action: :sync_status_from_source,
               domain: Sales
             )

    assert updated.status == :completed
    assert_datetime_equal(updated.completed_at, completed_at)
  end

  test "duplicate coupon snapshot for same order and code is rejected" do
    source = SalesHelpers.create_source_system!()
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)

    attrs = %{order_id: order.id, code: "SYNTHETIC100", discount_amount: Decimal.new("100.00")}

    Ash.create!(CouponSnapshot, attrs, action: :create_snapshot, domain: Sales)

    assert {:error, _} =
             Ash.create(CouponSnapshot, attrs, action: :create_snapshot, domain: Sales)

    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM sales_coupon_snapshots WHERE order_id = $1 AND code = $2",
        [
          Ecto.UUID.dump!(order.id),
          "SYNTHETIC100"
        ]
      )

    assert count == 1
  end

  test "valid internal transition mark_processing from pending succeeds" do
    source = SalesHelpers.create_source_system!()
    order = SalesHelpers.create_order_from_fixture!(:order_pending, source)

    assert {:ok, updated} = Ash.update(order, %{}, action: :mark_processing, domain: Sales)
    assert updated.status == :processing
  end

  defp assert_datetime_equal(%DateTime{} = left, %DateTime{} = right) do
    assert DateTime.compare(DateTime.truncate(left, :second), DateTime.truncate(right, :second)) ==
             :eq
  end
end
