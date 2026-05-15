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
    case RawBodyReader.fetch_raw_body(conn) do
      {:ok, raw_body} ->
        conn
        |> intake_params(path_token, raw_body)
        |> WebhookIntake.accept()
        |> then(&response_for_accept_result(&1, conn))

      {:error, :missing_raw_body} ->
        internal_error(conn)
    end
  end

  defp intake_params(conn, path_token, raw_body) do
    %{
      path_token: path_token,
      raw_body: raw_body,
      headers: normalize_headers(conn),
      remote_ip: conn.remote_ip,
      user_agent: get_req_header(conn, "user-agent") |> List.first()
    }
  end

  defp response_for_accept_result({:ok, _event}, conn), do: ok_response(conn)
  defp response_for_accept_result({:ignored, _, _}, conn), do: ok_response(conn)
  defp response_for_accept_result({:ignored, _}, conn), do: ok_response(conn)
  defp response_for_accept_result({:error, :wrong_path_token}, conn), do: not_found(conn)
  defp response_for_accept_result({:error, :invalid_signature}, conn), do: unauthorized(conn)
  defp response_for_accept_result({:error, :invalid_json}, conn), do: bad_request(conn)
  defp response_for_accept_result({:error, :no_source_system}, conn), do: service_unavailable(conn)
  defp response_for_accept_result({:error, :enqueue_failed}, conn), do: service_unavailable(conn)

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
