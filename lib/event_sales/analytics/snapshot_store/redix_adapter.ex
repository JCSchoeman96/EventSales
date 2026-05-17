defmodule EventSales.Analytics.SnapshotStore.RedixAdapter do
  @moduledoc """
  Redis-backed warm snapshot adapter for analytics hot state.

  This adapter uses a separate Redix process from webhook degraded-mode
  buffering so the two Redis concerns do not share names or configuration.
  """

  @behaviour EventSales.Analytics.SnapshotStore.Adapter

  @doc false
  @spec redix_name() :: atom()
  def redix_name, do: :event_sales_analytics_redis

  @impl true
  def put(key, summary, opts \\ []) when is_binary(key) and is_map(summary) do
    ttl_ms = Keyword.get(opts, :ttl_ms, default_ttl_ms())

    with {:ok, conn} <- connection(),
         {:ok, encoded} <- Jason.encode(summary),
         {:ok, "OK"} <- Redix.command(conn, ["SET", key, encoded, "PX", ttl_ms]) do
      :ok
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :unavailable}
    end
  end

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
end
