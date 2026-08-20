defmodule EventSales.Ingestion.HistoricalOrderMutationDetectorTest do
  use EventSales.DataCase, async: false

  alias EventSales.Ingestion.HistoricalOrderMutationDetector
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{CouponSnapshot, Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers

  @created_at_source ~U[2026-08-05 12:00:00.000000Z]
  @updated_at_source ~U[2026-08-05 13:00:00.000000Z]
  @completed_at ~U[2026-08-05 12:30:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    {:ok, source: source}
  end

  test "rejects an Order without a persisted id" do
    assert_raise ArgumentError, "Order must have a persisted id", fn ->
      HistoricalOrderMutationDetector.capture(%Order{})
    end
  end

  test "captures only selected header, item, and coupon truth in deterministic order", %{
    source: source
  } do
    order =
      create_order!(source, %{
        customer_name: "Customer Name",
        customer_email: "customer@example.test",
        payment_method: "payfast",
        payment_method_title: "PayFast",
        payment_gateway_transaction_id: "txn-1"
      })

    event_a = SalesHelpers.create_event!(source, %{name: "Event A"})
    event_b = SalesHelpers.create_event!(source, %{name: "Event B"})
    ticket_a = SalesHelpers.create_ticket_type!(event_a, %{name: "Ticket A"})
    ticket_b = SalesHelpers.create_ticket_type!(event_b, %{name: "Ticket B"})

    create_item!(order, event_b, ticket_b, %{
      woo_line_item_id: 20,
      woo_product_id: 202,
      woo_variation_id: 2,
      name: "Cosmetic B",
      quantity: 2,
      line_subtotal: Decimal.new("220.00"),
      line_total: Decimal.new("200.00"),
      line_total_tax: Decimal.new("20.00"),
      discount_total: Decimal.new("20.00"),
      source_tickera_event_id: 20_002,
      attribution_status_reason: :missing_product_mapping
    })

    create_item!(order, event_a, ticket_a, %{
      woo_line_item_id: 10,
      woo_product_id: 101,
      woo_variation_id: 1,
      name: "Cosmetic A",
      quantity: 1,
      line_subtotal: Decimal.new("110.00"),
      line_total: Decimal.new("100.00"),
      line_total_tax: Decimal.new("10.00"),
      discount_total: Decimal.new("10.00"),
      source_tickera_event_id: 10_001,
      attribution_status_reason: :order_event_mapping_conflict
    })

    create_coupon!(order, "ZETA", "7.00", "0.70")
    create_coupon!(order, "ALPHA", "5.00", "0.50")

    snapshot = HistoricalOrderMutationDetector.capture(order)

    assert snapshot.header == %{
             status: :completed,
             currency: "ZAR",
             created_at_source: @created_at_source,
             completed_at: @completed_at,
             paid_at: nil,
             raw_total: Decimal.new("300.00"),
             raw_discount_total: Decimal.new("30.00"),
             raw_tax_total: Decimal.new("30.00")
           }

    assert Enum.map(snapshot.order_items, & &1.woo_line_item_id) == [10, 20]
    assert Enum.map(snapshot.coupon_snapshots, & &1.code) == ["ALPHA", "ZETA"]

    assert Enum.at(snapshot.order_items, 0) == %{
             woo_line_item_id: 10,
             event_id: event_a.id,
             ticket_type_id: ticket_a.id,
             woo_product_id: 101,
             woo_variation_id: 1,
             quantity: 1,
             line_subtotal: Decimal.new("110.00"),
             line_total: Decimal.new("100.00"),
             line_total_tax: Decimal.new("10.00"),
             discount_total: Decimal.new("10.00"),
             item_kind: :ticket,
             mapping_status: :mapped,
             source_tickera_event_id: 10_001,
             attribution_status_reason: :order_event_mapping_conflict
           }

    assert Enum.at(snapshot.coupon_snapshots, 0) == %{
             code: "ALPHA",
             discount_amount: Decimal.new("5.00"),
             discount_tax: Decimal.new("0.50")
           }

    refute Map.has_key?(snapshot.header, :updated_at_source)
    refute Map.has_key?(snapshot.header, :customer_name)
    refute Map.has_key?(snapshot.header, :customer_email)
    refute Map.has_key?(snapshot.header, :payment_method)
    refute Map.has_key?(snapshot.header, :payment_method_title)
    refute Map.has_key?(snapshot.header, :payment_gateway_transaction_id)
    refute Map.has_key?(Enum.at(snapshot.order_items, 0), :name)
    refute Map.has_key?(Enum.at(snapshot.order_items, 0), :inserted_at)
    refute Map.has_key?(Enum.at(snapshot.coupon_snapshots, 0), :updated_at)
  end

  test "identical replay and source-version-only change do not mutate historical truth", %{
    source: source
  } do
    order = create_order!(source)
    before = HistoricalOrderMutationDetector.capture(order)

    assert %{changed?: false, candidate_event_ids: []} =
             HistoricalOrderMutationDetector.compare(
               before,
               HistoricalOrderMutationDetector.capture(order)
             )

    updated =
      Ash.update!(
        order,
        %{
          status: order.status,
          updated_at_source: DateTime.add(@updated_at_source, 1, :hour),
          completed_at: order.completed_at
        },
        action: :sync_status_from_source,
        domain: Sales
      )

    after_source_version = HistoricalOrderMutationDetector.capture(updated)

    assert before == after_source_version

    assert %{changed?: false, candidate_event_ids: []} =
             HistoricalOrderMutationDetector.compare(before, after_source_version)

    cosmetic =
      Ash.update!(
        updated,
        %{
          status: updated.status,
          updated_at_source: DateTime.add(@updated_at_source, 2, :hour),
          completed_at: updated.completed_at,
          customer_name: "Changed Customer",
          customer_email: "changed@example.test",
          payment_method: "cash",
          payment_method_title: "Cash",
          payment_gateway_transaction_id: "changed-transaction"
        },
        action: :sync_from_normalized,
        domain: Sales
      )

    after_cosmetic = HistoricalOrderMutationDetector.capture(cosmetic)

    assert before == after_cosmetic

    assert %{changed?: false, candidate_event_ids: []} =
             HistoricalOrderMutationDetector.compare(before, after_cosmetic)
  end

  test "included header fields are certificate-relevant mutations", %{source: source} do
    order = create_order!(source)
    before = HistoricalOrderMutationDetector.capture(order)

    mutations = %{
      status: :refunded,
      currency: "USD",
      created_at_source: DateTime.add(@created_at_source, 1, :day),
      completed_at: nil,
      paid_at: DateTime.add(@created_at_source, 2, :hour),
      raw_total: Decimal.new("301.00"),
      raw_discount_total: Decimal.new("31.00"),
      raw_tax_total: Decimal.new("31.00")
    }

    for {field, value} <- mutations do
      after_snapshot = put_in(before, [:header, field], value)

      assert %{changed?: true, candidate_event_ids: []} =
               HistoricalOrderMutationDetector.compare(before, after_snapshot)
    end
  end

  test "line removal reports the union of before and after persisted Event IDs", %{
    source: source
  } do
    order = create_order!(source)
    event_a = SalesHelpers.create_event!(source, %{name: "Event A"})
    event_b = SalesHelpers.create_event!(source, %{name: "Event B"})
    ticket_a = SalesHelpers.create_ticket_type!(event_a, %{name: "Ticket A"})
    ticket_b = SalesHelpers.create_ticket_type!(event_b, %{name: "Ticket B"})

    item_a = create_item!(order, event_a, ticket_a, %{woo_line_item_id: 10})
    create_item!(order, event_b, ticket_b, %{woo_line_item_id: 20})

    before = HistoricalOrderMutationDetector.capture(order)
    Ash.destroy!(item_a, action: :destroy_source_absent, domain: Sales)
    after_snapshot = HistoricalOrderMutationDetector.capture(order)

    assert %{changed?: true, candidate_event_ids: event_ids} =
             HistoricalOrderMutationDetector.compare(before, after_snapshot)

    assert event_ids == Enum.sort([event_a.id, event_b.id])
    assert Enum.map(after_snapshot.order_items, & &1.woo_line_item_id) == [20]
  end

  test "line addition changes truth and duplicate Event IDs are deduplicated", %{source: source} do
    order = create_order!(source)
    event = SalesHelpers.create_event!(source, %{name: "Added Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Added Ticket"})
    before = HistoricalOrderMutationDetector.capture(order)

    create_item!(order, event, ticket, %{woo_line_item_id: 10})
    create_item!(order, event, ticket, %{woo_line_item_id: 20})
    after_snapshot = HistoricalOrderMutationDetector.capture(order)

    assert %{changed?: true, candidate_event_ids: [candidate_event_id]} =
             HistoricalOrderMutationDetector.compare(before, after_snapshot)

    assert candidate_event_id == event.id
  end

  test "event attribution correction reports both old and new Event IDs", %{source: source} do
    order = create_order!(source)
    event_a = SalesHelpers.create_event!(source, %{name: "Event A"})
    event_b = SalesHelpers.create_event!(source, %{name: "Event B"})
    ticket_a = SalesHelpers.create_ticket_type!(event_a, %{name: "Ticket A"})
    ticket_b = SalesHelpers.create_ticket_type!(event_b, %{name: "Ticket B"})

    item =
      create_item!(order, event_a, ticket_a, %{
        woo_line_item_id: 10,
        source_tickera_event_id: 10_001
      })

    before = HistoricalOrderMutationDetector.capture(order)

    corrected =
      Ash.update!(
        item,
        %{
          event_id: event_b.id,
          ticket_type_id: ticket_b.id,
          source_tickera_event_id: 20_002,
          attribution_status_reason: nil
        },
        action: :correct_event_attribution,
        domain: Sales
      )

    assert corrected.event_id == event_b.id
    after_snapshot = HistoricalOrderMutationDetector.capture(order)

    assert %{changed?: true, candidate_event_ids: event_ids} =
             HistoricalOrderMutationDetector.compare(before, after_snapshot)

    assert event_ids == Enum.sort([event_a.id, event_b.id])
  end

  test "coupon removal and value correction are historical truth mutations", %{source: source} do
    order = create_order!(source)
    before = HistoricalOrderMutationDetector.capture(order)
    coupon = create_coupon!(order, "SAVE", "5.00", "0.50")
    added = HistoricalOrderMutationDetector.capture(order)

    assert %{changed?: true, candidate_event_ids: []} =
             HistoricalOrderMutationDetector.compare(before, added)

    Ash.update!(
      coupon,
      %{discount_amount: Decimal.new("6.00"), discount_tax: Decimal.new("0.60")},
      action: :sync_from_order,
      domain: Sales
    )

    corrected = HistoricalOrderMutationDetector.capture(order)

    assert %{changed?: true, candidate_event_ids: []} =
             HistoricalOrderMutationDetector.compare(before, corrected)

    Ash.destroy!(coupon, action: :destroy_source_absent, domain: Sales)
    removed = HistoricalOrderMutationDetector.capture(order)

    assert %{changed?: true, candidate_event_ids: []} =
             HistoricalOrderMutationDetector.compare(corrected, removed)
  end

  test "unresolved item mutations do not invent an Event candidate", %{source: source} do
    order = create_order!(source)

    item =
      create_item!(order, nil, nil, %{
        woo_line_item_id: 10,
        item_kind: :unknown,
        mapping_status: :pending_mapping_resolution
      })

    before = HistoricalOrderMutationDetector.capture(order)

    name_only =
      Ash.update!(
        item,
        %{name: "Renamed Only"},
        action: :sync_from_order,
        domain: Sales
      )

    name_only_snapshot = HistoricalOrderMutationDetector.capture(order)

    assert name_only.name == "Renamed Only"
    assert before == name_only_snapshot

    assert %{changed?: false, candidate_event_ids: []} =
             HistoricalOrderMutationDetector.compare(before, name_only_snapshot)

    changed_item =
      Ash.update!(
        name_only,
        %{
          woo_product_id: 999,
          woo_variation_id: 9_999,
          quantity: 2,
          line_subtotal: Decimal.new("220.00"),
          line_total: Decimal.new("200.00"),
          line_total_tax: Decimal.new("20.00")
        },
        action: :sync_from_order,
        domain: Sales
      )

    after_snapshot = HistoricalOrderMutationDetector.capture(order)

    assert changed_item.woo_product_id == 999
    assert changed_item.woo_variation_id == 9_999

    assert %{changed?: true, candidate_event_ids: []} =
             HistoricalOrderMutationDetector.compare(name_only_snapshot, after_snapshot)

    marked_non_ticket =
      Ash.update!(
        changed_item,
        %{},
        action: :mark_non_ticket,
        domain: Sales
      )

    marked_snapshot = HistoricalOrderMutationDetector.capture(order)

    assert marked_non_ticket.mapping_status == :non_ticket

    assert %{changed?: true, candidate_event_ids: []} =
             HistoricalOrderMutationDetector.compare(after_snapshot, marked_snapshot)
  end

  defp create_order!(source, attrs \\ %{}) do
    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      status: :completed,
      currency: "ZAR",
      completed_at: @completed_at,
      paid_at: nil,
      created_at_source: @created_at_source,
      updated_at_source: @updated_at_source,
      customer_name: "Test Customer",
      customer_email: "test@example.test",
      raw_total: Decimal.new("300.00"),
      raw_discount_total: Decimal.new("30.00"),
      raw_tax_total: Decimal.new("30.00"),
      payment_method: "card",
      payment_method_title: "Card",
      payment_gateway_transaction_id: "gateway-transaction"
    }

    Ash.create!(Order, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_item!(order, event, ticket, attrs) do
    defaults = %{
      order_id: order.id,
      event_id: event && event.id,
      ticket_type_id: ticket && ticket.id,
      woo_line_item_id: 10,
      woo_product_id: 101,
      woo_variation_id: 1,
      name: "Order Item Name",
      quantity: 1,
      line_subtotal: Decimal.new("110.00"),
      line_total: Decimal.new("100.00"),
      line_total_tax: Decimal.new("10.00"),
      discount_total: Decimal.new("10.00"),
      item_kind: if(event, do: :ticket, else: :unknown),
      mapping_status: if(event, do: :mapped, else: :pending_mapping_resolution),
      source_tickera_event_id: event && event.external_event_id,
      attribution_status_reason: nil
    }

    Ash.create!(OrderItem, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_coupon!(order, code, discount_amount, discount_tax) do
    Ash.create!(
      CouponSnapshot,
      %{
        order_id: order.id,
        code: code,
        discount_amount: Decimal.new(discount_amount),
        discount_tax: Decimal.new(discount_tax)
      },
      action: :create_snapshot,
      domain: Sales
    )
  end
end
