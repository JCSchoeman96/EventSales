defmodule EventSalesWeb.WebhookController do
  @moduledoc """
  WooCommerce webhook intake endpoint.

  Verifies HMAC against raw bytes captured by `EventSalesWeb.Plugs.RawBodyReader`
  before JSON parsing. Business processing is deferred to Oban workers.
  """

  use EventSalesWeb, :controller

  alias EventSales.Ingestion.WebhookIntake
  alias EventSalesWeb.Plugs.RawBodyReader

  def woocommerce(conn, %{"path_token" => path_token}) do
    with {:ok, raw_body} <- RawBodyReader.fetch_raw_body(conn),
         {:ok, _event} <-
           WebhookIntake.accept(%{
             path_token: path_token,
             raw_body: raw_body,
             headers: normalize_headers(conn),
             remote_ip: conn.remote_ip,
             user_agent: get_req_header(conn, "user-agent") |> List.first()
           }) do
      conn
      |> put_status(200)
      |> text("ok")
    else
      {:error, :missing_raw_body} ->
        conn
        |> put_status(500)
        |> text("internal error")

      {:error, :wrong_path_token} ->
        conn
        |> put_status(404)
        |> text("not found")

      {:error, :invalid_signature} ->
        conn
        |> put_status(401)
        |> text("unauthorized")

      {:error, :invalid_json} ->
        conn
        |> put_status(400)
        |> text("bad request")

      {:error, :no_source_system} ->
        conn
        |> put_status(503)
        |> text("service unavailable")

      {:error, :enqueue_failed} ->
        conn
        |> put_status(503)
        |> text("service unavailable")
    end
  end

  defp normalize_headers(conn) do
    Enum.map(conn.req_headers, fn {name, value} ->
      {String.downcase(name), value}
    end)
  end
end
