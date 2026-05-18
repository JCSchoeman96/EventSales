defmodule EventSales.Analytics.SnapshotStore.RedixAdapter do
  @moduledoc """
  Redis-backed warm snapshot adapter for analytics hot state.

  This adapter uses a separate Redix process from webhook degraded-mode
  buffering so the two Redis concerns do not share names or configuration.
  """

  @behaviour EventSales.Analytics.SnapshotStore.Adapter

  alias EventSales.Analytics.SnapshotCodec
  alias EventSales.Telemetry

  @scan_match "eventsales:analytics:hot_state:v1:event:*:summary"

  @doc false
  @spec redix_name() :: atom()
  def redix_name, do: :event_sales_analytics_redis

  @impl true
  def put(key, summary, opts \\ []) when is_binary(key) and is_map(summary) do
    ttl_ms = Keyword.get(opts, :ttl_ms, default_ttl_ms())

    with {:ok, conn} <- connection(),
         {:ok, encoded} <- SnapshotCodec.encode(summary),
         {:ok, "OK"} <- Redix.command(conn, ["SET", key, encoded, "PX", ttl_ms]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @impl true
  def list_event_summaries(opts \\ []) do
    scan_count = Keyword.get(opts, :scan_count, restore_scan_count())
    max_snapshots = Keyword.get(opts, :max_snapshots, restore_max_snapshots())

    with {:ok, conn} <- connection(),
         {:ok, summaries} <- scan_event_summaries(conn, "0", scan_count, max_snapshots, []) do
      {:ok, summaries}
    else
      {:error, reason} ->
        emit_restore(:error, reason, 0)
        {:error, reason}
    end
  rescue
    _ ->
      emit_restore(:error, :unavailable, 0)
      {:error, :unavailable}
  end

  defp scan_event_summaries(_conn, _cursor, _scan_count, max_snapshots, acc)
       when length(acc) >= max_snapshots do
    emit_restore(:ok, :bounded, length(acc))
    {:ok, Enum.reverse(acc)}
  end

  defp scan_event_summaries(conn, cursor, scan_count, max_snapshots, acc) do
    case Redix.command(conn, ["SCAN", cursor, "MATCH", @scan_match, "COUNT", scan_count]) do
      {:ok, [next_cursor, keys]} when is_list(keys) ->
        acc = restore_keys(conn, keys, max_snapshots, acc)

        cond do
          length(acc) >= max_snapshots ->
            emit_restore(:ok, :bounded, length(acc))
            {:ok, Enum.reverse(acc)}

          next_cursor == "0" ->
            emit_restore(:ok, :complete, length(acc))
            {:ok, Enum.reverse(acc)}

          true ->
            scan_event_summaries(conn, next_cursor, scan_count, max_snapshots, acc)
        end

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :unavailable}
    end
  end

  defp restore_keys(_conn, _keys, max_snapshots, acc) when length(acc) >= max_snapshots, do: acc

  defp restore_keys(conn, [key | rest], max_snapshots, acc) do
    acc =
      case restore_key(conn, key) do
        {:ok, restored} ->
          [restored | acc]

        {:error, :malformed} ->
          emit_restore(:skipped, :malformed, 0)
          acc

        {:error, reason} ->
          emit_restore(:skipped, low_cardinality_reason(reason), 0)
          acc
      end

    restore_keys(conn, rest, max_snapshots, acc)
  end

  defp restore_keys(_conn, [], _max_snapshots, acc), do: acc

  defp restore_key(conn, key) do
    with {:ok, event_id} <- event_id_from_key(key),
         {:ok, encoded} when is_binary(encoded) <- Redix.command(conn, ["GET", key]),
         {:ok, summary} <- SnapshotCodec.decode(encoded) do
      {:ok, %{event_id: event_id, summary: summary}}
    else
      {:ok, nil} -> {:error, :missing}
      {:error, :malformed} -> {:error, :malformed}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unavailable}
    end
  end

  defp event_id_from_key(key) when is_binary(key) do
    prefix = "eventsales:analytics:hot_state:v1:event:"

    with true <- String.starts_with?(key, prefix),
         true <- String.ends_with?(key, ":summary"),
         rest <- key |> String.replace_prefix(prefix, "") |> String.replace_suffix(":summary", ""),
         true <- rest != "" do
      {:ok, rest}
    else
      _ -> {:error, :malformed}
    end
  end

  defp emit_restore(result, reason, count) do
    Telemetry.emit(Telemetry.hot_state_snapshot_write(), %{count: count}, %{
      source: :redis,
      operation: :restore,
      result: result,
      reason: low_cardinality_reason(reason)
    })
  end

  defp low_cardinality_reason(nil), do: :none
  defp low_cardinality_reason(reason) when is_atom(reason), do: reason
  defp low_cardinality_reason(_reason), do: :error

  defp connection do
    case redix_name() |> Process.whereis() do
      nil -> {:error, :no_connection}
      pid when is_pid(pid) -> {:ok, pid}
    end
  end

  defp default_ttl_ms do
    :event_sales
    |> Application.get_env(:hot_state_aggregator, [])
    |> Keyword.get(:snapshot_ttl_ms, :timer.hours(1))
  end

  defp restore_scan_count do
    :event_sales
    |> Application.get_env(:hot_state_aggregator, [])
    |> Keyword.get(:restore_scan_count, 100)
  end

  defp restore_max_snapshots do
    :event_sales
    |> Application.get_env(:hot_state_aggregator, [])
    |> Keyword.get(:restore_max_snapshots, 1_000)
  end
end
