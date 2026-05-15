defmodule EventSales.Ingestion.WebhookEventStoreTest do
  use EventSales.DataCase, async: true

  alias EventSales.Ingestion.WebhookEventStore
  alias EventSales.TestSupport.SalesHelpers

  setup do
    source = SalesHelpers.create_source_system!()
    {:ok, source: source}
  end

  test "receive defaults accepted_via to postgres when omitted", %{source: source} do
    assert {:ok, event} = WebhookEventStore.create_receive(base_attrs(source))
    assert event.accepted_via == :postgres
  end

  test "receive preserves accepted_via redis_buffer when supplied", %{source: source} do
    attrs = Map.put(base_attrs(source), :accepted_via, :redis_buffer)

    assert {:ok, event} = WebhookEventStore.create_receive(attrs)
    assert event.accepted_via == :redis_buffer
  end

  defp base_attrs(source) do
    now = DateTime.utc_now()

    %{
      source_system_id: source.id,
      topic: "order.updated",
      resource_type: "order",
      resource_id: "10_001",
      delivery_id: "delivery-#{System.unique_integer([:positive])}",
      payload: %{"id" => 10_001},
      payload_hash: "abc123",
      raw_body_size: 42,
      signature_validated_at: now,
      received_at: now,
      sanitized_headers_snapshot: %{}
    }
  end
end
