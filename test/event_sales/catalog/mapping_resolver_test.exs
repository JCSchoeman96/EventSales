defmodule EventSales.Catalog.MappingResolverTest do
  use EventSales.DataCase, async: true

  alias EventSales.Catalog
  alias EventSales.Catalog.MappingResolver
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.TestSupport.SalesHelpers

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Mapped Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "General Admission"})

    {:ok, source: source, event: event, ticket: ticket}
  end

  test "product-only mapping resolves", %{source: source, event: event, ticket: ticket} do
    mapping = create_mapping!(source, event, ticket, %{woo_product_id: 501})

    assert {:ok, {:mapped, resolved}} = MappingResolver.resolve(source.id, 501, nil)
    assert resolved.id == mapping.id
  end

  test "product and variation mapping resolves", %{source: source, event: event} do
    ticket =
      SalesHelpers.create_ticket_type!(event, %{
        name: "Variation Admission",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 601,
        external_product_id: 501,
        external_variation_id: 601
      })

    mapping =
      create_mapping!(source, event, ticket, %{woo_product_id: 501, woo_variation_id: 601})

    assert {:ok, {:mapped, resolved}} = MappingResolver.resolve(source.id, 501, 601)
    assert resolved.id == mapping.id
  end

  test "variation-specific mapping wins over product-level mapping", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    product_mapping = create_mapping!(source, event, ticket, %{woo_product_id: 501})

    variation_event = SalesHelpers.create_event!(source, %{name: "Variation Event"})

    variation_ticket =
      SalesHelpers.create_ticket_type!(variation_event, %{
        name: "VIP",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 601,
        external_product_id: 501,
        external_variation_id: 601
      })

    variation_mapping =
      create_mapping!(source, variation_event, variation_ticket, %{
        woo_product_id: 501,
        woo_variation_id: 601
      })

    assert {:ok, {:mapped, resolved}} = MappingResolver.resolve(source.id, 501, 601)
    assert resolved.id == variation_mapping.id
    refute resolved.id == product_mapping.id
  end

  test "variation falls back to product-level mapping when exact variation is absent", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    mapping = create_mapping!(source, event, ticket, %{woo_product_id: 501})

    assert {:ok, {:mapped, resolved}} = MappingResolver.resolve(source.id, 501, 999)
    assert resolved.id == mapping.id
  end

  test "nil variation checks product-level mapping only", %{
    source: source,
    event: event
  } do
    ticket =
      SalesHelpers.create_ticket_type!(event, %{
        name: "Variation Only",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 601,
        external_product_id: 501,
        external_variation_id: 601
      })

    create_mapping!(source, event, ticket, %{woo_product_id: 501, woo_variation_id: 601})

    assert {:ok, :pending_mapping_resolution} = MappingResolver.resolve(source.id, 501, nil)
  end

  test "inactive mappings are ignored", %{source: source, event: event, ticket: ticket} do
    create_mapping!(source, event, ticket, %{woo_product_id: 501, active: false})

    assert {:ok, :pending_mapping_resolution} = MappingResolver.resolve(source.id, 501, nil)
  end

  test "unknown product remains pending mapping resolution", %{source: source} do
    assert {:ok, :pending_mapping_resolution} = MappingResolver.resolve(source.id, 999_999, nil)
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
