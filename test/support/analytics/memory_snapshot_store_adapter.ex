defmodule EventSales.TestSupport.Analytics.MemorySnapshotStoreAdapter do
  @moduledoc false

  @behaviour EventSales.Analytics.SnapshotStore.Adapter

  @key {__MODULE__, :state}

  @impl true
  def put(key, summary, _opts \\ []) do
    state = state()

    case state.fail_reason do
      nil ->
        write = %{key: key, summary: summary}
        {:ok, encoded} = EventSales.Analytics.SnapshotCodec.encode(summary)

        put_state(%{
          state
          | writes: state.writes ++ [write],
            snapshots: Map.put(state.snapshots, key, encoded)
        })

        :ok

      reason ->
        {:error, reason}
    end
  end

  @impl true
  def list_event_summaries(opts \\ []) do
    max_snapshots = Keyword.get(opts, :max_snapshots, 1_000)
    state = state()
    put_state(%{state | list_opts: opts})

    summaries =
      state
      |> Map.fetch!(:snapshots)
      |> Enum.take(max_snapshots)
      |> Enum.flat_map(fn {key, encoded} ->
        with {:ok, event_id} <- event_id_from_key(key),
             {:ok, summary} <- EventSales.Analytics.SnapshotCodec.decode(encoded) do
          [%{event_id: event_id, summary: summary}]
        else
          _ -> []
        end
      end)

    {:ok, summaries}
  end

  def writes do
    state() |> Map.get(:writes)
  end

  def fail_writes!(reason) do
    state = state()
    put_state(%{state | fail_reason: reason})
    :ok
  end

  def last_list_opts do
    state() |> Map.get(:list_opts)
  end

  def put_raw_snapshot_for_test!(key, raw) do
    state = state()
    put_state(%{state | snapshots: Map.put(state.snapshots, key, raw)})
    :ok
  end

  def reset! do
    put_state(%{writes: [], snapshots: %{}, fail_reason: nil, list_opts: nil})
    :ok
  end

  defp state do
    :persistent_term.get(@key, %{writes: [], snapshots: %{}, fail_reason: nil, list_opts: nil})
  end

  defp put_state(state) do
    :persistent_term.put(@key, state)
  end

  defp event_id_from_key("eventsales:analytics:hot_state:v1:event:" <> rest) do
    if String.ends_with?(rest, ":summary") do
      event_id = String.replace_suffix(rest, ":summary", "")
      if event_id == "", do: {:error, :malformed_key}, else: {:ok, event_id}
    else
      {:error, :malformed_key}
    end
  end

  defp event_id_from_key(_key), do: {:error, :malformed_key}
end
