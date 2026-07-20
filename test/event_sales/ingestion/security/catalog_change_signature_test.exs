defmodule EventSales.Ingestion.Security.CatalogChangeSignatureTest do
  use ExUnit.Case, async: true

  alias EventSales.Ingestion.Security.CatalogChangeSignature

  @path "/webhooks/catalog-change/path-token"
  @body ~s({"version":"2026-07-20.v1","signal_id":"0190d5d4-7b86-7ae2-8d90-70ea430a87c4"})
  @now 1_753_011_200

  test "signs and verifies the exact raw body and canonical request fields" do
    signature = CatalogChangeSignature.sign(@path, @now, @body, "dedicated-secret")

    assert String.starts_with?(signature, "v1=")
    assert :ok = CatalogChangeSignature.verify(@path, @now, @body, signature, "dedicated-secret")

    assert {:error, :invalid_signature} =
             CatalogChangeSignature.verify(
               @path,
               @now,
               @body <> " ",
               signature,
               "dedicated-secret"
             )
  end

  test "enforces the replay window" do
    signature = CatalogChangeSignature.sign(@path, @now, @body, "dedicated-secret")

    assert :ok =
             CatalogChangeSignature.verify_request(
               @path,
               Integer.to_string(@now),
               @body,
               signature,
               %{"current" => "dedicated-secret"},
               "current",
               now: @now + 300
             )

    assert {:error, :stale_timestamp} =
             CatalogChangeSignature.verify_request(
               @path,
               Integer.to_string(@now),
               @body,
               signature,
               %{"current" => "dedicated-secret"},
               "current",
               now: @now + 301
             )
  end

  test "selects current or previous keys and rejects unknown key ids" do
    previous = CatalogChangeSignature.sign(@path, @now, @body, "previous-secret")
    keys = %{"current" => "current-secret", "previous" => "previous-secret"}

    assert :ok =
             CatalogChangeSignature.verify_request(
               @path,
               Integer.to_string(@now),
               @body,
               previous,
               keys,
               "previous",
               now: @now
             )

    assert {:error, :unknown_key_id} =
             CatalogChangeSignature.verify_request(
               @path,
               Integer.to_string(@now),
               @body,
               previous,
               keys,
               "missing",
               now: @now
             )
  end
end
