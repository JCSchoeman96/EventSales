defmodule EventSales.Catalog.MissingCatalogResolverTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.MissingCatalogResolver
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Sales
  alias EventSales.Sales.Resources.OrderItem
  alias EventSales.TestSupport.FixtureHelpers
  alias EventSales.TestSupport.SalesHelpers

  setup do
    source = SalesHelpers.create_source_system!()
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    event = SalesHelpers.create_event!(source, %{name: "Recovered Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Recovered Ticket"})

    {:ok, source: source, order: order, event: event, ticket: ticket}
  end

  test "maps affected pending rows when a local mapping now exists", %{
    source: source,
    order: order,
    event: event
  } do
    item = create_item!(order, %{woo_product_id: 501, woo_variation_id: 601})
    other = create_item!(order, %{woo_line_item_id: 99_002, woo_product_id: 777})

    ticket =
      SalesHelpers.create_variation_ticket_type!(event, 501, 601, %{
        name: "Recovered Variation"
      })

    create_mapping!(source, event, ticket, %{woo_product_id: 501, woo_variation_id: 601})

    assert {:ok, %{mapped: 1, marked_unmapped: 0, unchanged: 0}} =
             MissingCatalogResolver.recover_product(source.id, 501, 601)

    assert Ash.get!(OrderItem, item.id, domain: Sales).mapping_status == :mapped
    assert Ash.get!(OrderItem, item.id, domain: Sales).event_id == event.id

    assert Ash.get!(OrderItem, other.id, domain: Sales).mapping_status ==
             :pending_mapping_resolution
  end

  test "leaves on-hold rows pending when a local mapping exists", %{
    source: source,
    order: order,
    event: event
  } do
    on_hold_order = put_order_on_hold!(order)
    item = create_item!(on_hold_order, %{woo_product_id: 501, woo_variation_id: 601})

    ticket =
      SalesHelpers.create_variation_ticket_type!(event, 501, 601, %{
        name: "Recovered Variation"
      })

    create_mapping!(source, event, ticket, %{woo_product_id: 501, woo_variation_id: 601})

    assert {:ok, %{mapped: 0, marked_unmapped: 0, unchanged: 1}} =
             MissingCatalogResolver.recover_product(source.id, 501, 601)

    persisted = Ash.get!(OrderItem, item.id, domain: Sales)
    assert persisted.mapping_status == :pending_mapping_resolution
    assert persisted.event_id == nil
    assert persisted.ticket_type_id == nil
  end

  test "does not mark an unresolved on-hold row unmapped", %{source: source, order: order} do
    on_hold_order = put_order_on_hold!(order)
    item = create_item!(on_hold_order, %{woo_product_id: 999_999, woo_variation_id: nil})

    assert {:ok, %{mapped: 0, marked_unmapped: 0, unchanged: 1}} =
             MissingCatalogResolver.recover_product(source.id, 999_999, nil)

    assert Ash.get!(OrderItem, item.id, domain: Sales).mapping_status ==
             :pending_mapping_resolution
  end

  test "maps pending rows for cancelled orders", %{
    source: source,
    order: order,
    event: event
  } do
    cancelled_order = put_order_status!(order, :cancelled)
    item = create_item!(cancelled_order, %{woo_product_id: 501, woo_variation_id: 601})

    ticket =
      SalesHelpers.create_variation_ticket_type!(event, 501, 601, %{
        name: "Recovered Variation"
      })

    create_mapping!(source, event, ticket, %{woo_product_id: 501, woo_variation_id: 601})

    assert {:ok, %{mapped: 1, marked_unmapped: 0, unchanged: 0}} =
             MissingCatalogResolver.recover_product(source.id, 501, 601)

    assert Ash.get!(OrderItem, item.id, domain: Sales).mapping_status == :mapped
  end

  test "marks matching still-pending rows unmapped and is duplicate safe", %{
    source: source,
    order: order
  } do
    item = create_item!(order, %{woo_product_id: 999_999, woo_variation_id: nil})

    assert {:ok, %{mapped: 0, marked_unmapped: 1, unchanged: 0}} =
             MissingCatalogResolver.recover_product(source.id, 999_999, nil)

    assert {:ok, %{mapped: 0, marked_unmapped: 0, unchanged: 0}} =
             MissingCatalogResolver.recover_product(source.id, 999_999, nil)

    assert Ash.get!(OrderItem, item.id, domain: Sales).mapping_status == :unmapped
  end

  test "leaves non-pending rows unchanged", %{source: source, order: order} do
    mapped = mapped_item!(source, order, %{woo_line_item_id: 91_001, woo_product_id: 501})
    non_ticket = non_ticket_item!(order, %{woo_line_item_id: 91_002, woo_product_id: 501})
    ignored = ignored_item!(order, %{woo_line_item_id: 91_003, woo_product_id: 501})

    assert {:ok, %{mapped: 0, marked_unmapped: 0, unchanged: 0}} =
             MissingCatalogResolver.recover_product(source.id, 501, nil)

    assert Ash.get!(OrderItem, mapped.id, domain: Sales).mapping_status == :mapped
    assert Ash.get!(OrderItem, non_ticket.id, domain: Sales).mapping_status == :non_ticket
    assert Ash.get!(OrderItem, ignored.id, domain: Sales).mapping_status == :ignored
  end

  test "does not create product mappings", %{source: source, order: order} do
    create_item!(order, %{woo_product_id: 123_456, woo_variation_id: nil})
    count_before = product_mapping_count!()

    assert {:ok, %{marked_unmapped: 1}} =
             MissingCatalogResolver.recover_product(source.id, 123_456, nil)

    assert product_mapping_count!() == count_before
  end

  test "filters source system in the order item database query", %{source: source, order: order} do
    create_item!(order, %{woo_product_id: 501, woo_variation_id: nil})
    handler_id = "missing-catalog-query-shape-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:event_sales, :repo, :query],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:repo_query, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %{marked_unmapped: 1}} =
             MissingCatalogResolver.recover_product(source.id, 501, nil)

    order_item_queries =
      collect_repo_queries()
      |> Enum.filter(&String.contains?(&1, ~s(FROM "sales_order_items")))

    assert Enum.any?(order_item_queries, fn query ->
             String.contains?(query, ~s("source_system_id")) and
               ((String.contains?(query, "JOIN") and String.contains?(query, ~s("sales_orders"))) or
                  String.contains?(query, ~s(EXISTS)))
           end)
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

  defp create_item!(order, attrs) do
    line =
      :woocommerce
      |> FixtureHelpers.decode_json_fixture!(:order_completed)
      |> Map.fetch!("line_items")
      |> hd()

    defaults = %{
      woo_line_item_id: System.unique_integer([:positive]),
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

  defp mapped_item!(source, order, attrs) do
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

  defp product_mapping_count! do
    ProductMapping
    |> Ash.read!(domain: Catalog)
    |> length()
  end

  defp put_order_on_hold!(order) do
    put_order_status!(order, :on_hold)
  end

  defp put_order_status!(order, status) do
    Ash.update!(
      order,
      %{
        status: status,
        updated_at_source: DateTime.add(order.updated_at_source, 1, :second)
      },
      action: :sync_status_from_source,
      domain: Sales
    )
  end

  defp collect_repo_queries(acc \\ []) do
    receive do
      {:repo_query, _measurements, %{query: query}} when is_binary(query) ->
        collect_repo_queries([query | acc])

      {:repo_query, _measurements, _metadata} ->
        collect_repo_queries(acc)
    after
      50 -> Enum.reverse(acc)
    end
  end

  defp unique_id, do: System.unique_integer([:positive])
end
