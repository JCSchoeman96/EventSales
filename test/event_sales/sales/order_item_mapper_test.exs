defmodule EventSales.Sales.OrderItemMapperTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Sales
  alias EventSales.Sales.OrderItemMapper
  alias EventSales.Sales.Resources.OrderItem
  alias EventSales.TestSupport.FixtureHelpers
  alias EventSales.TestSupport.SalesHelpers

  setup do
    source = SalesHelpers.create_source_system!()
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    event = SalesHelpers.create_event!(source, %{name: "Mapped Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "General Admission"})

    {:ok, source: source, order: order, event: event, ticket: ticket}
  end

  test "pending item with product mapping becomes mapped ticket", %{
    source: source,
    order: order,
    event: event,
    ticket: ticket
  } do
    create_mapping!(source, event, ticket, %{woo_product_id: 501})
    item = create_item!(order, %{woo_product_id: 501, woo_variation_id: nil})

    assert {:ok, mapped} = OrderItemMapper.map_item(item)

    assert mapped.mapping_status == :mapped
    assert mapped.item_kind == :ticket
    assert mapped.event_id == event.id
    assert mapped.ticket_type_id == ticket.id
  end

  test "pending variation item uses variation-specific mapping", %{
    source: source,
    order: order,
    event: event,
    ticket: ticket
  } do
    product_event = SalesHelpers.create_event!(source, %{name: "Product Event"})
    product_ticket = SalesHelpers.create_ticket_type!(product_event, %{name: "GA"})
    create_mapping!(source, product_event, product_ticket, %{woo_product_id: 501})
    create_mapping!(source, event, ticket, %{woo_product_id: 501, woo_variation_id: 601})

    item = create_item!(order, %{woo_product_id: 501, woo_variation_id: 601})

    assert {:ok, mapped} = OrderItemMapper.map_item(item)

    assert mapped.mapping_status == :mapped
    assert mapped.event_id == event.id
    assert mapped.ticket_type_id == ticket.id
  end

  test "unknown item remains pending mapping resolution", %{order: order} do
    item = create_item!(order, %{woo_product_id: 999_999, woo_variation_id: nil})

    assert {:ok, unchanged} = OrderItemMapper.map_item(item)

    assert unchanged.id == item.id
    assert unchanged.mapping_status == :pending_mapping_resolution
    assert unchanged.event_id == nil
    assert unchanged.ticket_type_id == nil
  end

  test "normal order mapping only mutates pending rows", %{
    source: source,
    order: order,
    event: event,
    ticket: ticket
  } do
    create_mapping!(source, event, ticket, %{woo_product_id: 501})
    pending = create_item!(order, %{woo_line_item_id: 80_001, woo_product_id: 501})
    mapped = mapped_item!(order, %{woo_line_item_id: 80_002})
    non_ticket = non_ticket_item!(order, %{woo_line_item_id: 80_003})
    ignored = ignored_item!(order, %{woo_line_item_id: 80_004})
    unmapped = unmapped_item!(order, %{woo_line_item_id: 80_005})

    assert {:ok, results} = OrderItemMapper.map_pending_items_for_order(order)

    assert Enum.map(results, & &1.id) == [pending.id]
    assert Ash.get!(OrderItem, pending.id, domain: Sales).mapping_status == :mapped
    assert Ash.get!(OrderItem, mapped.id, domain: Sales).mapping_status == :mapped
    assert Ash.get!(OrderItem, non_ticket.id, domain: Sales).mapping_status == :non_ticket
    assert Ash.get!(OrderItem, ignored.id, domain: Sales).mapping_status == :ignored
    assert Ash.get!(OrderItem, unmapped.id, domain: Sales).mapping_status == :unmapped
  end

  test "queue query includes pending and unmapped rows only", %{order: order} do
    pending = create_item!(order, %{woo_line_item_id: 81_001})
    unmapped = unmapped_item!(order, %{woo_line_item_id: 81_002})
    mapped_item!(order, %{woo_line_item_id: 81_003})
    non_ticket_item!(order, %{woo_line_item_id: 81_004})
    ignored_item!(order, %{woo_line_item_id: 81_005})

    assert {:ok, queue_items} = OrderItemMapper.list_unmapped_queue()

    queue_ids = MapSet.new(queue_items, & &1.id)
    assert MapSet.member?(queue_ids, pending.id)
    assert MapSet.member?(queue_ids, unmapped.id)
    assert MapSet.size(queue_ids) == 2
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

  defp mapped_item!(order, attrs) do
    source = Ash.load!(order, :source_system, domain: Sales).source_system
    event = SalesHelpers.create_event!(source, %{name: "Already Mapped #{unique_id()}"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Ticket #{unique_id()}"})

    create_item!(
      order,
      Map.merge(
        %{
          event_id: event.id,
          ticket_type_id: ticket.id,
          mapping_status: :mapped,
          item_kind: :ticket
        },
        attrs
      )
    )
  end

  defp non_ticket_item!(order, attrs) do
    order
    |> create_item!(attrs)
    |> Ash.update!(%{}, action: :mark_non_ticket, domain: Sales)
  end

  defp ignored_item!(order, attrs) do
    order
    |> create_item!(attrs)
    |> Ash.update!(%{}, action: :mark_ignored, domain: Sales)
  end

  defp unmapped_item!(order, attrs) do
    order
    |> create_item!(attrs)
    |> Ash.update!(%{}, action: :mark_unmapped, domain: Sales)
  end

  defp create_item!(order, attrs) do
    line =
      :woocommerce
      |> FixtureHelpers.decode_json_fixture!(:order_completed)
      |> Map.fetch!("line_items")
      |> hd()

    defaults = %{
      woo_line_item_id: unique_id(),
      woo_product_id: line["product_id"],
      woo_variation_id: line["variation_id"],
      name: line["name"],
      quantity: line["quantity"],
      line_subtotal: Decimal.new(line["subtotal"]),
      line_total: Decimal.new(line["total"]),
      discount_total: Decimal.new("0"),
      item_kind: :unknown,
      mapping_status: :pending_mapping_resolution
    }

    SalesHelpers.create_order_item_from_line!(order, line, Map.merge(defaults, attrs))
  end

  defp unique_id, do: System.unique_integer([:positive])
end
