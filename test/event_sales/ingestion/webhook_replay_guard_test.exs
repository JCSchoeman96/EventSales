defmodule EventSales.Ingestion.WebhookReplayGuardTest do
  use EventSales.DataCase, async: true

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Ingestion.Security.WebhookReplayGuard
  alias EventSales.TestSupport.SalesHelpers

  test "sanitize_headers/1 redacts signature and sensitive headers" do
    headers = [
      {"x-wc-webhook-signature", "abc"},
      {"authorization", "Bearer secret"},
      {"x-wc-webhook-topic", "order.updated"}
    ]

    snapshot = WebhookReplayGuard.sanitize_headers(headers)

    assert snapshot["x-wc-webhook-topic"] == "order.updated"
    assert snapshot["x-wc-webhook-signature"] == "[redacted]"
    assert snapshot["authorization"] == "[redacted]"
    refute snapshot["x-wc-webhook-signature"] == "abc"
  end

  test "source_updated_at_from_payload/1 parses date_modified_gmt without Z as UTC" do
    assert %DateTime{} =
             WebhookReplayGuard.source_updated_at_from_payload(%{
               "date_modified_gmt" => "2026-05-01T08:05:00"
             })
  end

  test "source_updated_at_from_payload/1 returns nil on unparseable date" do
    assert nil ==
             WebhookReplayGuard.source_updated_at_from_payload(%{
               "date_modified_gmt" => "not-a-date"
             })
  end

  test "classify_duplicate/2 returns duplicate when delivery_id and payload_hash match" do
    source = SalesHelpers.create_source_system!()
    delivery_id = "delivery-#{System.unique_integer([:positive])}"
    hash = WebhookReplayGuard.payload_hash(~s({"id":1}))

    assert {:ok, _event} =
             create_event(source.id, delivery_id, hash, ~U[2026-05-01 08:10:00Z], "10001")

    assert {:duplicate, %WebhookEvent{}} =
             WebhookReplayGuard.classify_duplicate(delivery_id, hash)
  end

  test "classify_duplicate/2 returns mismatch when delivery_id exists but hash differs" do
    source = SalesHelpers.create_source_system!()
    delivery_id = "delivery-#{System.unique_integer([:positive])}"
    hash_a = WebhookReplayGuard.payload_hash(~s({"id":1}))
    hash_b = WebhookReplayGuard.payload_hash(~s({"id":2}))

    assert {:ok, _} =
             create_event(source.id, delivery_id, hash_a, ~U[2026-05-01 08:10:00Z], "10001")

    assert {:duplicate_payload_mismatch, %WebhookEvent{payload_hash: ^hash_a}} =
             WebhookReplayGuard.classify_duplicate(delivery_id, hash_b)
  end

  test "check_stale/4 returns stale_replay when incoming updated_at is older than latest" do
    source = SalesHelpers.create_source_system!()

    assert {:ok, latest} =
             create_event(
               source.id,
               "delivery-#{System.unique_integer([:positive])}",
               WebhookReplayGuard.payload_hash(~s({"id":1})),
               ~U[2026-05-01 08:10:00Z],
               "10001"
             )

    assert {:stale_replay, metadata} =
             WebhookReplayGuard.check_stale(
               source.id,
               "order",
               "10001",
               ~U[2026-05-01 08:05:00Z]
             )

    assert metadata["latest_webhook_event_id"] == latest.id
    refute Map.has_key?(metadata, "payload")
    refute Map.has_key?(metadata, "raw_body")
  end

  defp create_event(source_system_id, delivery_id, payload_hash, source_updated_at, resource_id) do
    now = DateTime.utc_now()

    WebhookEvent
    |> Ash.Changeset.for_create(:receive, %{
      source_system_id: source_system_id,
      topic: "order.updated",
      resource_type: "order",
      resource_id: resource_id,
      delivery_id: delivery_id,
      payload: %{"id" => resource_id},
      payload_hash: payload_hash,
      raw_body_size: 10,
      signature_validated_at: now,
      received_at: now,
      source_updated_at: source_updated_at,
      sanitized_headers_snapshot: %{}
    })
    |> Ash.create(domain: Ingestion)
  end
end
