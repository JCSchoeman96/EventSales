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
    with {:ok, raw_body} <- RawBodyReader.fetch_raw_body(conn) do
      case WebhookIntake.accept(%{
             path_token: path_token,
             raw_body: raw_body,
             headers: normalize_headers(conn),
             remote_ip: conn.remote_ip,
             user_agent: get_req_header(conn, "user-agent") |> List.first()
           }) do
        {:ok, _event} -> ok_response(conn)
        {:ignored, _, _} -> ok_response(conn)
        {:ignored, _} -> ok_response(conn)
        {:error, :wrong_path_token} -> not_found(conn)
        {:error, :invalid_signature} -> unauthorized(conn)
        {:error, :invalid_json} -> bad_request(conn)
        {:error, :no_source_system} -> service_unavailable(conn)
        {:error, :enqueue_failed} -> service_unavailable(conn)
      end
    else
      {:error, :missing_raw_body} -> internal_error(conn)
    end
  end

  defp ok_response(conn) do
    conn
    |> put_status(200)
    |> text("ok")
  end

  defp internal_error(conn) do
    conn
    |> put_status(500)
    |> text("internal error")
  end

  defp not_found(conn) do
    conn
    |> put_status(404)
    |> text("not found")
  end

  defp unauthorized(conn) do
    conn
    |> put_status(401)
    |> text("unauthorized")
  end

  defp bad_request(conn) do
    conn
    |> put_status(400)
    |> text("bad request")
  end

  defp service_unavailable(conn) do
    conn
    |> put_status(503)
    |> text("service unavailable")
  end

  defp normalize_headers(conn) do
    Enum.map(conn.req_headers, fn {name, value} ->
      {String.downcase(name), value}
    end)
  end
end
