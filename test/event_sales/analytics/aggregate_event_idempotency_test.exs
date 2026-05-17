defmodule EventSales.Analytics.AggregateEventIdempotencyTest do
  use ExUnit.Case, async: false

  alias EventSales.Analytics.HotStateAggregator
  alias EventSales.TestSupport.Analytics.{MemoryEventAggregator, MemorySnapshotStoreAdapter}

  @event_id "d526dfd5-3e1d-46bc-a886-08a32e189910"
  @source_system_id "929a91d1-cd1c-498d-a45d-93ecc4b70db3"
  @order_id "eba6b213-42fa-4ce4-a451-d3fa2e2c44fb"

  setup do
    HotStateAggregator.reset_for_test!()
    MemoryEventAggregator.reset!()
    MemorySnapshotStoreAdapter.reset!()

    on_exit(fn ->
      HotStateAggregator.reset_for_test!()
      MemoryEventAggregator.reset!()
      MemorySnapshotStoreAdapter.reset!()
    end)

    :ok
  end

  test "duplicate aggregate event recomputes and writes only once" do
    MemoryEventAggregator.put_summary(@event_id, summary(%{total_sold: 2}))

    event = event(%{aggregate_event_id: "agg-duplicate"})

    assert :ok = HotStateAggregator.apply_event(event, event_aggregator: MemoryEventAggregator)
    assert :ok = HotStateAggregator.apply_event(event, event_aggregator: MemoryEventAggregator)

    assert MemoryEventAggregator.call_count(@event_id) == 1
    assert {:ok, %{total_sold: 2}} = HotStateAggregator.summary_for_event(@event_id)
    assert [%{summary: %{total_sold: 2}}] = MemorySnapshotStoreAdapter.writes()
  end

  test "failed recompute does not mark event applied and can be retried" do
    MemoryEventAggregator.put_error(@event_id, :db_unavailable)

    event = event(%{aggregate_event_id: "agg-retry"})

    assert {:error, :db_unavailable} =
             HotStateAggregator.apply_event(event, event_aggregator: MemoryEventAggregator)

    MemoryEventAggregator.put_summary(@event_id, summary(%{total_sold: 4}))

    assert :ok = HotStateAggregator.apply_event(event, event_aggregator: MemoryEventAggregator)

    assert MemoryEventAggregator.call_count(@event_id) == 2
    assert {:ok, %{total_sold: 4}} = HotStateAggregator.summary_for_event(@event_id)
  end

  test "stale source update is ignored" do
    MemoryEventAggregator.put_summary(@event_id, summary(%{total_sold: 5}))

    newer =
      event(%{
        aggregate_event_id: "agg-newer",
        source_updated_at: ~U[2026-05-17 10:00:00Z]
      })

    stale =
      event(%{
        aggregate_event_id: "agg-stale",
        source_updated_at: ~U[2026-05-17 09:59:59Z]
      })

    assert :ok = HotStateAggregator.apply_event(newer, event_aggregator: MemoryEventAggregator)
    assert :ok = HotStateAggregator.apply_event(stale, event_aggregator: MemoryEventAggregator)

    assert MemoryEventAggregator.call_count(@event_id) == 1
    assert {:ok, %{total_sold: 5}} = HotStateAggregator.summary_for_event(@event_id)
  end

  test "manual refresh bypasses stale source checks" do
    MemoryEventAggregator.put_summary(@event_id, summary(%{total_sold: 5}))

    newer =
      event(%{
        aggregate_event_id: "agg-source",
        source_updated_at: ~U[2026-05-17 10:00:00Z]
      })

    manual_refresh =
      event(%{
        aggregate_event_id: "agg-manual",
        reason: :manual_refresh,
        source_updated_at: ~U[2026-05-17 09:00:00Z]
      })

    assert :ok = HotStateAggregator.apply_event(newer, event_aggregator: MemoryEventAggregator)

    MemoryEventAggregator.put_summary(@event_id, summary(%{total_sold: 8}))

    assert :ok =
             HotStateAggregator.apply_event(manual_refresh,
               event_aggregator: MemoryEventAggregator
             )

    assert MemoryEventAggregator.call_count(@event_id) == 2
    assert {:ok, %{total_sold: 8}} = HotStateAggregator.summary_for_event(@event_id)
  end

  test "newer signal recomputes and replaces summary" do
    MemoryEventAggregator.put_summary(@event_id, summary(%{total_sold: 1}))

    first =
      event(%{
        aggregate_event_id: "agg-first",
        source_updated_at: ~U[2026-05-17 10:00:00Z]
      })

    assert :ok = HotStateAggregator.apply_event(first, event_aggregator: MemoryEventAggregator)

    MemoryEventAggregator.put_summary(@event_id, summary(%{total_sold: 7}))

    newer =
      event(%{
        aggregate_event_id: "agg-second",
        source_updated_at: ~U[2026-05-17 10:01:00Z]
      })

    assert :ok = HotStateAggregator.apply_event(newer, event_aggregator: MemoryEventAggregator)

    assert MemoryEventAggregator.call_count(@event_id) == 2
    assert {:ok, %{total_sold: 7}} = HotStateAggregator.summary_for_event(@event_id)
  end

  defp event(overrides) do
    %{
      aggregate_event_id: "agg-1",
      event_id: @event_id,
      reason: :order_processed,
      occurred_at: ~U[2026-05-17 10:00:00Z],
      source_system_id: @source_system_id,
      order_id: @order_id,
      source_updated_at: ~U[2026-05-17 10:00:00Z],
      payload_hash: "payload-hash"
    }
    |> Map.merge(overrides)
  end

  defp summary(overrides) do
    %{
      total_sold: 0,
      total_revenue: Decimal.new("0"),
      today_sold: 0,
      today_revenue: Decimal.new("0"),
      status_breakdown: %{}
    }
    |> Map.merge(overrides)
  end
end
