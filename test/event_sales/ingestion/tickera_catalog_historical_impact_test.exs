defmodule EventSales.Ingestion.TickeraCatalogHistoricalImpactTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion.TickeraCatalogHistoricalImpact
  alias EventSales.TestSupport.{FixtureHelpers, SalesHelpers}

  test "classifies source conflicts, unresolved pairs, and mapped history without eligibility leakage" do
    source = SalesHelpers.create_source_system!()
    {event, ticket} = mapped_destination!(source, 109_131, 109_425, 109_120, 109_425)

    create_item!(source, :completed, 109_131, 109_425, %{source_tickera_event_id: 109_120})
    create_item!(source, :completed, 109_131, 109_425, %{source_tickera_event_id: 999_999})
    create_item!(source, :on_hold, 109_131, 109_425, %{})

    create_item!(source, :completed, 109_131, 109_425, %{
      mapping_status: :mapped,
      event_id: event.id,
      ticket_type_id: ticket.id
    })

    create_item!(source, :completed, 109_131, 109_424, %{})

    assert {:ok, impact} =
             TickeraCatalogHistoricalImpact.forecast(
               source.id,
               %{
                 touched_product_keys: [{109_131, 109_424}, {109_131, 109_425}],
                 event_changes: [],
                 ticket_type_changes: [],
                 product_mapping_changes: []
               },
               now: ~U[2026-07-14 08:00:00Z]
             )

    assert impact["totals"]["eligible_lines"] == 1
    assert impact["totals"]["deferred_lines"] == 1
    assert impact["totals"]["conflicting_lines"] == 2
    assert impact["totals"]["already_mapped_lines"] == 1
    assert impact["eligibility"]["ignored_already_mapped"]["lines"] == 1

    assert [
             %{
               "woo_variation_id" => 109_424,
               "resolution" => "missing_destination",
               "conflicting_line_count" => 1
             },
             %{"woo_variation_id" => 109_425, "conflicting_line_count" => 1}
           ] = impact["by_product_variation"]
  end

  test "zero-create touched plan forecasts pending rows through an existing active mapping" do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        external_event_id: 109_120,
        external_event_kind: :tickera_event
      })

    ticket =
      SalesHelpers.create_ticket_type!(event, %{
        external_ticket_type_id: 109_425,
        external_ticket_type_kind: :woo_variation,
        external_product_id: 109_131,
        external_variation_id: 109_425
      })

    Ash.create!(
      ProductMapping,
      %{
        source_system_id: source.id,
        event_id: event.id,
        ticket_type_id: ticket.id,
        woo_product_id: 109_131,
        woo_variation_id: 109_425,
        original_label: "Ticket",
        current_label: "Ticket",
        active: true
      },
      action: :create,
      domain: Catalog
    )

    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)

    line =
      FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed)["line_items"] |> hd()

    SalesHelpers.create_order_item_from_line!(order, line, %{
      woo_product_id: 109_131,
      woo_variation_id: 109_425,
      quantity: 3
    })

    now = ~U[2026-07-14 08:00:00Z]

    assert {:ok, impact} =
             TickeraCatalogHistoricalImpact.forecast(
               source.id,
               %{
                 touched_product_keys: [{109_131, 109_425}],
                 event_changes: [],
                 ticket_type_changes: [],
                 product_mapping_changes: []
               },
               now: now
             )

    assert impact["totals"]["eligible_lines"] == 1
    assert impact["totals"]["eligible_quantity"] == 3

    assert [%{"resolution" => "existing_active_mapping", "proposed_event_external_id" => 109_120}] =
             impact["proposed_destinations"]

    assert impact["generated_at"] == "2026-07-14T08:00:00Z"
    refute inspect(impact) =~ "woo_order_id"
  end

  test "overlays planned adopt-existing identities on an unchanged active mapping" do
    source = SalesHelpers.create_source_system!()
    {event, ticket} = mapped_destination!(source, 109_131, 109_425, nil, nil)

    create_item!(source, :completed, 109_131, 109_425, %{source_tickera_event_id: 109_120})

    assert {:ok, impact} =
             TickeraCatalogHistoricalImpact.forecast(
               source.id,
               %{
                 touched_product_keys: [{109_131, 109_425}],
                 event_changes: [
                   %{action: :adopt_existing, event_id: event.id, external_event_id: 109_120}
                 ],
                 ticket_type_changes: [
                   %{
                     action: :adopt_existing,
                     ticket_type_id: ticket.id,
                     event_id: event.id,
                     external_ticket_type_id: 109_425
                   }
                 ],
                 product_mapping_changes: []
               },
               now: ~U[2026-07-14 08:00:00Z]
             )

    assert [
             %{
               "proposed_event_external_id" => 109_120,
               "proposed_ticket_type_external_id" => 109_425
             }
           ] =
             impact["proposed_destinations"]

    assert impact["totals"]["eligible_lines"] == 1
  end

  test "rejects malformed and over-broad touched scopes" do
    source = SalesHelpers.create_source_system!()

    assert {:error, :invalid_touched_product_key} =
             TickeraCatalogHistoricalImpact.forecast(source.id, %{touched_product_keys: [:bad]})

    assert {:error, :historical_impact_scope_too_large} =
             TickeraCatalogHistoricalImpact.forecast(
               source.id,
               %{touched_product_keys: [{1, nil}, {2, nil}]},
               max_pairs: 1
             )
  end

  defp mapped_destination!(source, product, variation, event_external_id, ticket_external_id) do
    event =
      SalesHelpers.create_event!(source, %{
        external_event_id: event_external_id,
        external_event_kind: :tickera_event
      })

    ticket =
      SalesHelpers.create_ticket_type!(event, %{
        external_ticket_type_id: ticket_external_id,
        external_ticket_type_kind: :woo_variation,
        external_product_id: product,
        external_variation_id: variation
      })

    Ash.create!(
      ProductMapping,
      %{
        source_system_id: source.id,
        event_id: event.id,
        ticket_type_id: ticket.id,
        woo_product_id: product,
        woo_variation_id: variation,
        original_label: "Ticket",
        current_label: "Ticket",
        active: true
      },
      action: :create,
      domain: Catalog
    )

    {event, ticket}
  end

  defp create_item!(source, status, product, variation, attrs) do
    unique = System.unique_integer([:positive])

    order_attrs =
      SalesHelpers.normalized_order_attrs_from_fixture!(:order_completed, source)
      |> Map.merge(%{
        status: status,
        woo_order_id: 900_000 + unique,
        order_number: "forecast-#{unique}"
      })

    order =
      Ash.create!(EventSales.Sales.Resources.Order, order_attrs,
        action: :create_normalized,
        domain: EventSales.Sales
      )

    line =
      FixtureHelpers.decode_json_fixture!(:woocommerce, :order_completed)["line_items"] |> hd()

    SalesHelpers.create_order_item_from_line!(
      order,
      line,
      Map.merge(
        %{
          woo_line_item_id: 800_000 + unique,
          woo_product_id: product,
          woo_variation_id: variation
        },
        attrs
      )
    )
  end
end
