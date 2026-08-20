defmodule EventSales.Ingestion.HistoricalRefundMutationDetectorTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Ingestion.HistoricalRefundMutationDetector
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem, Refund, RefundLine}
  alias EventSales.TestSupport.SalesHelpers

  @refund_created_at ~U[2026-08-05 14:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    {:ok, source: source}
  end

  test "accepts only a durable Refund", %{source: source} do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)

    assert {:error, :invalid_refund} = HistoricalRefundMutationDetector.capture(%Order{})

    assert {:error, :invalid_refund} =
             HistoricalRefundMutationDetector.capture(%Refund{order_id: order.id})
  end

  test "rejects malformed order identity and effective timestamps", %{source: source} do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    refund = create_refund!(source, order, %{woo_refund_id: 91_000})

    assert {:error, :invalid_refund} =
             HistoricalRefundMutationDetector.capture(%{refund | order_id: "not-a-uuid"})

    assert {:error, :invalid_refund} =
             HistoricalRefundMutationDetector.capture(%{
               refund
               | source_created_at: "not-a-datetime"
             })

    non_utc = %{
      @refund_created_at
      | time_zone: "Africa/Johannesburg",
        zone_abbr: "SAST",
        utc_offset: 7_200
    }

    assert {:error, :invalid_refund} =
             HistoricalRefundMutationDetector.capture(%{refund | source_created_at: non_utc})
  end

  test "accepts nil source_created_at as unresolved effective-time truth", %{source: source} do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    refund = create_refund!(source, order, %{woo_refund_id: 91_001, source_created_at: nil})

    assert {:ok, snapshot} = HistoricalRefundMutationDetector.capture(refund)
    assert snapshot.refund_truth.source_created_at == nil
  end

  test "rejects a non-nil parent id inconsistent with the source-scoped parent", %{
    source: source
  } do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    other_order = create_distinct_order!(source)
    refund = create_refund!(source, order, %{woo_refund_id: 91_002})

    assert {:error, :invalid_refund} =
             HistoricalRefundMutationDetector.capture(%{refund | order_id: other_order.id})
  end

  test "captures the exact parent Order, RefundLines, and parent OrderItems read-only", %{
    source: source
  } do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    other_order = create_distinct_order!(source)
    event = SalesHelpers.create_event!(source, %{name: "Refund Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Refund Ticket"})

    line =
      SalesHelpers.create_order_item_from_line!(
        order,
        %{
          "id" => 10_001,
          "product_id" => 1001,
          "variation_id" => 2001,
          "name" => "Refunded Ticket",
          "quantity" => 1,
          "subtotal" => "100.00",
          "total" => "100.00",
          "discount_total" => "0.00"
        },
        %{
          event_id: event.id,
          ticket_type_id: ticket.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    _other_line =
      SalesHelpers.create_order_item_from_line!(
        other_order,
        %{
          "id" => 20_001,
          "product_id" => 2001,
          "variation_id" => 3001,
          "name" => "Other Ticket",
          "quantity" => 1,
          "subtotal" => "200.00",
          "total" => "200.00",
          "discount_total" => "0.00"
        },
        %{
          event_id: event.id,
          ticket_type_id: ticket.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    refund = create_refund!(source, order, %{woo_refund_id: 91_001})
    _refund_line = create_refund_line!(refund, line, %{woo_refund_line_item_id: 88_001})

    refund_ids_before = ids(Refund, nil)
    refund_line_ids_before = refund_line_ids(refund.id)
    order_item_ids_before = ids(OrderItem, order.id)

    assert {:ok, snapshot} = HistoricalRefundMutationDetector.capture(refund)
    assert snapshot.parent_order_evidence.id == order.id
    assert snapshot.parent_order_evidence.source_system_id == source.id
    assert snapshot.parent_order_evidence.woo_order_id == order.woo_order_id
    assert snapshot.parent_order_evidence.created_at_source == order.created_at_source

    assert snapshot.parent_order_item_evidence |> Enum.map(& &1.woo_line_item_id) == [
             line.woo_line_item_id
           ]

    assert snapshot.refund_line_truth |> Enum.map(& &1.woo_refund_line_item_id) == [88_001]
    assert snapshot.refund_truth.source_state == :active
    assert snapshot.refund_truth.detail_status == :complete

    assert ids(Refund, nil) == refund_ids_before
    assert refund_line_ids(refund.id) == refund_line_ids_before
    assert ids(OrderItem, order.id) == order_item_ids_before
  end

  test "identical replay and cosmetic reason changes do not change certificate truth", %{
    source: source
  } do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    refund = create_refund!(source, order, %{woo_refund_id: 91_002, reason: "Original"})
    before = capture!(refund)

    assert %{changed?: false, candidate_event_ids: []} =
             HistoricalRefundMutationDetector.compare(before, capture!(refund))

    updated =
      Ash.update!(
        refund,
        %{reason: "Corrected explanation"},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: false, candidate_event_ids: []} =
             HistoricalRefundMutationDetector.compare(before, capture!(updated))
  end

  test "summary-only hydration does not change certificate truth", %{source: source} do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    refund = create_refund!(source, order, %{woo_refund_id: 91_003})
    before = capture!(refund)

    updated =
      Ash.update!(
        refund,
        %{summary_total_amount: Decimal.new("99.00")},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: false, candidate_event_ids: []} =
             HistoricalRefundMutationDetector.compare(before, capture!(updated))
  end

  test "financial and source-state changes report exact persisted Event IDs", %{source: source} do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    event_a = SalesHelpers.create_event!(source, %{name: "Event A"})
    ticket_a = SalesHelpers.create_ticket_type!(event_a, %{name: "Ticket A"})

    item_a =
      SalesHelpers.create_order_item_from_line!(
        order,
        order_line(10_101),
        %{
          event_id: event_a.id,
          ticket_type_id: ticket_a.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    refund = create_refund!(source, order, %{woo_refund_id: 91_003})
    create_refund_line!(refund, item_a, %{woo_refund_line_item_id: 88_003})
    before = capture!(refund)

    changed_amount =
      Ash.update!(
        refund,
        %{header_amount: Decimal.new("12.00")},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: [event_id]} =
             HistoricalRefundMutationDetector.compare(before, capture!(changed_amount))

    assert event_id == event_a.id

    voided =
      Ash.update!(
        changed_amount,
        %{void_reason: "source_deleted", voided_at: @refund_created_at},
        action: :mark_voided,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: [^event_id]} =
             HistoricalRefundMutationDetector.compare(capture!(changed_amount), capture!(voided))
  end

  test "product and variation evidence alone do not change certificate truth", %{source: source} do
    {_order, _event_a, _event_b, _item_a, _item_b, refund, line} =
      create_multi_event_refund!(source, 91_004)

    before = capture!(refund)

    updated_line =
      Ash.update!(
        line,
        %{woo_product_id: 777_001, woo_variation_id: 888_001},
        action: :sync_normalized,
        domain: Sales
      )

    assert updated_line.validation_reason == line.validation_reason

    assert %{changed?: false, candidate_event_ids: []} =
             HistoricalRefundMutationDetector.compare(before, capture!(refund))
  end

  test "parent OrderItem evidence alone does not change Refund truth", %{source: source} do
    {_order, _event_a, _event_b, item_a, _item_b, refund, _line} =
      create_multi_event_refund!(source, 91_005)

    before = capture!(refund)

    remapped = Ash.update!(item_a, %{}, action: :remap, domain: Sales)
    assert remapped.mapping_status == :pending_mapping_resolution

    assert %{changed?: false, candidate_event_ids: []} =
             HistoricalRefundMutationDetector.compare(before, capture!(refund))
  end

  test "RefundLine binding_reason forces parent-wide candidates", %{source: source} do
    {_order, event_a, event_b, _item_a, _item_b, refund, line} =
      create_multi_event_refund!(source, 91_006)

    before = capture!(refund)

    Ash.update!(
      line,
      %{binding_reason: "source_detail_conflict"},
      action: :sync_normalized,
      domain: Sales
    )

    assert %{changed?: true, candidate_event_ids: candidate_event_ids} =
             HistoricalRefundMutationDetector.compare(before, capture!(refund))

    assert candidate_event_ids == Enum.sort([event_a.id, event_b.id])
  end

  test "shipping and fee component ambiguity is parent-wide but known zero is exact", %{
    source: source
  } do
    {_order, event_a, event_b, _item_a, _item_b, refund, _line} =
      create_multi_event_refund!(source, 91_007)

    before = capture!(refund)

    zero_shipping =
      Ash.update!(
        refund,
        %{shipping_refund_amount: Decimal.new("0.00"), shipping_refund_tax: Decimal.new("0.00")},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: [event_id]} =
             HistoricalRefundMutationDetector.compare(before, capture!(zero_shipping))

    assert event_id == event_a.id

    nonzero_shipping =
      Ash.update!(
        zero_shipping,
        %{shipping_refund_amount: Decimal.new("2.00"), shipping_refund_tax: Decimal.new("0.00")},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: candidate_event_ids} =
             HistoricalRefundMutationDetector.compare(
               capture!(zero_shipping),
               capture!(nonzero_shipping)
             )

    assert candidate_event_ids == Enum.sort([event_a.id, event_b.id])

    unknown_shipping =
      Ash.update!(
        nonzero_shipping,
        %{shipping_refund_amount: Decimal.new("0.00"), shipping_refund_tax: nil},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: candidate_event_ids} =
             HistoricalRefundMutationDetector.compare(
               capture!(nonzero_shipping),
               capture!(unknown_shipping)
             )

    assert candidate_event_ids == Enum.sort([event_a.id, event_b.id])

    {_order, exact_event_a, _exact_event_b, _item_a, _item_b, exact_refund, _line} =
      create_multi_event_refund!(source, 91_011)

    exact_zero_fee =
      Ash.update!(
        exact_refund,
        %{fee_refund_amount: Decimal.new("0.00"), fee_refund_tax: Decimal.new("0.00")},
        action: :sync_normalized,
        domain: Sales
      )

    exact_fee_changed =
      Ash.update!(
        exact_zero_fee,
        %{header_amount: Decimal.new("11.00")},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: [event_id]} =
             HistoricalRefundMutationDetector.compare(
               capture!(exact_zero_fee),
               capture!(exact_fee_changed)
             )

    assert event_id == exact_event_a.id

    nonzero_fee =
      Ash.update!(
        unknown_shipping,
        %{
          shipping_refund_amount: nil,
          shipping_refund_tax: nil,
          fee_refund_amount: Decimal.new("2.00"),
          fee_refund_tax: Decimal.new("0.00")
        },
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: candidate_event_ids} =
             HistoricalRefundMutationDetector.compare(
               capture!(unknown_shipping),
               capture!(nonzero_fee)
             )

    assert candidate_event_ids == Enum.sort([event_a.id, event_b.id])

    zero_fee =
      Ash.update!(
        nonzero_fee,
        %{fee_refund_amount: Decimal.new("0.00"), fee_refund_tax: Decimal.new("0.00")},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: candidate_event_ids} =
             HistoricalRefundMutationDetector.compare(capture!(nonzero_fee), capture!(zero_fee))

    assert candidate_event_ids == Enum.sort([event_a.id, event_b.id])

    {_order, exact_event_a, _exact_event_b, _item_a, _item_b, exact_refund, _line} =
      create_multi_event_refund!(source, 91_012)

    exact_zero_residual =
      Ash.update!(
        exact_refund,
        %{unallocated_header_amount: Decimal.new("0.00")},
        action: :sync_normalized,
        domain: Sales
      )

    exact_residual_changed =
      Ash.update!(
        exact_zero_residual,
        %{header_amount: Decimal.new("11.00")},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: [event_id]} =
             HistoricalRefundMutationDetector.compare(
               capture!(exact_zero_residual),
               capture!(exact_residual_changed)
             )

    assert event_id == exact_event_a.id
  end

  test "canonicalizes Event IDs and rejects malformed parent evidence", %{source: source} do
    {_order, event_a, event_b, _item_a, _item_b, refund, _line} =
      create_multi_event_refund!(source, 91_013)

    event_a_id = event_a.id

    before = capture!(refund)
    [first_item | remaining_items] = before.parent_order_item_evidence

    malformed_parent_evidence = [
      %{first_item | event_id: "not-an-event-uuid"} | remaining_items
    ]

    after_snapshot = %{
      before
      | refund_truth: Map.put(before.refund_truth, :header_amount, Decimal.new("11.00")),
        parent_order_item_evidence: malformed_parent_evidence
    }

    assert %{changed?: true, candidate_event_ids: candidate_event_ids} =
             HistoricalRefundMutationDetector.compare(before, after_snapshot)

    assert candidate_event_ids == Enum.sort([event_a.id, event_b.id])
    refute "not-an-event-uuid" in candidate_event_ids

    [first_item | _remaining_items] = before.parent_order_item_evidence

    canonical_snapshot = %{
      before
      | refund_truth: Map.put(before.refund_truth, :header_amount, Decimal.new("12.00")),
        parent_order_item_evidence: [%{first_item | event_id: String.upcase(event_a.id)}]
    }

    assert %{changed?: true, candidate_event_ids: [^event_a_id]} =
             HistoricalRefundMutationDetector.compare(before, canonical_snapshot)
  end

  test "non-zero or unknown component tax is parent-wide", %{source: source} do
    {_order, event_a, event_b, _item_a, _item_b, refund, _line} =
      create_multi_event_refund!(source, 91_008)

    before = capture!(refund)

    nonzero_shipping_tax =
      Ash.update!(
        refund,
        %{shipping_refund_amount: Decimal.new("0.00"), shipping_refund_tax: Decimal.new("1.00")},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: candidate_event_ids} =
             HistoricalRefundMutationDetector.compare(before, capture!(nonzero_shipping_tax))

    assert candidate_event_ids == Enum.sort([event_a.id, event_b.id])

    unknown_fee_tax =
      Ash.update!(
        nonzero_shipping_tax,
        %{
          shipping_refund_amount: nil,
          shipping_refund_tax: nil,
          fee_refund_amount: Decimal.new("0.00"),
          fee_refund_tax: nil
        },
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: candidate_event_ids} =
             HistoricalRefundMutationDetector.compare(
               capture!(nonzero_shipping_tax),
               capture!(unknown_fee_tax)
             )

    assert candidate_event_ids == Enum.sort([event_a.id, event_b.id])
  end

  test "unallocated header residual uses zero versus unknown semantics", %{source: source} do
    {_order, event_a, event_b, _item_a, _item_b, refund, _line} =
      create_multi_event_refund!(source, 91_009)

    before = capture!(refund)

    nonzero_residual =
      Ash.update!(
        refund,
        %{unallocated_header_amount: Decimal.new("3.00")},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: candidate_event_ids} =
             HistoricalRefundMutationDetector.compare(before, capture!(nonzero_residual))

    assert candidate_event_ids == Enum.sort([event_a.id, event_b.id])

    zero_residual =
      Ash.update!(
        nonzero_residual,
        %{unallocated_header_amount: Decimal.new("0.00")},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: candidate_event_ids} =
             HistoricalRefundMutationDetector.compare(
               capture!(nonzero_residual),
               capture!(zero_residual)
             )

    assert candidate_event_ids == Enum.sort([event_a.id, event_b.id])

    unknown_residual =
      Ash.update!(
        zero_residual,
        %{unallocated_header_amount: nil},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: candidate_event_ids} =
             HistoricalRefundMutationDetector.compare(
               capture!(zero_residual),
               capture!(unknown_residual)
             )

    assert candidate_event_ids == Enum.sort([event_a.id, event_b.id])
  end

  test "uses the before and after Event union when exact refund allocation moves", %{
    source: source
  } do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    event_a = SalesHelpers.create_event!(source, %{name: "Event A"})
    event_b = SalesHelpers.create_event!(source, %{name: "Event B"})
    ticket_a = SalesHelpers.create_ticket_type!(event_a, %{name: "Ticket A"})
    ticket_b = SalesHelpers.create_ticket_type!(event_b, %{name: "Ticket B"})

    item_a =
      SalesHelpers.create_order_item_from_line!(
        order,
        order_line(10_201),
        %{
          event_id: event_a.id,
          ticket_type_id: ticket_a.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    item_b =
      SalesHelpers.create_order_item_from_line!(
        order,
        order_line(10_202),
        %{
          event_id: event_b.id,
          ticket_type_id: ticket_b.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    refund = create_refund!(source, order, %{woo_refund_id: 91_004})
    line = create_refund_line!(refund, item_a, %{woo_refund_line_item_id: 88_004})
    before = capture!(refund)

    corrected =
      Ash.update!(
        line,
        %{order_item_id: item_b.id, woo_refunded_item_id: item_b.woo_line_item_id},
        action: :sync_normalized,
        domain: Sales
      )

    assert corrected.order_item_id == item_b.id

    assert %{changed?: true, candidate_event_ids: candidate_event_ids} =
             HistoricalRefundMutationDetector.compare(before, capture!(refund))

    assert candidate_event_ids == Enum.sort([event_a.id, event_b.id])
  end

  test "falls back to all bounded parent Events for an unresolved RefundLine", %{
    source: source
  } do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    event_a = SalesHelpers.create_event!(source, %{name: "Event A"})
    event_b = SalesHelpers.create_event!(source, %{name: "Event B"})
    ticket_a = SalesHelpers.create_ticket_type!(event_a, %{name: "Ticket A"})
    ticket_b = SalesHelpers.create_ticket_type!(event_b, %{name: "Ticket B"})

    item_a =
      SalesHelpers.create_order_item_from_line!(
        order,
        order_line(10_301),
        %{
          event_id: event_a.id,
          ticket_type_id: ticket_a.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    _item_b =
      SalesHelpers.create_order_item_from_line!(
        order,
        order_line(10_302),
        %{
          event_id: event_b.id,
          ticket_type_id: ticket_b.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    refund = create_refund!(source, order, %{woo_refund_id: 91_005})
    create_refund_line!(refund, item_a, %{woo_refund_line_item_id: 88_005})
    before = capture!(refund)

    unresolved =
      Ash.update!(
        refund,
        %{detail_status: :unresolved, unresolved_reason: "source_detail_conflict"},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: candidate_event_ids} =
             HistoricalRefundMutationDetector.compare(before, capture!(unresolved))

    assert candidate_event_ids == Enum.sort([event_a.id, event_b.id])
  end

  test "falls back to all bounded parent Events for an order-level refund", %{source: source} do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    event_a = SalesHelpers.create_event!(source, %{name: "Event A"})
    event_b = SalesHelpers.create_event!(source, %{name: "Event B"})
    ticket_a = SalesHelpers.create_ticket_type!(event_a, %{name: "Ticket A"})
    ticket_b = SalesHelpers.create_ticket_type!(event_b, %{name: "Ticket B"})

    _item_a =
      SalesHelpers.create_order_item_from_line!(
        order,
        order_line(10_401),
        %{
          event_id: event_a.id,
          ticket_type_id: ticket_a.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    _item_b =
      SalesHelpers.create_order_item_from_line!(
        order,
        order_line(10_402),
        %{
          event_id: event_b.id,
          ticket_type_id: ticket_b.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    refund = create_refund!(source, order, %{woo_refund_id: 91_006})
    before = capture!(refund)

    changed =
      Ash.update!(
        refund,
        %{header_amount: Decimal.new("50.00")},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: candidate_event_ids} =
             HistoricalRefundMutationDetector.compare(before, capture!(changed))

    assert candidate_event_ids == Enum.sort([event_a.id, event_b.id])
  end

  test "a valid Refund without parent evidence returns no candidates", %{source: source} do
    refund =
      create_refund!(
        source,
        nil,
        %{
          woo_order_id: System.unique_integer([:positive]),
          woo_refund_id: 91_010,
          currency: "ZAR",
          order_id: nil,
          unallocated_header_amount: Decimal.new("0.00")
        }
      )

    before = capture!(refund)

    changed =
      Ash.update!(
        refund,
        %{header_amount: Decimal.new("20.00")},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: []} =
             HistoricalRefundMutationDetector.compare(before, capture!(changed))
  end

  test "does not attribute to Events outside the exact parent Order", %{source: source} do
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    other_order = create_distinct_order!(source)
    event = SalesHelpers.create_event!(source, %{name: "Parent Event"})
    other_event = SalesHelpers.create_event!(source, %{name: "Other Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Parent Ticket"})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other Ticket"})

    item =
      SalesHelpers.create_order_item_from_line!(
        order,
        order_line(10_501),
        %{
          event_id: event.id,
          ticket_type_id: ticket.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    _other_item =
      SalesHelpers.create_order_item_from_line!(
        other_order,
        order_line(10_502),
        %{
          event_id: other_event.id,
          ticket_type_id: other_ticket.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    refund = create_refund!(source, order, %{woo_refund_id: 91_007})
    create_refund_line!(refund, item, %{woo_refund_line_item_id: 88_007})
    before = capture!(refund)

    changed =
      Ash.update!(
        refund,
        %{header_amount: Decimal.new("75.00")},
        action: :sync_normalized,
        domain: Sales
      )

    assert %{changed?: true, candidate_event_ids: [candidate_event_id]} =
             HistoricalRefundMutationDetector.compare(before, capture!(changed))

    assert candidate_event_id == event.id
    refute candidate_event_id == other_event.id
  end

  defp capture!(refund) do
    assert {:ok, snapshot} = HistoricalRefundMutationDetector.capture(refund)
    snapshot
  end

  defp create_multi_event_refund!(source, woo_refund_id) do
    order = create_distinct_order!(source)
    event_a = SalesHelpers.create_event!(source, %{name: "Event A"})
    event_b = SalesHelpers.create_event!(source, %{name: "Event B"})
    ticket_a = SalesHelpers.create_ticket_type!(event_a, %{name: "Ticket A"})
    ticket_b = SalesHelpers.create_ticket_type!(event_b, %{name: "Ticket B"})

    item_a =
      SalesHelpers.create_order_item_from_line!(
        order,
        order_line(woo_refund_id * 10 + 1),
        %{
          event_id: event_a.id,
          ticket_type_id: ticket_a.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    item_b =
      SalesHelpers.create_order_item_from_line!(
        order,
        order_line(woo_refund_id * 10 + 2),
        %{
          event_id: event_b.id,
          ticket_type_id: ticket_b.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    refund = create_refund!(source, order, %{woo_refund_id: woo_refund_id})
    line = create_refund_line!(refund, item_a, %{woo_refund_line_item_id: woo_refund_id + 80_000})

    {order, event_a, event_b, item_a, item_b, refund, line}
  end

  defp create_refund!(source, order, attrs) do
    defaults = %{
      source_system_id: source.id,
      order_id: order && order.id,
      woo_order_id: order && order.woo_order_id,
      woo_refund_id: System.unique_integer([:positive]),
      currency: order && order.currency,
      source_state: :active,
      detail_status: :complete,
      summary_total_amount: Decimal.new("10.00"),
      header_amount: Decimal.new("10.00"),
      unallocated_header_amount: Decimal.new("0.00"),
      source_created_at: @refund_created_at
    }

    Ash.create!(Refund, Map.merge(defaults, attrs), action: :create_normalized, domain: Sales)
  end

  defp create_distinct_order!(source) do
    Ash.create!(
      Order,
      %{
        source_system_id: source.id,
        woo_order_id: System.unique_integer([:positive]),
        status: :completed,
        currency: "ZAR",
        created_at_source: @refund_created_at,
        updated_at_source: @refund_created_at,
        raw_total: Decimal.new("100.00")
      },
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_refund_line!(refund, order_item, attrs) do
    defaults = %{
      refund_id: refund.id,
      order_item_id: order_item.id,
      woo_refund_line_item_id: System.unique_integer([:positive]),
      woo_refunded_item_id: order_item.woo_line_item_id,
      refunded_quantity: 1,
      refund_total_amount: Decimal.new("10.00"),
      refund_total_tax: Decimal.new("0.00"),
      binding_reason: nil,
      validation_reason: nil
    }

    Ash.create!(RefundLine, Map.merge(defaults, attrs), action: :create_normalized, domain: Sales)
  end

  defp order_line(id) do
    %{
      "id" => id,
      "product_id" => id + 1000,
      "variation_id" => id + 2000,
      "name" => "Ticket #{id}",
      "quantity" => 1,
      "subtotal" => "100.00",
      "total" => "100.00",
      "discount_total" => "0.00"
    }
  end

  defp ids(resource, nil) do
    resource
    |> Ash.read!(domain: Sales)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp ids(resource, order_id) do
    resource
    |> Ash.Query.filter(order_id == ^order_id)
    |> Ash.read!(domain: Sales)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end

  defp refund_line_ids(refund_id) do
    RefundLine
    |> Ash.Query.filter(refund_id == ^refund_id)
    |> Ash.read!(domain: Sales)
    |> Enum.map(& &1.id)
    |> Enum.sort()
  end
end
