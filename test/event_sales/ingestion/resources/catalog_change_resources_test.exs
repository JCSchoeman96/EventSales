defmodule EventSales.Ingestion.Resources.CatalogChangeResourcesTest do
  use EventSales.DataCase, async: true

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{CatalogChangePendingTarget, CatalogChangeSignal}
  alias EventSales.TestSupport.SalesHelpers

  test "creates one immutable signal linked to a generation-tracked target" do
    source = SalesHelpers.create_source_system!()
    now = DateTime.utc_now()

    assert {:ok, target} =
             Ash.create(
               CatalogChangePendingTarget,
               %{
                 source_system_id: source.id,
                 target_type: :product,
                 target_id: 123,
                 latest_source_updated_at: now,
                 latest_reason: :saved,
                 first_received_at: now,
                 last_received_at: now,
                 quiet_until: now
               },
               action: :create,
               domain: Ingestion
             )

    assert target.generation == 1
    assert target.dispatched_generation == 0
    assert target.state == :pending

    assert {:ok, signal} =
             Ash.create(
               CatalogChangeSignal,
               %{
                 source_system_id: source.id,
                 pending_target_id: target.id,
                 signal_id: Ecto.UUID.generate(),
                 contract_version: "2026-07-20.v1",
                 payload_hash: String.duplicate("a", 64),
                 target_type: :product,
                 target_id: 123,
                 source_updated_at: now,
                 reason: :saved,
                 disposition: :accepted,
                 received_at: now
               },
               action: :accept,
               domain: Ingestion
             )

    assert signal.pending_target_id == target.id
    assert_raise ArgumentError, fn -> Ash.Changeset.for_update(signal, :update, %{}) end
  end
end
