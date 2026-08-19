defmodule EventSales.Ingestion.HistoricalCoverageResolverTest do
  use EventSales.DataCase, async: false

  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Repo
  alias EventSales.TestSupport.SalesHelpers

  @coverage_start ~U[2026-08-01 08:00:00.000000Z]
  @sales_covered_through ~U[2026-08-09 23:59:59.999999Z]
  @refunds_covered_through ~U[2026-08-13 12:00:00.000000Z]
  @certified_at ~U[2026-08-14 09:00:00.000000Z]
  @newer_certified_at ~U[2026-08-15 09:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Coverage Event"})

    {:ok, source: source, event: event}
  end

  test "returns not current when the Event has no historical certificate", %{event: event} do
    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)
  end

  test "does not treat a completed historical run without a certificate as current", %{
    event: event
  } do
    _run = completed_historical_run!(event)

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)
  end

  test "returns a fully valid current historical certificate", %{event: event} do
    run = certified_run!(event)

    assert {:ok, returned} = HistoricalCoverageResolver.resolve_current(event.id)
    assert returned.id == run.id
  end

  test "rejects a certificate whose order coverage is incomplete", %{event: event} do
    run = certified_run!(event)
    _run = update_run!(run, "order_coverage_status = 'incomplete'")

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)
  end

  test "rejects a certificate whose refund coverage is incomplete", %{event: event} do
    run = certified_run!(event)
    _run = update_run!(run, "refund_coverage_status = 'incomplete'")

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)
  end

  test "rejects an invalidated certificate", %{event: event} do
    run = certified_run!(event)

    assert {:ok, invalidated} =
             Ash.update(
               run,
               %{coverage_invalidation_reason: :historical_refund_changed},
               action: :invalidate_refund_coverage,
               domain: Ingestion
             )

    assert %DateTime{} = invalidated.coverage_invalidated_at

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)
  end

  test "rejects a certificate missing any coverage boundary", %{event: event} do
    for {field, offset} <-
          Enum.with_index([:coverage_start, :sales_covered_through, :refunds_covered_through]) do
      run = certified_run!(event)
      _run = update_run!(run, "#{field} = NULL")

      _run =
        update_run!(run, "coverage_certified_at = $2", [
          DateTime.add(@certified_at, offset, :second)
        ])

      assert {:error, :historical_coverage_not_current} =
               HistoricalCoverageResolver.resolve_current(event.id)
    end
  end

  test "fails closed when coverage_start is after sales_covered_through", %{event: event} do
    run = certified_run!(event)
    _run = update_run!(run, "coverage_start = $2", [~U[2026-08-10 00:00:00.000000Z]])

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)
  end

  test "accepts refunds covered through a time later than sales coverage", %{event: event} do
    _run = certified_run!(event)

    assert {:ok, returned} = HistoricalCoverageResolver.resolve_current(event.id)

    assert DateTime.compare(returned.refunds_covered_through, returned.sales_covered_through) ==
             :gt
  end

  test "returns the newest valid certification", %{event: event} do
    older = certified_run!(event) |> set_certified_at!(@certified_at)
    newer = certified_run!(event) |> set_certified_at!(@newer_certified_at)

    assert {:ok, returned} = HistoricalCoverageResolver.resolve_current(event.id)
    assert returned.id == newer.id
    assert returned.id != older.id
  end

  test "does not fall back to an older valid certificate after a newer one is invalidated", %{
    event: event
  } do
    _older = certified_run!(event) |> set_certified_at!(@certified_at)
    newer = certified_run!(event) |> set_certified_at!(@newer_certified_at)

    assert {:ok, _invalidated} =
             Ash.update(
               newer,
               %{coverage_invalidation_reason: :historical_order_changed},
               action: :invalidate_order_coverage,
               domain: Ingestion
             )

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)
  end

  test "returns a newer valid certificate after an older one is invalidated", %{event: event} do
    older = certified_run!(event) |> set_certified_at!(@certified_at)

    assert {:ok, _invalidated} =
             Ash.update(
               older,
               %{coverage_invalidation_reason: :historical_refund_changed},
               action: :invalidate_refund_coverage,
               domain: Ingestion
             )

    newer = certified_run!(event) |> set_certified_at!(@newer_certified_at)

    assert {:ok, returned} = HistoricalCoverageResolver.resolve_current(event.id)
    assert returned.id == newer.id
  end

  test "ignores a completed non-historical run even with certificate-shaped fields", %{
    source: source,
    event: event
  } do
    run = completed_manual_run!(source, event)

    _run =
      update_run!(
        run,
        "order_coverage_status = 'complete', refund_coverage_status = 'complete', " <>
          "coverage_start = $2, sales_covered_through = $3, refunds_covered_through = $4, " <>
          "coverage_certified_at = $5",
        [@coverage_start, @sales_covered_through, @refunds_covered_through, @certified_at]
      )

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)
  end

  test "never returns a certificate belonging to a different Event", %{
    source: source,
    event: event
  } do
    other_event = SalesHelpers.create_event!(source, %{name: "Other Coverage Event"})
    _run = certified_run!(other_event)

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)
  end

  test "returns a stable invalid-input error for an invalid Event ID" do
    assert {:error, :invalid_event_id} =
             HistoricalCoverageResolver.resolve_current("not-an-event-uuid")
  end

  test "performs no writes while resolving current coverage", %{event: event} do
    run = certified_run!(event)
    before = Ash.get!(SyncRun, run.id, domain: Ingestion)

    assert {:ok, returned} = HistoricalCoverageResolver.resolve_current(event.id)
    assert returned.id == run.id

    after_resolve = Ash.get!(SyncRun, run.id, domain: Ingestion)
    assert after_resolve == before
  end

  defp certified_run!(event) do
    event
    |> historical_run!()
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

  defp completed_historical_run!(event) do
    event
    |> historical_run!()
    |> Ash.update!(%{}, action: :start, domain: Ingestion)
    |> Ash.update!(%{}, action: :complete, domain: Ingestion)
  end

  defp historical_run!(event) do
    SyncRun
    |> Ash.Changeset.for_create(:queue_historical_backfill, %{
      event_id: event.id,
      date_to: @sales_covered_through
    })
    |> Ash.Changeset.force_change_attribute(:source_system_id, event.source_system_id)
    |> Ash.Changeset.force_change_attribute(:date_from, @coverage_start)
    |> Ash.create!(domain: Ingestion)
  end

  defp completed_manual_run!(source, event) do
    SyncRun
    |> Ash.Changeset.for_create(
      :queue_manual_scoped,
      %{
        source_system_id: source.id,
        event_id: event.id,
        date_from: @coverage_start,
        date_to: @sales_covered_through,
        sync_mode: :shallow,
        requested_via: :manual
      },
      context: %{scoped_manual_sync_now: ~U[2026-08-16 12:00:00.000000Z]}
    )
    |> Ash.create!(domain: Ingestion)
    |> Ash.update!(%{}, action: :start, domain: Ingestion)
    |> Ash.update!(%{}, action: :complete, domain: Ingestion)
  end

  defp set_certified_at!(run, certified_at) do
    update_run!(run, "coverage_certified_at = $2", [certified_at])
  end

  defp update_run!(run, assignments, params \\ []) do
    Repo.query!(
      "UPDATE ingestion_sync_runs SET #{assignments} WHERE id = $1",
      [Ecto.UUID.dump!(run.id) | params]
    )

    Ash.get!(SyncRun, run.id, domain: Ingestion)
  end
end
