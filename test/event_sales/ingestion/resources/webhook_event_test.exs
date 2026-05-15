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

  test ":receive duplicate delivery_id violates unique_delivery_id identity" do
    source = SalesHelpers.create_source_system!()
    delivery_id = "delivery-#{System.unique_integer([:positive])}"
    now = DateTime.utc_now()

    attrs = %{
      source_system_id: source.id,
      topic: "order.updated",
      resource_type: "order",
      resource_id: "123",
      delivery_id: delivery_id,
      payload: %{"id" => 123},
      payload_hash: "hash-a",
      raw_body_size: 10,
      signature_validated_at: now,
      received_at: now,
      source_updated_at: now,
      sanitized_headers_snapshot: %{}
    }

    assert {:ok, _} =
             WebhookEvent
             |> Ash.Changeset.for_create(:receive, attrs)
             |> Ash.create(domain: Ingestion)

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             WebhookEvent
             |> Ash.Changeset.for_create(:receive, Map.put(attrs, :payload_hash, "hash-b"))
             |> Ash.create(domain: Ingestion)

    assert Enum.any?(errors, fn
             %Ash.Error.Changes.InvalidAttribute{
               field: :delivery_id,
               private_vars: private_vars
             } ->
               private_vars[:constraint] ==
                 "ingestion_webhook_events_unique_delivery_id_index"

             _ ->
               false
           end)
  end

  defp payload_hash(raw_body) do
    :crypto.hash(:sha256, raw_body)
    |> Base.encode16(case: :lower)
  end
end
