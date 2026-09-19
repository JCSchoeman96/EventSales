defmodule EventSales.Ingestion.Resources.HistoricalOrderMembershipTest do
  use EventSales.DataCase, async: true

  alias EventSales.Catalog
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{HistoricalOrderMembership, SyncRun}
  alias EventSales.TestSupport.SalesHelpers

  @created_at ~U[2026-08-04 10:00:00.000000Z]
  @manifest_modified_at ~U[2026-08-04 10:05:00.000000Z]
  @latest_modified_at ~U[2026-08-14 10:05:00.000000Z]

  test "manifest resolution stores one exact run-scoped identity and replays safely" do
    run = historical_run!()

    attrs = %{
      sync_run_id: run.id,
      source_order_id: 42,
      manifest_source_created_at: @created_at,
      manifest_source_modified_at: @manifest_modified_at,
      last_source_modified_at: @manifest_modified_at
    }

    assert {:ok, first} =
             Ash.create(HistoricalOrderMembership, attrs,
               action: :resolve_manifest,
               domain: Ingestion
             )

    assert first.resolution_state == :manifest_resolved
    assert first.source_order_id == 42

    assert {:ok, replay} =
             Ash.create(
               HistoricalOrderMembership,
               %{attrs | last_source_modified_at: @latest_modified_at},
               action: :resolve_manifest,
               domain: Ingestion
             )

    assert replay.id == first.id
    assert replay.resolution_state == :manifest_resolved
    assert replay.last_source_modified_at == @latest_modified_at
    assert Ash.count!(HistoricalOrderMembership, domain: Ingestion) == 1
  end

  test "catch-up resolution can refresh a manifest member and replay in place" do
    run = historical_run!()

    {:ok, member} =
      Ash.create(
        HistoricalOrderMembership,
        %{
          sync_run_id: run.id,
          source_order_id: 42,
          manifest_source_created_at: @created_at,
          manifest_source_modified_at: @manifest_modified_at,
          last_source_modified_at: @manifest_modified_at
        },
        action: :resolve_manifest,
        domain: Ingestion
      )

    assert {:ok, resolved} =
             Ash.update(member, %{last_source_modified_at: @latest_modified_at},
               action: :resolve_catchup,
               domain: Ingestion
             )

    assert resolved.resolution_state == :catchup_resolved
    assert resolved.manifest_source_created_at == @created_at
    assert resolved.manifest_source_modified_at == @manifest_modified_at
    assert resolved.last_source_modified_at == @latest_modified_at

    assert {:ok, replay} =
             Ash.update(resolved, %{last_source_modified_at: @latest_modified_at},
               action: :resolve_catchup,
               domain: Ingestion
             )

    assert replay.id == member.id
    assert replay.resolution_state == :catchup_resolved
  end

  defp historical_run! do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        external_event_id: 805_042,
        external_event_kind: :tickera_event
      })

    event =
      Ash.update!(
        event,
        %{source_created_at: @created_at},
        action: :capture_source_created_at,
        domain: Catalog,
        context: %{
          event_sales_backfill_start_capture_authority:
            {EventSales.Catalog.Resources.Event, :verified}
        }
      )

    event = Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)

    SyncRun
    |> Ash.Changeset.for_create(:queue_historical_backfill, %{
      event_id: event.id,
      date_to: ~U[2026-08-09 23:59:59.999999Z]
    })
    |> Ash.Changeset.force_change_attribute(:source_system_id, source.id)
    |> Ash.Changeset.force_change_attribute(:date_from, @created_at)
    |> Ash.create!(domain: Ingestion)
  end
end
