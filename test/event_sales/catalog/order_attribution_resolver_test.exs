defmodule EventSales.Catalog.OrderAttributionResolverTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog
  alias EventSales.Catalog.OrderAttributionResolver
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.TestSupport.SalesHelpers

  setup do
    source = SalesHelpers.create_source_system!()

    wr_event =
      SalesHelpers.create_event!(source, %{
        name: "Lynette Beer LIVE - WR",
        external_event_id: 109_120,
        external_event_kind: :tickera_event
      })

    wr_ticket =
      SalesHelpers.create_ticket_type!(wr_event, %{
        name: "WR General",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 109_167,
        external_product_id: 109_132,
        external_variation_id: 109_167
      })

    {:ok, source: source, wr_event: wr_event, wr_ticket: wr_ticket}
  end

  test "maps by source Tickera event id then variation ticket type under that event", %{
    source: source,
    wr_event: wr_event,
    wr_ticket: wr_ticket
  } do
    create_mapping!(source, wr_event, wr_ticket, %{
      woo_product_id: 109_132,
      woo_variation_id: 109_167
    })

    assert {:ok, result} =
             OrderAttributionResolver.resolve(source.id, 109_120, 109_132, 109_167)

    assert result.status == :mapped
    assert result.event_id == wr_event.id
    assert result.ticket_type_id == wr_ticket.id
    assert result.source_tickera_event_id == 109_120
    assert result.attribution_status_reason == nil
  end

  test "maps product-level ticket type and mapping when variation is nil", %{
    source: source,
    wr_event: wr_event
  } do
    wr_product_ticket =
      SalesHelpers.create_ticket_type!(wr_event, %{
        name: "WR Product General",
        external_ticket_type_kind: :woo_product,
        external_ticket_type_id: 109_132,
        external_product_id: 109_132,
        external_variation_id: nil
      })

    create_mapping!(source, wr_event, wr_product_ticket, %{
      woo_product_id: 109_132,
      woo_variation_id: nil
    })

    assert {:ok, result} =
             OrderAttributionResolver.resolve(source.id, 109_120, 109_132, nil)

    assert result.status == :mapped
    assert result.event_id == wr_event.id
    assert result.ticket_type_id == wr_product_ticket.id
    assert result.source_tickera_event_id == 109_120
    assert result.attribution_status_reason == nil
  end

  test "stale active ProductMapping does not override event-first attribution", %{
    source: source,
    wr_event: wr_event,
    wr_ticket: wr_ticket
  } do
    mp_event =
      SalesHelpers.create_event!(source, %{
        name: "Lynette Beer LIVE - MP",
        external_event_id: 108_658,
        external_event_kind: :tickera_event
      })

    mp_ticket = SalesHelpers.create_ticket_type!(mp_event, %{name: "MP General"})

    create_mapping!(source, mp_event, mp_ticket, %{
      woo_product_id: 109_132,
      woo_variation_id: 109_167
    })

    assert {:ok, result} =
             OrderAttributionResolver.resolve(source.id, 109_120, 109_132, 109_167)

    assert result.status == :mapped
    assert result.event_id == wr_event.id
    assert result.ticket_type_id == wr_ticket.id
    assert result.attribution_status_reason == :order_event_mapping_conflict
  end

  test "maps with missing product mapping review reason when Event and TicketType exist", %{
    source: source,
    wr_event: wr_event,
    wr_ticket: wr_ticket
  } do
    assert {:ok, result} =
             OrderAttributionResolver.resolve(source.id, 109_120, 109_132, 109_167)

    assert result.status == :mapped
    assert result.event_id == wr_event.id
    assert result.ticket_type_id == wr_ticket.id
    assert result.attribution_status_reason == :missing_product_mapping
  end

  test "missing source event remains pending", %{source: source} do
    assert {:ok, result} =
             OrderAttributionResolver.resolve(source.id, 999_999, 109_132, 109_167)

    assert result.status == :pending
    assert result.event_id == nil
    assert result.ticket_type_id == nil
    assert result.source_tickera_event_id == 999_999
    assert result.attribution_status_reason == :source_event_not_found
  end

  test "missing ticket type under source event remains pending", %{source: source} do
    SalesHelpers.create_event!(source, %{
      name: "No Ticket Event",
      external_event_id: 999_001,
      external_event_kind: :tickera_event
    })

    assert {:ok, result} =
             OrderAttributionResolver.resolve(source.id, 999_001, 109_132, 109_167)

    assert result.status == :pending
    assert result.attribution_status_reason == :source_ticket_type_not_found
  end

  defp create_mapping!(source, event, ticket, attrs) do
    defaults = %{
      source_system_id: source.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_product_id: 1,
      woo_variation_id: nil,
      original_label: "Ticket",
      current_label: "Ticket",
      active: true
    }

    Ash.create!(ProductMapping, Map.merge(defaults, attrs), action: :create, domain: Catalog)
  end
end
