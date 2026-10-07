defmodule EventSales.Analytics.PeriodCoverageMaintenanceWorkerTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Analytics.PeriodCoverage
  alias EventSales.Analytics.PeriodCoverageEligibleEvents
  alias EventSales.Analytics.Workers.PeriodCoverageMaintenanceWorker
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.PeriodCoverageHelpers
  alias EventSales.TestSupport.{SalesHelpers, StubRefreshSnapshotWorker}

  test "eligible page query returns stable ascending ids" do
    source = SalesHelpers.create_source_system!()

    events =
      for _ <- 1..3, do: ready_event!(source, "Paging #{System.unique_integer([:positive])}")

    page1 = PeriodCoverageEligibleEvents.page_candidates(nil, limit: 2)
    assert length(page1.event_ids) == 2
    assert page1.event_ids == Enum.sort(page1.event_ids)

    page2 =
      PeriodCoverageEligibleEvents.page_candidates(page1.next_after_event_id, limit: 2)

    assert page2.event_ids != []
    refute Enum.any?(page2.event_ids, &(&1 in page1.event_ids))

    collected = PeriodCoverageEligibleEvents.collect_event_ids(limit: 100)

    assert Enum.all?(events, &(&1.id in collected))
  end

  test "short tail page does not enqueue another batch" do
    {last_raw_cursor, _} = last_raw_candidate_page()

    assert :ok =
             perform_job(PeriodCoverageMaintenanceWorker, %{
               "batch_size" => 50,
               "after_event_id" => last_raw_cursor
             })

    refute_enqueued(worker: PeriodCoverageMaintenanceWorker)
  end

  test "refresh enqueue only follows newly created intents" do
    source = SalesHelpers.create_source_system!()
    event = ready_event!(source, "Refresh gate #{System.unique_integer([:positive])}")
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    assert {:ok, %{bucket_intents_created: created, refresh_enqueued?: true}} =
             PeriodCoverage.ensure_event_buckets(event.id, now,
               refresh_snapshot_worker: StubRefreshSnapshotWorker
             )

    assert created > 0

    assert {:ok, %{bucket_intents_created: 0, refresh_enqueued?: false}} =
             PeriodCoverage.ensure_event_buckets(event.id, now,
               refresh_snapshot_worker: StubRefreshSnapshotWorker
             )
  end

  test "emits batch duration telemetry without high-cardinality labels" do
    {last_raw_cursor, _} = last_raw_candidate_page()

    handler_id = {__MODULE__, :maintenance_duration, make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:event_sales, :analytics, :period_coverage, :maintenance],
        fn _event, measurements, metadata, _ ->
          send(parent, {:maintenance_telemetry, measurements, metadata})
        end,
        nil
      )

    try do
      assert :ok =
               perform_job(PeriodCoverageMaintenanceWorker, %{
                 "batch_size" => 1,
                 "after_event_id" => last_raw_cursor
               })

      assert_receive {:maintenance_telemetry, measurements, metadata}

      assert is_integer(measurements.duration)
      assert measurements.duration >= 0
      assert metadata == %{component: :period_coverage}
      refute Map.has_key?(metadata, :event_id)
    after
      :telemetry.detach(handler_id)
    end
  end

  defp ready_event!(source, name) do
    event = SalesHelpers.create_event!(source, %{name: name})
    EventDetailCertificationHelpers.certify_analytics_ready!(event)
    PeriodCoverageHelpers.seed_v2_currency!(event, "ZAR")
    event
  end

  defp last_raw_candidate_page(after_id \\ nil, limit \\ 50) do
    page = PeriodCoverageEligibleEvents.page_candidates(after_id, limit: limit)

    if page.has_more? and page.next_after_event_id do
      last_raw_candidate_page(page.next_after_event_id, limit)
    else
      {page.next_after_event_id, page}
    end
  end
end
