defmodule EventSales.Catalog.EventOnboardingInvalidationTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, ProductMapping, TicketType}
  alias EventSales.TestSupport.SalesHelpers

  test "structural ProductMapping deactivation invalidates a pending Event" do
    %{mapping: mapping, event: event} = mapping_fixture!(80_001)

    pending = Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)

    Ash.update!(mapping, %{}, action: :deactivate, domain: Catalog)

    reloaded = Ash.get!(Event, pending.id, domain: Catalog)
    assert reloaded.analytics_onboarding_state == :unverified
  end

  test "structural ProductMapping creation invalidates a pending Event" do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{status: :active})
    ticket = ticket_fixture!(event, 80_012)
    Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)

    Ash.create!(
      ProductMapping,
      %{
        source_system_id: source.id,
        event_id: event.id,
        ticket_type_id: ticket.id,
        woo_product_id: 80_012,
        woo_variation_id: nil,
        original_label: "Ticket",
        current_label: "Ticket",
        active: true
      },
      action: :create,
      domain: Catalog
    )

    assert Ash.get!(Event, event.id, domain: Catalog).analytics_onboarding_state == :unverified
  end

  test "structural ProductMapping update invalidates a pending Event" do
    %{event: event, mapping: mapping} = mapping_fixture!(80_013)
    replacement_ticket = ticket_fixture!(event, 80_014)
    Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)

    Ash.update!(
      mapping,
      %{
        ticket_type_id: replacement_ticket.id,
        woo_product_id: 80_014,
        original_label: "Replacement",
        current_label: "Replacement"
      },
      action: :update,
      domain: Catalog
    )

    assert Ash.get!(Event, event.id, domain: Catalog).analytics_onboarding_state == :unverified
  end

  test "ProductMapping remap invalidates both old and new Events" do
    source = SalesHelpers.create_source_system!()
    old_event = SalesHelpers.create_event!(source, %{name: "Old Event"})
    new_event = SalesHelpers.create_event!(source, %{name: "New Event"})
    old_ticket = ticket_fixture!(old_event, 80_002)
    new_ticket = ticket_fixture!(new_event, 80_003)

    mapping = mapping_fixture!(source, old_event, old_ticket, 80_002)
    Ash.update!(old_event, %{}, action: :mark_backfill_pending, domain: Catalog)
    Ash.update!(new_event, %{}, action: :mark_backfill_pending, domain: Catalog)

    Ash.update!(
      mapping,
      %{
        event_id: new_event.id,
        ticket_type_id: new_ticket.id,
        woo_product_id: 80_003,
        original_label: "New",
        current_label: "New"
      },
      action: :remap,
      domain: Catalog
    )

    assert Ash.get!(Event, old_event.id, domain: Catalog).analytics_onboarding_state ==
             :unverified

    assert Ash.get!(Event, new_event.id, domain: Catalog).analytics_onboarding_state ==
             :unverified
  end

  test "label-only ProductMapping changes do not invalidate onboarding" do
    %{mapping: mapping, event: event} = mapping_fixture!(80_004)
    Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)

    Ash.update!(mapping, %{current_label: "Renamed"}, action: :update, domain: Catalog)

    assert Ash.get!(Event, event.id, domain: Catalog).analytics_onboarding_state ==
             :backfill_pending
  end

  test "a failed ProductMapping write does not invalidate onboarding" do
    %{mapping: mapping, event: event} = mapping_fixture!(80_005)
    Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)

    assert_raise Ash.Error.Invalid, fn ->
      Ash.update!(mapping, %{woo_product_id: 80_006}, action: :update, domain: Catalog)
    end

    assert Ash.get!(Event, event.id, domain: Catalog).analytics_onboarding_state ==
             :backfill_pending
  end

  test "mapped TicketType structural identity changes invalidate onboarding" do
    %{ticket: ticket, event: event} = mapping_fixture!(80_007)
    Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)

    Ash.update!(ticket, %{external_ticket_type_id: 80_008}, action: :update, domain: Catalog)

    assert Ash.get!(Event, event.id, domain: Catalog).analytics_onboarding_state == :unverified
  end

  test "TicketType name and capacity changes do not invalidate onboarding" do
    %{ticket: ticket, event: event} = mapping_fixture!(80_009)
    Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)

    Ash.update!(ticket, %{name: "Renamed", capacity: 99}, action: :update, domain: Catalog)

    assert Ash.get!(Event, event.id, domain: Catalog).analytics_onboarding_state ==
             :backfill_pending
  end

  test "Event external identity changes invalidate onboarding" do
    event =
      SalesHelpers.create_event!(SalesHelpers.create_source_system!(), %{
        external_event_id: 80_010
      })

    pending = Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)

    Ash.update!(pending, %{external_event_id: 80_011}, action: :update, domain: Catalog)

    assert Ash.get!(Event, event.id, domain: Catalog).analytics_onboarding_state == :unverified
  end

  test "Event business archive remains independent from onboarding state" do
    event = SalesHelpers.create_event!(SalesHelpers.create_source_system!(), %{status: :active})
    pending = Ash.update!(event, %{}, action: :mark_backfill_pending, domain: Catalog)

    archived = Ash.update!(pending, %{}, action: :archive, domain: Catalog)

    assert archived.status == :archived
    assert archived.analytics_onboarding_state == :backfill_pending
  end

  defp mapping_fixture!(woo_product_id) when is_integer(woo_product_id) do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{status: :active})
    ticket = ticket_fixture!(event, woo_product_id)
    mapping = mapping_fixture!(source, event, ticket, woo_product_id)
    %{source: source, event: event, ticket: ticket, mapping: mapping}
  end

  defp mapping_fixture!(source, event, ticket, woo_product_id) do
    Ash.create!(
      ProductMapping,
      %{
        source_system_id: source.id,
        event_id: event.id,
        ticket_type_id: ticket.id,
        woo_product_id: woo_product_id,
        woo_variation_id: nil,
        original_label: "Ticket",
        current_label: "Ticket",
        active: true
      },
      action: :create,
      domain: Catalog
    )
  end

  defp ticket_fixture!(event, woo_product_id) do
    Ash.create!(
      TicketType,
      %{
        event_id: event.id,
        name: "Ticket #{woo_product_id}",
        active: true,
        external_ticket_type_kind: :woo_product,
        external_ticket_type_id: woo_product_id,
        external_product_id: woo_product_id
      },
      action: :create,
      domain: Catalog
    )
  end
end
