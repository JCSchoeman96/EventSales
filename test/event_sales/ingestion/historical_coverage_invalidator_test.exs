defmodule EventSales.Ingestion.HistoricalCoverageInvalidatorTest do
  use EventSales.DataCase, async: false

  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalCoverageInvalidator
  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Sales
  alias EventSales.Sales.Resources.Order
  alias EventSales.TestSupport.SalesHelpers

  @coverage_start ~U[2026-08-01 08:00:00.000000Z]
  @sales_covered_through ~U[2026-08-09 23:59:59.999999Z]
  @within_sales_scope ~U[2026-08-05 12:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    {:ok, source: source}
  end

  test "rejects an invalid Order before resolving candidates", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Invalid Order Event"})
    _run = certified_run!(event)
    invalid_order = %Order{source_system_id: source.id, created_at_source: nil}

    assert {:error, :invalid_order} =
             HistoricalCoverageInvalidator.invalidate_order_change(invalid_order, [event.id])

    assert {:ok, _current} = HistoricalCoverageResolver.resolve_current(event.id)
  end

  test "rejects malformed Event IDs before making any invalidation write", %{
    source: source
  } do
    event = SalesHelpers.create_event!(source, %{name: "Malformed Candidate Event"})
    run = certified_run!(event)
    order = create_order!(source, @within_sales_scope)

    assert {:error, :invalid_event_id} =
             HistoricalCoverageInvalidator.invalidate_order_change(order, [event.id, "bad-id"])

    assert {:ok, current} = HistoricalCoverageResolver.resolve_current(event.id)
    assert current.id == run.id
  end

  test "skips an Event with no current historical coverage", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Uncertified Event"})
    order = create_order!(source, @within_sales_scope)

    assert {:ok,
            %{
              invalidated_event_ids: [],
              skipped: [%{event_id: event_id, reason: :no_current_coverage}]
            }} = HistoricalCoverageInvalidator.invalidate_order_change(order, [event.id])

    assert event_id == event.id
  end

  test "deduplicates candidates and preserves deterministic result order", %{source: source} do
    no_current = SalesHelpers.create_event!(source, %{name: "No Current Event"})

    outside = SalesHelpers.create_event!(source, %{name: "Outside Event"})

    outside_run =
      certified_run!(outside, %{
        sales_covered_through: DateTime.add(@within_sales_scope, -1, :second)
      })

    inside = SalesHelpers.create_event!(source, %{name: "Inside Event"})
    inside_run = certified_run!(inside)

    order =
      create_order!(source, @within_sales_scope, DateTime.add(@sales_covered_through, 1, :day))

    assert {:ok,
            %{
              invalidated_event_ids: [invalidated_id],
              skipped: [
                %{event_id: skipped_no_current_id, reason: :no_current_coverage},
                %{event_id: skipped_outside_id, reason: :outside_sales_coverage}
              ]
            }} =
             HistoricalCoverageInvalidator.invalidate_order_change(order, [
               no_current.id,
               outside.id,
               inside.id,
               no_current.id,
               inside.id
             ])

    assert invalidated_id == inside.id
    assert skipped_no_current_id == no_current.id
    assert skipped_outside_id == outside.id
    assert outside_run.id != inside_run.id
    assert {:ok, _current} = HistoricalCoverageResolver.resolve_current(outside.id)

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(inside.id)
  end

  test "skips Orders before B and after C", %{source: source} do
    before_event = SalesHelpers.create_event!(source, %{name: "Before B Event"})
    _before_run = certified_run!(before_event)
    before_order = create_order!(source, DateTime.add(@coverage_start, -1, :second))

    assert {:ok, %{invalidated_event_ids: [], skipped: [%{reason: :outside_sales_coverage}]}} =
             HistoricalCoverageInvalidator.invalidate_order_change(before_order, [before_event.id])

    after_event = SalesHelpers.create_event!(source, %{name: "After C Event"})
    _after_run = certified_run!(after_event)
    after_order = create_order!(source, DateTime.add(@sales_covered_through, 1, :second))

    assert {:ok, %{invalidated_event_ids: [], skipped: [%{reason: :outside_sales_coverage}]}} =
             HistoricalCoverageInvalidator.invalidate_order_change(after_order, [after_event.id])
  end

  test "treats both B and C as inclusive and ignores updated/refund/certification times", %{
    source: source
  } do
    for created_at_source <- [@coverage_start, @sales_covered_through] do
      event = SalesHelpers.create_event!(source, %{name: "Inclusive Event"})

      run =
        certified_run!(event, %{
          refunds_covered_through: @coverage_start
        })

      order =
        create_order!(
          source,
          created_at_source,
          DateTime.add(@sales_covered_through, 1, :day)
        )

      assert {:ok, %{invalidated_event_ids: [event_id], skipped: []}} =
               HistoricalCoverageInvalidator.invalidate_order_change(order, [event.id])

      assert event_id == event.id

      assert {:error, :historical_coverage_not_current} =
               HistoricalCoverageResolver.resolve_current(event.id)

      invalidated = Ash.get!(SyncRun, run.id, domain: Ingestion)
      assert invalidated.coverage_start == @coverage_start
      assert invalidated.sales_covered_through == @sales_covered_through
      assert invalidated.refunds_covered_through == @coverage_start
      assert %DateTime{} = invalidated.coverage_certified_at
    end
  end

  test "fails closed when the Order and certificate have different source systems", %{
    source: source
  } do
    other_source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(other_source, %{name: "Foreign Source Event"})
    run = certified_run!(event)
    order = create_order!(source, @within_sales_scope)

    assert {:error, :coverage_source_mismatch} =
             HistoricalCoverageInvalidator.invalidate_order_change(order, [event.id])

    assert {:ok, current} = HistoricalCoverageResolver.resolve_current(event.id)
    assert current.id == run.id
  end

  test "invalidates the exact certificate and replay becomes no current coverage", %{
    source: source
  } do
    event = SalesHelpers.create_event!(source, %{name: "Replay Event"})
    run = certified_run!(event)
    order = create_order!(source, @within_sales_scope)

    assert {:ok, %{invalidated_event_ids: [invalidated_id], skipped: []}} =
             HistoricalCoverageInvalidator.invalidate_order_change(order, [event.id])

    assert invalidated_id == event.id

    invalidated = Ash.get!(SyncRun, run.id, domain: Ingestion)
    assert invalidated.order_coverage_status == :incomplete
    assert invalidated.refund_coverage_status == :incomplete
    assert invalidated.coverage_invalidation_reason == :historical_order_changed
    assert %DateTime{} = invalidated.coverage_invalidated_at
    assert invalidated.coverage_start == run.coverage_start
    assert invalidated.sales_covered_through == run.sales_covered_through
    assert invalidated.refunds_covered_through == run.refunds_covered_through
    assert invalidated.coverage_certified_at == run.coverage_certified_at

    assert {:ok,
            %{
              invalidated_event_ids: [],
              skipped: [%{event_id: replay_event_id, reason: :no_current_coverage}]
            }} = HistoricalCoverageInvalidator.invalidate_order_change(order, [event.id])

    assert replay_event_id == event.id
  end

  defp certified_run!(event, attrs \\ %{}) do
    coverage =
      Map.merge(
        %{
          coverage_start: @coverage_start,
          sales_covered_through: @sales_covered_through,
          refunds_covered_through: @sales_covered_through
        },
        attrs
      )

    SyncRun
    |> Ash.Changeset.for_create(:queue_historical_backfill, %{
      event_id: event.id,
      date_to: coverage.sales_covered_through
    })
    |> Ash.Changeset.force_change_attribute(:source_system_id, event.source_system_id)
    |> Ash.Changeset.force_change_attribute(:date_from, coverage.coverage_start)
    |> Ash.create!(domain: Ingestion)
    |> Ash.update!(%{}, action: :start, domain: Ingestion)
    |> Ash.update!(coverage, action: :record_coverage_certification, domain: Ingestion)
    |> Ash.update!(%{}, action: :complete, domain: Ingestion)
  end

  defp create_order!(source, created_at_source),
    do: create_order!(source, created_at_source, created_at_source)

  defp create_order!(source, created_at_source, updated_at_source) do
    Ash.create!(
      Order,
      %{
        source_system_id: source.id,
        woo_order_id: System.unique_integer([:positive]),
        status: :completed,
        currency: "ZAR",
        created_at_source: created_at_source,
        updated_at_source: updated_at_source,
        raw_total: Decimal.new("100.00")
      },
      action: :create_normalized,
      domain: Sales
    )
  end
end
