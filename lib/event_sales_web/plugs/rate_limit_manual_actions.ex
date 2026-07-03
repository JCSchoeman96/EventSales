defmodule EventSalesWeb.Plugs.RateLimitManualActions do
  @moduledoc """
  ETS-backed HTTP rate limiter for admin mutation endpoints.
  """

  import Plug.Conn

  alias EventSales.Ingestion.Security.LowCardinalityKey
  alias EventSalesWeb.RateLimiting.EtsSlidingWindow

  @limited_routes MapSet.new([
                    "POST:/admin/login",
                    "GET:/admin/reconciliation/export.csv",
                    "GET:/admin/events/:event_id/exports/summary.csv",
                    "GET:/admin/events/:event_id/exports/orders.csv"
                  ])

  def init(opts), do: opts

  def call(conn, _opts) do
    route_key = route_key(conn)

    if limited_route?(route_key) do
      case EtsSlidingWindow.allow?(limiter_key(conn, route_key), manual_action_opts()) do
        :ok -> conn
        {:error, :rate_limited} -> rate_limited_response(conn)
      end
    else
      conn
    end
  end

  defp limited_route?(route_key), do: MapSet.member?(@limited_routes, route_key)

  defp route_key(conn) do
    method = conn.method |> String.upcase()
    path = normalize_path(conn.request_path)
    "#{method}:#{path}"
  end

  defp normalize_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &normalize_segment/1)
  end

  defp normalize_segment(segment) do
    cond do
      segment == "" -> segment
      uuid?(segment) -> ":event_id"
      numeric?(segment) -> ":event_id"
      true -> segment
    end
  end

  defp uuid?(segment) do
    String.match?(segment, ~r/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i)
  end

  defp numeric?(segment), do: String.match?(segment, ~r/^\d+$/)

  defp limiter_key(conn, route_key) do
    LowCardinalityKey.hash_remote_ip(conn.remote_ip) <> ":" <> route_key
  end

  defp manual_action_opts do
    config = Application.get_env(:event_sales, :admin_http_rate_limit, [])

    [
      window_ms: Keyword.get(config, :window_ms, 30_000),
      max_requests: Keyword.get(config, :max_requests, 10)
    ]
  end

  defp rate_limited_response(conn) do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(429, "Too many requests")
    |> halt()
  end
end
