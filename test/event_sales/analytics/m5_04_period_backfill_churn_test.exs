# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule EventSales.Analytics.M5_04PeriodBackfillChurnTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  import Ecto.Query

  alias EventSales.Analytics.PeriodComparisonReader
  alias EventSales.Analytics.PeriodCoverage
  alias EventSales.Analytics.Resources.EventPeriodAggregateSnapshot
  alias EventSales.Analytics.SnapshotRefresh
  alias EventSales.Analytics.Workers.RefreshSnapshotWorker
  alias EventSales.Repo
  alias EventSales.TestSupport.M5_04PeriodCertificationHelpers, as: Cert
  alias EventSales.TestSupport.SalesHelpers

  @now ~U[2026-05-17 10:17:33.000000Z]

  test "G2 live catch-up batches enqueue and execute refresh workers without pathological churn" do
    source = SalesHelpers.create_source_system!()
    event = Cert.prepare_analytics_ready_event!(source)
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Backfill"})
    admin = Cert.certification_admin!()
    page_count = 4
    mutations_per_page = 5

    assert {:ok, _} = PeriodCoverage.ensure_event_buckets(event.id, @now, enqueue_refresh?: false)

    {snap, enqueue_attempts, order_count} =
      Enum.reduce(1..page_count, {nil, 0, 0}, fn page, {snap_acc, enq, orders} ->
        {snap_after_page, orders_after_page} =
          Enum.reduce(1..mutations_per_page, {snap_acc, orders}, fn idx, {s, o} ->
            paid_at = DateTime.add(@now, -(page * 10 + idx) * 3600, :second)

            {_order, _item, after_snap} =
              Cert.ingest_sale_invalidate_only!(event, s, source, ticket, paid_at)

            {after_snap, o + 1}
          end)

        assert :ok = RefreshSnapshotWorker.enqueue_event(event.id)

        assert %{success: success, failure: failure} =
                 Oban.drain_queue(
                   queue: :analytics_rebuilds,
                   with_scheduled: true,
                   with_safety: false
                 )

        assert success >= 1
        assert failure == 0

        {snap_after_page, enq + 1, orders_after_page}
      end)

    assert order_count == page_count * mutations_per_page

    jobs_created = refresh_job_count(event.id)
    executions = completed_refresh_jobs(event.id)

    assert {:ok, _} = PeriodCoverage.ensure_event_buckets(event.id, @now, enqueue_refresh?: false)

    assert %{success: _terminal_success, failure: 0} =
             Oban.drain_queue(
               queue: :analytics_rebuilds,
               with_scheduled: true,
               with_safety: false
             )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id, now: @now, refreshed_at: @now)

    assert {:ok, result} =
             PeriodComparisonReader.compare_event(event.id, "ZAR", {:rolling_days, 7},
               actor: admin,
               now: @now
             )

    assert result.current.readiness == :ready

    pending =
      EventPeriodAggregateSnapshot
      |> where([s], s.event_id == ^event.id and s.projection_state == :refresh_pending)
      |> Repo.aggregate(:count)

    stale =
      EventPeriodAggregateSnapshot
      |> where([s], s.event_id == ^event.id and s.projection_state == :stale)
      |> Repo.aggregate(:count)

    assert pending == 0
    assert stale == 0
    assert executions >= page_count
    assert jobs_created >= page_count
    assert enqueue_attempts == page_count
    assert snap != nil
  end

  defp refresh_job_count(event_id) do
    from(j in "oban_jobs",
      where: j.worker == ^"EventSales.Analytics.Workers.RefreshSnapshotWorker",
      where: fragment("?->>'event_id' = ?", j.args, ^event_id),
      select: count(j.id)
    )
    |> Repo.one!()
  end

  defp completed_refresh_jobs(event_id) do
    from(j in "oban_jobs",
      where: j.worker == ^"EventSales.Analytics.Workers.RefreshSnapshotWorker",
      where: fragment("?->>'event_id' = ?", j.args, ^event_id),
      where: j.state == "completed",
      select: count(j.id)
    )
    |> Repo.one!()
  end
end
