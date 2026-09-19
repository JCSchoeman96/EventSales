defmodule EventSales.Ingestion.Resources.HistoricalRefundObservationTest do
  use EventSales.DataCase, async: true

  alias EventSales.Catalog
  alias EventSales.Ingestion

  alias EventSales.Ingestion.Resources.{
    HistoricalOrderMembership,
    HistoricalRefundObservation,
    HistoricalRefundReference,
    SyncRun
  }

  alias EventSales.TestSupport.SalesHelpers

  @created_at ~U[2026-08-04 10:00:00.000000Z]

  test "manifest observation is one per membership and catch-up is monotonic" do
    membership = membership!()

    attrs = %{
      historical_order_membership_id: membership.id,
      reference_count: 0,
      observed_at: @created_at
    }

    assert {:ok, first} =
             Ash.create(HistoricalRefundObservation, attrs,
               action: :resolve_manifest,
               domain: Ingestion
             )

    assert first.resolution_state == :manifest_resolved

    assert {:ok, replay} =
             Ash.create(HistoricalRefundObservation, %{attrs | reference_count: 1},
               action: :resolve_manifest,
               domain: Ingestion
             )

    assert replay.id == first.id
    assert replay.reference_count == 1

    assert {:ok, resolved} =
             Ash.update(replay, %{reference_count: 1},
               action: :resolve_catchup,
               domain: Ingestion
             )

    assert resolved.resolution_state == :catchup_resolved
  end

  test "references are unique, replay-safe, and can be confirmed absent" do
    membership = membership!()

    {:ok, observation} =
      Ash.create(
        HistoricalRefundObservation,
        %{
          historical_order_membership_id: membership.id,
          reference_count: 1,
          observed_at: @created_at
        },
        action: :resolve_manifest,
        domain: Ingestion
      )

    attrs = %{historical_refund_observation_id: observation.id, woo_refund_id: 91_001}

    assert {:ok, present} =
             Ash.create(HistoricalRefundReference, attrs,
               action: :observe_present,
               domain: Ingestion
             )

    assert present.source_state == :present

    assert {:ok, replay} =
             Ash.create(HistoricalRefundReference, attrs,
               action: :observe_present,
               domain: Ingestion
             )

    assert replay.id == present.id

    assert {:ok, absent} =
             Ash.update(replay, %{}, action: :confirm_absent, domain: Ingestion)

    assert absent.source_state == :absent_confirmed
  end

  defp membership! do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        external_event_id: System.unique_integer([:positive]),
        external_event_kind: :tickera_event
      })

    event =
      Ash.update!(event, %{source_created_at: @created_at},
        action: :capture_source_created_at,
        domain: Catalog,
        context: %{
          event_sales_backfill_start_capture_authority: {Catalog.Resources.Event, :verified}
        }
      )

    event = Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)

    run =
      SyncRun
      |> Ash.Changeset.for_create(:queue_historical_backfill, %{
        event_id: event.id,
        date_to: ~U[2026-08-09 23:59:59.999999Z]
      })
      |> Ash.Changeset.force_change_attribute(:source_system_id, source.id)
      |> Ash.Changeset.force_change_attribute(:date_from, @created_at)
      |> Ash.create!(domain: Ingestion)

    Ash.create!(
      HistoricalOrderMembership,
      %{
        sync_run_id: run.id,
        source_order_id: System.unique_integer([:positive]),
        manifest_source_created_at: @created_at,
        manifest_source_modified_at: @created_at,
        last_source_modified_at: @created_at
      },
      action: :resolve_manifest,
      domain: Ingestion
    )
  end
end
