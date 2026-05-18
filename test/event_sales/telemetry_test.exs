defmodule EventSales.TelemetryTest do
  use ExUnit.Case, async: true

  alias EventSales.Telemetry, as: EventSalesTelemetry
  alias Telemetry.Metrics.{Counter, LastValue, Summary}

  test "telemetry supervisor starts under the application supervisor" do
    assert Process.whereis(EventSalesWeb.Telemetry)
  end

  test "custom telemetry event can be emitted and handled" do
    handler_id = "event-sales-telemetry-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler_id,
        EventSalesTelemetry.webhook_accepted(),
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    EventSalesTelemetry.emit(EventSalesTelemetry.webhook_accepted(), %{count: 1}, %{
      topic: "order.created"
    })

    assert_receive {:telemetry_event, [:event_sales, :webhook, :accepted], %{count: 1},
                    %{topic: "order.created"}}
  end

  test "webhook accepted and rejected counters are defined" do
    assert_metric(%Counter{
      name: [:event_sales, :webhook, :accepted, :count],
      event_name: [:event_sales, :webhook, :accepted],
      measurement: :count
    })

    assert_metric(%Counter{
      name: [:event_sales, :webhook, :rejected, :count],
      event_name: [:event_sales, :webhook, :rejected],
      measurement: :count
    })
  end

  test "REST latency and error telemetry metrics are defined" do
    assert_metric(%Summary{
      name: [:event_sales, :rest, :request, :stop, :duration],
      event_name: [:event_sales, :rest, :request, :stop],
      measurement: :duration
    })

    assert_metric(%Counter{
      name: [:event_sales, :rest, :request, :exception, :count],
      event_name: [:event_sales, :rest, :request, :exception],
      measurement: :count
    })
  end

  test "Oban supervisor and job telemetry metrics are defined" do
    assert_metric(%LastValue{
      name: [:oban, :supervisor, :init, :system_time],
      event_name: [:oban, :supervisor, :init],
      measurement: :system_time
    })

    assert_metric(%Counter{
      name: [:oban, :job, :start, :system_time],
      event_name: [:oban, :job, :start],
      measurement: :system_time
    })

    assert_metric(%Summary{
      name: [:oban, :job, :stop, :duration],
      event_name: [:oban, :job, :stop],
      measurement: :duration
    })

    assert_metric(%Counter{
      name: [:oban, :job, :exception, :duration],
      event_name: [:oban, :job, :exception],
      measurement: :duration
    })
  end

  test "HotStateAggregator rebuild placeholder telemetry metrics are defined" do
    assert_metric(%Counter{
      name: [:event_sales, :hot_state, :rebuild, :start, :count],
      event_name: [:event_sales, :hot_state, :rebuild, :start],
      measurement: :count
    })

    assert_metric(%Summary{
      name: [:event_sales, :hot_state, :rebuild, :stop, :duration],
      event_name: [:event_sales, :hot_state, :rebuild, :stop],
      measurement: :duration
    })

    assert_metric(%Counter{
      name: [:event_sales, :hot_state, :rebuild, :exception, :count],
      event_name: [:event_sales, :hot_state, :rebuild, :exception],
      measurement: :count
    })
  end

  test "historical snapshot refresh telemetry metrics are defined" do
    assert_metric(%Counter{
      name: [:event_sales, :snapshots, :refresh, :start, :count],
      event_name: [:event_sales, :snapshots, :refresh, :start],
      measurement: :count
    })

    assert_metric(%Summary{
      name: [:event_sales, :snapshots, :refresh, :stop, :duration],
      event_name: [:event_sales, :snapshots, :refresh, :stop],
      measurement: :duration
    })

    assert_metric(%Counter{
      name: [:event_sales, :snapshots, :refresh, :exception, :count],
      event_name: [:event_sales, :snapshots, :refresh, :exception],
      measurement: :count
    })
  end

  test "reconciliation telemetry metrics are defined" do
    assert_metric(%Counter{
      name: [:event_sales, :reconciliation, :start, :count],
      event_name: [:event_sales, :reconciliation, :start],
      measurement: :count
    })

    assert_metric(%Counter{
      name: [:event_sales, :reconciliation, :stop, :count],
      event_name: [:event_sales, :reconciliation, :stop],
      measurement: :count
    })

    assert_metric(%Counter{
      name: [:event_sales, :reconciliation, :exception, :count],
      event_name: [:event_sales, :reconciliation, :exception],
      measurement: :count
    })

    assert_metric(%Counter{
      name: [:event_sales, :reconciliation, :pause, :count],
      event_name: [:event_sales, :reconciliation, :pause],
      measurement: :count
    })
  end

  test "cache invalidation telemetry metric is defined with low-cardinality tags" do
    assert_metric_with_tags(%Counter{
      name: [:event_sales, :cache, :invalidate, :count],
      event_name: [:event_sales, :cache, :invalidate],
      measurement: :count,
      tags: [:scope, :reason, :source]
    })
  end

  defp assert_metric(expected_metric) do
    assert Enum.any?(EventSalesWeb.Telemetry.metrics(), &metric_matches?(&1, expected_metric))
  end

  defp metric_matches?(metric, expected_metric) do
    metric.__struct__ == expected_metric.__struct__ and
      metric.name == expected_metric.name and
      metric.event_name == expected_metric.event_name and
      measurement_matches?(metric, expected_metric.measurement)
  end

  defp measurement_matches?(%{measurement: measurement, name: name}, expected_measurement)
       when is_function(measurement, 1) do
    List.last(name) == expected_measurement
  end

  defp measurement_matches?(%{measurement: measurement}, expected_measurement) do
    measurement == expected_measurement
  end

  defp assert_metric_with_tags(expected_metric) do
    assert Enum.any?(EventSalesWeb.Telemetry.metrics(), fn metric ->
             metric_matches?(metric, expected_metric) and tags_match?(metric, expected_metric)
           end)
  end

  defp tags_match?(metric, %{tags: expected_tags}) do
    Map.get(metric, :tags) == expected_tags
  end
end
