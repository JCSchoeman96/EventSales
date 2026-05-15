defmodule EventSales.Ingestion.Resources.WebhookEventTest do
  use EventSales.DataCase, async: true

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.TestSupport.FixtureHelpers
  alias EventSales.TestSupport.SalesHelpers

  test ":receive creates queued event with payload hash" do
    source = SalesHelpers.create_source_system!()
    raw_body = FixtureHelpers.read_fixture!(:woocommerce, :order_completed)
    now = DateTime.utc_now()

    assert {:ok, event} =
             WebhookEvent
             |> Ash.Changeset.for_create(:receive, %{
               source_system_id: source.id,
               topic: "order.updated",
               resource_type: "order",
               resource_id: "123",
               delivery_id: "delivery-#{System.unique_integer([:positive])}",
               payload: Jason.decode!(raw_body),
               payload_hash: payload_hash(raw_body),
               raw_body_size: byte_size(raw_body),
               signature_validated_at: now,
               received_at: now
             })
             |> Ash.create(domain: Ingestion)

    assert event.status == :queued
    assert event.accepted_via == :postgres
  end

  defp payload_hash(raw_body) do
    :crypto.hash(:sha256, raw_body)
    |> Base.encode16(case: :lower)
  end
end
