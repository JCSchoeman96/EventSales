defmodule EventSales.Ingestion.Resources.WebhookDeliveryFailureTest do
  use EventSales.DataCase, async: true

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookDeliveryFailure

  test ":log_failure stores bounded metadata without raw payload" do
    now = DateTime.utc_now()

    assert {:ok, failure} =
             WebhookDeliveryFailure
             |> Ash.Changeset.for_create(:log_failure, %{
               reason: :invalid_signature,
               topic: "order.updated",
               metadata: %{byte_size: 42},
               received_at: now
             })
             |> Ash.create(domain: Ingestion)

    assert failure.reason == :invalid_signature
    refute Map.has_key?(failure.metadata, "line_items")
  end

  test ":log_failure rejects oversized metadata" do
    now = DateTime.utc_now()
    huge_metadata = %{blob: String.duplicate("x", 3000)}

    assert {:error, %Ash.Error.Invalid{errors: errors}} =
             WebhookDeliveryFailure
             |> Ash.Changeset.for_create(:log_failure, %{
               reason: :invalid_json,
               metadata: huge_metadata,
               received_at: now
             })
             |> Ash.create(domain: Ingestion)

    assert Enum.any?(errors, &match?(%Ash.Error.Changes.InvalidAttribute{field: :metadata}, &1))
  end
end
