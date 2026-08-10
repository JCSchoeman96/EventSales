defmodule EventSales.Ingestion.TickeraCatalogHistoricalImpactTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion.TickeraCatalogHistoricalImpact
  alias EventSales.Repo
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

    assert {:error,
            {:historical_impact_scope_too_large, %{observed_pairs: 2, max_total_pairs: 1}}} =
             TickeraCatalogHistoricalImpact.forecast(
               source.id,
               %{touched_product_keys: [{1, nil}, {2, nil}]},
               max_total_pairs: 1
             )
  end

  test "executes one aggregate query per bounded historical-impact batch" do
    source = SalesHelpers.create_source_system!()

    for {pair_count, expected_queries} <- [{0, 0}, {1, 1}, {25, 1}, {26, 2}, {50, 2}, {51, 3}] do
      {result, queries} =
        capture_queries(fn ->
          TickeraCatalogHistoricalImpact.forecast(
            source.id,
            forecast_context(pairs(pair_count)),
            now: ~U[2026-07-14 08:00:00Z]
          )
        end)

      assert {:ok, impact} = result
      assert length(impact["proposed_destinations"]) == pair_count
      assert aggregate_query_count(queries) == expected_queries
    end
  end

  test "uses one bulk active ProductMapping read for a multi-batch forecast" do
    source = SalesHelpers.create_source_system!()

    {result, queries} =
      capture_queries(fn ->
        TickeraCatalogHistoricalImpact.forecast(
          source.id,
          forecast_context(pairs(51)),
          now: ~U[2026-07-14 08:00:00Z]
        )
      end)

    assert {:ok, _impact} = result
    assert aggregate_query_count(queries) == 3
    assert mapping_query_count(queries) == 1
  end

  test "normalizes duplicate and reversed keys without pair or quantity duplication" do
    source = SalesHelpers.create_source_system!()
    keys = pairs(26)

    create_item!(source, :completed, 1, nil, %{quantity: 2})
    create_item!(source, :completed, 26, 1_026, %{quantity: 3})

    assert {:ok, impact} =
             TickeraCatalogHistoricalImpact.forecast(
               source.id,
               forecast_context(Enum.reverse(keys) ++ [hd(keys)]),
               now: ~U[2026-07-14 08:00:00Z]
             )

    assert length(impact["proposed_destinations"]) == 26
    assert length(impact["by_product_variation"]) == 26
    assert impact["totals"]["affected_pending_lines"] == 2
    assert impact["totals"]["affected_quantity"] == 5

    assert impact["proposed_destinations"] ==
             Enum.sort_by(impact["proposed_destinations"], fn destination ->
               {destination["woo_product_id"], destination["woo_variation_id"] || -1}
             end)
  end

  test "preserves nil variations and quantities across an aggregate batch boundary" do
    source = SalesHelpers.create_source_system!()

    create_item!(source, :completed, 25, nil, %{quantity: 2})
    create_item!(source, :completed, 26, 1_026, %{quantity: 3})

    assert {:ok, impact} =
             TickeraCatalogHistoricalImpact.forecast(
               source.id,
               forecast_context(pairs(26)),
               now: ~U[2026-07-14 08:00:00Z]
             )

    assert impact["totals"]["affected_pending_lines"] == 2
    assert impact["totals"]["affected_quantity"] == 5

    assert %{
             "woo_variation_id" => nil,
             "pending_line_count" => 1,
             "quantity" => 2
           } = by_pair(impact, 25, nil)

    assert %{
             "woo_variation_id" => 1_026,
             "pending_line_count" => 1,
             "quantity" => 3
           } = by_pair(impact, 26, 1_026)
  end

  test "overlays adopted identities for an existing mapping in a later batch" do
    source = SalesHelpers.create_source_system!()
    {event, ticket} = mapped_destination!(source, 26, 1_026, nil, nil)

    assert {:ok, impact} =
             TickeraCatalogHistoricalImpact.forecast(
               source.id,
               %{
                 forecast_context(pairs(26))
                 | event_changes: [
                     %{action: :adopt_existing, event_id: event.id, external_event_id: 109_120}
                   ],
                   ticket_type_changes: [
                     %{
                       action: :adopt_existing,
                       ticket_type_id: ticket.id,
                       event_id: event.id,
                       external_ticket_type_id: 109_425
                     }
                   ]
               },
               now: ~U[2026-07-14 08:00:00Z]
             )

    assert %{
             "resolution" => "existing_active_mapping",
             "proposed_event_external_id" => 109_120,
             "proposed_ticket_type_external_id" => 109_425
           } = by_pair(impact, 26, 1_026)
  end

  test "accepts the total scope boundary and rejects the next pair with bounded metadata" do
    source = SalesHelpers.create_source_system!()

    assert {:ok, impact} =
             TickeraCatalogHistoricalImpact.forecast(
               source.id,
               forecast_context(pairs(5_000)),
               now: ~U[2026-07-14 08:00:00Z]
             )

    assert length(impact["proposed_destinations"]) == 5_000

    assert {:error,
            {:historical_impact_scope_too_large, %{observed_pairs: 5_001, max_total_pairs: 5_000}}} =
             TickeraCatalogHistoricalImpact.forecast(
               source.id,
               forecast_context(pairs(5_001)),
               now: ~U[2026-07-14 08:00:00Z]
             )
  end

  test "rejects invalid bounded query and total limits without raising" do
    source = SalesHelpers.create_source_system!()

    for opts <- [
          [max_batch_pairs: 0],
          [max_batch_pairs: 26],
          [max_batch_pairs: "25"],
          [max_total_pairs: 0],
          [max_total_pairs: "5000"]
        ] do
      assert {:error, {:invalid_historical_impact_limits, %{max_supported_batch_pairs: 25}}} =
               TickeraCatalogHistoricalImpact.forecast(
                 source.id,
                 forecast_context(pairs(1)),
                 opts
               )
    end
  end

  defp mapped_destination!(source, product, variation, event_external_id, ticket_external_id) do
    event =
      SalesHelpers.create_event!(source, %{
        external_event_id: event_external_id,
        external_event_kind: :tickera_event
      })

    ticket =
      if is_nil(variation) do
        SalesHelpers.create_ticket_type!(event, %{
          external_ticket_type_id: ticket_external_id,
          external_ticket_type_kind: if(is_nil(ticket_external_id), do: nil, else: :woo_product),
          external_product_id: product
        })
      else
        SalesHelpers.create_variation_ticket_type!(event, product, variation, %{
          external_ticket_type_id: ticket_external_id || variation
        })
      end

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

  defp forecast_context(keys) do
    %{
      touched_product_keys: keys,
      event_changes: [],
      ticket_type_changes: [],
      product_mapping_changes: []
    }
  end

  defp pairs(0), do: []

  defp pairs(count) do
    for product_id <- 1..count do
      {product_id, if(rem(product_id, 2) == 0, do: product_id + 1_000, else: nil)}
    end
  end

  defp capture_queries(fun) do
    handler_id = {__MODULE__, self(), make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measurements, metadata, {test_pid, id} ->
          send(test_pid, {id, inspect(metadata.query)})
        end,
        {parent, handler_id}
      )

    try do
      {fun.(), collect_queries(handler_id, [])}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_queries(handler_id, queries) do
    receive do
      {^handler_id, query} -> collect_queries(handler_id, [query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end

  defp aggregate_query_count(queries),
    do: Enum.count(queries, &String.contains?(&1, "sales_order_items"))

  defp mapping_query_count(queries),
    do: Enum.count(queries, &String.contains?(&1, "catalog_product_mappings"))

  defp by_pair(impact, product_id, variation_id) do
    Enum.find(impact["by_product_variation"], fn pair ->
      pair["woo_product_id"] == product_id and pair["woo_variation_id"] == variation_id
    end)
  end
end
