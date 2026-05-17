defmodule EventSales.TestSupport.Analytics.MemorySnapshotStoreAdapter do
  @moduledoc false

  @behaviour EventSales.Analytics.SnapshotStore.Adapter

  @table __MODULE__

  @impl true
  def put(key, summary, _opts \\ []) do
    table = ensure_table!()
    state = state(table)

    case state.fail_reason do
      nil ->
        write = %{key: key, summary: summary}
        :ets.insert(table, {:state, %{state | writes: state.writes ++ [write]}})
        :ok

      reason ->
        {:error, reason}
    end
  end

  def writes do
    ensure_table!() |> state() |> Map.get(:writes)
  end

  def fail_writes!(reason) do
    table = ensure_table!()
    state = state(table)
    :ets.insert(table, {:state, %{state | fail_reason: reason}})
    :ok
  end

  def reset! do
    table = ensure_table!()
    :ets.insert(table, {:state, %{writes: [], fail_reason: nil}})
    :ok
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
        reset!()
        @table

      table ->
        table
    end
  end

  defp state(table) do
    case :ets.lookup(table, :state) do
      [{:state, state}] -> state
      [] -> %{writes: [], fail_reason: nil}
    end
  end
end
