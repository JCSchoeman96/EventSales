defmodule EventSales.Analytics.PreM5TimeCertificationTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Analytics.Aggregators.EventAggregator
  alias EventSales.Analytics.HistoricalCatchupFreshnessNotifier
  alias EventSales.Analytics.OrderProcessedNotifier
  alias EventSales.Analytics.RefundProcessedNotifier
  alias EventSales.Analytics.Resources.EventSourceFreshnessSnapshot
  alias EventSales.Analytics.SourceFreshness
  alias EventSales.Analytics.TimeRules
  alias EventSales.Analytics.TimeRules.Period
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Ingestion.HistoricalCatchupEvidence
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem, Refund, RefundLine}
  alias EventSales.TestSupport.SalesHelpers

  @johannesburg "Africa/Johannesburg"
  @report_now ~U[2026-06-02 10:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{name: "PRE-M5 Time", slug: unique_slug("pre-m5-time")})

    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Certification Ticket"})

    %{source: source, event: event, ticket: ticket}
  end

  test "period aggregation keeps sale gross on paid_at and refund value on source_created_at", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    {:ok, yesterday} = TimeRules.yesterday_bounds(@johannesburg, @report_now)
    {:ok, today} = TimeRules.today_bounds(@johannesburg, @report_now)

    order =
      create_order!(source,
        paid_at: ~U[2026-06-01 10:00:00.000000Z],
        completed_at: ~U[2026-06-02 08:00:00.000000Z]
      )

    item =
      create_item!(order, event, ticket,
        line_total: Decimal.new("100.00"),
        line_total_tax: Decimal.new("15.00")
      )

    refund =
      create_refund!(source, order, source_created_at: ~U[2026-06-02 09:00:00.000000Z])

    create_refund_line!(refund, item,
      refunded_quantity: 1,
      refund_total_amount: Decimal.new("25.00"),
      refund_total_tax: Decimal.new("5.00")
    )

    assert {:ok, yesterday_summaries} =
             EventAggregator.financial_summaries_for_event_period(event.id, yesterday)

    yesterday_summary = yesterday_summaries["ZAR"]
    assert Decimal.equal?(yesterday_summary.gross_ticket_value, Decimal.new("115.00"))
    assert yesterday_summary.recognised_order_count == 1
    assert Decimal.equal?(yesterday_summary.refund_ticket_value, Decimal.new("0"))

    assert {:ok, today_summaries} =
             EventAggregator.financial_summaries_for_event_period(event.id, today)

    today_summary = today_summaries["ZAR"]
    assert Decimal.equal?(today_summary.gross_ticket_value, Decimal.new("0"))
    assert today_summary.recognised_order_count == 0
    assert Decimal.equal?(today_summary.refund_ticket_value, Decimal.new("30.00"))
    assert Decimal.compare(today_summary.net_ticket_value, Decimal.new("0")) == :lt
  end

  test "order, refund, and terminal catch-up producers converge on distinct durable clocks", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    now = DateTime.utc_now()
    order_clock = DateTime.add(now, -8, :minute)
    refund_clock = DateTime.add(now, -6, :minute)
    sync_clock = DateTime.add(now, -2, :minute)

    order =
      create_order!(source,
        updated_at_source: order_clock,
        paid_at: order_clock,
        completed_at: order_clock
      )

    create_item!(order, event, ticket)

    assert :ok = OrderProcessedNotifier.notify_order_source_applied(order)
    order_snapshot = read_freshness_snapshot!(event.id)
    assert order_snapshot.order_source_watermark_at == order_clock
    assert is_nil(order_snapshot.refund_source_watermark_at)
    assert is_nil(order_snapshot.sync_source_observed_at)

    refund = create_refund!(source, order, source_created_at: refund_clock)

    assert :ok = RefundProcessedNotifier.notify_refund_applied(refund)
    refund_snapshot = read_freshness_snapshot!(event.id)
    assert refund_snapshot.order_source_watermark_at == order_clock
    assert refund_snapshot.refund_source_watermark_at == refund_clock
    assert is_nil(refund_snapshot.sync_source_observed_at)

    metadata =
      HistoricalCatchupEvidence.terminal_metadata(catchup_evidence(sync_clock), "terminal-proof")

    assert HistoricalCatchupEvidence.state(metadata) == :catchup_terminal

    run = %SyncRun{
      id: Ecto.UUID.generate(),
      event_id: event.id,
      sync_type: :historical_backfill,
      status: :completed
    }

    cursor = %SyncCursor{sync_run_id: run.id, status: :done, metadata: metadata}

    assert :ok = HistoricalCatchupFreshnessNotifier.notify_terminal_success(run, cursor)

    assert :ok =
             assert_freshness_components!(event.id, %{
               order_source_watermark_at: order_clock,
               refund_source_watermark_at: refund_clock,
               sync_source_observed_at: sync_clock
             })

    assert {:ok, %{anchor_at: ^sync_clock, classification: :normal}} =
             SourceFreshness.for_event(event.id, now: now)
  end

  test "90-day custom bounds normalize while custom financial aggregation stays disabled", %{
    event: event
  } do
    assert {:ok, %Period{kind: :custom} = period} =
             TimeRules.custom_civil_bounds(
               ~N[2026-01-01 00:00:00.000000],
               ~N[2026-04-01 00:00:00.000000],
               @johannesburg
             )

    assert Date.diff(~D[2026-04-01], ~D[2026-01-01]) == 90

    assert EventAggregator.financial_summaries_for_event_period(event.id, period) ==
             {:error, :unsupported_period_kind}
  end

  test "comparison_windows preserve canonical today bounds and one captured now anchor" do
    assert {:ok, canonical_today} = TimeRules.today_bounds(@johannesburg, @report_now)

    assert {:ok, windows} =
             TimeRules.comparison_windows(@johannesburg, @report_now, :today)

    assert windows.captured_now_utc == @report_now
    assert windows.current.start_utc == canonical_today.start_utc
    assert windows.current.end_utc == @report_now
    assert canonical_today.end_utc == ~U[2026-06-02 22:00:00.000000Z]
    refute windows.current.end_utc == canonical_today.end_utc
  end

  defp create_order!(source, attrs) do
    now = DateTime.utc_now()

    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "PRE-M5-#{System.unique_integer([:positive])}",
      status: :completed,
      currency: "ZAR",
      paid_at: ~U[2026-06-01 10:00:00.000000Z],
      completed_at: ~U[2026-06-02 08:00:00.000000Z],
      created_at_source: DateTime.add(now, -10, :minute),
      updated_at_source: DateTime.add(now, -8, :minute),
      raw_total: Decimal.new("100.00"),
      raw_discount_total: Decimal.new("0"),
      raw_tax_total: Decimal.new("15.00")
    }

    Ash.create!(Order, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_item!(order, %Event{} = event, %TicketType{} = ticket, attrs \\ []) do
    defaults = %{
      order_id: order.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_line_item_id: System.unique_integer([:positive]),
      woo_product_id: System.unique_integer([:positive]),
      woo_variation_id: nil,
      name: "Certification Ticket",
      quantity: 1,
      line_subtotal: Decimal.new("100.00"),
      line_total: Decimal.new("100.00"),
      line_total_tax: Decimal.new("15.00"),
      discount_total: Decimal.new("0"),
      item_kind: :ticket,
      mapping_status: :mapped
    }

    Ash.create!(OrderItem, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_refund!(source, order, attrs) do
    defaults = %{
      source_system_id: source.id,
      order_id: order.id,
      woo_order_id: order.woo_order_id,
      woo_refund_id: System.unique_integer([:positive]),
      currency: order.currency,
      source_state: :active,
      detail_status: :complete,
      summary_total_amount: Decimal.new("30.00"),
      header_amount: Decimal.new("0"),
      shipping_refund_amount: Decimal.new("0"),
      shipping_refund_tax: Decimal.new("0"),
      fee_refund_amount: Decimal.new("0"),
      fee_refund_tax: Decimal.new("0"),
      unallocated_header_amount: Decimal.new("0"),
      source_created_at: ~U[2026-06-02 09:00:00.000000Z]
    }

    Ash.create!(Refund, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_refund_line!(refund, item, attrs) do
    defaults = %{
      refund_id: refund.id,
      order_item_id: item.id,
      woo_refund_line_item_id: System.unique_integer([:positive]),
      woo_refunded_item_id: item.woo_line_item_id,
      woo_product_id: item.woo_product_id,
      woo_variation_id: item.woo_variation_id,
      refunded_quantity: 1,
      refund_subtotal_amount: Decimal.new("25.00"),
      refund_total_amount: Decimal.new("25.00"),
      refund_total_tax: Decimal.new("5.00")
    }

    Ash.create!(RefundLine, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp catchup_evidence(source_observed_at) do
    %HistoricalCatchupEvidence{
      schema_version: "2026-08-13.catchup.v1",
      phase: "catch_up",
      boundary_token: "catchup-token",
      manifest_hash: String.duplicate("a", 64),
      manifest_expires_at: DateTime.add(source_observed_at, 1, :day),
      source_observed_at: source_observed_at,
      state: "pending_first_page"
    }
  end

  defp assert_freshness_components!(event_id, expected) do
    snapshot = read_freshness_snapshot!(event_id)
    assert Map.take(snapshot, Map.keys(expected)) == expected

    rows =
      EventSourceFreshnessSnapshot
      |> Ash.Query.filter(event_id == ^event_id)
      |> Ash.read!(domain: EventSales.Analytics)

    assert length(rows) == 1
    :ok
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp read_freshness_snapshot!(event_id) do
    EventSourceFreshnessSnapshot
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.read_one!(domain: EventSales.Analytics)
  end
end
