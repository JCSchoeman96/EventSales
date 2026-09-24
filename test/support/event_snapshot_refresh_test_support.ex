defmodule EventSales.TestSupport.EventSnapshotRefreshTestSupport do
  @moduledoc false

  alias EventSales.Repo
  alias EventSales.TestSupport.UnboxedPostgres

  @doc false
  def wait_for_advisory_lock_wait!(backend_pid, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    wait =
      Stream.repeatedly(fn ->
        Process.sleep(15)
        advisory_lock_wait?(backend_pid)
      end)
      |> Enum.reduce_while(false, fn waiting?, _ ->
        cond do
          waiting? -> {:halt, true}
          System.monotonic_time(:millisecond) > deadline -> {:halt, false}
          true -> {:cont, false}
        end
      end)

    unless wait,
      do: raise("expected backend #{backend_pid} to block on PostgreSQL advisory lock")

    :ok
  end

  @doc false
  def advisory_lock_wait?(backend_pid) do
    UnboxedPostgres.with_connection(fn ->
      %Postgrex.Result{rows: rows} =
        Repo.query!(
          "SELECT wait_event_type, wait_event FROM pg_stat_activity WHERE pid = $1",
          [backend_pid]
        )

      case rows do
        [["Lock", wait_event]] when is_binary(wait_event) ->
          String.contains?(wait_event, "advisory")

        _ ->
          false
      end
    end)
  end

  @doc false
  def transaction_isolation_level do
    %Postgrex.Result{rows: [[level]]} = Repo.query!("SHOW transaction_isolation")
    level
  end
end
