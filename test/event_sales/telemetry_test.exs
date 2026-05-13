defmodule EventSales.TelemetryTest do
  use ExUnit.Case, async: true

  alias EventSales.Telemetry
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
        Telemetry.webhook_accepted(),
        fn event_name, measurements, metadata, _config ->
          send(test_pid, {:telemetry_event, event_name, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    Telemetry.emit(Telemetry.webhook_accepted(), %{count: 1}, %{topic: "order.created"})

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

  defp assert_metric(expected_metric) do
    assert Enum.any?(EventSalesWeb.Telemetry.metrics(), &metric_matches?(&1, expected_metric))
  end

  defp metric_matches?(metric, expected_metric) do
    metric.__struct__ == expected_metric.__struct__ and
      metric.name == expected_metric.name and
      metric.event_name == expected_metric.event_name and
      metric.measurement == expected_metric.measurement
  end
end
