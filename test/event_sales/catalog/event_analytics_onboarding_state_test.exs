defmodule EventSales.Catalog.EventAnalyticsOnboardingStateTest do
  use EventSales.DataCase, async: true

  alias EventSales.Catalog
  alias EventSales.Catalog.EventImporter
  alias EventSales.Catalog.Resources.{Event, ProductMapping}
  alias EventSales.TestSupport.SalesHelpers

  test "new Events default to unverified" do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{status: :draft})

    assert event.status == :draft
    assert Map.get(event, :analytics_onboarding_state) == :unverified
  end

  test "active business status is independent from onboarding state" do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{status: :active})

    assert event.status == :active
    assert Map.get(event, :analytics_onboarding_state) == :unverified
  end

  test "mark_backfill_pending transitions unverified Events" do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{})

    transitioned =
      Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)

    assert Map.get(transitioned, :analytics_onboarding_state) == :backfill_pending
  end

  test "invalidate_onboarding transitions backfill-pending Events to unverified" do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{})

    pending = Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)

    invalidated =
      Ash.update!(pending, %{}, action: :invalidate_onboarding, domain: Catalog)

    assert Map.get(invalidated, :analytics_onboarding_state) == :unverified
  end

  test "mark_backfill_pending rejects an already pending Event" do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{})
    pending = Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)

    assert {:error, _error} =
             Ash.update(pending, %{}, action: :mark_backfill_pending, domain: Catalog)
  end

  test "invalidate_onboarding rejects an unverified Event" do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{})

    assert {:error, _error} =
             Ash.update(event, %{}, action: :invalidate_onboarding, domain: Catalog)
  end

  test "generic Event updates cannot set onboarding state" do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{})

    assert {:error, _error} =
             Ash.update(
               event,
               %{analytics_onboarding_state: :backfill_pending},
               action: :update,
               domain: Catalog
             )
  end

  test "generic Event creates cannot set onboarding state" do
    source = SalesHelpers.create_source_system!()

    assert {:error, _error} =
             Ash.create(
               Event,
               %{
                 source_system_id: source.id,
                 name: "Protected Create",
                 slug: "protected-create",
                 analytics_onboarding_state: :backfill_pending
               },
               action: :create,
               domain: Catalog
             )
  end

  test "archiving an Event preserves onboarding state" do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{})

    pending = Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)
    archived = Ash.update!(pending, %{}, action: :archive, domain: Catalog)

    assert archived.status == :archived
    assert Map.get(archived, :analytics_onboarding_state) == :backfill_pending
  end

  test "EventImporter-created Events default to unverified" do
    source = SalesHelpers.create_source_system!()

    assert {:ok, %{event: event, outcome: :created}} =
             EventImporter.import_tickera_event(source.id, %{
               external_event_id: 70_007,
               name: "Imported Event",
               slug: "imported-event"
             })

    assert Map.get(event, :analytics_onboarding_state) == :unverified
  end

  test "active catalog-created Events default to unverified" do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{status: :active})

    assert event.status == :active
    assert Map.get(event, :analytics_onboarding_state) == :unverified
  end

  test "valid TicketTypes and ProductMappings do not certify an Event" do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{})

    ticket = SalesHelpers.create_variation_ticket_type!(event, 80_000, 80_001)

    mapping =
      Ash.create!(
        ProductMapping,
        %{
          source_system_id: source.id,
          event_id: event.id,
          ticket_type_id: ticket.id,
          woo_product_id: 80_000,
          woo_variation_id: 80_001,
          original_label: "Variation Ticket",
          current_label: "Variation Ticket",
          active: true
        },
        action: :create,
        domain: Catalog
      )

    assert mapping.event_id == event.id

    persisted_event = Ash.get!(Event, event.id, domain: Catalog)
    assert Map.get(persisted_event, :analytics_onboarding_state) == :unverified
  end
end
