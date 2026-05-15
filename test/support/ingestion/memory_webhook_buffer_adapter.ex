defmodule EventSales.TestSupport.Ingestion.MemoryWebhookBufferAdapter do
  @moduledoc """
  In-memory pending/processing buffer for tests (mirrors Redis adapter semantics).
  """

  @behaviour EventSales.Ingestion.RedisWebhookBuffer.Adapter

  @table __MODULE__
  @force_ack_unavailable_key :memory_webhook_buffer_force_ack_unavailable

  @doc false
  def force_ack_unavailable! do
    Process.put(@force_ack_unavailable_key, true)
    :ok
  end

  @doc false
  def clear_ack_override! do
    Process.delete(@force_ack_unavailable_key)
    :ok
  end

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
    if Process.get(@force_ack_unavailable_key) do
      {:error, :unavailable}
    else
      do_ack(entry)
    end
  end

  defp do_ack(entry) do
    table = ensure_table!()
    state = get_state(table)

    if entry in state.processing do
      :ets.insert(table, {:state, %{state | processing: List.delete(state.processing, entry)}})
      :ok
    else
      {:error, :unavailable}
    end
  end

  @impl true
  def requeue(entry) when is_binary(entry) do
    table = ensure_table!()
    state = get_state(table)

    cond do
      entry not in state.processing ->
        {:error, :unavailable}

      length(state.pending) >= max_entries() ->
        {:error, :full}

      true ->
        :ets.insert(
          table,
          {:state,
           %{
             pending: state.pending ++ [entry],
             processing: List.delete(state.processing, entry)
           }}
        )

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
    clear_ack_override!()
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
