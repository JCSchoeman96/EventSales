defmodule EventSales.Health.DatabaseReadinessTest do
  use ExUnit.Case, async: true

  alias EventSales.Health.DatabaseReadiness

  test "initial state fails closed until the immediate probe completes" do
    test_pid = self()

    probe = fn ->
      send(test_pid, :probe_started)

      receive do
        :finish_probe -> :ok
      end
    end

    {server, table} = unique_names()
    start_supervised!({DatabaseReadiness, name: server, table: table, probe: probe})

    assert_receive :probe_started
    assert DatabaseReadiness.status(table) == :not_ready

    send(Process.whereis(server), :finish_probe)
    assert_eventually(fn -> DatabaseReadiness.status(table) == :ready end)
  end

  test "successful and failed probes publish readiness and recover" do
    test_pid = self()

    probe = fn ->
      receive do
        {:probe_result, result} -> result
      after
        0 ->
          send(test_pid, :probe_waiting)

          receive do
            {:probe_result, result} -> result
          end
      end
    end

    {server, table} = unique_names()
    pid = start_supervised!({DatabaseReadiness, name: server, table: table, probe: probe})

    assert_receive :probe_waiting
    send(pid, {:probe_result, {:error, :database_unavailable}})
    assert_eventually(fn -> DatabaseReadiness.status(table) == :not_ready end)

    DatabaseReadiness.probe_now(server)
    assert_receive :probe_waiting
    send(pid, {:probe_result, :ok})
    assert_eventually(fn -> DatabaseReadiness.status(table) == :ready end)
  end

  test "a successful snapshot fails closed after it becomes stale" do
    clock = :atomics.new(1, [])
    :atomics.put(clock, 1, 1_000)
    now = fn -> :atomics.get(clock, 1) end
    {server, table} = unique_names()

    start_supervised!(
      {DatabaseReadiness,
       name: server, table: table, probe: fn -> :ok end, now: now, stale_after_ms: 15_000}
    )

    assert_eventually(fn ->
      DatabaseReadiness.status(table, now: now, stale_after_ms: 15_000) == :ready
    end)

    :atomics.put(clock, 1, 16_001)

    assert DatabaseReadiness.status(table, now: now, stale_after_ms: 15_000) == :not_ready
  end

  test "periodic polling schedules one probe per interval" do
    test_pid = self()

    probe = fn ->
      send(test_pid, :probed)
      :ok
    end

    schedule = fn pid, interval_ms ->
      send(test_pid, {:scheduled, pid, interval_ms})
      make_ref()
    end

    {server, table} = unique_names()

    start_supervised!(
      {DatabaseReadiness,
       name: server, table: table, probe: probe, schedule: schedule, interval_ms: 5_000}
    )

    assert_receive {:scheduled, pid, 5_000}
    assert_receive :probed
    send(pid, :probe)
    assert_receive {:scheduled, ^pid, 5_000}
    assert_receive :probed
    assert DatabaseReadiness.status(table) == :ready
  end

  defp unique_names do
    suffix = System.unique_integer([:positive])

    {String.to_atom("database_readiness_server_#{suffix}"),
     String.to_atom("database_readiness_table_#{suffix}")}
  end

  defp assert_eventually(fun, attempts \\ 50)
  defp assert_eventually(fun, 0), do: assert(fun.())

  defp assert_eventually(fun, attempts) do
    if fun.() do
      assert true
    else
      Process.sleep(1)
      assert_eventually(fun, attempts - 1)
    end
  end
end
