defmodule EventSales.TestSupport.WooCommerceWebhookHelpersTest do
  use ExUnit.Case, async: true

  @moduledoc false

  alias EventSales.TestSupport.WooCommerceWebhookHelpers

  test "sign_raw_body/2 returns Base64 HMAC-SHA256 for exact raw bytes" do
    raw_body = ~s({"id":1001,"status":"completed"})

    assert WooCommerceWebhookHelpers.sign_raw_body(raw_body, "test_webhook_secret") ==
             "ktZX0lLZW3LNYcJENZ7d7Zx/5ydf0f2jiqXKUhT40ns="
  end

  test "signed_headers/2 includes Woo-style topic resource delivery and signature headers" do
    raw_body = ~s({"id":1001,"status":"completed"})

    headers =
      WooCommerceWebhookHelpers.signed_headers(raw_body,
        secret: "test_webhook_secret",
        topic: "order.created",
        resource: "order",
        delivery_id: "delivery-123",
        webhook_id: "webhook-456"
      )

    assert {"x-wc-webhook-topic", "order.created"} in headers
    assert {"x-wc-webhook-resource", "order"} in headers
    assert {"x-wc-webhook-delivery-id", "delivery-123"} in headers
    assert {"x-wc-webhook-id", "webhook-456"} in headers

    assert {"x-wc-webhook-signature", "ktZX0lLZW3LNYcJENZ7d7Zx/5ydf0f2jiqXKUhT40ns="} in headers
  end
end
