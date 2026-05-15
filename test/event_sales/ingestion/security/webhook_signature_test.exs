defmodule EventSales.Ingestion.Security.WebhookSignatureTest do
  use ExUnit.Case, async: true

  alias EventSales.Ingestion.Security.WebhookSignature
  alias EventSales.TestSupport.WooCommerceWebhookHelpers

  test "valid signature is accepted" do
    raw_body = ~s({"id":1})
    signature = WooCommerceWebhookHelpers.sign_raw_body(raw_body, "secret")

    assert :ok = WebhookSignature.verify(raw_body, "secret", signature)
  end

  test "wrong signature is rejected" do
    assert {:error, :invalid_signature} =
             WebhookSignature.verify(~s({"id":1}), "secret", "bad")
  end

  test "missing signature is rejected" do
    assert {:error, :missing_signature} =
             WebhookSignature.verify("body", "secret", nil)
  end

  test "re-encoded JSON with same semantics but different bytes does not verify" do
    raw_a = ~s({"id":1,"status":"completed"})
    raw_b = ~s({"status":"completed","id":1})
    refute raw_a == raw_b

    signature_for_b = WooCommerceWebhookHelpers.sign_raw_body(raw_b, "secret")

    assert {:error, :invalid_signature} =
             WebhookSignature.verify(raw_a, "secret", signature_for_b)
  end
end
