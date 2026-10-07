defmodule EventSales.Analytics.PeriodCoverageQueryPlanTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.PeriodCoverageCurrencyResolver
  alias EventSales.Analytics.PeriodCoverageEligibleEvents
  alias EventSales.Analytics.PeriodCoverageMaterializer
  alias EventSales.Analytics.PeriodProjectionRefresh
  alias EventSales.Repo
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.PeriodComparisonHelpers
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

  test "eligible analytics-ready paging explain uses selective predicates", %{event: event} do
    _noise = insert_johannesburg_noise_rows!(event, 40)

    sql = PeriodCoverageEligibleEvents.explain_sql()

    assert {:ok, %{rows: [[plan_json]]}} =
             Repo.query("EXPLAIN (FORMAT JSON) #{sql}", [
               ~w(passed mismatched superseded failed cancelled),
               Ecto.UUID.dump!(Ecto.UUID.generate()),
               50
             ])

    plan = normalize_explain_plan(plan_json)
    assert is_map(plan)
    assert Map.has_key?(plan, "Plan")
  end

  test "bounded johannesburg envelope lookup explain is selective", %{event: event} do
    identities = [
      {"ZAR", ~U[2026-05-16 22:00:00.000000Z], ~U[2026-05-17 22:00:00.000000Z]}
    ]

    insert_johannesburg_noise_rows!(event, 60)

    PeriodComparisonHelpers.create_event_bucket!(
      event.id,
      "ZAR",
      %{
        bucket_kind: :johannesburg_day,
        bucket_timezone: "Africa/Johannesburg",
        bucket_start_utc: ~U[2026-05-16 22:00:00.000000Z],
        bucket_end_utc: ~U[2026-05-17 22:00:00.000000Z]
      },
      %{
        projection_state: :current,
        gross_ticket_quantity: 0,
        gross_ticket_value: Decimal.new("0")
      }
    )

    query = PeriodProjectionRefresh.current_johannesburg_envelope_query(event.id, identities)
    {sql, params} = Repo.to_sql(:all, query)

    assert {:ok, %{rows: [[plan_json]]}} = Repo.query("EXPLAIN (FORMAT JSON) #{sql}", params)
    plan = normalize_explain_plan(plan_json)
    assert plan_uses_index?(plan)

    rows =
      PeriodProjectionRefresh.current_johannesburg_envelope_query(event.id, identities)
      |> EventSales.Repo.all()

    assert length(rows) == 1
    assert hd(rows).currency == "ZAR"
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

  defp insert_johannesburg_noise_rows!(event, count) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    noise =
      for i <- 1..count do
        start = DateTime.add(~U[2020-01-01 22:00:00.000000Z], i, :day)
        finish = DateTime.add(start, 1, :day)

        %{
          id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
          event_id: Ecto.UUID.dump!(event.id),
          currency: "NOISE",
          bucket_kind: "johannesburg_day",
          bucket_start_utc: start,
          bucket_end_utc: finish,
          bucket_timezone: "Africa/Johannesburg",
          gross_ticket_quantity: 0,
          gross_ticket_value: Decimal.new("0"),
          refund_ticket_quantity: 0,
          refund_ticket_value: Decimal.new("0"),
          generation_id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
          semantic_version: 1,
          coverage_identity: "m5_04d:event_period_bucket_v1",
          projection_state: "current",
          refreshed_at: now,
          source_watermark_at: nil,
          inserted_at: now,
          updated_at: now
        }
      end

    Repo.insert_all("analytics_event_period_aggregate_snapshots", noise)
  end

  defp normalize_explain_plan(plan_json) when is_binary(plan_json), do: Jason.decode!(plan_json)
  defp normalize_explain_plan([plan | _]) when is_map(plan), do: plan
  defp normalize_explain_plan(plan) when is_map(plan), do: plan

  defp plan_uses_index?(plan) do
    plan
    |> Jason.encode!()
    |> String.contains?("Index")
  end
end
