defmodule EventSales.TestSupport.WooCommerceWebhookHelpers do
  @moduledoc """
  Test-only helpers for constructing signed WooCommerce webhook requests.
  """

  @default_delivery_id "slice-1-5-delivery"
  @default_resource "order"
  @default_secret "slice_1_5_webhook_secret"
  @default_topic "order.updated"
  @default_webhook_id "slice-1-5-webhook"

  @spec sign_raw_body(iodata(), iodata()) :: String.t()
  def sign_raw_body(raw_body, secret) do
    :hmac
    |> :crypto.mac(:sha256, IO.iodata_to_binary(secret), IO.iodata_to_binary(raw_body))
    |> Base.encode64()
  end

  @spec signed_headers(iodata(), keyword()) :: [{String.t(), String.t()}]
  def signed_headers(raw_body, opts \\ []) when is_list(opts) do
    secret = Keyword.get(opts, :secret, @default_secret)
    topic = Keyword.get(opts, :topic, @default_topic)
    resource = Keyword.get(opts, :resource, @default_resource)
    delivery_id = Keyword.get(opts, :delivery_id, @default_delivery_id)
    webhook_id = Keyword.get(opts, :webhook_id, @default_webhook_id)

    [
      {"x-wc-webhook-topic", topic},
      {"x-wc-webhook-resource", resource},
      {"x-wc-webhook-delivery-id", delivery_id},
      {"x-wc-webhook-id", webhook_id},
      {"x-wc-webhook-signature", sign_raw_body(raw_body, secret)}
    ]
  end
end
