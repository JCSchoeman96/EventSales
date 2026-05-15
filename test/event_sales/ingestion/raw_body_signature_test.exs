defmodule EventSales.Ingestion.RawBodySignatureTest do
  use EventSales.DataCase, async: true

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Ingestion.WebhookIntake
  alias EventSales.TestSupport.SalesHelpers
  alias EventSales.TestSupport.WooCommerceWebhookHelpers

  @token "test-token"
  @secret "slice_1_5_webhook_secret"

  setup do
    _source = SalesHelpers.create_source_system!()
    :ok
  end

  test "accept rejects when signature was computed for different raw bytes" do
    raw_a = ~s({"id":1,"status":"completed"})
    raw_b = ~s({"status":"completed","id":1})

    headers =
      WooCommerceWebhookHelpers.signed_headers(raw_b,
        secret: @secret,
        delivery_id: "delivery-#{System.unique_integer([:positive])}"
      )

    assert {:error, :invalid_signature} =
             WebhookIntake.accept(%{
               path_token: @token,
               raw_body: raw_a,
               headers: headers,
               remote_ip: {127, 0, 0, 1},
               user_agent: "test"
             })

    assert [] = Ash.read!(WebhookEvent, domain: Ingestion)
  end
end
