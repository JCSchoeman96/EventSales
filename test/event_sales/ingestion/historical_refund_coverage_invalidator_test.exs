defmodule EventSales.Ingestion.HistoricalRefundCoverageInvalidatorTest do
  use EventSales.DataCase, async: false

  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.HistoricalRefundCoverageInvalidator
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.TestSupport.SalesHelpers

  @coverage_start ~U[2026-08-01 08:00:00.000000Z]
  @sales_covered_through ~U[2026-08-09 23:59:59.999999Z]
  @refunds_covered_through ~U[2026-08-09 23:59:59.999999Z]
  @sale_inside ~U[2026-08-05 12:00:00.000000Z]
  @refund_inside ~U[2026-08-05 14:00:00.000000Z]
  @refund_after_h ~U[2026-08-10 00:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    {:ok, source: source}
  end

  test "rejects a malformed AFTER snapshot", %{source: source} do
    malformed_after = %{refund_truth: %{source_system_id: source.id}}

    assert {:error, :invalid_refund_snapshot} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               malformed_after,
               []
             )
  end

  test "rejects a malformed BEFORE snapshot", %{source: source} do
    after_snapshot = snapshot(source.id, @sale_inside, @refund_inside)
    malformed_before = Map.delete(after_snapshot, :refund_truth)

    assert {:error, :invalid_refund_snapshot} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               malformed_before,
               after_snapshot,
               []
             )
  end

  test "rejects non-UTC persisted snapshot evidence", %{source: source} do
    non_utc = %DateTime{
      @sale_inside
      | time_zone: "Africa/Johannesburg",
        zone_abbr: "SAST",
        utc_offset: 7_200
    }

    malformed_after = snapshot(source.id, non_utc, @refund_inside)

    assert {:error, :invalid_refund_snapshot} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               malformed_after,
               []
             )
  end

  test "rejects a malformed candidate Event UUID", %{source: source} do
    after_snapshot = snapshot(source.id, @sale_inside, @refund_inside)

    assert {:error, :invalid_event_id} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               after_snapshot,
               ["not-an-event-uuid"]
             )
  end

  test "deduplicates candidate Event IDs and returns them in deterministic order", %{
    source: source
  } do
    event_a = SalesHelpers.create_event!(source, %{name: "Event A"})
    event_b = SalesHelpers.create_event!(source, %{name: "Event B"})
    _run_a = certified_run!(event_a)
    _run_b = certified_run!(event_b)

    assert {:ok, result} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               snapshot(source.id, @sale_inside, @refund_inside),
               [String.upcase(event_b.id), event_a.id, event_b.id]
             )

    assert result == %{
             invalidated_event_ids: Enum.sort([event_a.id, event_b.id]),
             skipped: []
           }
  end

  test "an empty candidate set returns an empty success", %{source: source} do
    assert {:ok, %{invalidated_event_ids: [], skipped: []}} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               snapshot(source.id, nil, nil),
               []
             )
  end

  test "skips a candidate with no current historical certificate", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Uncertified Event"})

    assert {:ok, %{invalidated_event_ids: [], skipped: [%{event_id: event_id, reason: reason}]}} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               snapshot(source.id, @sale_inside, @refund_inside),
               [event.id]
             )

    assert event_id == event.id
    assert reason == :no_current_coverage
  end

  test "fails closed when BEFORE or AFTER source evidence mismatches the certificate source", %{
    source: source
  } do
    other_source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Source Guard Event"})
    _run = certified_run!(event)

    before_snapshot = snapshot(other_source.id, @sale_inside, @refund_inside)
    after_snapshot = snapshot(source.id, @sale_inside, @refund_inside)

    assert {:error, :coverage_source_mismatch} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               before_snapshot,
               after_snapshot,
               [event.id]
             )

    assert {:ok, _current} = HistoricalCoverageResolver.resolve_current(event.id)
  end

  test "treats a parent sale exactly at B as inside", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Sale At B"})
    run = certified_run!(event)

    assert {:ok, %{invalidated_event_ids: [event_id], skipped: []}} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               snapshot(source.id, @coverage_start, @refund_inside),
               [event.id]
             )

    assert event_id == event.id
    assert Ash.get!(SyncRun, run.id, domain: Ingestion).refund_coverage_status == :incomplete
  end

  test "treats a parent sale exactly at C as inside", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Sale At C"})
    run = certified_run!(event)

    assert {:ok, %{invalidated_event_ids: [event_id], skipped: []}} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               snapshot(source.id, @sales_covered_through, @refund_inside),
               [event.id]
             )

    assert event_id == event.id
    assert Ash.get!(SyncRun, run.id, domain: Ingestion).refund_coverage_status == :incomplete
  end

  test "skips a parent sale before B", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Sale Before B"})
    _run = certified_run!(event)
    before_b = DateTime.add(@coverage_start, -1, :microsecond)

    assert {:ok, %{invalidated_event_ids: [], skipped: [%{reason: :outside_refund_coverage}]}} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               snapshot(source.id, before_b, @refund_inside),
               [event.id]
             )
  end

  test "skips a parent sale after C", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Sale After C"})
    _run = certified_run!(event)
    after_c = DateTime.add(@sales_covered_through, 1, :microsecond)

    assert {:ok, %{invalidated_event_ids: [], skipped: [%{reason: :outside_refund_coverage}]}} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               snapshot(source.id, after_c, @refund_inside),
               [event.id]
             )
  end

  test "treats a refund effective time exactly at H as inside", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Refund At H"})
    _run = certified_run!(event)

    assert {:ok, %{invalidated_event_ids: [event_id], skipped: []}} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               snapshot(source.id, @sale_inside, @refunds_covered_through),
               [event.id]
             )

    assert event_id == event.id
  end

  test "skips a known refund effective time after H", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Refund After H"})
    _run = certified_run!(event)

    assert {:ok, %{invalidated_event_ids: [], skipped: [%{reason: :outside_refund_coverage}]}} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               snapshot(source.id, @sale_inside, @refund_after_h),
               [event.id]
             )
  end

  test "treats nil refund effective time as inside when the parent sale is inside", %{
    source: source
  } do
    event = SalesHelpers.create_event!(source, %{name: "Refund Without Effective Time"})
    _run = certified_run!(event)

    assert {:ok, %{invalidated_event_ids: [event_id], skipped: []}} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               snapshot(source.id, @sale_inside, nil),
               [event.id]
             )

    assert event_id == event.id
  end

  test "invalidates when an existing refund moves from inside to outside", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Inside To Outside"})
    _run = certified_run!(event)

    assert {:ok, %{invalidated_event_ids: [event_id], skipped: []}} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               snapshot(source.id, @sale_inside, @refund_inside),
               snapshot(source.id, @sale_inside, @refund_after_h),
               [event.id]
             )

    assert event_id == event.id
  end

  test "invalidates when an existing refund moves from outside to inside", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Outside To Inside"})
    _run = certified_run!(event)
    before_b = DateTime.add(@coverage_start, -1, :microsecond)

    assert {:ok, %{invalidated_event_ids: [event_id], skipped: []}} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               snapshot(source.id, before_b, @refund_inside),
               snapshot(source.id, @sale_inside, @refund_inside),
               [event.id]
             )

    assert event_id == event.id
  end

  test "skips an existing refund when both snapshots are outside", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Both Outside"})
    _run = certified_run!(event)
    before_b = DateTime.add(@coverage_start, -1, :microsecond)
    after_c = DateTime.add(@sales_covered_through, 1, :microsecond)

    assert {:ok, %{invalidated_event_ids: [], skipped: [%{reason: :outside_refund_coverage}]}} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               snapshot(source.id, before_b, @refund_inside),
               snapshot(source.id, after_c, @refund_after_h),
               [event.id]
             )
  end

  test "invalidates an existing refund when both snapshots are inside", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Both Inside"})
    run = certified_run!(event)

    assert {:ok, %{invalidated_event_ids: [event_id], skipped: []}} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               snapshot(source.id, @sale_inside, @refund_inside),
               snapshot(source.id, @sale_inside, @refunds_covered_through),
               [event.id]
             )

    assert event_id == event.id
    assert Ash.get!(SyncRun, run.id, domain: Ingestion).refund_coverage_status == :incomplete
  end

  test "invalidates a new refund when AFTER is inside", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "New Inside"})
    _run = certified_run!(event)

    assert {:ok, %{invalidated_event_ids: [event_id], skipped: []}} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               snapshot(source.id, @sale_inside, @refund_inside),
               [event.id]
             )

    assert event_id == event.id
  end

  test "skips a new refund when AFTER is after H", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "New After H"})
    _run = certified_run!(event)

    assert {:ok, %{invalidated_event_ids: [], skipped: [%{reason: :outside_refund_coverage}]}} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               snapshot(source.id, @sale_inside, @refund_after_h),
               [event.id]
             )
  end

  test "returns an indeterminate scope error when parent sale evidence is missing", %{
    source: source
  } do
    event = SalesHelpers.create_event!(source, %{name: "Missing Parent Scope"})
    _run = certified_run!(event)

    assert {:error, :refund_scope_indeterminate} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               snapshot(source.id, nil, @refund_inside),
               [event.id]
             )
  end

  test "invalidates all exact current certificates in a multi-Event candidate set", %{
    source: source
  } do
    event_a = SalesHelpers.create_event!(source, %{name: "Multi Event A"})
    event_b = SalesHelpers.create_event!(source, %{name: "Multi Event B"})
    run_a = certified_run!(event_a)
    run_b = certified_run!(event_b)

    assert {:ok, %{invalidated_event_ids: invalidated_event_ids, skipped: []}} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               snapshot(source.id, @sale_inside, @refund_inside),
               [event_b.id, event_a.id]
             )

    assert invalidated_event_ids == Enum.sort([event_a.id, event_b.id])
    assert Ash.get!(SyncRun, run_a.id, domain: Ingestion).refund_coverage_status == :incomplete
    assert Ash.get!(SyncRun, run_b.id, domain: Ingestion).refund_coverage_status == :incomplete
  end

  test "returns deterministic mixed invalidated and no-current results", %{source: source} do
    no_current = SalesHelpers.create_event!(source, %{name: "Mixed No Current"})
    current = SalesHelpers.create_event!(source, %{name: "Mixed Current"})
    _run = certified_run!(current)

    assert {:ok, result} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               snapshot(source.id, @sale_inside, @refund_inside),
               [current.id, no_current.id, current.id]
             )

    assert result == %{
             invalidated_event_ids: [current.id],
             skipped: [%{event_id: no_current.id, reason: :no_current_coverage}]
           }
  end

  test "maps an invalidation action failure to a stable error", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Action Failure"})
    _run = certified_run!(event)
    install_invalidation_failure_trigger!()

    assert {:error, :refund_coverage_invalidation_failed} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               snapshot(source.id, @sale_inside, @refund_inside),
               [event.id]
             )
  end

  test "successful invalidation makes refund coverage incomplete and preserves other certificate fields",
       %{
         source: source
       } do
    event = SalesHelpers.create_event!(source, %{name: "Preserve Certificate"})
    run = certified_run!(event)

    preserved =
      Map.take(run, [
        :order_coverage_status,
        :coverage_start,
        :sales_covered_through,
        :refunds_covered_through,
        :coverage_certified_at
      ])

    assert {:ok, %{invalidated_event_ids: [event_id], skipped: []}} =
             HistoricalRefundCoverageInvalidator.invalidate_refund_change(
               nil,
               snapshot(source.id, @sale_inside, @refund_inside),
               [event.id]
             )

    assert event_id == event.id
    invalidated = Ash.get!(SyncRun, run.id, domain: Ingestion)
    assert invalidated.refund_coverage_status == :incomplete

    for {field, value} <- preserved do
      assert Map.get(invalidated, field) == value
    end

    assert invalidated.coverage_invalidation_reason == :historical_refund_changed
  end

  defp snapshot(source_system_id, parent_created_at, refund_created_at) do
    %{
      refund_truth: %{
        source_system_id: source_system_id,
        source_created_at: refund_created_at
      },
      refund_line_truth: [],
      parent_order_evidence: parent_order_evidence(source_system_id, parent_created_at),
      parent_order_item_evidence: []
    }
  end

  defp parent_order_evidence(_source_system_id, nil), do: nil

  defp parent_order_evidence(source_system_id, created_at_source) do
    %{
      id: Ecto.UUID.generate(),
      source_system_id: source_system_id,
      created_at_source: created_at_source
    }
  end

  defp certified_run!(event, attrs \\ %{}) do
    coverage =
      Map.merge(
        %{
          coverage_start: @coverage_start,
          sales_covered_through: @sales_covered_through,
          refunds_covered_through: @refunds_covered_through
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
end
