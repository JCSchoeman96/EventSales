defmodule EventSales.Analytics.EventAggregatorTest do
  use EventSales.DataCase, async: true

  alias EventSales.Analytics.Aggregators.EventAggregator
  alias EventSales.Analytics.TimeRules
  alias EventSales.Analytics.TimeRules.Period
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem, Refund, RefundLine}
  alias EventSales.TestSupport.SalesHelpers

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Metric Event", slug: "metric-event"})
    other_event = SalesHelpers.create_event!(source, %{name: "Other Event", slug: "other-event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "General Admission"})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other Ticket"})

    %{
      source: source,
      event: event,
      other_event: other_event,
      ticket: ticket,
      other_ticket: other_ticket
    }
  end

  test "summarizes event-scoped rows without pre-filtering mapping status", %{
    source: source,
    event: event,
    other_event: other_event,
    ticket: ticket,
    other_ticket: other_ticket
  } do
    completed =
      create_order!(source, :completed,
        woo_order_id: 90_001,
        completed_at: ~U[2026-05-16 22:30:00.000000Z]
      )

    pending = create_order!(source, :pending, woo_order_id: 90_002, completed_at: nil)
    refunded = create_order!(source, :refunded, woo_order_id: 90_003, completed_at: nil)
    cancelled = create_order!(source, :cancelled, woo_order_id: 90_004)

    create_item!(completed, event, ticket,
      woo_line_item_id: 1,
      quantity: 2,
      line_total: Decimal.new("900.00"),
      mapping_status: :mapped,
      item_kind: :ticket
    )

    create_item!(completed, event, ticket,
      woo_line_item_id: 2,
      quantity: 1,
      line_total: Decimal.new("450.00"),
      mapping_status: :unmapped,
      item_kind: :ticket
    )

    create_item!(completed, event, ticket,
      woo_line_item_id: 3,
      quantity: 1,
      line_total: Decimal.new("200.00"),
      mapping_status: :non_ticket,
      item_kind: :non_ticket
    )

    create_item!(pending, event, ticket,
      woo_line_item_id: 4,
      quantity: 1,
      line_total: Decimal.new("500.00"),
      mapping_status: :mapped,
      item_kind: :ticket
    )

    create_item!(refunded, event, ticket,
      woo_line_item_id: 5,
      quantity: 1,
      line_total: Decimal.new("450.00"),
      mapping_status: :mapped,
      item_kind: :ticket
    )

    create_item!(cancelled, event, ticket,
      woo_line_item_id: 6,
      quantity: 1,
      line_total: Decimal.new("450.00"),
      mapping_status: :mapped,
      item_kind: :ticket
    )

    other_order = create_order!(source, :completed, woo_order_id: 90_005)

    create_item!(other_order, other_event, other_ticket,
      woo_line_item_id: 7,
      quantity: 9,
      line_total: Decimal.new("9999.00"),
      mapping_status: :mapped,
      item_kind: :ticket
    )

    assert {:ok, summary} =
             EventAggregator.summary_for_event(event.id,
               now: ~U[2026-05-17 10:00:00.000000Z],
               timezone: "Africa/Johannesburg"
             )

    assert summary == %{
             total_sold: 2,
             total_revenue: Decimal.new("900.00"),
             today_sold: 2,
             today_revenue: Decimal.new("900.00"),
             status_breakdown: %{completed: 3, pending: 1, refunded: 1, cancelled: 1}
           }
  end

  describe "legacy summary_for_event today uses sale effective time" do
    @now ~U[2026-06-01 12:00:00.000000Z]
    @timezone "Africa/Johannesburg"

    test "paid_at inside today wins over completed_at outside today", %{
      source: source,
      event: event,
      ticket: ticket
    } do
      order =
        create_order!(source, :completed,
          woo_order_id: 93_001,
          paid_at: ~U[2026-06-01 10:00:00.000000Z],
          completed_at: ~U[2026-05-31 10:00:00.000000Z]
        )

      create_item!(order, event, ticket,
        woo_line_item_id: 80,
        quantity: 1,
        line_total: Decimal.new("100.00")
      )

      assert {:ok, summary} =
               EventAggregator.summary_for_event(event.id, now: @now, timezone: @timezone)

      assert summary.total_sold == 1
      assert summary.today_sold == 1
      assert Decimal.equal?(summary.today_revenue, Decimal.new("100.00"))
      assert summary.status_breakdown == %{completed: 1}
    end

    test "paid_at outside today excludes row even when completed_at is inside today", %{
      source: source,
      event: event,
      ticket: ticket
    } do
      order =
        create_order!(source, :completed,
          woo_order_id: 93_002,
          paid_at: ~U[2026-05-31 10:00:00.000000Z],
          completed_at: ~U[2026-06-01 10:00:00.000000Z]
        )

      create_item!(order, event, ticket,
        woo_line_item_id: 81,
        quantity: 1,
        line_total: Decimal.new("100.00")
      )

      assert {:ok, summary} =
               EventAggregator.summary_for_event(event.id, now: @now, timezone: @timezone)

      assert summary.total_sold == 1
      assert Decimal.equal?(summary.total_revenue, Decimal.new("100.00"))
      assert summary.today_sold == 0
      assert Decimal.equal?(summary.today_revenue, Decimal.new("0"))
      assert summary.status_breakdown == %{completed: 1}
    end

    test "falls back to completed_at when paid_at is nil", %{
      source: source,
      event: event,
      ticket: ticket
    } do
      order =
        create_order!(source, :completed,
          woo_order_id: 93_003,
          paid_at: nil,
          completed_at: ~U[2026-06-01 10:00:00.000000Z]
        )

      create_item!(order, event, ticket,
        woo_line_item_id: 82,
        quantity: 2,
        line_total: Decimal.new("200.00")
      )

      assert {:ok, summary} =
               EventAggregator.summary_for_event(event.id, now: @now, timezone: @timezone)

      assert summary.today_sold == 2
      assert Decimal.equal?(summary.today_revenue, Decimal.new("200.00"))
    end

    test "completed row with both clocks nil keeps totals but excludes today", %{
      source: source,
      event: event,
      ticket: ticket
    } do
      order =
        create_order!(source, :completed,
          woo_order_id: 93_004,
          paid_at: nil,
          completed_at: nil
        )

      create_item!(order, event, ticket,
        woo_line_item_id: 83,
        quantity: 2,
        line_total: Decimal.new("200.00")
      )

      assert {:ok, summary} =
               EventAggregator.summary_for_event(event.id, now: @now, timezone: @timezone)

      assert summary.total_sold == 2
      assert Decimal.equal?(summary.total_revenue, Decimal.new("200.00"))
      assert summary.today_sold == 0
      assert Decimal.equal?(summary.today_revenue, Decimal.new("0"))
    end

    test "pending row with paid_at inside today does not count toward totals or today", %{
      source: source,
      event: event,
      ticket: ticket
    } do
      order =
        create_order!(source, :pending,
          woo_order_id: 93_005,
          paid_at: ~U[2026-06-01 10:00:00.000000Z],
          completed_at: nil
        )

      create_item!(order, event, ticket,
        woo_line_item_id: 84,
        quantity: 1,
        line_total: Decimal.new("100.00")
      )

      assert {:ok, summary} =
               EventAggregator.summary_for_event(event.id, now: @now, timezone: @timezone)

      assert summary.total_sold == 0
      assert Decimal.equal?(summary.total_revenue, Decimal.new("0"))
      assert summary.today_sold == 0
      assert Decimal.equal?(summary.today_revenue, Decimal.new("0"))
      assert summary.status_breakdown == %{pending: 1}
    end

    test "invalid timezone preserves totals and zeroes today", %{
      source: source,
      event: event,
      ticket: ticket
    } do
      order =
        create_order!(source, :completed,
          woo_order_id: 93_006,
          paid_at: nil,
          completed_at: ~U[2026-06-01 10:00:00.000000Z]
        )

      create_item!(order, event, ticket,
        woo_line_item_id: 85,
        quantity: 1,
        line_total: Decimal.new("100.00")
      )

      assert {:ok, summary} =
               EventAggregator.summary_for_event(event.id,
                 now: @now,
                 timezone: "Invalid/Timezone"
               )

      assert summary.total_sold == 1
      assert Decimal.equal?(summary.total_revenue, Decimal.new("100.00"))
      assert summary.today_sold == 0
      assert Decimal.equal?(summary.today_revenue, Decimal.new("0"))
      assert summary.status_breakdown == %{completed: 1}
    end
  end

  test "legacy summary_for_event stays completed-only while canonical gross includes historical completion evidence",
       %{
         source: source,
         event: event,
         ticket: ticket
       } do
    cancelled =
      create_order!(source, :cancelled,
        woo_order_id: 92_001,
        completed_at: ~U[2026-05-17 08:00:00.000000Z]
      )

    create_item!(cancelled, event, ticket,
      woo_line_item_id: 40,
      quantity: 1,
      line_total: Decimal.new("450.00"),
      line_total_tax: Decimal.new("67.50")
    )

    assert {:ok, legacy} = EventAggregator.summary_for_event(event.id)
    assert legacy.total_sold == 0
    assert Decimal.equal?(legacy.total_revenue, Decimal.new("0"))

    assert {:ok, canonical} = EventAggregator.financial_summaries_for_event(event.id)
    summary = canonical["ZAR"]
    assert Decimal.equal?(summary.gross_ticket_quantity, Decimal.new(1))
    assert Decimal.equal?(summary.gross_ticket_value, Decimal.new("517.50"))
  end

  test "financial_summaries_for_event returns empty map for only unrecognised pending rows", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    pending = create_order!(source, :pending, woo_order_id: 92_010, completed_at: nil)

    create_item!(pending, event, ticket,
      woo_line_item_id: 41,
      quantity: 3,
      line_total: Decimal.new("900.00")
    )

    assert {:ok, summaries} = EventAggregator.financial_summaries_for_event(event.id)
    assert summaries == %{}
  end

  test "refund on never-recognised order does not produce canonical refund primitives", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    pending = create_order!(source, :pending, woo_order_id: 92_020, completed_at: nil)

    item =
      create_item!(pending, event, ticket,
        woo_line_item_id: 42,
        quantity: 1,
        line_total: Decimal.new("80.00"),
        line_total_tax: Decimal.new("12.00")
      )

    refund = create_refund!(source, pending, 902)
    create_refund_line!(refund, item, qty: 1, total: "40.00", tax: "6.00")

    assert {:ok, summaries} = EventAggregator.financial_summaries_for_event(event.id)
    assert summaries == %{}
  end

  test "financial_summaries_for_event returns canonical tax-inclusive gross and distinct order count",
       %{
         source: source,
         event: event,
         ticket: ticket
       } do
    order =
      create_order!(source, :completed,
        woo_order_id: 91_001,
        completed_at: ~U[2026-05-17 08:00:00.000000Z]
      )

    create_item!(order, event, ticket,
      woo_line_item_id: 11,
      quantity: 2,
      line_total: Decimal.new("100.00"),
      line_total_tax: Decimal.new("15.00")
    )

    assert {:ok, summaries} = EventAggregator.financial_summaries_for_event(event.id)
    summary = summaries["ZAR"]

    assert summary.currency == "ZAR"
    assert Decimal.equal?(summary.gross_ticket_quantity, Decimal.new(2))
    assert Decimal.equal?(summary.gross_ticket_value, Decimal.new("115.00"))
    assert summary.recognised_order_count == 1
    assert Decimal.equal?(summary.net_ticket_value, Decimal.new("115.00"))
  end

  test "preserves historical gross when current status is refunded but completion evidence exists",
       %{
         source: source,
         event: event,
         ticket: ticket
       } do
    order =
      create_order!(source, :refunded,
        woo_order_id: 91_002,
        completed_at: ~U[2026-05-17 08:00:00.000000Z]
      )

    create_item!(order, event, ticket,
      woo_line_item_id: 12,
      quantity: 2,
      line_total: Decimal.new("80.00"),
      line_total_tax: Decimal.new("12.00")
    )

    assert {:ok, summaries} = EventAggregator.financial_summaries_for_event(event.id)
    summary = summaries["ZAR"]

    assert Decimal.equal?(summary.gross_ticket_quantity, Decimal.new(2))
    assert Decimal.equal?(summary.gross_ticket_value, Decimal.new("92.00"))
  end

  test "summary_for_event returns mixed currency error without choosing a currency", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    zar_order = create_order!(source, :completed, woo_order_id: 91_010, currency: "ZAR")
    usd_order = create_order!(source, :completed, woo_order_id: 91_011, currency: "USD")

    create_item!(zar_order, event, ticket,
      woo_line_item_id: 20,
      quantity: 1,
      line_total: Decimal.new("10.00")
    )

    create_item!(usd_order, event, ticket,
      woo_line_item_id: 21,
      quantity: 1,
      line_total: Decimal.new("20.00")
    )

    assert EventAggregator.summary_for_event(event.id) == {:error, :mixed_currency}
  end

  test "recognised order count stays one per event when one order spans overlapping events", %{
    source: source,
    event: event,
    other_event: other_event,
    ticket: ticket,
    other_ticket: other_ticket
  } do
    order =
      create_order!(source, :completed,
        woo_order_id: 91_030,
        completed_at: ~U[2026-05-17 08:00:00.000000Z]
      )

    create_item!(order, event, ticket,
      woo_line_item_id: 31,
      quantity: 1,
      line_total: Decimal.new("100.00"),
      line_total_tax: Decimal.new("15.00")
    )

    create_item!(order, other_event, other_ticket,
      woo_line_item_id: 32,
      quantity: 1,
      line_total: Decimal.new("200.00"),
      line_total_tax: Decimal.new("30.00")
    )

    assert {:ok, event_a} = EventAggregator.financial_summaries_for_event(event.id)
    assert {:ok, event_b} = EventAggregator.financial_summaries_for_event(other_event.id)

    assert event_a["ZAR"].recognised_order_count == 1
    assert event_b["ZAR"].recognised_order_count == 1

    # Contract: event-scoped counts are not additive into a global total (M1-06 §14).
    refute event_a["ZAR"].recognised_order_count + event_b["ZAR"].recognised_order_count == 1
  end

  describe "financial_summaries_for_event_period/2" do
    test "paid_at wins over completed_at for period placement", %{
      source: source,
      event: event,
      ticket: ticket
    } do
      period = jhb_today_period!(~D[2026-06-01])

      paid_inside =
        create_order!(source, :completed,
          woo_order_id: 94_001,
          paid_at: ~U[2026-06-01 12:00:00.000000Z],
          completed_at: ~U[2026-05-31 12:00:00.000000Z]
        )

      create_item!(paid_inside, event, ticket,
        woo_line_item_id: 50,
        quantity: 1,
        line_total: Decimal.new("100.00"),
        line_total_tax: Decimal.new("15.00")
      )

      paid_outside =
        create_order!(source, :completed,
          woo_order_id: 94_002,
          paid_at: ~U[2026-05-31 12:00:00.000000Z],
          completed_at: ~U[2026-06-01 12:00:00.000000Z]
        )

      create_item!(paid_outside, event, ticket,
        woo_line_item_id: 51,
        quantity: 1,
        line_total: Decimal.new("200.00"),
        line_total_tax: Decimal.new("30.00")
      )

      assert {:ok, summaries} =
               EventAggregator.financial_summaries_for_event_period(event.id, period)

      summary = summaries["ZAR"]
      assert Decimal.equal?(summary.gross_ticket_value, Decimal.new("115.00"))
      assert summary.recognised_order_count == 1
    end

    test "falls back to completed_at when paid_at is nil", %{
      source: source,
      event: event,
      ticket: ticket
    } do
      period = jhb_today_period!(~D[2026-06-01])

      order =
        create_order!(source, :completed,
          woo_order_id: 94_003,
          paid_at: nil,
          completed_at: ~U[2026-06-01 10:00:00.000000Z]
        )

      create_item!(order, event, ticket,
        woo_line_item_id: 52,
        quantity: 1,
        line_total: Decimal.new("50.00"),
        line_total_tax: Decimal.new("7.50")
      )

      assert {:ok, summaries} =
               EventAggregator.financial_summaries_for_event_period(event.id, period)

      assert Decimal.equal?(summaries["ZAR"].gross_ticket_value, Decimal.new("57.50"))
    end

    test "preserves historical gross in period when status is refunded", %{
      source: source,
      event: event,
      ticket: ticket
    } do
      period = jhb_today_period!(~D[2026-06-01])

      order =
        create_order!(source, :refunded,
          woo_order_id: 94_004,
          paid_at: nil,
          completed_at: ~U[2026-06-01 08:00:00.000000Z]
        )

      create_item!(order, event, ticket,
        woo_line_item_id: 53,
        quantity: 1,
        line_total: Decimal.new("80.00"),
        line_total_tax: Decimal.new("12.00")
      )

      assert {:ok, summaries} =
               EventAggregator.financial_summaries_for_event_period(event.id, period)

      assert Decimal.equal?(summaries["ZAR"].gross_ticket_value, Decimal.new("92.00"))
    end

    test "half-open sale boundaries include start and exclude end", %{
      source: source,
      event: event,
      ticket: ticket
    } do
      period = jhb_today_period!(~D[2026-06-01])
      start = period.start_utc
      ending = period.end_utc

      at_start =
        create_order!(source, :completed,
          woo_order_id: 94_005,
          paid_at: start,
          completed_at: nil
        )

      create_item!(at_start, event, ticket,
        woo_line_item_id: 54,
        quantity: 1,
        line_total: Decimal.new("10.00"),
        line_total_tax: Decimal.new("1.00")
      )

      at_end =
        create_order!(source, :completed,
          woo_order_id: 94_006,
          paid_at: ending,
          completed_at: nil
        )

      create_item!(at_end, event, ticket,
        woo_line_item_id: 55,
        quantity: 1,
        line_total: Decimal.new("99.00"),
        line_total_tax: Decimal.new("9.00")
      )

      assert {:ok, summaries} =
               EventAggregator.financial_summaries_for_event_period(event.id, period)

      assert Decimal.equal?(summaries["ZAR"].gross_ticket_value, Decimal.new("11.00"))
    end

    test "places refunds by source_created_at independently from sale effective time", %{
      source: source,
      event: event,
      ticket: ticket
    } do
      period = jhb_today_period!(~D[2026-06-01])

      sale_outside =
        create_order!(source, :completed,
          woo_order_id: 94_007,
          paid_at: ~U[2026-05-30 12:00:00.000000Z],
          completed_at: ~U[2026-05-30 12:00:00.000000Z]
        )

      item_outside =
        create_item!(sale_outside, event, ticket,
          woo_line_item_id: 56,
          quantity: 2,
          line_total: Decimal.new("80.00"),
          line_total_tax: Decimal.new("12.00")
        )

      refund_inside =
        create_refund!(source, sale_outside, 904,
          source_created_at: ~U[2026-06-01 10:00:00.000000Z]
        )

      create_refund_line!(refund_inside, item_outside, qty: 1, total: "40.00", tax: "6.00")

      assert {:ok, summaries} =
               EventAggregator.financial_summaries_for_event_period(event.id, period)

      summary = summaries["ZAR"]
      assert Decimal.equal?(summary.gross_ticket_value, Decimal.new("0"))
      assert Decimal.equal?(summary.refund_ticket_value, Decimal.new("46.00"))
      assert Decimal.compare(summary.net_ticket_value, Decimal.new("0")) == :lt
      assert summary.recognised_order_count == 0

      sale_inside =
        create_order!(source, :completed,
          woo_order_id: 94_008,
          paid_at: ~U[2026-06-01 11:00:00.000000Z],
          completed_at: ~U[2026-06-01 11:00:00.000000Z]
        )

      item_inside =
        create_item!(sale_inside, event, ticket,
          woo_line_item_id: 57,
          quantity: 2,
          line_total: Decimal.new("80.00"),
          line_total_tax: Decimal.new("12.00")
        )

      refund_outside =
        create_refund!(source, sale_inside, 905,
          source_created_at: ~U[2026-05-30 12:00:00.000000Z]
        )

      create_refund_line!(refund_outside, item_inside, qty: 1, total: "40.00", tax: "6.00")

      assert {:ok, inside_summaries} =
               EventAggregator.financial_summaries_for_event_period(event.id, period)

      inside = inside_summaries["ZAR"]
      assert Decimal.equal?(inside.gross_ticket_value, Decimal.new("92.00"))
      assert Decimal.equal?(inside.refund_ticket_value, Decimal.new("46.00"))
    end

    test "half-open refund boundaries include start and exclude end", %{
      source: source,
      event: event,
      ticket: ticket
    } do
      period = jhb_today_period!(~D[2026-06-01])
      start = period.start_utc
      ending = period.end_utc

      order =
        create_order!(source, :completed,
          woo_order_id: 94_009,
          paid_at: ~U[2026-05-30 12:00:00.000000Z],
          completed_at: ~U[2026-05-30 12:00:00.000000Z]
        )

      item =
        create_item!(order, event, ticket,
          woo_line_item_id: 58,
          quantity: 2,
          line_total: Decimal.new("80.00"),
          line_total_tax: Decimal.new("12.00")
        )

      refund_at_start = create_refund!(source, order, 906, source_created_at: start)
      create_refund_line!(refund_at_start, item, qty: 1, total: "10.00", tax: "1.00")

      order2 =
        create_order!(source, :completed,
          woo_order_id: 94_010,
          paid_at: ~U[2026-05-30 13:00:00.000000Z],
          completed_at: ~U[2026-05-30 13:00:00.000000Z]
        )

      item2 =
        create_item!(order2, event, ticket,
          woo_line_item_id: 59,
          quantity: 2,
          line_total: Decimal.new("80.00"),
          line_total_tax: Decimal.new("12.00")
        )

      refund_at_end = create_refund!(source, order2, 907, source_created_at: ending)
      create_refund_line!(refund_at_end, item2, qty: 1, total: "99.00", tax: "9.00")

      assert {:ok, summaries} =
               EventAggregator.financial_summaries_for_event_period(event.id, period)

      assert Decimal.equal?(summaries["ZAR"].refund_ticket_value, Decimal.new("11.00"))
    end

    test "returns missing_sale_effective_time for recognised sale with no clocks", %{
      source: source,
      event: event,
      ticket: ticket
    } do
      period = jhb_today_period!(~D[2026-06-01])

      order =
        create_order!(source, :completed,
          woo_order_id: 94_011,
          paid_at: nil,
          completed_at: nil
        )

      create_item!(order, event, ticket,
        woo_line_item_id: 60,
        quantity: 1,
        line_total: Decimal.new("10.00"),
        line_total_tax: Decimal.new("1.00")
      )

      assert EventAggregator.financial_summaries_for_event_period(event.id, period) ==
               {:error, :missing_sale_effective_time}
    end

    test "returns missing_refund_effective_time for qualifying refund without source_created_at",
         %{
           source: source,
           event: event,
           ticket: ticket
         } do
      period = jhb_today_period!(~D[2026-06-01])

      order =
        create_order!(source, :completed,
          woo_order_id: 94_012,
          paid_at: ~U[2026-05-30 12:00:00.000000Z],
          completed_at: ~U[2026-05-30 12:00:00.000000Z]
        )

      item =
        create_item!(order, event, ticket,
          woo_line_item_id: 61,
          quantity: 1,
          line_total: Decimal.new("10.00"),
          line_total_tax: Decimal.new("1.00")
        )

      refund = create_refund!(source, order, 908, source_created_at: nil)
      create_refund_line!(refund, item, qty: 1, total: "5.00", tax: "0.50")

      assert EventAggregator.financial_summaries_for_event_period(event.id, period) ==
               {:error, :missing_refund_effective_time}
    end

    test "primitive completeness is scoped to the requested period", %{
      source: source,
      event: event,
      ticket: ticket
    } do
      period = jhb_today_period!(~D[2026-06-01])

      complete_inside =
        create_order!(source, :completed,
          woo_order_id: 94_013,
          paid_at: ~U[2026-06-01 10:00:00.000000Z],
          completed_at: nil
        )

      create_item!(complete_inside, event, ticket,
        woo_line_item_id: 62,
        quantity: 1,
        line_total: Decimal.new("10.00"),
        line_total_tax: Decimal.new("1.00")
      )

      incomplete_outside =
        create_order!(source, :completed,
          woo_order_id: 94_014,
          paid_at: ~U[2026-05-30 10:00:00.000000Z],
          completed_at: nil
        )

      create_item!(incomplete_outside, event, ticket,
        woo_line_item_id: 63,
        quantity: 1,
        line_total: Decimal.new("10.00"),
        line_total_tax: nil
      )

      assert {:ok, summaries} =
               EventAggregator.financial_summaries_for_event_period(event.id, period)

      assert Decimal.equal?(summaries["ZAR"].gross_ticket_value, Decimal.new("11.00"))

      incomplete_inside =
        create_order!(source, :completed,
          woo_order_id: 94_015,
          paid_at: ~U[2026-06-01 11:00:00.000000Z],
          completed_at: nil
        )

      create_item!(incomplete_inside, event, ticket,
        woo_line_item_id: 64,
        quantity: 1,
        line_total: Decimal.new("10.00"),
        line_total_tax: nil
      )

      assert EventAggregator.financial_summaries_for_event_period(event.id, period) ==
               {:error, :incomplete_financial_primitives}
    end

    test "counts one recognised order per currency for multiple ticket lines in period", %{
      source: source,
      event: event,
      ticket: ticket
    } do
      period = jhb_today_period!(~D[2026-06-01])

      order =
        create_order!(source, :completed,
          woo_order_id: 94_016,
          paid_at: ~U[2026-06-01 09:00:00.000000Z],
          completed_at: nil
        )

      create_item!(order, event, ticket,
        woo_line_item_id: 65,
        quantity: 1,
        line_total: Decimal.new("10.00"),
        line_total_tax: Decimal.new("1.00")
      )

      create_item!(order, event, ticket,
        woo_line_item_id: 66,
        quantity: 2,
        line_total: Decimal.new("20.00"),
        line_total_tax: Decimal.new("2.00")
      )

      assert {:ok, summaries} =
               EventAggregator.financial_summaries_for_event_period(event.id, period)

      assert summaries["ZAR"].recognised_order_count == 1
    end

    test "keeps currency partitions separate within a period", %{
      source: source,
      event: event,
      ticket: ticket
    } do
      period = jhb_today_period!(~D[2026-06-01])

      zar =
        create_order!(source, :completed,
          woo_order_id: 94_017,
          currency: "ZAR",
          paid_at: ~U[2026-06-01 10:00:00.000000Z],
          completed_at: nil
        )

      usd =
        create_order!(source, :completed,
          woo_order_id: 94_018,
          currency: "USD",
          paid_at: ~U[2026-06-01 10:00:00.000000Z],
          completed_at: nil
        )

      create_item!(zar, event, ticket,
        woo_line_item_id: 67,
        quantity: 1,
        line_total: Decimal.new("10.00"),
        line_total_tax: Decimal.new("1.00")
      )

      create_item!(usd, event, ticket,
        woo_line_item_id: 68,
        quantity: 1,
        line_total: Decimal.new("20.00"),
        line_total_tax: Decimal.new("2.00")
      )

      assert {:ok, summaries} =
               EventAggregator.financial_summaries_for_event_period(event.id, period)

      assert map_size(summaries) == 2
      assert Decimal.equal?(summaries["ZAR"].gross_ticket_value, Decimal.new("11.00"))
      assert Decimal.equal?(summaries["USD"].gross_ticket_value, Decimal.new("22.00"))
    end

    test "rejects unsupported period kinds before aggregation", %{event: event} do
      custom_period =
        forged_period!(~U[2026-06-01 00:00:00.000000Z], ~U[2026-06-02 00:00:00.000000Z], :custom)

      rolling_8 =
        forged_period!(
          ~U[2026-06-01 00:00:00.000000Z],
          ~U[2026-06-09 00:00:00.000000Z],
          {:rolling_days, 8}
        )

      assert EventAggregator.financial_summaries_for_event_period(event.id, custom_period) ==
               {:error, :unsupported_period_kind}

      assert EventAggregator.financial_summaries_for_event_period(event.id, rolling_8) ==
               {:error, :unsupported_period_kind}
    end

    test "rejects spoofed supported period semantics", %{event: event} do
      decade_today = %Period{
        kind: :today,
        start_utc: ~U[2020-01-01 00:00:00.000000Z],
        end_utc: ~U[2030-01-01 00:00:00.000000Z],
        timezone: "Africa/Johannesburg"
      }

      assert EventAggregator.financial_summaries_for_event_period(event.id, decade_today) ==
               {:error, :invalid_period}

      wrong_zone_today = %Period{
        kind: :today,
        start_utc: ~U[2026-06-01 00:00:00.000000Z],
        end_utc: ~U[2026-06-02 00:00:00.000000Z],
        timezone: "UTC"
      }

      assert EventAggregator.financial_summaries_for_event_period(event.id, wrong_zone_today) ==
               {:error, :invalid_period}

      non_midnight_today = %Period{
        kind: :today,
        start_utc: ~U[2026-06-01 01:00:00.000000Z],
        end_utc: ~U[2026-06-02 01:00:00.000000Z],
        timezone: "Africa/Johannesburg"
      }

      assert EventAggregator.financial_summaries_for_event_period(event.id, non_midnight_today) ==
               {:error, :invalid_period}

      eight_day_rolling = %Period{
        kind: {:rolling_days, 7},
        start_utc: ~U[2026-06-01 00:00:00.000000Z],
        end_utc: ~U[2026-06-09 00:00:00.000000Z],
        timezone: nil
      }

      assert EventAggregator.financial_summaries_for_event_period(event.id, eight_day_rolling) ==
               {:error, :invalid_period}

      wrong_rolling_span = %Period{
        kind: {:rolling_days, 30},
        start_utc: ~U[2026-06-01 00:00:00.000000Z],
        end_utc: ~U[2026-06-15 00:00:00.000000Z],
        timezone: nil
      }

      assert EventAggregator.financial_summaries_for_event_period(event.id, wrong_rolling_span) ==
               {:error, :invalid_period}
    end

    test "accepts genuine TimeRules preset periods", %{event: event} do
      now = civil_noon_utc(~D[2026-06-10])

      assert {:ok, today} = TimeRules.today_bounds("Africa/Johannesburg", now)
      assert {:ok, _} = EventAggregator.financial_summaries_for_event_period(event.id, today)

      assert {:ok, yesterday} = TimeRules.yesterday_bounds("Africa/Johannesburg", now)
      assert {:ok, _} = EventAggregator.financial_summaries_for_event_period(event.id, yesterday)

      assert {:ok, rolling_7} = TimeRules.last_7_days_bounds(now)
      assert {:ok, _} = EventAggregator.financial_summaries_for_event_period(event.id, rolling_7)

      assert {:ok, rolling_30} = TimeRules.last_30_days_bounds(now)
      assert {:ok, _} = EventAggregator.financial_summaries_for_event_period(event.id, rolling_30)
    end

    test "rejects invalid period bounds", %{event: event} do
      non_utc_start = DateTime.from_naive!(~N[2026-06-01 00:00:00], "Africa/Johannesburg")

      invalid =
        %Period{
          start_utc: non_utc_start,
          end_utc: ~U[2026-06-02 00:00:00.000000Z],
          kind: :today,
          timezone: "Africa/Johannesburg"
        }

      assert EventAggregator.financial_summaries_for_event_period(event.id, invalid) ==
               {:error, :invalid_period}

      reversed = %Period{
        kind: :today,
        start_utc: ~U[2026-06-02 00:00:00.000000Z],
        end_utc: ~U[2026-06-01 00:00:00.000000Z],
        timezone: "Africa/Johannesburg"
      }

      assert EventAggregator.financial_summaries_for_event_period(event.id, reversed) ==
               {:error, :invalid_period}
    end

    test "returns empty map for supported period with no qualifying facts", %{event: event} do
      period = jhb_yesterday_period!(~D[2026-01-01])

      assert EventAggregator.financial_summaries_for_event_period(event.id, period) == {:ok, %{}}
    end
  end

  test "financial_summaries_for_event applies qualifying refunds without changing gross", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    order = create_order!(source, :completed, woo_order_id: 91_020)

    item =
      create_item!(order, event, ticket,
        woo_line_item_id: 30,
        quantity: 2,
        line_total: Decimal.new("80.00"),
        line_total_tax: Decimal.new("12.00")
      )

    refund = create_refund!(source, order, 901)
    create_refund_line!(refund, item, qty: 1, total: "40.00", tax: "6.00")

    assert {:ok, summaries} = EventAggregator.financial_summaries_for_event(event.id)
    summary = summaries["ZAR"]

    assert Decimal.equal?(summary.gross_ticket_quantity, Decimal.new(2))
    assert Decimal.equal?(summary.gross_ticket_value, Decimal.new("92.00"))
    assert Decimal.equal?(summary.refund_ticket_quantity, Decimal.new(1))
    assert Decimal.equal?(summary.refund_ticket_value, Decimal.new("46.00"))
    assert Decimal.equal?(summary.net_ticket_quantity, Decimal.new(1))
    assert Decimal.equal?(summary.net_ticket_value, Decimal.new("46.00"))
  end

  defp create_order!(source, status, attrs) do
    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "M-#{System.unique_integer([:positive])}",
      status: status,
      currency: "ZAR",
      completed_at: ~U[2026-05-17 08:00:00.000000Z],
      created_at_source: ~U[2026-05-17 07:00:00.000000Z],
      updated_at_source: ~U[2026-05-17 08:00:00.000000Z],
      raw_total: Decimal.new("0"),
      raw_discount_total: Decimal.new("0"),
      raw_tax_total: Decimal.new("0")
    }

    Ash.create!(Order, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_item!(order, %Event{} = event, %TicketType{} = ticket, attrs) do
    defaults = %{
      order_id: order.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_line_item_id: System.unique_integer([:positive]),
      woo_product_id: System.unique_integer([:positive]),
      woo_variation_id: nil,
      name: "Metric Ticket",
      quantity: 1,
      line_subtotal: Decimal.new("450.00"),
      line_total: Decimal.new("450.00"),
      discount_total: Decimal.new("0"),
      item_kind: :ticket,
      mapping_status: :mapped
    }

    Ash.create!(OrderItem, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp jhb_today_period!(%Date{} = civil_date) do
    {:ok, period} = TimeRules.today_bounds("Africa/Johannesburg", civil_noon_utc(civil_date))
    period
  end

  defp jhb_yesterday_period!(%Date{} = civil_date) do
    {:ok, period} =
      TimeRules.yesterday_bounds(
        "Africa/Johannesburg",
        civil_noon_utc(Date.add(civil_date, 1))
      )

    period
  end

  defp civil_noon_utc(%Date{} = date) do
    {:ok, local_noon} = DateTime.new(date, ~T[12:00:00.000000], "Africa/Johannesburg")
    {:ok, utc_noon} = DateTime.shift_zone(local_noon, "Etc/UTC")
    utc_noon
  end

  defp forged_period!(start_utc, end_utc, kind) do
    timezone =
      case kind do
        {:rolling_days, _} -> nil
        _ -> "Africa/Johannesburg"
      end

    %Period{
      start_utc: start_utc,
      end_utc: end_utc,
      kind: kind,
      timezone: timezone
    }
  end

  defp create_refund!(source, order, woo_refund_id, attrs \\ []) do
    defaults = %{
      source_system_id: source.id,
      order_id: order.id,
      woo_order_id: order.woo_order_id,
      woo_refund_id: woo_refund_id,
      currency: order.currency,
      source_state: :active,
      detail_status: :complete,
      summary_total_amount: Decimal.new("10"),
      header_amount: Decimal.new("0"),
      shipping_refund_amount: Decimal.new("0"),
      shipping_refund_tax: Decimal.new("0"),
      fee_refund_amount: Decimal.new("0"),
      fee_refund_tax: Decimal.new("0"),
      unallocated_header_amount: Decimal.new("0"),
      source_created_at: ~U[2026-05-17 09:00:00.000000Z]
    }

    Ash.create!(Refund, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_refund_line!(refund, item, opts) do
    Ash.create!(
      RefundLine,
      %{
        refund_id: refund.id,
        order_item_id: item.id,
        woo_refund_line_item_id: Keyword.get(opts, :line_id, 1),
        woo_refunded_item_id: item.woo_line_item_id,
        woo_product_id: item.woo_product_id,
        woo_variation_id: item.woo_variation_id,
        refunded_quantity: Keyword.get(opts, :qty, 1),
        refund_subtotal_amount: Decimal.new(Keyword.get(opts, :total, "10.00")),
        refund_total_amount: Decimal.new(Keyword.get(opts, :total, "10.00")),
        refund_total_tax: Decimal.new(Keyword.get(opts, :tax, "0.00"))
      },
      action: :create_normalized,
      domain: Sales
    )
  end
end
