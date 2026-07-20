defmodule EventSalesWeb.CatalogChangeController do
  use EventSalesWeb, :controller

  alias EventSales.Ingestion.{CatalogChangeContract, CatalogChangeIntake}
  alias EventSales.Ingestion.Security.CatalogChangeSignature
  alias EventSalesWeb.Plugs.RawBodyReader

  def create(conn, %{"path_token" => token}) do
    config = Application.get_env(:event_sales, :catalog_change_trigger, [])

    with true <- Keyword.get(config, :receiver_enabled, false),
         true <- token == Keyword.get(config, :path_token),
         ["application/json" <> _] <- get_req_header(conn, "content-type"),
         encoding when encoding in [[], ["identity"]] <- get_req_header(conn, "content-encoding"),
         {:ok, raw_body} <- RawBodyReader.fetch_raw_body(conn),
         :ok <- verify(conn, raw_body, config),
         {:ok, payload} <- Jason.decode(raw_body),
         {:ok, _signal} <- CatalogChangeContract.parse(payload),
         source_id when is_binary(source_id) <- Keyword.get(config, :source_system_id),
         result <- CatalogChangeIntake.persist(source_id, raw_body, payload) do
      respond(conn, result)
    else
      false ->
        conn |> put_status(404) |> json(%{error: "not_found"})

      [] ->
        conn |> put_status(415) |> json(%{error: "unsupported_media_type"})

      [_] ->
        conn |> put_status(415) |> json(%{error: "unsupported_content_encoding"})

      {:error, %Jason.DecodeError{}} ->
        conn |> put_status(400) |> json(%{error: "invalid_signal"})

      {:error, :invalid_signal} ->
        conn |> put_status(400) |> json(%{error: "invalid_signal"})

      {:error, reason}
      when reason in [:invalid_signature, :invalid_timestamp, :stale_timestamp, :unknown_key_id] ->
        conn |> put_status(401) |> json(%{error: "unauthorized"})

      _ ->
        conn |> put_status(503) |> json(%{error: "temporarily_unavailable"})
    end
  end

  defp verify(conn, body, config) do
    keys =
      %{}
      |> maybe_key(Keyword.get(config, :current_key_id), Keyword.get(config, :current_secret))
      |> maybe_key(Keyword.get(config, :previous_key_id), Keyword.get(config, :previous_secret))

    CatalogChangeSignature.verify_request(
      conn.request_path,
      header(conn, "x-eventsales-trigger-timestamp"),
      body,
      header(conn, "x-eventsales-trigger-signature"),
      keys,
      header(conn, "x-eventsales-trigger-key-id"),
      replay_window_seconds: Keyword.get(config, :replay_window_seconds, 300)
    )
  end

  defp header(conn, name), do: get_req_header(conn, name) |> List.first()

  defp maybe_key(map, id, secret) when is_binary(id) and is_binary(secret),
    do: Map.put(map, id, secret)

  defp maybe_key(map, _, _), do: map
  defp respond(conn, {:ok, :accepted}), do: conn |> put_status(202) |> json(%{status: "accepted"})
  defp respond(conn, {:ok, :duplicate}), do: json(conn, %{status: "duplicate"})

  defp respond(conn, {:error, :signal_id_payload_mismatch}),
    do: conn |> put_status(409) |> json(%{error: "signal_id_payload_mismatch"})

  defp respond(conn, _), do: conn |> put_status(503) |> json(%{error: "temporarily_unavailable"})
end
