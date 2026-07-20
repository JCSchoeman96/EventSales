defmodule EventSalesWeb.CatalogChangeControllerTest do
  use EventSalesWeb.ConnCase, async: false
  import EventSales.DataCase, only: [setup_sandbox: 1]

  alias EventSales.Ingestion.Security.CatalogChangeSignature
  alias EventSales.TestSupport.SalesHelpers

  setup tags do
    setup_sandbox(tags)
    source = SalesHelpers.create_source_system!()
    old = Application.get_env(:event_sales, :catalog_change_trigger)

    Application.put_env(:event_sales, :catalog_change_trigger,
      receiver_enabled: true,
      path_token: "catalog-token",
      source_system_id: source.id,
      current_key_id: "current",
      current_secret: "trigger-secret",
      replay_window_seconds: 300
    )

    on_exit(fn -> Application.put_env(:event_sales, :catalog_change_trigger, old) end)
    :ok
  end

  test "accepts a signed raw signal and rejects a mismatch", %{conn: conn} do
    payload = %{
      "version" => "2026-07-20.v1",
      "signal_id" => Ecto.UUID.generate(),
      "source" => "wordpress_tickera",
      "target_type" => "event",
      "target_id" => 123,
      "source_updated_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "reason" => "saved"
    }

    body = Jason.encode!(payload)
    timestamp = System.system_time(:second)
    path = "/webhooks/catalog-change/catalog-token"
    signature = CatalogChangeSignature.sign(path, timestamp, body, "trigger-secret")

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-eventsales-trigger-key-id", "current")
      |> put_req_header("x-eventsales-trigger-timestamp", Integer.to_string(timestamp))
      |> put_req_header("x-eventsales-trigger-signature", signature)
      |> post(path, body)

    assert json_response(conn, 202) == %{"status" => "accepted"}
  end

  test "rejects missing authentication headers without entering intake", %{conn: conn} do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/webhooks/catalog-change/catalog-token", "{}")

    assert json_response(conn, 401) == %{"error" => "unauthorized"}
  end
end
