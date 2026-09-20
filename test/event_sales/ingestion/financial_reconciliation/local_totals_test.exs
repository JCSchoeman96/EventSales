defmodule EventSales.Ingestion.FinancialReconciliation.LocalTotalsTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Ingestion
  alias EventSales.Ingestion.FinancialReconciliation.LocalTotals

  alias EventSales.Ingestion.Resources.{
    HistoricalOrderMembership,
    HistoricalRefundObservation,
    HistoricalRefundReference,
    SyncRun
  }

  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.FinancialPrimitives
  alias EventSales.Sales.Resources.{Order, OrderItem, Refund, RefundLine}
  alias EventSales.TestSupport.{HistoricalCoverageHelpers, SalesHelpers}

  require Ash.Query

  @coverage_start ~U[2026-08-01 08:00:00.000000Z]
  @sales_covered_through ~U[2026-08-09 23:59:59.999999Z]
  @refunds_covered_through ~U[2026-08-13 12:00:00.000000Z]
  @modified_at ~U[2026-08-04 10:00:00.000000Z]
  @observed_at ~U[2026-08-13 11:00:00.000000Z]
  @completed_at ~U[2026-08-04 11:00:00.000000Z]
  @refund_created_at ~U[2026-08-05 10:00:00.000000Z]
  @certified_at ~U[2026-08-10 10:00:00.000000Z]
  @newer_certified_at ~U[2026-08-11 10:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        external_event_id: 902_001,
        external_event_kind: :tickera_event
      })

    event =
      Ash.update!(event, %{source_created_at: @coverage_start},
        action: :capture_source_created_at,
        domain: Catalog,
        context: %{event_sales_backfill_start_capture_authority: {Event, :verified}}
      )

    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    run = certified_run!(event)

    %{source: source, event: event, ticket: ticket, run: run}
  end

  test "extracts gross and refund primitives for manifest-resolved target members", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_001, :target, :manifest, [701])
    order = create_order!(source, 20_001, status: :completed)
    item = create_ticket_item!(order, event, ticket, 501, qty: 2, total: "80.00", tax: "12.00")
    refund = create_refund!(source, order, 701)
    create_refund_line!(refund, item, qty: 1, total: "40.00", tax: "6.00")

    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    totals = result.currencies["ZAR"]

    assert Decimal.equal?(totals.gross_ticket_quantity, Decimal.new("2"))
    assert Decimal.equal?(totals.gross_ticket_value, Decimal.new("92.00"))
    assert Decimal.equal?(totals.refund_ticket_quantity, Decimal.new("1"))
    assert Decimal.equal?(totals.refund_ticket_value, Decimal.new("46.00"))
    assert Decimal.equal?(totals.net_ticket_quantity, Decimal.new("1"))
    assert Decimal.equal?(totals.net_ticket_value, Decimal.new("46.00"))
  end

  test "includes catchup-resolved target members", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    membership = create_membership!(run, 20_002, :target, :catchup, [])
    assert membership.resolution_state == :catchup_resolved

    order = create_order!(source, 20_002, status: :completed)
    create_ticket_item!(order, event, ticket, 502, qty: 1, total: "50.00", tax: "7.50")

    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    totals = result.currencies["ZAR"]
    assert Decimal.equal?(totals.gross_ticket_quantity, Decimal.new("1"))
    assert Decimal.equal?(totals.gross_ticket_value, Decimal.new("57.50"))
  end

  test "ignores non-target membership rows", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_003, :non_target, :manifest, [])
    create_membership!(run, 20_004, :target, :manifest, [])

    order = create_order!(source, 20_004, status: :completed)
    create_ticket_item!(order, event, ticket, 504, qty: 1, total: "10.00", tax: "0.00")

    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    assert Decimal.equal?(result.currencies["ZAR"].gross_ticket_quantity, Decimal.new("1"))
  end

  test "recognises gross from completion timestamp when status is not completed", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_010, :target, :manifest, [])
    order = create_order!(source, 20_010, status: :processing, completed_at: @completed_at)
    create_ticket_item!(order, event, ticket, 510, qty: 1, total: "25.00", tax: "0.00")

    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    assert Decimal.equal?(result.currencies["ZAR"].gross_ticket_quantity, Decimal.new("1"))
  end

  test "preserves gross for refunded orders with completion history", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_011, :target, :manifest, [711])
    order = create_order!(source, 20_011, status: :refunded, completed_at: @completed_at)
    item = create_ticket_item!(order, event, ticket, 511, qty: 2, total: "80.00", tax: "12.00")
    refund = create_refund!(source, order, 711)
    create_refund_line!(refund, item, qty: 2, total: "80.00", tax: "12.00")

    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    totals = result.currencies["ZAR"]
    assert Decimal.equal?(totals.gross_ticket_quantity, Decimal.new("2"))
    assert Decimal.equal?(totals.gross_ticket_value, Decimal.new("92.00"))
    assert Decimal.equal?(totals.net_ticket_quantity, Decimal.new("0"))
  end

  test "seeds zero-value currency partition for never-completed target orders", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_012, :target, :manifest, [])
    order = create_order!(source, 20_012, status: :processing, completed_at: nil)
    create_ticket_item!(order, event, ticket, 512, qty: 1, total: "10.00", tax: "0.00")

    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    assert_six_zero_partition!(result, "ZAR")
  end

  test "collapses multiple zero-value target orders into one currency partition", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_081, :target, :manifest, [])
    create_membership!(run, 20_082, :target, :manifest, [])

    order_a = create_order!(source, 20_081, status: :processing, completed_at: nil)
    order_b = create_order!(source, 20_082, status: :processing, completed_at: nil)
    create_ticket_item!(order_a, event, ticket, 581, qty: 1, total: "10.00", tax: "0.00")
    create_ticket_item!(order_b, event, ticket, 582, qty: 1, total: "10.00", tax: "0.00")

    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    assert map_size(result.currencies) == 1
    assert_six_zero_partition!(result, "ZAR")
  end

  test "returns zero and recognised currency partitions together", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_083, :target, :manifest, [])
    create_membership!(run, 20_084, :target, :manifest, [])

    order_zar = create_order!(source, 20_083, status: :processing, completed_at: nil)
    order_usd = create_order!(source, 20_084, status: :completed, currency: "USD")
    create_ticket_item!(order_zar, event, ticket, 583, qty: 1, total: "10.00", tax: "0.00")
    create_ticket_item!(order_usd, event, ticket, 584, qty: 1, total: "20.00", tax: "0.00")

    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    assert_six_zero_partition!(result, "ZAR")
    assert Decimal.equal?(result.currencies["USD"].gross_ticket_value, Decimal.new("20.00"))
  end

  test "accumulates totals per currency across multiple target members", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_013, :target, :manifest, [])
    create_membership!(run, 20_014, :target, :manifest, [])

    order_zar = create_order!(source, 20_013, status: :completed, currency: "ZAR")
    order_usd = create_order!(source, 20_014, status: :completed, currency: "USD")
    create_ticket_item!(order_zar, event, ticket, 513, qty: 1, total: "10.00", tax: "0.00")
    create_ticket_item!(order_usd, event, ticket, 514, qty: 1, total: "20.00", tax: "0.00")

    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    assert Decimal.equal?(result.currencies["ZAR"].gross_ticket_value, Decimal.new("10.00"))
    assert Decimal.equal?(result.currencies["USD"].gross_ticket_value, Decimal.new("20.00"))
  end

  test "extract resolves the current certified run for an event", %{
    event: event,
    source: source,
    run: run,
    ticket: ticket
  } do
    create_membership!(run, 20_015, :target, :manifest, [])
    order = create_order!(source, 20_015, status: :completed)
    create_ticket_item!(order, event, ticket, 515, qty: 1, total: "5.00", tax: "0.00")

    assert {:ok, result} = LocalTotals.extract(event.id)
    assert result.sync_run_id == run.id
    assert result.event_id == event.id
    assert result.source_system_id == source.id
  end

  test "returns empty currency totals when no target memberships exist", %{
    source: source,
    event: event,
    run: run
  } do
    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    assert result.currencies == %{}
  end

  test "blocks an older certified run when a newer current certificate exists", %{
    source: source,
    event: event,
    run: setup_run,
    ticket: ticket
  } do
    older = setup_run |> set_certified_at!(@certified_at)
    _newer = certified_run!(event) |> set_certified_at!(@newer_certified_at)

    create_membership!(older, 20_031, :target, :manifest, [])
    order = create_order!(source, 20_031, status: :completed)
    create_ticket_item!(order, event, ticket, 531, qty: 1, total: "10.00", tax: "0.00")

    assert {:error, {:invalid_scope, %{reason: :historical_certificate_not_current}}} =
             LocalTotals.extract_for_run(older, event, source)
  end

  test "blocks an invalidated supplied certificate", %{
    source: source,
    event: event,
    run: run,
    ticket: ticket
  } do
    create_membership!(run, 20_032, :target, :manifest, [])
    order = create_order!(source, 20_032, status: :completed)
    create_ticket_item!(order, event, ticket, 532, qty: 1, total: "10.00", tax: "0.00")

    assert {:ok, invalidated} =
             Ash.update(
               run,
               %{coverage_invalidation_reason: :historical_order_changed},
               action: :invalidate_order_coverage,
               domain: Ingestion
             )

    assert {:error, {:invalid_scope, %{reason: :historical_certificate_not_current}}} =
             LocalTotals.extract_for_run(invalidated, event, source)
  end

  test "blocks missing target member order", %{source: source, event: event, run: run} do
    create_membership!(run, 20_040, :target, :manifest, [])

    assert {:error, {:missing_local_fact, %{kind: :order, source_order_id: 20_040}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks missing gross line_total_tax", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_042, :target, :manifest, [])
    order = create_order!(source, 20_042, status: :completed)
    item = create_ticket_item!(order, event, ticket, 542, qty: 1, total: "10.00", tax: "0.00")
    nullify_column!("sales_order_items", item.id, "line_total_tax")

    assert {:error, {:financial_primitive_incomplete, %{field: :line_total_tax}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "accepts explicit zero gross tax", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_043, :target, :manifest, [])
    order = create_order!(source, 20_043, status: :completed)
    create_ticket_item!(order, event, ticket, 543, qty: 1, total: "10.00", tax: "0.00")

    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    assert Decimal.equal?(result.currencies["ZAR"].gross_ticket_value, Decimal.new("10.00"))
  end

  test "excludes non-ticket lines", %{source: source, event: event, ticket: ticket, run: run} do
    create_membership!(run, 20_050, :target, :manifest, [])
    order = create_order!(source, 20_050, status: :completed)

    Ash.create!(
      OrderItem,
      %{
        order_id: order.id,
        woo_line_item_id: 550,
        woo_product_id: 1,
        name: "Fee",
        quantity: 1,
        line_subtotal: Decimal.new("5"),
        line_total: Decimal.new("5"),
        line_total_tax: Decimal.new("0"),
        discount_total: Decimal.new("0"),
        item_kind: :non_ticket,
        mapping_status: :non_ticket
      },
      action: :create_normalized,
      domain: Sales
    )

    create_ticket_item!(order, event, ticket, 551, qty: 1, total: "10.00", tax: "0.00")

    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    assert Decimal.equal?(result.currencies["ZAR"].gross_ticket_value, Decimal.new("10.00"))
  end

  test "blocks missing refund observation", %{source: source, event: event, run: run} do
    create_membership_without_observation!(run, 20_060, :target)
    create_order!(source, 20_060, status: :completed)

    assert {:error, {:missing_local_fact, %{kind: :refund_observation, source_order_id: 20_060}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks refund reference count mismatch", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    membership = create_membership!(run, 20_061, :target, :manifest, [761])

    observation =
      HistoricalRefundObservation
      |> Ash.Query.filter(historical_order_membership_id == ^membership.id)
      |> Ash.read_one!(domain: Ingestion)

    set_observation_reference_count!(observation.id, 2)

    order = create_order!(source, 20_061, status: :completed)
    item = create_ticket_item!(order, event, ticket, 561, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 761)
    create_refund_line!(refund, item, qty: 1, total: "10.00", tax: "0.00")

    assert {:error, {:missing_local_fact, %{kind: :refund_reference_inconsistent}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "accepts explicit zero refunds", %{source: source, event: event, ticket: ticket, run: run} do
    create_membership!(run, 20_062, :target, :manifest, [])
    order = create_order!(source, 20_062, status: :completed)
    create_ticket_item!(order, event, ticket, 562, qty: 1, total: "10.00", tax: "0.00")

    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    assert Decimal.equal?(result.currencies["ZAR"].refund_ticket_value, Decimal.new("0"))
  end

  test "blocks missing durable refund for present reference", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_063, :target, :manifest, [763])
    order = create_order!(source, 20_063, status: :completed)
    create_ticket_item!(order, event, ticket, 563, qty: 1, total: "10.00", tax: "0.00")

    assert {:error, {:missing_local_fact, %{kind: :refund, woo_refund_id: 763}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks voided refund for present reference", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_064, :target, :manifest, [764])
    order = create_order!(source, 20_064, status: :completed)
    item = create_ticket_item!(order, event, ticket, 564, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 764, source_state: :voided)
    create_refund_line!(refund, item, qty: 1, total: "10.00", tax: "0.00")

    assert {:error, {:missing_local_fact, %{kind: :refund_not_active}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks incomplete refund detail", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_065, :target, :manifest, [765])
    order = create_order!(source, 20_065, status: :completed)
    item = create_ticket_item!(order, event, ticket, 565, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 765, detail_status: :reference_only)
    create_refund_line!(refund, item, qty: 1, total: "10.00", tax: "0.00")

    assert {:error, {:missing_local_fact, %{kind: :refund_not_complete}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks missing refund effective time", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_066, :target, :manifest, [766])
    order = create_order!(source, 20_066, status: :completed)
    item = create_ticket_item!(order, event, ticket, 566, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 766, source_created_at: nil)
    create_refund_line!(refund, item, qty: 1, total: "10.00", tax: "0.00")

    assert {:error, {:timestamp_incomplete, %{field: :source_created_at}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks refund effective time after refunds_covered_through", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_067, :target, :manifest, [767])
    order = create_order!(source, 20_067, status: :completed)
    item = create_ticket_item!(order, event, ticket, 567, qty: 1, total: "10.00", tax: "0.00")

    refund =
      create_refund!(source, order, 767,
        source_created_at: DateTime.add(@refunds_covered_through, 1, :hour)
      )

    create_refund_line!(refund, item, qty: 1, total: "10.00", tax: "0.00")

    assert {:error, {:timestamp_incomplete, %{field: :source_created_at}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks refund currency mismatch", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_068, :target, :manifest, [768])
    order = create_order!(source, 20_068, status: :completed, currency: "ZAR")
    item = create_ticket_item!(order, event, ticket, 568, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 768, currency: "USD")
    create_refund_line!(refund, item, qty: 1, total: "10.00", tax: "0.00")

    assert {:error, {:currency_conflict, %{woo_refund_id: 768}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks nil refund currency", %{source: source, event: event, ticket: ticket, run: run} do
    create_membership!(run, 20_091, :target, :manifest, [791])
    order = create_order!(source, 20_091, status: :completed)
    item = create_ticket_item!(order, event, ticket, 591, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 791)
    create_refund_line!(refund, item, qty: 1, total: "10.00", tax: "0.00")
    nullify_column!("sales_refunds", refund.id, "currency")

    assert {:error, {:currency_conflict, %{woo_refund_id: 791}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks blank refund currency", %{source: source, event: event, ticket: ticket, run: run} do
    create_membership!(run, 20_092, :target, :manifest, [792])
    order = create_order!(source, 20_092, status: :completed)
    item = create_ticket_item!(order, event, ticket, 592, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 792)
    create_refund_line!(refund, item, qty: 1, total: "10.00", tax: "0.00")
    set_column!("sales_refunds", refund.id, "currency", "")

    assert {:error, {:currency_conflict, %{woo_refund_id: 792}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks whitespace refund currency", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_093, :target, :manifest, [793])
    order = create_order!(source, 20_093, status: :completed)
    item = create_ticket_item!(order, event, ticket, 593, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 793)
    create_refund_line!(refund, item, qty: 1, total: "10.00", tax: "0.00")
    set_column!("sales_refunds", refund.id, "currency", "   ")

    assert {:error, {:currency_conflict, %{woo_refund_id: 793}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "accepts matching refund currency", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_094, :target, :manifest, [794])
    order = create_order!(source, 20_094, status: :completed, currency: "ZAR")
    item = create_ticket_item!(order, event, ticket, 594, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 794, currency: "ZAR")
    create_refund_line!(refund, item, qty: 1, total: "10.00", tax: "0.00")

    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    assert Decimal.equal?(result.currencies["ZAR"].refund_ticket_value, Decimal.new("10.00"))
  end

  test "blocks nil refund parent order_id", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_095, :target, :manifest, [795])
    order = create_order!(source, 20_095, status: :completed)
    item = create_ticket_item!(order, event, ticket, 595, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 795)
    create_refund_line!(refund, item, qty: 1, total: "10.00", tax: "0.00")
    nullify_column!("sales_refunds", refund.id, "order_id")

    assert {:error, {:missing_local_fact, %{kind: :refund_parent_binding, woo_refund_id: 795}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks refund parent order_id pointing at another order", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_096, :target, :manifest, [796])
    order = create_order!(source, 20_096, status: :completed)
    other_order = create_order!(source, 20_196, status: :completed)
    item = create_ticket_item!(order, event, ticket, 596, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 796)
    create_refund_line!(refund, item, qty: 1, total: "10.00", tax: "0.00")
    set_column!("sales_refunds", refund.id, "order_id", Ecto.UUID.dump!(other_order.id))

    assert {:error, {:missing_local_fact, %{kind: :refund_parent_binding, woo_refund_id: 796}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks historical recognition unproven when refund evidence exists", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_069, :target, :manifest, [769])
    order = create_order!(source, 20_069, status: :refunded, completed_at: nil)
    item = create_ticket_item!(order, event, ticket, 569, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 769)
    create_refund_line!(refund, item, qty: 1, total: "10.00", tax: "0.00")

    assert {:error, {:historical_recognition_unproven, %{source_order_id: 20_069}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "excludes absent_confirmed refund references from refund totals", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    membership = create_membership!(run, 20_085, :target, :manifest, [785])
    order = create_order!(source, 20_085, status: :completed)
    item = create_ticket_item!(order, event, ticket, 585, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 785)
    create_refund_line!(refund, item, qty: 1, total: "10.00", tax: "0.00")

    observation =
      HistoricalRefundObservation
      |> Ash.Query.filter(historical_order_membership_id == ^membership.id)
      |> Ash.read_one!(domain: Ingestion)

    reference =
      HistoricalRefundReference
      |> Ash.Query.filter(
        historical_refund_observation_id == ^observation.id and woo_refund_id == 785
      )
      |> Ash.read_one!(domain: Ingestion)

    Ash.update!(reference, %{}, action: :confirm_absent, domain: Ingestion)
    set_observation_reference_count!(observation.id, 0)

    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    assert Decimal.equal?(result.currencies["ZAR"].refund_ticket_value, Decimal.new("0"))
  end

  test "excludes refund lines bound to non-target order lines", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    other_event =
      SalesHelpers.create_event!(source, %{
        name: "Other",
        slug: "other-#{System.unique_integer([:positive])}"
      })

    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other"})

    create_membership!(run, 20_070, :target, :manifest, [770])
    order = create_order!(source, 20_070, status: :completed)

    _target_item =
      create_ticket_item!(order, event, ticket, 570, qty: 1, total: "10.00", tax: "0.00")

    other_item =
      Ash.create!(
        OrderItem,
        %{
          order_id: order.id,
          event_id: other_event.id,
          ticket_type_id: other_ticket.id,
          woo_line_item_id: 571,
          woo_product_id: 1,
          name: "Other",
          quantity: 1,
          line_subtotal: Decimal.new("5"),
          line_total: Decimal.new("5"),
          line_total_tax: Decimal.new("0"),
          discount_total: Decimal.new("0"),
          item_kind: :ticket,
          mapping_status: :mapped
        },
        action: :create_normalized,
        domain: Sales
      )

    refund = create_refund!(source, order, 770)
    create_refund_line!(refund, other_item, qty: 1, total: "5.00", tax: "0.00")

    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    assert Decimal.equal?(result.currencies["ZAR"].refund_ticket_value, Decimal.new("0"))
  end

  test "blocks non-target refund line with nil order_item_id", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    other_event =
      SalesHelpers.create_event!(source, %{
        name: "Other Nil Binder",
        slug: "other-nil-#{System.unique_integer([:positive])}"
      })

    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other"})

    create_membership!(run, 20_101, :target, :manifest, [801])
    order = create_order!(source, 20_101, status: :completed)
    create_ticket_item!(order, event, ticket, 601, qty: 1, total: "10.00", tax: "0.00")

    other_item =
      Ash.create!(
        OrderItem,
        %{
          order_id: order.id,
          event_id: other_event.id,
          ticket_type_id: other_ticket.id,
          woo_line_item_id: 602,
          woo_product_id: 1,
          name: "Other",
          quantity: 1,
          line_subtotal: Decimal.new("5"),
          line_total: Decimal.new("5"),
          line_total_tax: Decimal.new("0"),
          discount_total: Decimal.new("0"),
          item_kind: :ticket,
          mapping_status: :mapped
        },
        action: :create_normalized,
        domain: Sales
      )

    refund = create_refund!(source, order, 801)

    Ash.create!(
      RefundLine,
      %{
        refund_id: refund.id,
        order_item_id: nil,
        woo_refund_line_item_id: 1,
        woo_refunded_item_id: other_item.woo_line_item_id,
        refunded_quantity: 1,
        refund_total_amount: Decimal.new("5"),
        refund_total_tax: Decimal.new("0")
      },
      action: :create_normalized,
      domain: Sales
    )

    assert {:error, {:unresolved_attribution, %{reason: "binder_mismatch"}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks non-target refund line with wrong same-order order_item_id", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    other_event =
      SalesHelpers.create_event!(source, %{
        name: "Other Wrong Binder",
        slug: "other-wrong-#{System.unique_integer([:positive])}"
      })

    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other"})

    create_membership!(run, 20_102, :target, :manifest, [802])
    order = create_order!(source, 20_102, status: :completed)

    target_item =
      create_ticket_item!(order, event, ticket, 611, qty: 1, total: "10.00", tax: "0.00")

    other_item =
      Ash.create!(
        OrderItem,
        %{
          order_id: order.id,
          event_id: other_event.id,
          ticket_type_id: other_ticket.id,
          woo_line_item_id: 612,
          woo_product_id: 1,
          name: "Other",
          quantity: 1,
          line_subtotal: Decimal.new("5"),
          line_total: Decimal.new("5"),
          line_total_tax: Decimal.new("0"),
          discount_total: Decimal.new("0"),
          item_kind: :ticket,
          mapping_status: :mapped
        },
        action: :create_normalized,
        domain: Sales
      )

    refund = create_refund!(source, order, 802)

    Ash.create!(
      RefundLine,
      %{
        refund_id: refund.id,
        order_item_id: target_item.id,
        woo_refund_line_item_id: 1,
        woo_refunded_item_id: other_item.woo_line_item_id,
        refunded_quantity: 1,
        refund_total_amount: Decimal.new("5"),
        refund_total_tax: Decimal.new("0")
      },
      action: :create_normalized,
      domain: Sales
    )

    assert {:error, {:unresolved_attribution, %{reason: "binder_mismatch"}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks cross-order refund line order_item_id", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    other_event =
      SalesHelpers.create_event!(source, %{
        name: "Cross Order Binder",
        slug: "cross-order-#{System.unique_integer([:positive])}"
      })

    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other"})

    create_membership!(run, 20_103, :target, :manifest, [803])
    order = create_order!(source, 20_103, status: :completed)
    create_ticket_item!(order, event, ticket, 621, qty: 1, total: "10.00", tax: "0.00")

    other_order = create_order!(source, 20_203, status: :completed)

    member_other_item =
      Ash.create!(
        OrderItem,
        %{
          order_id: order.id,
          event_id: other_event.id,
          ticket_type_id: other_ticket.id,
          woo_line_item_id: 622,
          woo_product_id: 1,
          name: "Other",
          quantity: 1,
          line_subtotal: Decimal.new("5"),
          line_total: Decimal.new("5"),
          line_total_tax: Decimal.new("0"),
          discount_total: Decimal.new("0"),
          item_kind: :ticket,
          mapping_status: :mapped
        },
        action: :create_normalized,
        domain: Sales
      )

    cross_order_item =
      Ash.create!(
        OrderItem,
        %{
          order_id: other_order.id,
          event_id: other_event.id,
          ticket_type_id: other_ticket.id,
          woo_line_item_id: 623,
          woo_product_id: 1,
          name: "Cross",
          quantity: 1,
          line_subtotal: Decimal.new("5"),
          line_total: Decimal.new("5"),
          line_total_tax: Decimal.new("0"),
          discount_total: Decimal.new("0"),
          item_kind: :ticket,
          mapping_status: :mapped
        },
        action: :create_normalized,
        domain: Sales
      )

    refund = create_refund!(source, order, 803)

    Ash.create!(
      RefundLine,
      %{
        refund_id: refund.id,
        order_item_id: cross_order_item.id,
        woo_refund_line_item_id: 1,
        woo_refunded_item_id: member_other_item.woo_line_item_id,
        refunded_quantity: 1,
        refund_total_amount: Decimal.new("5"),
        refund_total_tax: Decimal.new("0")
      },
      action: :create_normalized,
      domain: Sales
    )

    assert {:error, {:unresolved_attribution, %{reason: "cross_order_binder"}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks unknown woo_refunded_item_id", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_104, :target, :manifest, [804])
    order = create_order!(source, 20_104, status: :completed)
    item = create_ticket_item!(order, event, ticket, 631, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 804)

    Ash.create!(
      RefundLine,
      %{
        refund_id: refund.id,
        order_item_id: item.id,
        woo_refund_line_item_id: 1,
        woo_refunded_item_id: 99_999,
        refunded_quantity: 1,
        refund_total_amount: Decimal.new("10"),
        refund_total_tax: Decimal.new("0")
      },
      action: :create_normalized,
      domain: Sales
    )

    assert {:error, {:unresolved_attribution, %{reason: "unknown_parent_line_binder"}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks missing woo_refunded_item_id", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_105, :target, :manifest, [805])
    order = create_order!(source, 20_105, status: :completed)
    item = create_ticket_item!(order, event, ticket, 641, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 805)

    Ash.create!(
      RefundLine,
      %{
        refund_id: refund.id,
        order_item_id: item.id,
        woo_refund_line_item_id: 1,
        woo_refunded_item_id: nil,
        refunded_quantity: 1,
        refund_total_amount: Decimal.new("10"),
        refund_total_tax: Decimal.new("0")
      },
      action: :create_normalized,
      domain: Sales
    )

    assert {:error, {:unresolved_attribution, %{reason: "missing_refunded_item_id"}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks unresolved refund binder", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_071, :target, :manifest, [771])
    order = create_order!(source, 20_071, status: :completed)
    item = create_ticket_item!(order, event, ticket, 571, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 771)

    Ash.create!(
      RefundLine,
      %{
        refund_id: refund.id,
        order_item_id: nil,
        woo_refund_line_item_id: 1,
        woo_refunded_item_id: item.woo_line_item_id,
        refunded_quantity: 1,
        refund_total_amount: Decimal.new("10"),
        refund_total_tax: Decimal.new("0"),
        binding_reason: "order_item_not_found"
      },
      action: :create_normalized,
      domain: Sales
    )

    assert {:error, {:unresolved_attribution, %{reason: "binding_reason"}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks missing refund amount on selected ticket line", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_072, :target, :manifest, [772])
    order = create_order!(source, 20_072, status: :completed)
    item = create_ticket_item!(order, event, ticket, 572, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 772)
    line = create_refund_line!(refund, item, qty: 1, total: "10.00", tax: "0.00")
    nullify_column!("sales_refund_lines", line.id, "refund_total_amount")

    assert {:error, {:financial_primitive_incomplete, %{field: :refund_total_amount}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "blocks missing refund tax on selected ticket line", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_073, :target, :manifest, [773])
    order = create_order!(source, 20_073, status: :completed)
    item = create_ticket_item!(order, event, ticket, 573, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 773)
    line = create_refund_line!(refund, item, qty: 1, total: "10.00", tax: "0.00")
    nullify_column!("sales_refund_lines", line.id, "refund_total_tax")

    assert {:error, {:financial_primitive_incomplete, %{field: :refund_total_tax}}} =
             LocalTotals.extract_for_run(run, event, source)
  end

  test "accepts value-only refund with zero quantity", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_074, :target, :manifest, [774])
    order = create_order!(source, 20_074, status: :completed)
    item = create_ticket_item!(order, event, ticket, 574, qty: 1, total: "15.00", tax: "0.00")
    refund = create_refund!(source, order, 774)
    create_refund_line!(refund, item, qty: 0, total: "15.00", tax: "0.00")

    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    totals = result.currencies["ZAR"]
    assert Decimal.equal?(totals.refund_ticket_quantity, Decimal.new("0"))
    assert Decimal.equal?(totals.refund_ticket_value, Decimal.new("15.00"))
  end

  test "sums multiple refunds against the same order item", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_075, :target, :manifest, [775, 776])
    order = create_order!(source, 20_075, status: :completed)
    item = create_ticket_item!(order, event, ticket, 575, qty: 3, total: "30.00", tax: "0.00")

    refund_a = create_refund!(source, order, 775)

    refund_b =
      create_refund!(source, order, 776,
        source_created_at: DateTime.add(@refund_created_at, 1, :hour)
      )

    create_refund_line!(refund_a, item, qty: 1, total: "10.00", tax: "0.00", line_id: 1)
    create_refund_line!(refund_b, item, qty: 1, total: "10.00", tax: "0.00", line_id: 2)

    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    totals = result.currencies["ZAR"]
    assert Decimal.equal?(totals.refund_ticket_quantity, Decimal.new("2"))
    assert Decimal.equal?(totals.refund_ticket_value, Decimal.new("20.00"))
  end

  test "does not clamp over-refund net values", %{
    source: source,
    event: event,
    ticket: ticket,
    run: run
  } do
    create_membership!(run, 20_076, :target, :manifest, [777])
    order = create_order!(source, 20_076, status: :completed)
    item = create_ticket_item!(order, event, ticket, 576, qty: 1, total: "10.00", tax: "0.00")
    refund = create_refund!(source, order, 777)
    create_refund_line!(refund, item, qty: 2, total: "20.00", tax: "0.00")

    assert {:ok, result} = LocalTotals.extract_for_run(run, event, source)
    totals = result.currencies["ZAR"]
    assert Decimal.equal?(totals.net_ticket_quantity, Decimal.new("-1"))
    assert Decimal.equal?(totals.net_ticket_value, Decimal.new("-10.00"))
  end

  test "does not call SourceExtractor or WooCommerce client modules" do
    local_source =
      File.read!(
        Path.join([
          File.cwd!(),
          "lib/event_sales/ingestion/financial_reconciliation/local_totals.ex"
        ])
      )

    refute local_source =~ "alias EventSales.Ingestion.FinancialReconciliation.SourceExtractor"
    refute local_source =~ "SourceExtractor."
    refute local_source =~ "WooCommerceClient"
    refute local_source =~ "Req."
    refute local_source =~ "HTTPoison"
  end

  defp certified_run!(event) do
    SyncRun
    |> Ash.Changeset.for_create(:queue_historical_backfill, %{
      event_id: event.id,
      date_to: @sales_covered_through
    })
    |> Ash.Changeset.force_change_attribute(:source_system_id, event.source_system_id)
    |> Ash.Changeset.force_change_attribute(:date_from, @coverage_start)
    |> Ash.create!(domain: Ingestion)
    |> Ash.update!(%{}, action: :start, domain: Ingestion)
    |> Ash.update!(
      %{
        coverage_start: @coverage_start,
        sales_covered_through: @sales_covered_through,
        refunds_covered_through: @refunds_covered_through,
        coverage_evidence: HistoricalCoverageHelpers.certified_evidence()
      },
      action: :record_coverage_certification,
      domain: Ingestion
    )
    |> Ash.update!(%{}, action: :complete, domain: Ingestion)
  end

  defp create_membership!(run, source_order_id, event_match_state, phase, refund_ids) do
    membership =
      Ash.create!(
        HistoricalOrderMembership,
        %{
          sync_run_id: run.id,
          source_order_id: source_order_id,
          manifest_source_created_at: @modified_at,
          manifest_source_modified_at: @modified_at,
          last_source_modified_at: @modified_at,
          event_match_state: event_match_state
        },
        action: :resolve_manifest,
        domain: Ingestion
      )

    membership =
      if phase == :catchup do
        Ash.update!(
          membership,
          %{last_source_modified_at: @modified_at, event_match_state: event_match_state},
          action: :resolve_catchup,
          domain: Ingestion
        )
      else
        membership
      end

    Ash.create!(
      HistoricalRefundObservation,
      %{
        historical_order_membership_id: membership.id,
        reference_count: length(refund_ids),
        observed_at: @observed_at
      },
      action: :resolve_manifest,
      domain: Ingestion
    )

    observation =
      HistoricalRefundObservation
      |> Ash.Query.filter(historical_order_membership_id == ^membership.id)
      |> Ash.read_one!(domain: Ingestion)

    Enum.each(refund_ids, fn refund_id ->
      Ash.create!(
        HistoricalRefundReference,
        %{
          historical_refund_observation_id: observation.id,
          woo_refund_id: refund_id,
          last_observed_at: @observed_at
        },
        action: :observe_present,
        domain: Ingestion
      )
    end)

    membership
  end

  defp create_membership_without_observation!(run, source_order_id, event_match_state) do
    Ash.create!(
      HistoricalOrderMembership,
      %{
        sync_run_id: run.id,
        source_order_id: source_order_id,
        manifest_source_created_at: @modified_at,
        manifest_source_modified_at: @modified_at,
        last_source_modified_at: @modified_at,
        event_match_state: event_match_state
      },
      action: :resolve_manifest,
      domain: Ingestion
    )
  end

  defp assert_six_zero_partition!(result, currency) do
    totals = result.currencies[currency]
    assert totals

    assert totals == FinancialPrimitives.derive_net_totals(FinancialPrimitives.empty_totals())
  end

  defp nullify_column!(table, id, column) do
    Repo.query!(
      "UPDATE #{table} SET #{column} = NULL WHERE id = $1",
      [Ecto.UUID.dump!(id)]
    )
  end

  defp set_column!(table, id, column, value) do
    Repo.query!(
      "UPDATE #{table} SET #{column} = $2 WHERE id = $1",
      [Ecto.UUID.dump!(id), value]
    )
  end

  defp set_observation_reference_count!(observation_id, reference_count) do
    Repo.query!(
      "UPDATE ingestion_historical_refund_observations SET reference_count = $2 WHERE id = $1",
      [Ecto.UUID.dump!(observation_id), reference_count]
    )
  end

  defp set_certified_at!(run, certified_at) do
    Repo.query!(
      "UPDATE ingestion_sync_runs SET coverage_certified_at = $2 WHERE id = $1",
      [Ecto.UUID.dump!(run.id), certified_at]
    )

    Ash.get!(SyncRun, run.id, domain: Ingestion)
  end

  defp create_order!(source, woo_order_id, opts) do
    Ash.create!(
      Order,
      %{
        source_system_id: source.id,
        woo_order_id: woo_order_id,
        order_number: to_string(woo_order_id),
        status: Keyword.get(opts, :status, :completed),
        currency: Keyword.get(opts, :currency, "ZAR"),
        completed_at: Keyword.get(opts, :completed_at, @completed_at),
        created_at_source: @modified_at,
        updated_at_source: @modified_at,
        raw_total: Decimal.new("100"),
        raw_discount_total: Decimal.new("0"),
        raw_tax_total: Decimal.new("0")
      },
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_ticket_item!(order, event, ticket, woo_line_item_id, opts) do
    total = Keyword.get(opts, :total, "10.00")
    tax = Keyword.get(opts, :tax, "0.00")
    qty = Keyword.get(opts, :qty, 1)

    attrs = %{
      order_id: order.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_line_item_id: woo_line_item_id,
      woo_product_id: 501,
      woo_variation_id: 601,
      name: "Ticket",
      quantity: qty,
      line_subtotal: if(is_nil(total), do: nil, else: Decimal.new(total)),
      line_total: if(is_nil(total), do: nil, else: Decimal.new(total)),
      line_total_tax: if(is_nil(tax), do: nil, else: Decimal.new(tax)),
      discount_total: Decimal.new("0"),
      item_kind: :ticket,
      mapping_status: :mapped,
      source_tickera_event_id: event.external_event_id
    }

    Ash.create!(OrderItem, attrs, action: :create_normalized, domain: Sales)
  end

  defp create_refund!(source, order, woo_refund_id, opts \\ []) do
    Ash.create!(
      Refund,
      %{
        source_system_id: source.id,
        order_id: order.id,
        woo_order_id: order.woo_order_id,
        woo_refund_id: woo_refund_id,
        currency: Keyword.get(opts, :currency, order.currency),
        source_state: Keyword.get(opts, :source_state, :active),
        detail_status: Keyword.get(opts, :detail_status, :complete),
        summary_total_amount: Decimal.new("10"),
        header_amount: Decimal.new("0"),
        shipping_refund_amount: Decimal.new("0"),
        shipping_refund_tax: Decimal.new("0"),
        fee_refund_amount: Decimal.new("0"),
        fee_refund_tax: Decimal.new("0"),
        unallocated_header_amount: Decimal.new("0"),
        source_created_at: Keyword.get(opts, :source_created_at, @refund_created_at)
      },
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_refund_line!(refund, item, opts) do
    total = Keyword.get(opts, :total, "10.00")
    tax = Keyword.get(opts, :tax, "0.00")
    qty = Keyword.get(opts, :qty, 1)
    line_id = Keyword.get(opts, :line_id, 1)

    Ash.create!(
      RefundLine,
      %{
        refund_id: refund.id,
        order_item_id: item.id,
        woo_refund_line_item_id: line_id,
        woo_refunded_item_id: item.woo_line_item_id,
        woo_product_id: item.woo_product_id,
        woo_variation_id: item.woo_variation_id,
        refunded_quantity: qty,
        refund_subtotal_amount: if(is_nil(total), do: nil, else: Decimal.new(total)),
        refund_total_amount: if(is_nil(total), do: nil, else: Decimal.new(total)),
        refund_total_tax: if(is_nil(tax), do: nil, else: Decimal.new(tax))
      },
      action: :create_normalized,
      domain: Sales
    )
  end
end
