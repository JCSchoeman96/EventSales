defmodule EventSalesWeb.WebhookControllerTest do
  use EventSalesWeb.ConnCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  import EventSales.DataCase, only: [setup_sandbox: 1]

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{WebhookDeliveryFailure, WebhookEvent}
  alias EventSales.Ingestion.Security.WebhookSignature
  alias EventSales.Ingestion.Workers.ProcessWebhookWorker
  alias EventSales.TestSupport.FixtureHelpers
  alias EventSales.TestSupport.SalesHelpers
  alias EventSales.TestSupport.WooCommerceWebhookHelpers
  alias EventSalesWeb.Plugs.RawBodyReader

  @token "test-token"
  @secret "slice_1_5_webhook_secret"

  setup tags do
    setup_sandbox(tags)
    source = SalesHelpers.create_source_system!()
    {:ok, source: source}
  end

  test "signed JSON webhook verifies HMAC against stored raw bytes through Endpoint", %{
    conn: conn
  } do
    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    headers = signed_headers(raw_body, delivery_id: unique_delivery_id())

    assert :ok =
             WebhookSignature.verify(
               raw_body,
               @secret,
               signature_from(headers)
             )

    conn =
      conn
      |> put_req_headers(headers)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/woocommerce/#{@token}", raw_body)

    assert response(conn, 200) == "ok"
    assert {:ok, stored} = RawBodyReader.fetch_raw_body(conn)
    assert stored == raw_body
    assert is_map(conn.body_params)
    assert [%{status: :queued}] = Ash.read!(WebhookEvent, domain: Ingestion)
    assert_enqueued(worker: ProcessWebhookWorker, queue: :webhooks)
  end

  test "valid signed webhook persists and enqueues", %{conn: conn} do
    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    headers = signed_headers(raw_body, delivery_id: unique_delivery_id())

    conn = post_webhook(conn, headers, raw_body)

    assert response(conn, 200) == "ok"
    assert length(Ash.read!(WebhookEvent, domain: Ingestion)) == 1
    assert_enqueued(worker: ProcessWebhookWorker, queue: :webhooks)
  end

  test "valid signed product.updated webhook persists and enqueues without inline REST", %{
    conn: conn
  } do
    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :product_updated)

    headers =
      signed_headers(raw_body,
        delivery_id: unique_delivery_id(),
        topic: "product.updated",
        resource: "product"
      )

    conn = post_webhook(conn, headers, raw_body)

    assert response(conn, 200) == "ok"

    assert [
             %WebhookEvent{
               status: :queued,
               topic: "product.updated",
               resource_type: "product",
               resource_id: "501"
             }
           ] = Ash.read!(WebhookEvent, domain: Ingestion)

    assert_enqueued(worker: ProcessWebhookWorker, queue: :webhooks)

    controller_source = File.read!("lib/event_sales_web/controllers/webhook_controller.ex")
    refute controller_source =~ "WooCommerceClient"
    refute controller_source =~ "/wp-json/wc/"
  end

  test "missing signature header is rejected", %{conn: conn} do
    raw_body = ~s({"id":1})
    headers = signed_headers(raw_body, delivery_id: unique_delivery_id())
    headers = Enum.reject(headers, fn {name, _} -> name == "x-wc-webhook-signature" end)

    conn = post_webhook(conn, headers, raw_body)

    assert response(conn, 401) == "unauthorized"
    assert [] = Ash.read!(WebhookEvent, domain: Ingestion)
  end

  test "invalid signature is rejected", %{conn: conn} do
    raw_body = ~s({"id":1})

    headers =
      signed_headers(raw_body, signature: "bad-signature", delivery_id: unique_delivery_id())

    conn = post_webhook(conn, headers, raw_body)

    assert response(conn, 401) == "unauthorized"
    assert [] = Ash.read!(WebhookEvent, domain: Ingestion)
    assert [%{reason: :invalid_signature}] = Ash.read!(WebhookDeliveryFailure, domain: Ingestion)
  end

  test "wrong path token returns not found", %{conn: conn} do
    raw_body = ~s({"id":1})
    headers = signed_headers(raw_body, delivery_id: unique_delivery_id())

    conn =
      conn
      |> put_req_headers(headers)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/woocommerce/wrong-token", raw_body)

    assert response(conn, 404) == "not found"
  end

  test "GET to webhook path is not routed", %{conn: conn} do
    conn = get(conn, ~p"/webhooks/woocommerce/#{@token}")

    assert response(conn, 404)
  end

  test "malformed JSON webhook fails at parser without persisting intake records", %{conn: conn} do
    raw_body = "not-json"
    headers = signed_headers(raw_body, delivery_id: unique_delivery_id())

    assert_raise Plug.Parsers.ParseError, fn ->
      post_webhook(conn, headers, raw_body)
    end

    assert [] = Ash.read!(WebhookEvent, domain: Ingestion)
    assert [] = Ash.read!(WebhookDeliveryFailure, domain: Ingestion)
  end

  test "malformed JSON on non-webhook routes still fails at parser", %{conn: conn} do
    assert_raise Plug.Parsers.ParseError, fn ->
      conn
      |> put_req_header("content-type", "application/json")
      |> post("/does-not-exist", "not-json")
    end
  end

  test "duplicate delivery_id with different body returns 200 without second event", %{conn: conn} do
    delivery_id = unique_delivery_id()
    raw_body_a = ~s({"id":10001,"status":"completed"})
    raw_body_b = ~s({"id":10001,"status":"pending"})

    conn = post_webhook(conn, signed_headers(raw_body_a, delivery_id: delivery_id), raw_body_a)
    assert response(conn, 200) == "ok"

    conn =
      post_webhook(
        build_conn(),
        signed_headers(raw_body_b, delivery_id: delivery_id),
        raw_body_b
      )

    assert response(conn, 200) == "ok"
    assert length(Ash.read!(WebhookEvent, domain: Ingestion)) == 1

    assert [%{reason: :duplicate_payload_mismatch}] =
             Ash.read!(WebhookDeliveryFailure, domain: Ingestion)

    assert length(all_enqueued(worker: ProcessWebhookWorker)) == 1
  end

  test "duplicate delivery returns 200 without second event", %{conn: conn} do
    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    delivery_id = unique_delivery_id()
    headers = signed_headers(raw_body, delivery_id: delivery_id)

    conn = post_webhook(conn, headers, raw_body)
    assert response(conn, 200) == "ok"

    conn = post_webhook(build_conn(), headers, raw_body)
    assert response(conn, 200) == "ok"
    assert length(Ash.read!(WebhookEvent, domain: Ingestion)) == 1
    assert length(all_enqueued(worker: ProcessWebhookWorker)) == 1
  end

  test "stale replay returns 200 with failure metadata only", %{conn: conn, source: source} do
    base = FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed)
    newer = Map.put(base, "date_modified_gmt", "2026-05-01T08:10:00")
    older = Map.put(base, "date_modified_gmt", "2026-05-01T08:05:00")

    newer_raw = Jason.encode!(newer)
    older_raw = Jason.encode!(older)

    conn =
      post_webhook(conn, signed_headers(newer_raw, delivery_id: unique_delivery_id()), newer_raw)

    assert response(conn, 200) == "ok"

    conn =
      post_webhook(
        build_conn(),
        signed_headers(older_raw, delivery_id: unique_delivery_id()),
        older_raw
      )

    assert response(conn, 200) == "ok"
    assert length(Ash.read!(WebhookEvent, domain: Ingestion)) == 1

    assert [%{reason: :stale_replay, source_system_id: sid}] =
             Ash.read!(WebhookDeliveryFailure, domain: Ingestion)

    assert sid == source.id
    assert length(all_enqueued(worker: ProcessWebhookWorker)) == 1
  end

  test "pool saturated with buffer enabled returns 200 without persisting", %{conn: conn} do
    err = %DBConnection.ConnectionError{message: "queue_timeout", reason: :queue_timeout}

    EventSales.TestSupport.Ingestion.StubWebhookEventStore.set_persist_error(err)
    on_exit(fn -> EventSales.TestSupport.Ingestion.StubWebhookEventStore.clear!() end)
    EventSales.TestSupport.Ingestion.MemoryWebhookBufferAdapter.reset!()
    on_exit(fn -> EventSales.TestSupport.Ingestion.MemoryWebhookBufferAdapter.reset!() end)

    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    headers = signed_headers(raw_body, delivery_id: unique_delivery_id())

    conn = post_webhook(conn, headers, raw_body)

    assert response(conn, 200) == "ok"
    assert [] = Ash.read!(WebhookEvent, domain: Ingestion)
    refute_enqueued(worker: ProcessWebhookWorker)
  end

  test "no source system returns service unavailable", %{conn: conn} do
    alias EventSales.Catalog
    alias EventSales.Catalog.Resources.SourceSystem

    for source <- Ash.read!(SourceSystem, domain: Catalog) do
      Ash.update!(source, %{active: false}, action: :update, domain: Catalog)
    end

    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    headers = signed_headers(raw_body, delivery_id: unique_delivery_id())

    conn = post_webhook(conn, headers, raw_body)

    assert response(conn, 503) == "service unavailable"
    assert [] = Ash.read!(WebhookEvent, domain: Ingestion)
    refute_enqueued(worker: ProcessWebhookWorker)
    assert [%{reason: :no_source_system}] = Ash.read!(WebhookDeliveryFailure, domain: Ingestion)
  end

  defp put_req_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
  end

  defp post_webhook(conn, headers, raw_body) do
    conn
    |> put_req_headers(headers)
    |> put_req_header("content-type", "application/json")
    |> post(~p"/webhooks/woocommerce/#{@token}", raw_body)
  end

  defp signed_headers(raw_body, opts) do
    delivery_id = Keyword.get(opts, :delivery_id, unique_delivery_id())

    headers =
      WooCommerceWebhookHelpers.signed_headers(raw_body,
        secret: @secret,
        delivery_id: delivery_id,
        topic: Keyword.get(opts, :topic, "order.updated"),
        resource: Keyword.get(opts, :resource, "order")
      )

    case Keyword.get(opts, :signature) do
      nil ->
        headers

      signature ->
        List.keyreplace(
          headers,
          "x-wc-webhook-signature",
          0,
          {"x-wc-webhook-signature", signature}
        )
    end
  end

  defp signature_from(headers) do
    {_, signature} = List.keyfind(headers, "x-wc-webhook-signature", 0)
    signature
  end

  defp unique_delivery_id do
    "delivery-#{System.unique_integer([:positive])}"
  end
end
