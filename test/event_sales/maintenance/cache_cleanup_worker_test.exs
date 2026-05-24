defmodule EventSales.Maintenance.CacheCleanupWorkerTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.HotStateAggregator
  alias EventSales.Maintenance.CacheCleanupWorker
  alias EventSales.Telemetry

  test "uses maintenance queue and does not retry" do
    assert CacheCleanupWorker.__opts__() |> Keyword.fetch!(:queue) == :maintenance
    assert CacheCleanupWorker.__opts__() |> Keyword.fetch!(:max_attempts) == 1
  end

  test "does not crash when cache table is absent and emits no-op telemetry" do
    HotStateAggregator.delete_cache_table_for_test!()

    handler_id = "cache-cleanup-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      Telemetry.maintenance_cache_cleanup_stop(),
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok = CacheCleanupWorker.perform(%Oban.Job{args: %{}})

    assert_receive {:telemetry, [:event_sales, :maintenance, :cache_cleanup, :stop],
                    %{count: 0, duration: duration},
                    %{
                      worker: :cache_cleanup_worker,
                      affected_count: 0,
                      reason: :no_owned_cleanup_api
                    }},
                   500

    assert is_integer(duration)
  end
end
