defmodule EventSales.Analytics.PeriodCoverageQueryPlanTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.PeriodCoverageCurrencyResolver
  alias EventSales.Analytics.PeriodCoverageMaterializer
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.PeriodCoverageHelpers
  alias EventSales.TestSupport.SalesHelpers
  alias EventSales.TestSupport.StubRefreshSnapshotWorker

  @now ~U[2026-05-17 10:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Coverage query plan"})
    EventDetailCertificationHelpers.certify_analytics_ready!(event)
    PeriodCoverageHelpers.seed_v2_currency!(event, "ZAR")
    %{event: event}
  end

  test "materialize uses fixed insert count independent of bucket cardinality", %{event: event} do
    {result, queries} =
      capture_select_queries(fn ->
        PeriodCoverageMaterializer.materialize(event.id, @now,
          refresh_snapshot_worker: StubRefreshSnapshotWorker
        )
      end)

    assert match?({:ok, %{bucket_intents_created: created}} when created > 0, result)

    insert_queries = Enum.filter(queries, &String.contains?(&1, "INSERT INTO"))
    assert length(insert_queries) == 1
  end

  test "currency discovery for event uses one query", %{event: event} do
    {result, queries} =
      capture_select_queries(fn ->
        PeriodCoverageCurrencyResolver.currencies_for_event(event.id)
      end)

    assert result == {:ok, ["ZAR"]}
    assert length(queries) == 1
  end

  defp capture_select_queries(fun) do
    handler_id = {__MODULE__, self(), make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        EventSales.Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measurements, metadata, {test_pid, id} ->
          send(test_pid, {id, metadata.query})
        end,
        {parent, handler_id}
      )

    try do
      result = fun.()
      {result, collect_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_queries(handler_id, acc) do
    receive do
      {^handler_id, sql} -> collect_queries(handler_id, [sql | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
