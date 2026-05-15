defmodule EventSales.TestSupport.Ingestion.MemoryWebhookBufferAdapter do
  @moduledoc """
  In-memory pending/processing buffer for tests (mirrors Redis adapter semantics).
  """

  @behaviour EventSales.Ingestion.RedisWebhookBuffer.Adapter

  @table __MODULE__

  @impl true
  def push(entry) when is_binary(entry) do
    table = ensure_table!()
    state = get_state(table)

    if length(state.pending) >= max_entries() do
      {:error, :full}
    else
      :ets.insert(table, {:state, %{state | pending: state.pending ++ [entry]}})
      :ok
    end
  end

  @impl true
  def claim do
    table = ensure_table!()
    state = get_state(table)

    case state.pending do
      [] ->
        :empty

      [entry | rest] ->
        :ets.insert(
          table,
          {:state, %{state | pending: rest, processing: state.processing ++ [entry]}}
        )

        {:ok, entry}
    end
  end

  @impl true
  def ack(entry) when is_binary(entry) do
    table = ensure_table!()
    state = get_state(table)
    :ets.insert(table, {:state, %{state | processing: List.delete(state.processing, entry)}})
    :ok
  end

  @impl true
  def requeue(entry) when is_binary(entry) do
    table = ensure_table!()
    state = get_state(table)
    state = %{state | processing: List.delete(state.processing, entry)}

    if length(state.pending) >= max_entries() do
      {:error, :full}
    else
      :ets.insert(table, {:state, %{state | pending: state.pending ++ [entry]}})
      :ok
    end
  end

  @impl true
  def depth do
    table = ensure_table!()
    length(get_state(table).pending)
  end

  @impl true
  def processing_depth do
    table = ensure_table!()
    length(get_state(table).processing)
  end

  @doc false
  def reset! do
    table = ensure_table!()
    :ets.insert(table, {:state, %{pending: [], processing: []}})
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

  defp get_state(table) do
    case :ets.lookup(table, :state) do
      [{:state, state}] -> state
      [] -> %{pending: [], processing: []}
    end
  end

  defp max_entries do
    EventSales.Ingestion.RedisWebhookBuffer.max_entries()
  end
end
