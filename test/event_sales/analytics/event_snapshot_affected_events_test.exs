defmodule EventSales.Analytics.EventSnapshotAffectedEventsTest do
  use ExUnit.Case, async: true

  alias EventSales.Analytics.EventSnapshotAffectedEvents

  test "resolves the event from a newly created order snapshot" do
    event_id = Ecto.UUID.generate()

    assert {:ok, [^event_id]} =
             EventSnapshotAffectedEvents.resolve(nil, snapshot([event_id]))
  end

  test "deduplicates the same persisted event across before and after snapshots" do
    event_id = Ecto.UUID.generate()

    assert {:ok, [^event_id]} =
             EventSnapshotAffectedEvents.resolve(snapshot([event_id]), snapshot([event_id]))
  end

  test "returns both events when attribution moves between events" do
    old_event_id = "00000000-0000-0000-0000-000000000001"
    new_event_id = "00000000-0000-0000-0000-000000000002"

    assert {:ok, [^old_event_id, ^new_event_id]} =
             EventSnapshotAffectedEvents.resolve(
               snapshot([old_event_id]),
               snapshot([new_event_id])
             )
  end

  test "includes an explicit authoritative event id" do
    explicit_event_id = Ecto.UUID.generate()

    assert {:ok, [^explicit_event_id]} =
             EventSnapshotAffectedEvents.resolve(nil, snapshot([]), [explicit_event_id])
  end

  test "sorts multiple event ids canonically regardless of snapshot order" do
    first = "00000000-0000-0000-0000-000000000001"
    second = "00000000-0000-0000-0000-000000000002"
    third = "00000000-0000-0000-0000-000000000003"

    assert {:ok, [^first, ^second, ^third]} =
             EventSnapshotAffectedEvents.resolve(
               snapshot([third, first]),
               snapshot([second, third])
             )
  end

  test "ignores nil persisted event ids" do
    event_id = Ecto.UUID.generate()

    assert {:ok, [^event_id]} =
             EventSnapshotAffectedEvents.resolve(snapshot([nil]), snapshot([event_id, nil]))
  end

  test "rejects malformed persisted event ids" do
    assert {:error, :invalid_event_id} =
             EventSnapshotAffectedEvents.resolve(snapshot(["not-a-uuid"]), snapshot([]))
  end

  test "rejects malformed explicit event ids" do
    assert {:error, :invalid_event_id} =
             EventSnapshotAffectedEvents.resolve(nil, snapshot([]), ["not-a-uuid"])
  end

  test "does not include an unresolved source event candidate by itself" do
    source_event_id = 123
    order_snapshot = %{order_items: [%{event_id: nil, source_tickera_event_id: source_event_id}]}

    assert {:ok, []} = EventSnapshotAffectedEvents.resolve(nil, order_snapshot)
  end

  defp snapshot(event_ids) do
    %{order_items: Enum.map(event_ids, &%{event_id: &1})}
  end
end
