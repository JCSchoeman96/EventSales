defmodule EventSales.Catalog.EventSourceCreatedAtTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.TestSupport.SalesHelpers

  @source_created_at ~U[2026-08-07 08:00:00.123456Z]

  test "captures source creation time through the dedicated Event action" do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        external_event_kind: :tickera_event,
        external_event_id: 70_001
      })

    assert {:ok, captured} =
             Ash.update(
               event,
               %{source_created_at: @source_created_at},
               action: :capture_source_created_at,
               domain: Catalog
             )

    assert Map.get(captured, :source_created_at) == @source_created_at
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

  test "capturing the same source creation time is idempotent" do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        external_event_kind: :tickera_event,
        external_event_id: 70_003
      })

    assert {:ok, first} = capture(event, @source_created_at)
    assert {:ok, second} = capture(first, @source_created_at)
    assert Map.get(second, :source_created_at) == @source_created_at
  end

  test "capturing a different source creation time fails closed" do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        external_event_kind: :tickera_event,
        external_event_id: 70_004
      })

    assert {:ok, captured} = capture(event, @source_created_at)

    assert {:error, error} = capture(captured, ~U[2026-08-07 09:00:00Z])
    assert inspect(error) =~ "source_created_at_conflict"

    persisted = Ash.get!(Event, event.id, domain: Catalog)
    assert Map.get(persisted, :source_created_at) == @source_created_at
  end

  defp capture(event, source_created_at) do
    Ash.update(
      event,
      %{source_created_at: source_created_at},
      action: :capture_source_created_at,
      domain: Catalog
    )
  end
end
