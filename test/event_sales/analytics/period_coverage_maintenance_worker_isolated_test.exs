defmodule EventSales.Analytics.PeriodCoverageMaintenanceWorkerIsolatedTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Analytics.PeriodCoverageEligibleEvents
  alias EventSales.Analytics.Workers.PeriodCoverageMaintenanceWorker
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.PeriodCoverageHelpers
  alias EventSales.TestSupport.SalesHelpers

  test "full raw candidate page enqueues one continuation at the last raw cursor" do
    source = SalesHelpers.create_source_system!()
    _events = for i <- 1..2, do: ready_event!(source, "Chain #{i}")

    page0 = PeriodCoverageEligibleEvents.page_candidates(nil, limit: 1)

    assert :ok =
             PeriodCoverageMaintenanceWorker.perform_with_opts(
               %Oban.Job{args: %{"batch_size" => 1, "after_event_id" => nil}},
               []
             )

    assert_enqueued(
      worker: PeriodCoverageMaintenanceWorker,
      args: %{
        "batch_size" => 1,
        "after_event_id" => page0.next_after_event_id
      }
    )

    assert :ok =
             PeriodCoverageMaintenanceWorker.perform_with_opts(
               %Oban.Job{
                 args: %{
                   "batch_size" => 1,
                   "after_event_id" => page0.next_after_event_id
                 }
               },
               []
             )

    page1 =
      PeriodCoverageEligibleEvents.page_candidates(page0.next_after_event_id, limit: 1)

    assert page1.candidates_examined == 1
    assert page1.next_after_event_id != page0.next_after_event_id
  end

  test "continuation insert failure returns error for Oban retry" do
    source = SalesHelpers.create_source_system!()
    _event_a = ready_event!(source, "Continuation failure A")
    _event_b = ready_event!(source, "Continuation failure B")

    page = PeriodCoverageEligibleEvents.page_candidates(nil, limit: 1)
    assert page.has_more?

    assert {:error, :injected_continuation_insert_failure} =
             PeriodCoverageMaintenanceWorker.perform_with_opts(
               %Oban.Job{args: %{"batch_size" => 1, "after_event_id" => nil}},
               continuation_inserter: fn _job ->
                 {:error, :injected_continuation_insert_failure}
               end
             )
  end

  defp ready_event!(source, name) do
    event = SalesHelpers.create_event!(source, %{name: name})
    EventDetailCertificationHelpers.certify_analytics_ready!(event)
    PeriodCoverageHelpers.seed_v2_currency!(event, "ZAR")
    event
  end
end
