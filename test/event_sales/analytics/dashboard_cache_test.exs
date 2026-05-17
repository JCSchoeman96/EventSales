defmodule EventSales.Analytics.DashboardCacheTest do
  use ExUnit.Case, async: false

  alias EventSales.Analytics.{CacheKeys, DashboardCache, HotStateAggregator}

  @event_id "0a701836-b78d-4fe4-9b30-3f2618093e20"
  @other_event_id "261f2e93-49ba-48af-b8b0-8dc91a65f71a"

  setup do
    HotStateAggregator.reset_for_test!()
    on_exit(fn -> HotStateAggregator.reset_for_test!() end)
    :ok
  end

  test "returns miss before ETS owner creates the table" do
    HotStateAggregator.delete_cache_table_for_test!()

    assert :miss = DashboardCache.get_event_summary(@event_id)
  end

  test "writes and reads event summaries through the named ETS table" do
    summary = summary(%{total_sold: 3})

    assert :ok = DashboardCache.put_event_summary(@event_id, summary)
    assert {:ok, ^summary} = DashboardCache.get_event_summary(@event_id)
  end

  test "invalidates only the scoped event summary" do
    assert :ok = DashboardCache.put_event_summary(@event_id, summary(%{total_sold: 1}))
    assert :ok = DashboardCache.put_event_summary(@other_event_id, summary(%{total_sold: 2}))

    assert :ok = DashboardCache.invalidate_event(@event_id, :mapping_changed)

    assert :miss = DashboardCache.get_event_summary(@event_id)
    assert {:ok, %{total_sold: 2}} = DashboardCache.get_event_summary(@other_event_id)
  end

  test "does not create duplicate ETS tables from cache reads or writes" do
    table = DashboardCache.table_name()

    assert :ets.whereis(table) != :undefined
    assert :miss = DashboardCache.get_event_summary(@event_id)
    assert :ok = DashboardCache.put_event_summary(@event_id, summary(%{}))
    assert :ets.whereis(table) != :undefined
  end

  test "cache keys include namespace, version, and event scope" do
    assert CacheKeys.event_summary(@event_id) ==
             {:eventsales, :analytics, :hot_state, :v1, :event_summary, @event_id}

    assert CacheKeys.redis_event_snapshot(@event_id) ==
             "eventsales:analytics:hot_state:v1:event:#{@event_id}:summary"
  end

  defp summary(overrides) do
    %{
      total_sold: 0,
      total_revenue: Decimal.new("0"),
      today_sold: 0,
      today_revenue: Decimal.new("0"),
      status_breakdown: %{},
      updated_at: ~U[2026-05-17 10:00:00Z]
    }
    |> Map.merge(overrides)
  end
end
