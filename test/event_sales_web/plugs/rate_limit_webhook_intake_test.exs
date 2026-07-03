defmodule EventSalesWeb.Plugs.RateLimitWebhookIntakeTest do
  use EventSalesWeb.ConnCase, async: false

  import EventSales.DataCase, only: [setup_sandbox: 1]

  alias EventSales.Ingestion
  alias EventSales.Ingestion.RedisRateLimiter
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Telemetry
  alias EventSales.TestSupport.FixtureHelpers
  alias EventSales.TestSupport.SalesHelpers
  alias EventSalesWeb.Plugs.RateLimitWebhookIntake

  @token "test-token"
  @secret "slice_1_5_webhook_secret"

  setup tags do
    setup_sandbox(tags)
    SalesHelpers.create_source_system!()
    :ok
  end

  test "allows the first webhook request through the plug", %{conn: conn} do
    conn =
      conn
      |> put_req_headers(
        signed_headers(FixtureHelpers.read_fixture!(:woocommerce, :order_completed))
      )
      |> put_req_header("content-type", "application/json")
      |> Map.put(:path_params, %{"path_token" => @token})
      |> RateLimitWebhookIntake.call([])

    refute conn.halted
  end

  test "returns 429 from the plug when rate limited", %{conn: conn} do
    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)

    base_conn =
      conn
      |> put_req_headers(signed_headers(raw_body, delivery_id: "rate-limit-1"))
      |> put_req_header("content-type", "application/json")
      |> Map.put(:path_params, %{"path_token" => @token})

    key = RedisRateLimiter.webhook_key(base_conn.remote_ip, :present, "router")
    :ok = RedisRateLimiter.saturate_for_test!(key)

    handler_id = "webhook-rate-limited-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        Telemetry.webhook_rate_limited(),
        fn event, measurements, metadata, _ ->
          send(self(), {:rate_limited, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    limited_conn = RateLimitWebhookIntake.call(base_conn, [])

    assert limited_conn.halted
    assert limited_conn.status == 429

    assert_receive {:rate_limited, [:event_sales, :webhook, :rate_limited], %{count: 1}, metadata}

    refute Map.has_key?(metadata, :path_token)
    refute Map.has_key?(metadata, :signature)
    refute Map.has_key?(metadata, :raw_body)
    refute Map.has_key?(metadata, :email)
    refute Map.has_key?(metadata, :phone)
    assert metadata.layer == :router
    assert metadata.token_presence in [:present, :missing]
  end

  test "rate limited webhook through endpoint does not persist", %{conn: conn} do
    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    headers = signed_headers(raw_body, delivery_id: "rate-limit-endpoint")

    first =
      conn
      |> put_req_headers(headers)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/woocommerce/#{@token}", raw_body)

    assert response(first, 200) == "ok"

    ip = {127, 0, 0, 1}

    :ok =
      RedisRateLimiter.saturate_for_test!(
        RedisRateLimiter.webhook_key(ip, :missing, "pre_parser")
      )

    :ok =
      RedisRateLimiter.saturate_for_test!(RedisRateLimiter.webhook_key(ip, :present, "router"))

    second =
      build_conn()
      |> put_req_headers(headers)
      |> put_req_header("content-type", "application/json")
      |> post(~p"/webhooks/woocommerce/#{@token}", raw_body)

    assert response(second, 429)
    assert [%WebhookEvent{}] = Ash.read!(WebhookEvent, domain: Ingestion)
  end

  test "missing path token uses low-cardinality telemetry tags", %{conn: conn} do
    base_conn =
      conn
      |> Map.put(:path_params, %{})

    key = RedisRateLimiter.webhook_key(base_conn.remote_ip, :missing, "router")
    :ok = RedisRateLimiter.saturate_for_test!(key)

    handler_id = "webhook-rate-limited-missing-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        Telemetry.webhook_rate_limited(),
        fn _event, _measurements, metadata, _ ->
          send(self(), {:missing_token_metadata, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    limited_conn = RateLimitWebhookIntake.call(base_conn, [])

    assert limited_conn.halted
    assert limited_conn.status == 429

    assert_receive {:missing_token_metadata, metadata}
    assert metadata.token_presence == :missing
    refute Map.has_key?(metadata, :path_token)
  end

  defp put_req_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc ->
      put_req_header(acc, name, value)
    end)
  end

  defp signed_headers(raw_body, opts \\ []) do
    delivery_id =
      Keyword.get(opts, :delivery_id, "delivery-#{System.unique_integer([:positive])}")

    signature =
      :crypto.mac(:hmac, :sha256, @secret, raw_body)
      |> Base.encode64()

    [
      {"x-wc-webhook-signature", signature},
      {"x-wc-webhook-delivery-id", delivery_id},
      {"x-wc-webhook-topic", "order.updated"},
      {"x-wc-webhook-resource", "order"}
    ]
  end
end
