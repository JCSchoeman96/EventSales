defmodule EventSales.Analytics.PeriodCoverageMaterializerTest do
  use EventSales.DataCase, async: false

  import Ecto.Query

  require Ash.Query

  alias EventSales.Analytics
  alias EventSales.Analytics.Resources.EventPeriodAggregateSnapshot
  alias EventSales.Analytics.PeriodCoverage
  alias EventSales.Analytics.PeriodCoverageMaterializer
  alias EventSales.Analytics.SnapshotRefresh
  alias EventSales.Analytics.Resources.EventPeriodAggregateSnapshot
  alias EventSales.Repo
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.PeriodComparisonHelpers
  alias EventSales.TestSupport.PeriodCoverageHelpers
  alias EventSales.TestSupport.SalesHelpers
  alias EventSales.TestSupport.StubRefreshSnapshotWorker

  @now ~U[2026-05-17 10:00:00.000000Z]
  @later ~U[2026-05-17 11:30:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Coverage materializer"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    EventDetailCertificationHelpers.certify_analytics_ready!(event)
    PeriodCoverageHelpers.seed_v2_currency!(event, "ZAR")

    %{source: source, event: event, ticket: ticket}
  end

  test "materialize inserts refresh_pending rows only for absent identities", %{event: event} do
    assert {:ok, %{bucket_intents_created: created, refresh_enqueued?: true}} =
             PeriodCoverageMaterializer.materialize(event.id, @now,
               refresh_snapshot_worker: StubRefreshSnapshotWorker
             )

    assert created > 0

    assert Enum.all?(
             Repo.all(from(r in EventPeriodAggregateSnapshot, where: r.event_id == ^event.id)),
             &(&1.projection_state == :refresh_pending)
           )
  end

  test "idempotent materialize creates zero rows and does not enqueue refresh", %{event: event} do
    worker = StubRefreshSnapshotWorker

    assert {:ok, %{bucket_intents_created: _}} =
             PeriodCoverageMaterializer.materialize(event.id, @now,
               refresh_snapshot_worker: worker
             )

    assert {:ok, %{bucket_intents_created: 0, refresh_enqueued?: false}} =
             PeriodCoverageMaterializer.materialize(event.id, @now,
               refresh_snapshot_worker: worker
             )
  end

  test "does not churn CURRENT rows", %{event: event, source: source, ticket: ticket} do
    PeriodComparisonHelpers.seed_comparison_projection!(
      event,
      source,
      ticket,
      "ZAR",
      :yesterday,
      @now,
      %{
        current: %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")},
        previous: %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")}
      }
    )

    before =
      EventPeriodAggregateSnapshot
      |> Ash.Query.filter(event_id == ^event.id and projection_state == :current)
      |> Ash.read!(domain: Analytics)
      |> Enum.map(&snapshot_fingerprint/1)
      |> Enum.sort()

    assert {:ok, %{bucket_intents_created: created}} =
             PeriodCoverageMaterializer.materialize(event.id, @now, enqueue_refresh?: false)

    assert created > 0

    after_rows =
      EventPeriodAggregateSnapshot
      |> Ash.Query.filter(event_id == ^event.id and projection_state == :current)
      |> Ash.read!(domain: Analytics)
      |> Enum.map(&snapshot_fingerprint/1)
      |> Enum.sort()

    assert before == after_rows
  end

  test "does not overwrite non-CURRENT rows", %{event: event, source: source, ticket: ticket} do
    PeriodComparisonHelpers.seed_comparison_projection!(
      event,
      source,
      ticket,
      "ZAR",
      :yesterday,
      @now,
      %{
        current: %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")},
        previous: %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")}
      }
    )

    stale =
      EventPeriodAggregateSnapshot
      |> Ash.Query.filter(event_id == ^event.id)
      |> Ash.Query.limit(1)
      |> Ash.read_one!(domain: Analytics)

    Ash.update!(stale, %{projection_state: :stale}, action: :update_snapshot, domain: Analytics)
    stale_id = stale.id

    assert {:ok, _} =
             PeriodCoverageMaterializer.materialize(event.id, @now, enqueue_refresh?: false)

    reloaded = Ash.get!(EventPeriodAggregateSnapshot, stale_id, domain: Analytics)
    assert reloaded.projection_state == :stale
  end

  test "full planner materialize then snapshot refresh publishes CURRENT zeros", %{event: event} do
    assert {:ok, %{bucket_intents_created: created}} =
             PeriodCoverageMaterializer.materialize(event.id, @later, enqueue_refresh?: false)

    assert created > 0
    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id, now: @later)
  end

  test "moving horizon: materialize + refresh yields ready today read", %{
    event: event,
    source: source,
    ticket: ticket
  } do
    PeriodComparisonHelpers.seed_comparison_projection!(
      event,
      source,
      ticket,
      "ZAR",
      :today,
      @now,
      %{
        current: %{gross_ticket_quantity: 2, gross_ticket_value: Decimal.new("20.00")},
        previous: %{gross_ticket_quantity: 1, gross_ticket_value: Decimal.new("10.00")}
      }
    )

    assert {:ok, %{bucket_intents_created: created}} =
             PeriodCoverage.ensure_event_buckets(event.id, @later, enqueue_refresh?: false)

    assert created > 0

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id, now: @later)

    {:ok, _windows, plan} = PeriodComparisonHelpers.plan_for(:today, @later)
    current_plan = Enum.find(plan.operands, &(&1.operand == :current))

    assert Enum.all?(buckets_for_operand(current_plan), fn spec ->
             row =
               EventPeriodAggregateSnapshot
               |> Ash.Query.filter(
                 event_id == ^event.id and currency == ^"ZAR" and
                   bucket_kind == ^spec.bucket_kind and
                   bucket_start_utc == ^spec.bucket_start_utc and
                   bucket_end_utc == ^spec.bucket_end_utc
               )
               |> Ash.read_one!(domain: Analytics)

             row.projection_state == :current
           end)
  end

  defp buckets_for_operand(operand_plan) do
    envelopes =
      Enum.map(operand_plan.edge_fragments, fn fragment ->
        hour_start = fragment.envelope_hour_start_utc

        %{
          bucket_kind: :utc_hour,
          bucket_start_utc: hour_start,
          bucket_end_utc: DateTime.add(hour_start, 1, :hour)
        }
      end)

    operand_plan.fixed_buckets ++ envelopes
  end

  defp snapshot_fingerprint(row) do
    {row.id, row.generation_id, row.refreshed_at, row.updated_at, row.projection_state}
  end
end
