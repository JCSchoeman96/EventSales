defmodule EventSalesWeb.Plugs.WebhookIntakePreParserGuard do
  @moduledoc """
  Cheap webhook admission guard that runs before `Plug.Parsers`.

  Limits body-parsing cost for `/webhooks/woocommerce/*` using a coarse
  Redis-backed key derived from request path and hashed remote IP.
  """

  import Plug.Conn

  alias EventSales.Ingestion.RedisRateLimiter
  alias EventSales.Ingestion.Security.LowCardinalityKey
  alias EventSales.Telemetry

  @webhook_prefix "/webhooks/woocommerce/"
  @catalog_change_prefix "/webhooks/catalog-change/"

  def init(opts), do: opts

  def call(%Plug.Conn{request_path: path} = conn, _opts) when is_binary(path) do
    if webhook_path?(path) do
      case RedisRateLimiter.allow?(limiter_key(conn), scope: :pre_parser) do
        :ok ->
          conn

        {:error, :disabled} ->
          conn

        {:error, :rate_limited} ->
          emit_rate_limited(:pre_parser)
          rate_limited_response(conn)

        {:error, _} ->
          emit_rate_limited(:pre_parser_unavailable)
          rate_limited_response(conn)
      end
    else
      conn
    end
  end

  defp webhook_path?(path),
    do:
      String.starts_with?(path, @webhook_prefix) or
        String.starts_with?(path, @catalog_change_prefix)

  defp limiter_key(conn) do
    RedisRateLimiter.webhook_key(
      conn.remote_ip,
      LowCardinalityKey.token_presence(:missing),
      "pre_parser"
    )
  end

  defp rate_limited_response(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(429, Jason.encode!(%{error: "rate_limited"}))
    |> halt()
  end

  defp emit_rate_limited(layer) do
    Telemetry.emit(Telemetry.webhook_rate_limited(), %{count: 1}, %{
      layer: layer,
      token_presence: :missing
    })
  end
end
