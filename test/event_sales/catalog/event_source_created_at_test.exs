defmodule EventSales.Catalog.EventSourceCreatedAtTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.TestSupport.SalesHelpers

  @source_created_at ~U[2026-08-07 08:00:00.123456Z]

  test "rejects direct source creation capture without verified backfill authority" do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        external_event_kind: :tickera_event,
        external_event_id: 70_001
      })

    assert {:error, error} =
             Ash.update(
               event,
               %{source_created_at: @source_created_at},
               action: :capture_source_created_at,
               domain: Catalog
             )

    assert inspect(error) =~ "verified BackfillStartCapture authority"
    assert is_nil(Map.get(Ash.get!(Event, event.id, domain: Catalog), :source_created_at))
  end

  test "generic Event update cannot rewrite source creation time" do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        external_event_kind: :tickera_event,
        external_event_id: 70_002
      })

    assert {:error, _error} =
             Ash.update(
               event,
               %{source_created_at: @source_created_at},
               action: :update,
               domain: Catalog
             )

    assert is_nil(Map.get(Ash.get!(Event, event.id, domain: Catalog), :source_created_at))
  end
end
