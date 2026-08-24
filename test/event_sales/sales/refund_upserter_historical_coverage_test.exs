defmodule EventSales.Sales.RefundUpserterHistoricalCoverageTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.RefundUpserter
  alias EventSales.Sales.Resources.{Refund, RefundLine}
  alias EventSales.TestSupport.SalesHelpers

  @coverage_start ~U[2026-05-01 00:00:00.000000Z]
  @sales_covered_through ~U[2026-05-09 23:59:59.999999Z]
  @refunds_covered_through ~U[2026-05-09 23:59:59.999999Z]
  @refund_inside ~U[2026-05-05 10:00:00.000000Z]
  @refund_after_h ~U[2026-05-10 00:00:00.000000Z]

  test "rolls back Refund, lines, and the first D3B invalidation when the second fails" do
    source = SalesHelpers.create_source_system!()

    %{order: order, items: [item_a, item_b], events: [event_a, event_b]} =
      SalesHelpers.create_mixed_event_order!(source)

    assert {:ok, reference} =
             RefundUpserter.upsert_reference(source.id, order.woo_order_id, %{
               woo_refund_id: 98_001,
               summary_total_amount: Decimal.new("1300.00"),
               reason: "customer request"
             })

    run_a = certified_run!(event_a)
    run_b = certified_run!(event_b)
    before_refund = Ash.get!(Refund, reference.id, domain: Sales)
    before_lines = refund_lines(reference.id)
    before_certificate_a = Ash.get!(SyncRun, run_a.id, domain: Ingestion)
    before_certificate_b = Ash.get!(SyncRun, run_b.id, domain: Ingestion)

    install_second_invalidation_failure_trigger!()

    assert {:error, :refund_coverage_invalidation_failed} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(98_001, [
                 refund_line(88_001, item_a),
                 refund_line(88_002, item_b)
               ])
             )

    assert Ash.get!(Refund, reference.id, domain: Sales) == before_refund
    assert refund_lines(reference.id) == before_lines
    assert Ash.get!(SyncRun, run_a.id, domain: Ingestion) == before_certificate_a
    assert Ash.get!(SyncRun, run_b.id, domain: Ingestion) == before_certificate_b
  end

  test "new normalized historical detail invalidates its exact Event certificate" do
    %{source: source, order: order, items: [item_a | _], events: [event_a | _]} = mixed_fixture!()
    run = certified_run!(event_a)

    assert {:ok, %Refund{}} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(98_002, [refund_line(88_003, item_a)])
             )

    assert_invalidated!(run)
  end

  test "new normalized detail after H leaves the Event certificate unchanged" do
    %{source: source, order: order, items: [item_a | _], events: [event_a | _]} = mixed_fixture!()
    run = certified_run!(event_a)

    assert {:ok, %Refund{}} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(
                 98_003,
                 [refund_line(88_004, item_a)],
                 %{source_created_at: @refund_after_h}
               )
             )

    assert_current!(event_a, run)
  end

  test "an exact normalized replay does not invalidate coverage" do
    %{source: source, order: order, items: [item_a | _], events: [event_a | _]} = mixed_fixture!()
    normalized = normalized_refund(98_004, [refund_line(88_005, item_a)])

    assert {:ok, first} =
             RefundUpserter.upsert_normalized_refund(source.id, order.woo_order_id, normalized)

    run = certified_run!(event_a)
    install_invalidation_failure_trigger!()

    assert {:ok, %Refund{id: refund_id}} =
             RefundUpserter.upsert_normalized_refund(source.id, order.woo_order_id, normalized)

    assert refund_id == first.id
    assert_current!(event_a, run)
  end

  test "reference-only to complete persists lines before invalidating both exact Events" do
    %{source: source, order: order, items: [item_a, item_b], events: [event_a, event_b]} =
      mixed_fixture!()

    assert {:ok, %Refund{detail_status: :reference_only}} =
             RefundUpserter.upsert_reference(source.id, order.woo_order_id, %{
               woo_refund_id: 98_005,
               summary_total_amount: Decimal.new("1300.00")
             })

    run_a = certified_run!(event_a)
    run_b = certified_run!(event_b)

    assert {:ok, %Refund{detail_status: :complete}} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(98_005, [
                 refund_line(88_006, item_a),
                 refund_line(88_007, item_b)
               ])
             )

    assert_invalidated!(run_a)
    assert_invalidated!(run_b)
  end

  test "new malformed detail invalidates every bounded parent Event" do
    %{source: source, order: order, events: events} = fixture_with_third_event!()
    runs = Enum.map(events, &certified_run!/1)

    assert {:ok, %Refund{detail_status: :unresolved}} =
             RefundUpserter.upsert_refund(
               source.id,
               order.woo_order_id,
               malformed_refund_payload(98_006)
             )

    Enum.each(runs, &assert_invalidated!/1)
  end

  test "an identical malformed replay does not invalidate coverage" do
    %{source: source, order: order, events: [event_a | _]} = mixed_fixture!()
    malformed = malformed_refund_payload(98_007)

    assert {:ok, %Refund{}} =
             RefundUpserter.upsert_refund(source.id, order.woo_order_id, malformed)

    run = certified_run!(event_a)
    install_invalidation_failure_trigger!()

    assert {:ok, %Refund{}} =
             RefundUpserter.upsert_refund(source.id, order.woo_order_id, malformed)

    assert_current!(event_a, run)
  end

  test "new reference-only detail invalidates every bounded parent Event" do
    %{source: source, order: order, events: events} = fixture_with_third_event!()
    runs = Enum.map(events, &certified_run!/1)

    assert {:ok, %Refund{detail_status: :reference_only}} =
             RefundUpserter.upsert_reference(source.id, order.woo_order_id, %{
               woo_refund_id: 98_008,
               summary_total_amount: Decimal.new("1300.00")
             })

    Enum.each(runs, &assert_invalidated!/1)
  end

  test "summary and audit-only reference hydration remains outside certificate truth" do
    %{source: source, order: order, events: [event_a | _]} = mixed_fixture!()

    assert {:ok, %Refund{}} =
             RefundUpserter.upsert_reference(source.id, order.woo_order_id, %{
               woo_refund_id: 98_009,
               summary_total_amount: nil,
               reason: nil
             })

    run = certified_run!(event_a)
    install_invalidation_failure_trigger!()

    assert {:ok, %Refund{summary_total_amount: amount}} =
             RefundUpserter.upsert_reference(source.id, order.woo_order_id, %{
               woo_refund_id: 98_009,
               summary_total_amount: Decimal.new("45.00"),
               reason: "audit note"
             })

    assert amount == Decimal.new("45.00")
    assert_current!(event_a, run)
  end

  test "parent binding resolution invalidates the newly affected Event" do
    source = SalesHelpers.create_source_system!()

    unresolved_line =
      refund_line(88_010, %{woo_line_item_id: 70_004, woo_product_id: 501, woo_variation_id: 601})

    normalized = normalized_refund(98_010, [unresolved_line])

    assert {:ok, %Refund{order_id: nil}} =
             RefundUpserter.upsert_normalized_refund(source.id, 10_004, normalized)

    %{order: order, items: [item_a | _], events: [event_a | _]} =
      SalesHelpers.create_mixed_event_order!(source)

    run = certified_run!(event_a)

    assert {:ok, %Refund{order_id: order_id, id: refund_id}} =
             RefundUpserter.upsert_normalized_refund(source.id, order.woo_order_id, normalized)

    assert order_id == order.id
    assert_invalidated!(run)

    assert [%RefundLine{order_item_id: order_item_id, binding_reason: nil}] =
             refund_lines(refund_id)

    assert order_item_id == item_a.id
  end

  test "a source-detail conflict that changes completeness invalidates parent-wide coverage" do
    %{source: source, order: order, items: [item_a | _], events: events} =
      fixture_with_third_event!()

    assert {:ok, %Refund{}} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(98_011, [refund_line(88_011, item_a)])
             )

    runs = Enum.map(events, &certified_run!/1)

    changed_line =
      Map.put(refund_line(88_011, item_a), :refund_total_amount, Decimal.new("651.00"))

    assert {:ok, %Refund{detail_status: :unresolved, unresolved_reason: "source_detail_conflict"}} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(98_011, [changed_line], %{header_amount: Decimal.new("1301.00")})
             )

    Enum.each(runs, &assert_invalidated!/1)
  end

  test "active to voided invalidates the BEFORE exact Event candidates" do
    %{
      source: source,
      order: order,
      items: [item_a, item_b | _],
      events: [event_a, event_b, event_c]
    } =
      fixture_with_third_event!()

    assert {:ok, refund} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(98_012, [
                 refund_line(88_012, item_a),
                 refund_line(88_013, item_b)
               ])
             )

    run_a = certified_run!(event_a)
    run_b = certified_run!(event_b)
    run_c = certified_run!(event_c)
    observed_at = ~U[2026-05-06 10:00:00Z]

    assert {:ok, %Refund{source_state: :voided}} =
             RefundUpserter.mark_source_deleted(
               source.id,
               order.woo_order_id,
               refund.woo_refund_id,
               observed_at
             )

    assert_invalidated!(run_a)
    assert_invalidated!(run_b)
    assert_current!(event_c, run_c)
  end

  test "already-voided source deletion replay does not invalidate coverage" do
    %{source: source, order: order, items: [item_a | _], events: [event_a | _]} = mixed_fixture!()

    assert {:ok, refund} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(98_013, [refund_line(88_014, item_a)])
             )

    first_at = ~U[2026-05-06 11:00:00Z]

    assert {:ok, %Refund{voided_at: voided_at}} =
             RefundUpserter.mark_source_deleted(
               source.id,
               order.woo_order_id,
               refund.woo_refund_id,
               first_at
             )

    assert DateTime.compare(voided_at, first_at) == :eq

    run = certified_run!(event_a)
    install_invalidation_failure_trigger!()
    second_at = ~U[2026-05-06 12:00:00Z]

    assert {:ok, %Refund{voided_at: replayed_voided_at}} =
             RefundUpserter.mark_source_deleted(
               source.id,
               order.woo_order_id,
               refund.woo_refund_id,
               second_at
             )

    assert DateTime.compare(replayed_voided_at, first_at) == :eq

    assert_current!(event_a, run)
  end

  test "header-only value refunds invalidate every bounded parent Event" do
    %{source: source, order: order, events: events} = fixture_with_third_event!()
    runs = Enum.map(events, &certified_run!/1)

    assert {:ok, %Refund{}} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(
                 98_014,
                 [],
                 %{unallocated_header_amount: Decimal.new("1300.00")}
               )
             )

    Enum.each(runs, &assert_invalidated!/1)
  end

  test "exact bound multi-Event lines invalidate only their deterministic Events" do
    %{
      source: source,
      order: order,
      items: [item_a, item_b | _],
      events: [event_a, event_b, event_c]
    } = fixture_with_third_event!()

    run_a = certified_run!(event_a)
    run_b = certified_run!(event_b)
    run_c = certified_run!(event_c)

    assert {:ok, %Refund{}} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(98_015, [
                 refund_line(88_015, item_a),
                 refund_line(88_016, item_b)
               ])
             )

    assert_invalidated!(run_a)
    assert_invalidated!(run_b)
    assert_current!(event_c, run_c)
  end

  test "a no-parent Refund persists successfully without guessing an Event" do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Unrelated Event"})
    run = certified_run!(event)

    assert {:ok, %Refund{order_id: nil}} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               10_099,
               normalized_refund(98_016, [
                 refund_line(88_017, %{
                   woo_line_item_id: 70_004,
                   woo_product_id: 501,
                   woo_variation_id: 601
                 })
               ])
             )

    assert_current!(event, run)
  end

  test "a D3A capture error rolls back before any Refund mutation" do
    source = SalesHelpers.create_source_system!()
    parent = SalesHelpers.create_order_from_fixture!(:order_mixed_event, source)
    other = SalesHelpers.create_order_from_fixture!(:order_completed, source)

    assert {:ok, refund} =
             RefundUpserter.upsert_reference(source.id, parent.woo_order_id, %{
               woo_refund_id: 98_017,
               summary_total_amount: Decimal.new("45.00")
             })

    Repo.query!(
      "UPDATE sales_refunds SET order_id = $2 WHERE id = $1",
      [Ecto.UUID.dump!(refund.id), Ecto.UUID.dump!(other.id)]
    )

    before = Ash.get!(Refund, refund.id, domain: Sales)

    assert {:error, :invalid_refund} =
             RefundUpserter.upsert_reference(source.id, parent.woo_order_id, %{
               woo_refund_id: refund.woo_refund_id,
               summary_total_amount: Decimal.new("46.00")
             })

    assert Ash.get!(Refund, refund.id, domain: Sales) == before
  end

  test "all four public mutation paths retain the Refund result shape" do
    source = SalesHelpers.create_source_system!()

    assert {:ok, %Refund{}} =
             RefundUpserter.upsert_reference(source.id, 10_101, %{woo_refund_id: 98_018})

    assert {:ok, %Refund{}} =
             RefundUpserter.upsert_refund(source.id, 10_101, malformed_refund_payload(98_019))

    assert {:ok, %Refund{} = normalized} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               10_101,
               normalized_refund(98_020, [])
             )

    assert {:ok, %Refund{}} =
             RefundUpserter.mark_source_deleted(
               source.id,
               10_101,
               normalized.woo_refund_id,
               ~U[2026-05-06 13:00:00Z]
             )
  end

  defp mixed_fixture! do
    source = SalesHelpers.create_source_system!()
    source |> SalesHelpers.create_mixed_event_order!() |> Map.put(:source, source)
  end

  defp fixture_with_third_event! do
    source = SalesHelpers.create_source_system!()
    fixture = SalesHelpers.create_mixed_event_order!(source)

    event_c = SalesHelpers.create_event!(source, %{name: "Synthetic Event C"})
    ticket_c = SalesHelpers.create_variation_ticket_type!(event_c, 503, 603)

    item_c =
      SalesHelpers.create_order_item_from_line!(
        fixture.order,
        %{
          "id" => 70_006,
          "product_id" => 503,
          "variation_id" => 603,
          "name" => "Synthetic Event C Standard",
          "quantity" => 1,
          "subtotal" => "200.00",
          "total" => "200.00",
          "discount_total" => "0.00"
        },
        %{
          event_id: event_c.id,
          ticket_type_id: ticket_c.id,
          item_kind: :ticket,
          mapping_status: :mapped
        }
      )

    fixture
    |> Map.put(:source, source)
    |> Map.update!(:items, &(&1 ++ [item_c]))
    |> Map.update!(:events, &(&1 ++ [event_c]))
  end

  defp malformed_refund_payload(refund_id) do
    %{
      "id" => refund_id,
      "amount" => "1300.00",
      "line_items" => "not-a-list"
    }
  end

  defp assert_invalidated!(run) do
    invalidated = Ash.get!(SyncRun, run.id, domain: Ingestion)
    assert invalidated.refund_coverage_status == :incomplete
    assert invalidated.coverage_invalidation_reason == :historical_refund_changed
  end

  defp assert_current!(event, run) do
    assert {:ok, current} = HistoricalCoverageResolver.resolve_current(event.id)
    assert current.id == run.id
  end

  defp install_invalidation_failure_trigger! do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION eventsales_test_fail_refund_invalidation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      IF NEW.coverage_invalidation_reason = 'historical_refund_changed' THEN
        RAISE EXCEPTION 'forced refund invalidation failure';
      END IF;

      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER eventsales_test_fail_refund_invalidation
    BEFORE UPDATE ON ingestion_sync_runs
    FOR EACH ROW
    EXECUTE FUNCTION eventsales_test_fail_refund_invalidation()
    """)
  end

  defp normalized_refund(refund_id, line_items, attrs \\ %{}) do
    defaults = %{
      woo_refund_id: refund_id,
      header_amount: Decimal.new("1300.00"),
      reason: "customer request",
      source_created_at: @refund_inside,
      line_items: line_items,
      shipping_refund_amount: nil,
      shipping_refund_tax: nil,
      fee_refund_amount: nil,
      fee_refund_tax: nil,
      unallocated_header_amount: Decimal.new("0.00")
    }

    Map.merge(defaults, attrs)
  end

  defp refund_line(line_id, order_item) do
    %{
      woo_refund_line_item_id: line_id,
      woo_refunded_item_id: order_item.woo_line_item_id,
      woo_product_id: order_item.woo_product_id,
      woo_variation_id: order_item.woo_variation_id,
      refunded_quantity: 1,
      refund_subtotal_amount: Decimal.new("650.00"),
      refund_total_amount: Decimal.new("650.00"),
      refund_total_tax: Decimal.new("0.00"),
      binding_reason: nil,
      validation_reason: nil
    }
  end

  defp refund_lines(refund_id) do
    RefundLine
    |> Ash.Query.filter(refund_id == ^refund_id)
    |> Ash.Query.sort(woo_refund_line_item_id: :asc)
    |> Ash.read!(domain: Sales)
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
        refunds_covered_through: @refunds_covered_through
      },
      action: :record_coverage_certification,
      domain: Ingestion
    )
    |> Ash.update!(%{}, action: :complete, domain: Ingestion)
  end

  defp install_second_invalidation_failure_trigger! do
    Repo.query!("""
    CREATE TEMP TABLE eventsales_test_refund_invalidation_attempts (
      attempt integer NOT NULL
    ) ON COMMIT DROP
    """)

    Repo.query!("""
    CREATE OR REPLACE FUNCTION eventsales_test_fail_second_refund_invalidation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      attempt_count integer;
    BEGIN
      IF NEW.coverage_invalidation_reason = 'historical_refund_changed' THEN
        INSERT INTO eventsales_test_refund_invalidation_attempts (attempt) VALUES (1);
        SELECT count(*) INTO attempt_count
        FROM eventsales_test_refund_invalidation_attempts;

        IF attempt_count = 2 THEN
          RAISE EXCEPTION 'forced second refund invalidation failure';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER eventsales_test_fail_second_refund_invalidation
    BEFORE UPDATE ON ingestion_sync_runs
    FOR EACH ROW
    EXECUTE FUNCTION eventsales_test_fail_second_refund_invalidation()
    """)
  end
end
