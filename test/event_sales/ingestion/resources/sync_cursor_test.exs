defmodule EventSales.Ingestion.Resources.SyncCursorTest do
  use EventSales.DataCase, async: true

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.TestSupport.SalesHelpers

  @off_peak ~U[2026-05-16 12:00:00.000000Z]

  test ":upsert_active persists cursor fields for a sync run" do
    run = create_manual_run!()

    assert {:ok, cursor} =
             SyncCursor
             |> Ash.Changeset.for_create(:upsert_active, %{
               sync_run_id: run.id,
               page: 2,
               modified_after: ~U[2026-05-01 00:00:00Z],
               modified_before: ~U[2026-05-02 00:00:00Z],
               last_seen_order_id: 12_345,
               metadata: %{"step" => "page"}
             })
             |> Ash.create(domain: Ingestion)

    assert cursor.sync_run_id == run.id
    assert cursor.page == 2
    assert DateTime.compare(cursor.modified_after, ~U[2026-05-01 00:00:00Z]) == :eq
    assert DateTime.compare(cursor.modified_before, ~U[2026-05-02 00:00:00Z]) == :eq
    assert cursor.last_seen_order_id == 12_345
    assert cursor.status == :active
    assert cursor.metadata == %{"step" => "page"}
  end

  test ":upsert_active updates the same run cursor without creating a second row" do
    run = create_manual_run!()

    assert {:ok, _} =
             upsert_active!(run.id, %{page: 1, last_seen_order_id: 100})

    assert {:ok, updated} =
             upsert_active!(run.id, %{page: 3, last_seen_order_id: 300})

    assert updated.page == 3
    assert updated.last_seen_order_id == 300
    assert Ash.count!(SyncCursor, domain: Ingestion) == 1
  end

  test "a second sync run does not read the first run's cursor" do
    first_run = create_manual_run!()
    second_run = create_manual_run!()

    assert {:ok, first_cursor} =
             upsert_active!(first_run.id, %{page: 4, last_seen_order_id: 9001})

    assert {:ok, second_cursor} =
             upsert_active!(second_run.id, %{page: 1, last_seen_order_id: nil})

    assert first_cursor.sync_run_id == first_run.id
    assert second_cursor.sync_run_id == second_run.id
    assert second_cursor.page == 1
    refute second_cursor.id == first_cursor.id
  end

  test ":mark_done and :mark_failed transition cursor status" do
    run = create_manual_run!()
    {:ok, cursor} = upsert_active!(run.id, %{page: 1})

    assert {:ok, done} =
             Ash.update(cursor, %{last_seen_order_id: 42}, action: :mark_done, domain: Ingestion)

    assert done.status == :done
    assert done.last_seen_order_id == 42

    {:ok, cursor} = upsert_active!(run.id, %{page: 2})

    assert {:ok, failed} =
             Ash.update(cursor, %{metadata: %{"error" => "boom"}},
               action: :mark_failed,
               domain: Ingestion
             )

    assert failed.status == :failed
  end

  defp upsert_active!(sync_run_id, attrs) do
    payload =
      Map.merge(
        %{
          sync_run_id: sync_run_id,
          page: 1,
          modified_after: ~U[2026-05-01 00:00:00Z],
          modified_before: ~U[2026-05-02 00:00:00Z],
          metadata: %{}
        },
        attrs
      )

    SyncCursor
    |> Ash.Changeset.for_create(:upsert_active, payload)
    |> Ash.create(domain: Ingestion)
  end

  defp create_manual_run! do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Cursor", slug: unique_slug("cursor")})

    {:ok, run} =
      SyncRun
      |> Ash.Changeset.for_create(:queue_manual_scoped, %{
        source_system_id: source.id,
        event_id: event.id,
        date_from: ~U[2026-05-01 00:00:00Z],
        date_to: ~U[2026-05-02 00:00:00Z],
        sync_mode: :shallow,
        requested_via: :manual
      })
      |> Ash.create(domain: Ingestion, context: %{scoped_manual_sync_now: @off_peak})

    run
  end

  defp unique_slug(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
