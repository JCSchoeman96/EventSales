defmodule EventSales.Catalog.MissingCatalogResolverTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.MissingCatalogResolver
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalCoverageInvalidator
  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.FixtureHelpers
  alias EventSales.TestSupport.SalesHelpers

  @coverage_start ~U[2026-08-01 08:00:00.000000Z]
  @sales_covered_through ~U[2026-08-09 23:59:59.999999Z]
  @within_sales_scope ~U[2026-08-05 12:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)
    event = SalesHelpers.create_event!(source, %{name: "Recovered Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Recovered Ticket"})

    {:ok, source: source, order: order, event: event, ticket: ticket}
  end

  test "maps a pending item to Event B and invalidates Event B coverage", %{source: source} do
    order = create_coverage_order!(source)
    event_b = SalesHelpers.create_event!(source, %{name: "Recovered Event B"})
    ticket_b = SalesHelpers.create_variation_ticket_type!(event_b, 501, 601)
    create_mapping!(source, event_b, ticket_b, %{woo_product_id: 501, woo_variation_id: 601})
    item = create_item!(order, %{woo_product_id: 501, woo_variation_id: 601})
    run = certified_run!(event_b)

    assert {:ok, %{mapped: 1, marked_unmapped: 0, unchanged: 0}} =
             MissingCatalogResolver.recover_product(source.id, 501, 601)

    assert Ash.get!(OrderItem, item.id, domain: Sales).mapping_status == :mapped
    assert Ash.get!(OrderItem, item.id, domain: Sales).event_id == event_b.id

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event_b.id)

    assert Ash.get!(SyncRun, run.id, domain: Ingestion).coverage_invalidation_reason ==
             :historical_order_changed
  end

  test "uses only the mixed Order's A and B candidates", %{source: source} do
    order = create_coverage_order!(source)
    event_a = SalesHelpers.create_event!(source, %{name: "Mixed Event A"})
    event_b = SalesHelpers.create_event!(source, %{name: "Mixed Event B"})
    event_c = SalesHelpers.create_event!(source, %{name: "Mixed Event C"})
    ticket_a = SalesHelpers.create_variation_ticket_type!(event_a, 701, 702)
    ticket_b = SalesHelpers.create_variation_ticket_type!(event_b, 501, 601)
    _ticket_c = SalesHelpers.create_variation_ticket_type!(event_c, 801, 802)

    create_mapping!(source, event_b, ticket_b, %{woo_product_id: 501, woo_variation_id: 601})

    mapped_item!(source, order, %{
      woo_line_item_id: 91_101,
      woo_product_id: 701,
      woo_variation_id: 702,
      event_id: event_a.id,
      ticket_type_id: ticket_a.id
    })

    create_item!(order, %{
      woo_line_item_id: 91_102,
      woo_product_id: 501,
      woo_variation_id: 601
    })

    run_a = certified_run!(event_a)
    run_b = certified_run!(event_b)
    run_c = certified_run!(event_c)
    test_pid = self()

    invalidator = fn invalidation_order, event_ids ->
      send(test_pid, {:d4b2_candidates, event_ids})
      HistoricalCoverageInvalidator.invalidate_order_change(invalidation_order, event_ids)
    end

    assert {:ok, %{mapped: 1, marked_unmapped: 0, unchanged: 0}} =
             MissingCatalogResolver.recover_product(source.id, 501, 601,
               historical_coverage_invalidator: invalidator
             )

    assert_receive {:d4b2_candidates, candidate_event_ids}
    assert candidate_event_ids == Enum.sort([event_a.id, event_b.id])

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event_a.id)

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event_b.id)

    assert {:ok, current} = HistoricalCoverageResolver.resolve_current(event_c.id)
    assert current.id == run_c.id

    assert Ash.get!(SyncRun, run_a.id, domain: Ingestion).coverage_invalidation_reason ==
             :historical_order_changed

    assert Ash.get!(SyncRun, run_b.id, domain: Ingestion).coverage_invalidation_reason ==
             :historical_order_changed
  end

  test "leaves a certificate current when the Order is outside B through C", %{
    source: source
  } do
    order = create_coverage_order!(source, DateTime.add(@coverage_start, -1, :second))
    event_b = SalesHelpers.create_event!(source, %{name: "Outside Coverage Event"})
    ticket_b = SalesHelpers.create_variation_ticket_type!(event_b, 501, 601)
    create_mapping!(source, event_b, ticket_b, %{woo_product_id: 501, woo_variation_id: 601})
    create_item!(order, %{woo_product_id: 501, woo_variation_id: 601})
    run = certified_run!(event_b)

    assert {:ok, %{mapped: 1, marked_unmapped: 0, unchanged: 0}} =
             MissingCatalogResolver.recover_product(source.id, 501, 601)

    assert {:ok, current} = HistoricalCoverageResolver.resolve_current(event_b.id)
    assert current.id == run.id
  end

  test "defers an on-hold item without calling D2A", %{source: source} do
    order = create_coverage_order!(source) |> put_order_status!(:on_hold)
    event_b = SalesHelpers.create_event!(source, %{name: "Deferred Event"})
    ticket_b = SalesHelpers.create_variation_ticket_type!(event_b, 501, 601)
    create_mapping!(source, event_b, ticket_b, %{woo_product_id: 501, woo_variation_id: 601})
    create_item!(order, %{woo_product_id: 501, woo_variation_id: 601})
    run = certified_run!(event_b)
    test_pid = self()

    invalidator = fn _order, _event_ids ->
      send(test_pid, :unexpected_d4b2_d2a_call)
      {:error, :unexpected_d2a_call}
    end

    assert {:ok, %{mapped: 0, marked_unmapped: 0, unchanged: 1}} =
             MissingCatalogResolver.recover_product(source.id, 501, 601,
               historical_coverage_invalidator: invalidator
             )

    refute_receive :unexpected_d4b2_d2a_call
    assert {:ok, current} = HistoricalCoverageResolver.resolve_current(event_b.id)
    assert current.id == run.id
  end

  test "marks a pending item with an existing Event candidate unmapped and invalidates it", %{
    source: source
  } do
    order = create_coverage_order!(source)
    event_a = SalesHelpers.create_event!(source, %{name: "Existing Candidate Event"})
    ticket_a = SalesHelpers.create_variation_ticket_type!(event_a, 999, 1000)

    item =
      create_item!(order, %{
        woo_product_id: 999,
        woo_variation_id: 1000,
        event_id: event_a.id,
        ticket_type_id: ticket_a.id
      })

    run = certified_run!(event_a)

    assert {:ok, %{mapped: 0, marked_unmapped: 1, unchanged: 0}} =
             MissingCatalogResolver.recover_product(source.id, 999, 1000)

    persisted = Ash.get!(OrderItem, item.id, domain: Sales)
    assert persisted.mapping_status == :unmapped
    assert persisted.event_id == event_a.id

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event_a.id)

    assert Ash.get!(SyncRun, run.id, domain: Ingestion).coverage_invalidation_reason ==
             :historical_order_changed
  end

  test "commits changed recovery with no candidates without guessing or calling D2A", %{
    source: source
  } do
    order = create_coverage_order!(source)
    event = SalesHelpers.create_event!(source, %{name: "Unrelated Current Event"})
    _ticket = SalesHelpers.create_ticket_type!(event, %{name: "Unrelated Ticket"})
    create_item!(order, %{woo_product_id: 999_999, woo_variation_id: nil})
    run = certified_run!(event)
    test_pid = self()

    invalidator = fn _order, _event_ids ->
      send(test_pid, :unexpected_d4b2_d2a_call)
      {:error, :unexpected_d2a_call}
    end

    assert {:ok, %{mapped: 0, marked_unmapped: 1, unchanged: 0}} =
             MissingCatalogResolver.recover_product(source.id, 999_999, nil,
               historical_coverage_invalidator: invalidator
             )

    refute_receive :unexpected_d4b2_d2a_call
    assert {:ok, current} = HistoricalCoverageResolver.resolve_current(event.id)
    assert current.id == run.id
  end

  test "compares once and calls D2A once for multiple items on one Order", %{
    source: source
  } do
    order = create_coverage_order!(source)
    event_b = SalesHelpers.create_event!(source, %{name: "Batch Recovery Event"})
    ticket_b = SalesHelpers.create_variation_ticket_type!(event_b, 501, 601)
    create_mapping!(source, event_b, ticket_b, %{woo_product_id: 501, woo_variation_id: 601})
    create_item!(order, %{woo_line_item_id: 92_101, woo_product_id: 501, woo_variation_id: 601})
    create_item!(order, %{woo_line_item_id: 92_102, woo_product_id: 501, woo_variation_id: 601})
    _run = certified_run!(event_b)
    test_pid = self()

    invalidator = fn invalidation_order, event_ids ->
      send(test_pid, {:d4b2_single_d2a, event_ids})
      HistoricalCoverageInvalidator.invalidate_order_change(invalidation_order, event_ids)
    end

    assert {:ok, %{mapped: 2, marked_unmapped: 0, unchanged: 0}} =
             MissingCatalogResolver.recover_product(source.id, 501, 601,
               historical_order_mutation_detector: __MODULE__.CountingDetector,
               historical_coverage_invalidator: invalidator
             )

    assert Process.get(:d4b2_capture_calls) == 2
    assert Process.get(:d4b2_compare_calls) == 1
    assert_receive {:d4b2_single_d2a, [event_id]}
    assert event_id == event_b.id
  end

  test "commits the first Order before a second Order transaction fails", %{source: source} do
    event_b = SalesHelpers.create_event!(source, %{name: "Independent Order Event"})
    ticket_b = SalesHelpers.create_variation_ticket_type!(event_b, 501, 601)
    create_mapping!(source, event_b, ticket_b, %{woo_product_id: 501, woo_variation_id: 601})
    first_order = create_coverage_order!(source)
    second_order = create_coverage_order!(source)
    first_item = create_item!(first_order, %{woo_product_id: 501, woo_variation_id: 601})
    second_item = create_item!(second_order, %{woo_product_id: 501, woo_variation_id: 601})
    test_pid = self()

    invalidator = fn order, event_ids ->
      calls = Process.get(:d4b2_order_transaction_calls, [])
      Process.put(:d4b2_order_transaction_calls, [order.id | calls])
      send(test_pid, {:d4b2_order_d2a, order.id})

      if length(calls) == 1 do
        {:error, :second_order_failure}
      else
        HistoricalCoverageInvalidator.invalidate_order_change(order, event_ids)
      end
    end

    assert {:error, :second_order_failure} =
             MissingCatalogResolver.recover_product(source.id, 501, 601,
               historical_coverage_invalidator: invalidator
             )

    persisted_items = [
      Ash.get!(OrderItem, first_item.id, domain: Sales),
      Ash.get!(OrderItem, second_item.id, domain: Sales)
    ]

    assert Enum.count(persisted_items, &(&1.mapping_status == :mapped)) == 1
    assert Enum.count(persisted_items, &(&1.mapping_status == :pending_mapping_resolution)) == 1
    assert_receive {:d4b2_order_d2a, _first_order_id}
    assert_receive {:d4b2_order_d2a, _second_order_id}
  end

  test "preserves mapped, marked-unmapped, and deferred counts", %{source: source} do
    event_b = SalesHelpers.create_event!(source, %{name: "Counted Event"})
    ticket_b = SalesHelpers.create_variation_ticket_type!(event_b, 501, 601)
    create_mapping!(source, event_b, ticket_b, %{woo_product_id: 501, woo_variation_id: 601})

    mapped_order = create_coverage_order!(source)
    mapped_item = create_item!(mapped_order, %{woo_product_id: 501, woo_variation_id: 601})

    invalid_order = create_coverage_order!(source)

    invalid_item =
      create_item!(invalid_order, %{
        woo_product_id: 501,
        woo_variation_id: 601,
        source_tickera_event_id: 999_999,
        attribution_status_reason: :invalid_source_tickera_event_id
      })

    deferred_order = create_coverage_order!(source) |> put_order_status!(:on_hold)
    deferred_item = create_item!(deferred_order, %{woo_product_id: 501, woo_variation_id: 601})

    assert {:ok, %{mapped: 1, marked_unmapped: 1, unchanged: 1}} =
             MissingCatalogResolver.recover_product(source.id, 501, 601)

    assert Ash.get!(OrderItem, mapped_item.id, domain: Sales).mapping_status == :mapped
    assert Ash.get!(OrderItem, invalid_item.id, domain: Sales).mapping_status == :unmapped

    assert Ash.get!(OrderItem, deferred_item.id, domain: Sales).mapping_status ==
             :pending_mapping_resolution
  end

  test "rolls back OrderItem recovery when D2A returns an error", %{source: source} do
    order = create_coverage_order!(source)
    event_b = SalesHelpers.create_event!(source, %{name: "Injected D2A Failure Event"})
    ticket_b = SalesHelpers.create_variation_ticket_type!(event_b, 501, 601)
    create_mapping!(source, event_b, ticket_b, %{woo_product_id: 501, woo_variation_id: 601})
    item = create_item!(order, %{woo_product_id: 501, woo_variation_id: 601})
    before = item_projection(item)
    invalidator = fn _order, _event_ids -> {:error, :test_d2a_failure} end

    assert {:error, :test_d2a_failure} =
             MissingCatalogResolver.recover_product(source.id, 501, 601,
               historical_coverage_invalidator: invalidator
             )

    assert item_projection(Ash.get!(OrderItem, item.id, domain: Sales)) == before
  end

  test "real mapper and D2A rollback restores both current certificates", %{source: source} do
    order = create_coverage_order!(source)
    event_a = SalesHelpers.create_event!(source, %{name: "Rollback Event A"})
    event_b = SalesHelpers.create_event!(source, %{name: "Rollback Event B"})
    ticket_a = SalesHelpers.create_variation_ticket_type!(event_a, 701, 702)
    ticket_b = SalesHelpers.create_variation_ticket_type!(event_b, 501, 601)
    create_mapping!(source, event_b, ticket_b, %{woo_product_id: 501, woo_variation_id: 601})

    mapped =
      mapped_item!(source, order, %{
        woo_line_item_id: 93_101,
        woo_product_id: 701,
        woo_variation_id: 702,
        event_id: event_a.id,
        ticket_type_id: ticket_a.id
      })

    pending =
      create_item!(order, %{woo_line_item_id: 93_102, woo_product_id: 501, woo_variation_id: 601})

    before_items = order_projection(order.id)
    run_a = certified_run!(event_a)
    run_b = certified_run!(event_b)

    install_second_invalidation_failure_trigger!()

    assert {:error, :order_coverage_invalidation_failed} =
             MissingCatalogResolver.recover_product(source.id, 501, 601)

    assert order_projection(order.id) == before_items

    assert item_projection(Ash.get!(OrderItem, pending.id, domain: Sales)) ==
             item_projection(pending)

    assert item_projection(Ash.get!(OrderItem, mapped.id, domain: Sales)) ==
             item_projection(mapped)

    assert {:ok, current_a} = HistoricalCoverageResolver.resolve_current(event_a.id)
    assert current_a.id == run_a.id
    assert {:ok, current_b} = HistoricalCoverageResolver.resolve_current(event_b.id)
    assert current_b.id == run_b.id

    for run <- [run_a, run_b] do
      restored = Ash.get!(SyncRun, run.id, domain: Ingestion)
      assert restored.order_coverage_status == :complete
      assert restored.refund_coverage_status == :complete
      assert restored.coverage_invalidation_reason == nil
      assert restored.coverage_invalidated_at == nil
    end
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

  defp certified_run!(event) do
    SyncRun
    |> Ash.Changeset.for_create(:queue_historical_backfill, %{
      event_id: event.id,
      date_to: @sales_covered_through
    })
    |> Ash.Changeset.force_change_attribute(:source_system_id, event.source_system_id)
    |> Ash.Changeset.force_change_attribute(:date_from, @coverage_start)
    |> Ash.create!(domain: Ingestion)
    |> Ash.update!(%{}, action: :start, domain: Ingestion)
    |> Ash.update!(
      %{
        coverage_start: @coverage_start,
        sales_covered_through: @sales_covered_through,
        refunds_covered_through: @sales_covered_through
      },
      action: :record_coverage_certification,
      domain: Ingestion
    )
    |> Ash.update!(%{}, action: :complete, domain: Ingestion)
  end

  defp create_coverage_order!(source, created_at_source \\ @within_sales_scope) do
    Ash.create!(
      Order,
      %{
        source_system_id: source.id,
        woo_order_id: System.unique_integer([:positive]),
        status: :completed,
        currency: "ZAR",
        created_at_source: created_at_source,
        updated_at_source: created_at_source,
        raw_total: Decimal.new("100.00")
      },
      action: :create_normalized,
      domain: Sales
    )
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

  defp order_projection(order_id) do
    OrderItem
    |> Ash.Query.filter(order_id == ^order_id)
    |> Ash.Query.sort(woo_line_item_id: :asc, id: :asc)
    |> Ash.read!(domain: Sales)
    |> Enum.map(&item_projection/1)
  end

  defp item_projection(item) do
    Map.take(item, [
      :woo_line_item_id,
      :event_id,
      :ticket_type_id,
      :woo_product_id,
      :woo_variation_id,
      :quantity,
      :line_subtotal,
      :line_total,
      :line_total_tax,
      :discount_total,
      :item_kind,
      :mapping_status,
      :source_tickera_event_id,
      :attribution_status_reason
    ])
  end

  defp install_second_invalidation_failure_trigger! do
    Repo.query!("""
    CREATE TEMP TABLE eventsales_d4b2_invalidation_counter (count integer NOT NULL)
    """)

    Repo.query!("""
    INSERT INTO eventsales_d4b2_invalidation_counter (count) VALUES (0)
    """)

    Repo.query!("""
    CREATE OR REPLACE FUNCTION eventsales_test_fail_second_order_invalidation()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      invalidation_count integer;
    BEGIN
      IF NEW.coverage_invalidation_reason = 'historical_order_changed' THEN
        UPDATE pg_temp.eventsales_d4b2_invalidation_counter
        SET count = count + 1
        RETURNING count INTO invalidation_count;

        IF invalidation_count = 2 THEN
          RAISE EXCEPTION 'forced second D2A invalidation failure';
        END IF;
      END IF;

      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER eventsales_test_fail_second_order_invalidation
    BEFORE UPDATE ON ingestion_sync_runs
    FOR EACH ROW
    EXECUTE FUNCTION eventsales_test_fail_second_order_invalidation()
    """)
  end

  defp unique_id, do: System.unique_integer([:positive])

  defmodule CountingDetector do
    def capture(order) do
      Process.put(:d4b2_capture_calls, Process.get(:d4b2_capture_calls, 0) + 1)
      EventSales.Ingestion.HistoricalOrderMutationDetector.capture(order)
    end

    def compare(before, after_snapshot) do
      Process.put(:d4b2_compare_calls, Process.get(:d4b2_compare_calls, 0) + 1)
      EventSales.Ingestion.HistoricalOrderMutationDetector.compare(before, after_snapshot)
    end
  end
end
