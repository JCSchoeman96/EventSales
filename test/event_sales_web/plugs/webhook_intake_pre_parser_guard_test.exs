defmodule EventSalesWeb.Plugs.WebhookIntakePreParserGuardTest do
  use ExUnit.Case, async: false

  alias EventSales.Ingestion.RedisRateLimiter
  alias EventSales.TestSupport.Ingestion.MemoryRateLimiterAdapter
  alias EventSalesWeb.Plugs.WebhookIntakePreParserGuard

  setup do
    MemoryRateLimiterAdapter.reset_for_test!()
    on_exit(fn -> MemoryRateLimiterAdapter.reset_for_test!() end)
    :ok
  end

  test "allows the first webhook request before body parsing" do
    conn =
      :get
      |> Plug.Test.conn("/webhooks/woocommerce/test-token")
      |> WebhookIntakePreParserGuard.call([])

    refute conn.halted
  end

  test "returns 429 for webhook paths above the pre-parser limit" do
    base_conn = Plug.Test.conn(:post, "/webhooks/woocommerce/test-token")

    key = RedisRateLimiter.webhook_key(base_conn.remote_ip, :missing, "pre_parser")
    :ok = RedisRateLimiter.saturate_for_test!(key)

    limited_conn = WebhookIntakePreParserGuard.call(base_conn, [])

    assert limited_conn.halted
    assert limited_conn.status == 429
  end

  test "ignores non-webhook paths" do
    conn =
      :get
      |> Plug.Test.conn("/health")
      |> WebhookIntakePreParserGuard.call([])

    refute conn.halted
  end
end
