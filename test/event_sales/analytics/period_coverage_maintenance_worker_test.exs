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
    _event = ready_event!(source, "Paging #{System.unique_integer([:positive])}")

    page1 = PeriodCoverageEligibleEvents.page_event_ids(nil, limit: 2)
    assert length(page1) == 2
    assert page1 == Enum.sort(page1)

    page2 = PeriodCoverageEligibleEvents.page_event_ids(List.last(page1), limit: 2)
    assert page2 != []
    refute Enum.any?(page2, &(&1 in page1))
  end

  test "short tail page does not enqueue another batch" do
    tail =
      PeriodCoverageEligibleEvents.page_event_ids(nil, limit: 10_000)
      |> List.last()

    assert :ok =
             perform_job(PeriodCoverageMaintenanceWorker, %{
               "batch_size" => 50,
               "after_event_id" => tail
             })

    refute_enqueued(worker: PeriodCoverageMaintenanceWorker)
  end

  test "full page schedules exactly one follow-up batch" do
    page = PeriodCoverageEligibleEvents.page_event_ids(nil, limit: 2)
    assert length(page) == 2

    after_id =
      PeriodCoverageEligibleEvents.page_event_ids(nil, limit: 10_000)
      |> Enum.take(length(page) - 2)
      |> List.last()
      |> case do
        nil -> "00000000-0000-0000-0000-000000000000"
        id -> id
      end

    assert :ok =
             perform_job(PeriodCoverageMaintenanceWorker, %{
               "batch_size" => 2,
               "after_event_id" => after_id
             })

    assert_enqueued(
      worker: PeriodCoverageMaintenanceWorker,
      args: %{"batch_size" => 2, "after_event_id" => List.last(page)}
    )
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
    tail =
      PeriodCoverageEligibleEvents.page_event_ids(nil, limit: 10_000)
      |> List.last()

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
                 "after_event_id" => tail
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

  test "eligible event failure increments failures without aborting the worker batch" do
    page = PeriodCoverageEligibleEvents.page_event_ids(nil, limit: 1)
    assert page != []

    handler_id = {__MODULE__, :failures, make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        [:event_sales, :analytics, :period_coverage, :maintenance],
        fn _event, measurements, _metadata, _ ->
          send(parent, {:maintenance_measurements, measurements})
        end,
        nil
      )

    try do
      assert :ok =
               PeriodCoverageMaintenanceWorker.perform(%Oban.Job{
                 args: %{
                   "batch_size" => 1,
                   "after_event_id" =>
                     cursor_before_id(hd(page)),
                   "period_coverage_opts" => [
                     refresh_snapshot_worker:
                       EventSales.Analytics.PeriodCoverageMaintenanceWorkerTest.StubFailingRefreshWorker
                   ]
                 }
               })

      assert_receive {:maintenance_measurements, measurements}
      assert measurements.failures >= 1
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

  defp cursor_before_id(event_id) do
    PeriodCoverageEligibleEvents.page_event_ids(nil, limit: 10_000)
    |> Enum.take_while(&(&1 < event_id))
    |> List.last()
    |> case do
      nil -> "00000000-0000-0000-0000-000000000000"
      id -> id
    end
  end

  defmodule StubFailingRefreshWorker do
    def enqueue_event(_event_id, _opts \\ []), do: {:error, :stub_enqueue_failed}
  end
end
