defmodule EventSalesWeb.Plugs.RateLimitWebhookIntake do
  @moduledoc """
  Token-aware Redis-backed webhook intake rate limiter.

  Runs in the router pipeline before `WebhookController` so rate-limited
  requests return `429` before durable intake.
  """

  import Plug.Conn

  alias EventSales.Ingestion.RedisRateLimiter
  alias EventSales.Ingestion.Security.LowCardinalityKey
  alias EventSales.Telemetry

  def init(opts), do: opts

  def call(%Plug.Conn{path_params: %{"path_token" => path_token}} = conn, _opts) do
    case RedisRateLimiter.allow?(limiter_key(conn, path_token), scope: :router) do
      :ok ->
        conn

      {:error, :disabled} ->
        conn

      {:error, :rate_limited} ->
        emit_rate_limited(path_token)
        rate_limited_response(conn)

      {:error, _} ->
        emit_rate_limited(path_token)
        rate_limited_response(conn)
    end
  end

  def call(conn, _opts) do
    case RedisRateLimiter.allow?(
           RedisRateLimiter.webhook_key(
             conn.remote_ip,
             LowCardinalityKey.token_presence(:missing),
             "router"
           ),
           scope: :router
         ) do
      :ok ->
        conn

      {:error, :disabled} ->
        conn

      {:error, :rate_limited} ->
        emit_rate_limited(:missing)
        rate_limited_response(conn)

      {:error, _} ->
        emit_rate_limited(:missing)
        rate_limited_response(conn)
    end
  end

  defp limiter_key(conn, path_token) do
    RedisRateLimiter.webhook_key(
      conn.remote_ip,
      LowCardinalityKey.token_presence_from_path_token(path_token),
      "router"
    )
  end

  defp rate_limited_response(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(429, Jason.encode!(%{error: "rate_limited"}))
    |> halt()
  end

  defp emit_rate_limited(path_token) do
    token_presence =
      case path_token do
        :missing -> :missing
        token -> LowCardinalityKey.token_presence_from_path_token(token)
      end

    Telemetry.emit(Telemetry.webhook_rate_limited(), %{count: 1}, %{
      layer: :router,
      token_presence: token_presence
    })
  end
end
