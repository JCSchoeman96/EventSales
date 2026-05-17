defmodule EventSales.TestSupport.Analytics.MemoryEventAggregator do
  @moduledoc false

  @table __MODULE__

  def put_summary(event_id, summary) do
    table = ensure_table!()
    state = state(table)
    :ets.insert(table, {:state, put_in(state, [:summaries, event_id], {:ok, summary})})
    :ok
  end

  def put_error(event_id, reason) do
    table = ensure_table!()
    state = state(table)
    :ets.insert(table, {:state, put_in(state, [:summaries, event_id], {:error, reason})})
    :ok
  end

  def summary_for_event(event_id, _opts \\ []) do
    table = ensure_table!()
    state = state(table)
    calls = Map.update(state.calls, event_id, 1, &(&1 + 1))
    :ets.insert(table, {:state, %{state | calls: calls}})

    Map.get(state.summaries, event_id, {:error, :missing_summary})
  end

  def call_count(event_id) do
    ensure_table!() |> state() |> Map.get(:calls) |> Map.get(event_id, 0)
  end

  def reset! do
    table = ensure_table!()
    :ets.insert(table, {:state, %{summaries: %{}, calls: %{}}})
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
      [] -> %{summaries: %{}, calls: %{}}
    end
  end
end
