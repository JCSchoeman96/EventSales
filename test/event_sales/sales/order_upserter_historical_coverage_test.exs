defmodule EventSales.Sales.OrderUpserterHistoricalCoverageTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalCoverageInvalidator
  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Sales
  alias EventSales.Sales.OrderUpserter
  alias EventSales.Sales.Resources.{CouponSnapshot, Order, OrderItem}
  alias EventSales.TestSupport.{FixtureHelpers, SalesHelpers}

  @coverage_start ~U[2026-08-01 00:00:00.000000Z]
  @sales_covered_through ~U[2026-08-09 23:59:59.999999Z]
  @historical_created_at ~U[2026-08-05 12:00:00.000000Z]
  @post_coverage_created_at ~U[2026-08-10 12:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        name: "D2B2 Event",
        external_event_id: 109_120,
        external_event_kind: :tickera_event
      })

    ticket =
      SalesHelpers.create_variation_ticket_type!(event, 501, 601, %{
        name: "D2B2 Ticket"
      })

    create_mapping!(source, event, ticket, %{woo_product_id: 501, woo_variation_id: 601})

    {:ok, source: source, event: event, ticket: ticket}
  end

  test "new historical Order invalidates its current Event certificate", %{
    source: source,
    event: event
  } do
    run = certified_run!(event)

    assert {:ok, order} = OrderUpserter.upsert_order(source.id, payload(@historical_created_at))
    assert order.created_at_source == @historical_created_at

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)

    invalidated = Ash.get!(SyncRun, run.id, domain: Ingestion)
    assert invalidated.coverage_invalidation_reason == :historical_order_changed
  end

  test "new historical Order with a latent exact source Event invalidates its certificate", %{
    source: source
  } do
    event =
      SalesHelpers.create_event!(source, %{
        external_event_id: 109_124,
        external_event_kind: :tickera_event
      })

    run = certified_run!(event)

    latent_payload =
      payload(@historical_created_at)
      |> put_in(["line_items", Access.at(0), "meta_data"], tickera_event_meta(109_124))

    assert {:ok, order} = OrderUpserter.upsert_order(source.id, latent_payload)

    assert [%OrderItem{event_id: nil, attribution_status_reason: :source_ticket_type_not_found}] =
             order_items(order.id)

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)

    assert Ash.get!(SyncRun, run.id, domain: Ingestion).coverage_invalidation_reason ==
             :historical_order_changed
  end

  test "a later financial mutation resolves the now-existing latent source Event", %{
    source: source
  } do
    latent_payload =
      payload(@historical_created_at)
      |> put_in(["line_items", Access.at(0), "meta_data"], tickera_event_meta(109_125))

    assert {:ok, order} = OrderUpserter.upsert_order(source.id, latent_payload)

    event =
      SalesHelpers.create_event!(source, %{
        external_event_id: 109_125,
        external_event_kind: :tickera_event
      })

    run = certified_run!(event)

    changed_payload =
      latent_payload
      |> Map.put("date_modified_gmt", woo_datetime(~U[2026-08-05 13:00:00.000000Z]))
      |> Map.put("total", "901.00")

    assert {:ok, changed} = OrderUpserter.upsert_order(source.id, changed_payload)
    assert changed.id == order.id

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)

    assert Ash.get!(SyncRun, run.id, domain: Ingestion).coverage_invalidation_reason ==
             :historical_order_changed
  end

  test "a changed mixed Order invalidates mapped and latent exact Events", %{
    source: source,
    event: event_a
  } do
    latent_payload =
      mixed_payload(@historical_created_at)
      |> put_in(["line_items", Access.at(1), "meta_data"], tickera_event_meta(109_126))

    assert {:ok, order} = OrderUpserter.upsert_order(source.id, latent_payload)

    event_b =
      SalesHelpers.create_event!(source, %{
        external_event_id: 109_126,
        external_event_kind: :tickera_event
      })

    run_a = certified_run!(event_a)
    run_b = certified_run!(event_b)

    changed_payload =
      latent_payload
      |> Map.put("date_modified_gmt", woo_datetime(~U[2026-08-05 13:00:00.000000Z]))
      |> Map.put("total", "1301.00")

    assert {:ok, changed} = OrderUpserter.upsert_order(source.id, changed_payload)
    assert changed.id == order.id

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event_a.id)

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event_b.id)

    assert Ash.get!(SyncRun, run_a.id, domain: Ingestion).coverage_invalidation_reason ==
             :historical_order_changed

    assert Ash.get!(SyncRun, run_b.id, domain: Ingestion).coverage_invalidation_reason ==
             :historical_order_changed
  end

  test "a removed source identity retains the BEFORE exact Event candidate", %{
    source: source
  } do
    source_event_id = 109_127

    initial_payload =
      payload(@historical_created_at)
      |> put_in(["line_items", Access.at(0), "product_id"], 901)
      |> put_in(["line_items", Access.at(0), "variation_id"], 902)
      |> put_in(
        ["line_items", Access.at(0), "meta_data"],
        tickera_event_meta(source_event_id)
      )

    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)

    event =
      SalesHelpers.create_event!(source, %{
        external_event_id: source_event_id,
        external_event_kind: :tickera_event
      })

    run = certified_run!(event)

    removed_payload =
      initial_payload
      |> Map.put("date_modified_gmt", woo_datetime(~U[2026-08-05 13:00:00.000000Z]))
      |> put_in(["line_items", Access.at(0), "meta_data"], [])

    assert {:ok, changed} = OrderUpserter.upsert_order(source.id, removed_payload)
    assert changed.id == order.id

    assert [%OrderItem{event_id: nil, source_tickera_event_id: nil}] = order_items(order.id)

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)

    assert Ash.get!(SyncRun, run.id, domain: Ingestion).coverage_invalidation_reason ==
             :historical_order_changed
  end

  test "a changed Order invalidates multiple latent exact source Events", %{source: source} do
    source_event_ids = [109_128, 109_129]

    initial_payload =
      mixed_payload(@historical_created_at)
      |> put_in(
        ["line_items", Access.at(0), "meta_data"],
        tickera_event_meta(Enum.at(source_event_ids, 0))
      )
      |> put_in(
        ["line_items", Access.at(1), "meta_data"],
        tickera_event_meta(Enum.at(source_event_ids, 1))
      )

    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)

    events =
      Enum.map(source_event_ids, fn external_event_id ->
        SalesHelpers.create_event!(source, %{
          external_event_id: external_event_id,
          external_event_kind: :tickera_event
        })
      end)

    runs = Enum.map(events, &certified_run!/1)

    changed_payload =
      initial_payload
      |> Map.put("date_modified_gmt", woo_datetime(~U[2026-08-05 13:00:00.000000Z]))
      |> Map.put("total", "1301.00")

    assert {:ok, changed} = OrderUpserter.upsert_order(source.id, changed_payload)
    assert changed.id == order.id

    Enum.zip(events, runs)
    |> Enum.each(fn {event, run} ->
      assert {:error, :historical_coverage_not_current} =
               HistoricalCoverageResolver.resolve_current(event.id)

      assert Ash.get!(SyncRun, run.id, domain: Ingestion).coverage_invalidation_reason ==
               :historical_order_changed
    end)
  end

  test "explicit reconciliation Event is unioned with latent source Events", %{
    source: source
  } do
    source_event_ids = [109_130, 109_131]
    reconciliation_event_id = 109_132

    initial_payload =
      mixed_payload(@historical_created_at)
      |> put_in(
        ["line_items", Access.at(0), "meta_data"],
        tickera_event_meta(Enum.at(source_event_ids, 0))
      )
      |> put_in(
        ["line_items", Access.at(1), "meta_data"],
        tickera_event_meta(Enum.at(source_event_ids, 1))
      )

    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)

    source_events =
      Enum.map(source_event_ids, fn external_event_id ->
        SalesHelpers.create_event!(source, %{
          external_event_id: external_event_id,
          external_event_kind: :tickera_event
        })
      end)

    reconciliation_event =
      SalesHelpers.create_event!(source, %{
        external_event_id: reconciliation_event_id,
        external_event_kind: :tickera_event
      })

    events = source_events ++ [reconciliation_event]
    runs = Enum.map(events, &certified_run!/1)
    test_pid = self()

    invalidator = fn invalidation_order, event_ids ->
      send(test_pid, {:candidate_event_ids, event_ids})
      HistoricalCoverageInvalidator.invalidate_order_change(invalidation_order, event_ids)
    end

    changed_payload =
      initial_payload
      |> Map.put("date_modified_gmt", woo_datetime(~U[2026-08-05 13:00:00.000000Z]))
      |> Map.put("total", "1301.00")

    assert {:ok, reconciled} =
             OrderUpserter.reconcile_event_order(
               source.id,
               reconciliation_event.id,
               changed_payload,
               [],
               historical_coverage_invalidator: invalidator
             )

    assert reconciled.id == order.id

    expected_event_ids = Enum.sort(Enum.map(events, & &1.id))
    assert_receive {:candidate_event_ids, ^expected_event_ids}
    assert_receive {:candidate_event_ids, ^expected_event_ids}

    Enum.zip(events, runs)
    |> Enum.each(fn {event, run} ->
      assert {:error, :historical_coverage_not_current} =
               HistoricalCoverageResolver.resolve_current(event.id)

      assert Ash.get!(SyncRun, run.id, domain: Ingestion).coverage_invalidation_reason ==
               :historical_order_changed
    end)
  end

  test "a new invalid source identity does not guess an Event candidate", %{
    source: source,
    event: event
  } do
    run = certified_run!(event)

    invalid_payload =
      payload(@historical_created_at)
      |> put_in(
        ["line_items", Access.at(0), "meta_data"],
        tickera_event_meta(109_133) ++ tickera_event_meta(109_134)
      )

    assert {:ok, order} = OrderUpserter.upsert_order(source.id, invalid_payload)

    assert [
             %OrderItem{
               event_id: nil,
               attribution_status_reason: :invalid_source_tickera_event_id
             }
           ] =
             order_items(order.id)

    assert {:ok, current} = HistoricalCoverageResolver.resolve_current(event.id)
    assert current.id == run.id
  end

  test "a new missing source Event does not guess a candidate", %{
    source: source,
    event: event
  } do
    run = certified_run!(event)
    missing_source_event_id = 109_135

    missing_payload =
      payload(@historical_created_at)
      |> put_in(
        ["line_items", Access.at(0), "meta_data"],
        tickera_event_meta(missing_source_event_id)
      )

    assert {:ok, order} = OrderUpserter.upsert_order(source.id, missing_payload)

    assert [%OrderItem{event_id: nil, attribution_status_reason: :source_event_not_found}] =
             order_items(order.id)

    assert {:ok, current} = HistoricalCoverageResolver.resolve_current(event.id)
    assert current.id == run.id
  end

  test "new post-coverage Order leaves its current certificate unchanged", %{
    source: source,
    event: event
  } do
    run = certified_run!(event)

    assert {:ok, _order} =
             OrderUpserter.upsert_order(source.id, payload(@post_coverage_created_at))

    assert {:ok, current} = HistoricalCoverageResolver.resolve_current(event.id)
    assert current.id == run.id
  end

  test "identical replay and updated_at_source-only advancement do not invalidate", %{
    source: source,
    event: event
  } do
    initial_payload = payload(@historical_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)
    run = certified_run!(event)
    test_pid = self()

    candidate_resolver = fn _order, _before_snapshot, _after_snapshot, _explicit_event_ids ->
      send(test_pid, :unexpected_candidate_resolver_call)
      {:error, :unexpected_candidate_resolver_call}
    end

    assert {:ok, replayed} =
             OrderUpserter.upsert_order(
               source.id,
               initial_payload,
               historical_order_coverage_candidate_resolver: candidate_resolver
             )

    assert replayed.id == order.id

    version_only_payload =
      initial_payload
      |> Map.put("date_modified_gmt", woo_datetime(~U[2026-08-05 13:00:00.000000Z]))

    assert {:ok, advanced} =
             OrderUpserter.upsert_order(
               source.id,
               version_only_payload,
               historical_order_coverage_candidate_resolver: candidate_resolver
             )

    assert advanced.id == order.id
    refute_receive :unexpected_candidate_resolver_call

    assert {:ok, current} = HistoricalCoverageResolver.resolve_current(event.id)
    assert current.id == run.id
  end

  test "equal-version paid_at hydration invalidates historical coverage", %{
    source: source,
    event: event
  } do
    initial_payload = payload(@historical_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)
    run = certified_run!(event)

    hydrated_payload =
      initial_payload
      |> Map.put("date_paid_gmt", woo_datetime(~U[2026-08-05 12:30:00.000000Z]))

    assert {:ok, hydrated} = OrderUpserter.upsert_order(source.id, hydrated_payload)
    assert hydrated.id == order.id
    assert hydrated.paid_at == ~U[2026-08-05 12:30:00.000000Z]

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)

    invalidated = Ash.get!(SyncRun, run.id, domain: Ingestion)
    assert invalidated.coverage_invalidation_reason == :historical_order_changed
  end

  test "attribution correction invalidates both persisted Event candidates", %{
    source: source,
    event: original_event
  } do
    corrected_event =
      SalesHelpers.create_event!(source, %{
        name: "D2B2 Corrected Event",
        external_event_id: 109_121,
        external_event_kind: :tickera_event
      })

    corrected_ticket =
      SalesHelpers.create_variation_ticket_type!(corrected_event, 502, 602, %{
        name: "D2B2 Corrected Ticket"
      })

    create_mapping!(source, corrected_event, corrected_ticket, %{
      woo_product_id: 502,
      woo_variation_id: 602
    })

    initial_payload = payload(@historical_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)

    original_run = certified_run!(original_event)
    corrected_run = certified_run!(corrected_event)

    corrected_payload =
      initial_payload
      |> Map.put("date_modified_gmt", woo_datetime(~U[2026-08-05 13:00:00.000000Z]))
      |> put_in(["line_items", Access.at(0), "product_id"], 502)
      |> put_in(["line_items", Access.at(0), "variation_id"], 602)
      |> put_in(["line_items", Access.at(0), "meta_data"], tickera_event_meta(109_121))

    [corrected_line] = corrected_payload["line_items"]

    assert {:ok, corrected} =
             OrderUpserter.reconcile_event_order(
               source.id,
               corrected_event.id,
               corrected_payload,
               [corrected_line]
             )

    assert corrected.id == order.id
    assert [%OrderItem{event_id: corrected_event_id}] = order_items(order.id)
    assert corrected_event_id == corrected_event.id

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(original_event.id)

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(corrected_event.id)

    assert Ash.get!(SyncRun, original_run.id, domain: Ingestion).coverage_invalidation_reason ==
             :historical_order_changed

    assert Ash.get!(SyncRun, corrected_run.id, domain: Ingestion).coverage_invalidation_reason ==
             :historical_order_changed
  end

  test "historical to post-coverage created_at correction invalidates from BEFORE", %{
    source: source,
    event: event
  } do
    initial_payload = payload(@historical_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)
    run = certified_run!(event)

    corrected_payload =
      payload(@post_coverage_created_at, ~U[2026-08-11 12:00:00.000000Z])

    assert {:ok, corrected} = OrderUpserter.upsert_order(source.id, corrected_payload)
    assert corrected.id == order.id

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)

    invalidated = Ash.get!(SyncRun, run.id, domain: Ingestion)
    assert invalidated.coverage_invalidation_reason == :historical_order_changed
  end

  test "post-coverage to historical created_at correction invalidates from AFTER", %{
    source: source,
    event: event
  } do
    initial_payload = payload(@post_coverage_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)
    run = certified_run!(event)

    corrected_payload =
      payload(@historical_created_at, ~U[2026-08-11 13:00:00.000000Z])

    assert {:ok, corrected} = OrderUpserter.upsert_order(source.id, corrected_payload)
    assert corrected.id == order.id

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)

    invalidated = Ash.get!(SyncRun, run.id, domain: Ingestion)
    assert invalidated.coverage_invalidation_reason == :historical_order_changed
  end

  test "exact reconciliation to an empty subset invalidates the explicit target", %{
    source: source,
    event: event
  } do
    initial_payload = payload(@historical_created_at)
    [line] = initial_payload["line_items"]

    assert {:ok, order} =
             OrderUpserter.reconcile_event_order(source.id, event.id, initial_payload, [line])

    run = certified_run!(event)

    emptied_payload =
      initial_payload
      |> Map.put("date_modified_gmt", woo_datetime(~U[2026-08-05 13:00:00.000000Z]))
      |> Map.put("coupon_lines", [])

    assert {:ok, emptied} =
             OrderUpserter.reconcile_event_order(source.id, event.id, emptied_payload, [])

    assert emptied.id == order.id
    assert order_items(order.id) == []
    assert coupons(order.id) == []

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)

    invalidated = Ash.get!(SyncRun, run.id, domain: Ingestion)
    assert invalidated.coverage_invalidation_reason == :historical_order_changed
  end

  test "unchanged exact reconciliation does not invalidate the explicit target", %{
    source: source,
    event: event
  } do
    initial_payload = payload(@historical_created_at)
    [line] = initial_payload["line_items"]

    assert {:ok, order} =
             OrderUpserter.reconcile_event_order(source.id, event.id, initial_payload, [line])

    run = certified_run!(event)

    assert {:ok, replayed} =
             OrderUpserter.reconcile_event_order(source.id, event.id, initial_payload, [line])

    assert replayed.id == order.id
    assert {:ok, current} = HistoricalCoverageResolver.resolve_current(event.id)
    assert current.id == run.id
  end

  test "stale source version skips D2A and preserves the current certificate", %{
    source: source,
    event: event
  } do
    initial_payload = payload(@historical_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)
    run = certified_run!(event)

    stale_payload =
      initial_payload
      |> Map.put("date_modified_gmt", woo_datetime(~U[2026-08-05 11:00:00.000000Z]))
      |> Map.put("total", "1.00")

    invalidator = fn _order, _event_ids -> {:error, :unexpected_d2a_call} end

    assert {:ok, :stale_noop} =
             OrderUpserter.upsert_order(
               source.id,
               stale_payload,
               historical_coverage_invalidator: invalidator
             )

    persisted = Ash.get!(Order, order.id, domain: Sales)
    assert persisted.raw_total == Decimal.new("900.00")
    assert {:ok, current} = HistoricalCoverageResolver.resolve_current(event.id)
    assert current.id == run.id
  end

  test "a failure on AFTER invalidation rolls back Order, children, and BEFORE invalidation", %{
    source: source,
    event: event
  } do
    initial_payload = payload(@historical_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)
    run = certified_run!(event)

    before_order = Ash.get!(Order, order.id, domain: Sales)
    before_items = order_projection(order.id)
    before_coupons = coupon_projection(order.id)
    before_certificate = Ash.get!(SyncRun, run.id, domain: Ingestion)

    invalidator = fn invalidation_order, event_ids ->
      call_number = Process.get(:d2b2_invalidation_calls, 0) + 1
      Process.put(:d2b2_invalidation_calls, call_number)

      if call_number == 1 do
        HistoricalCoverageInvalidator.invalidate_order_change(invalidation_order, event_ids)
      else
        {:error, :test_invalidation_failure}
      end
    end

    changed_payload =
      initial_payload
      |> Map.put("date_modified_gmt", woo_datetime(~U[2026-08-05 13:00:00.000000Z]))
      |> Map.put("total", "901.00")
      |> put_in(["line_items", Access.at(0), "total"], "901.00")
      |> put_in(["coupon_lines", Access.at(0), "discount"], "101.00")

    assert {:error, :test_invalidation_failure} =
             OrderUpserter.upsert_order(
               source.id,
               changed_payload,
               historical_coverage_invalidator: invalidator
             )

    assert Process.get(:d2b2_invalidation_calls) == 2
    assert Ash.get!(Order, order.id, domain: Sales) == before_order
    assert order_projection(order.id) == before_items
    assert coupon_projection(order.id) == before_coupons
    assert Ash.get!(SyncRun, run.id, domain: Ingestion) == before_certificate
    assert {:ok, current} = HistoricalCoverageResolver.resolve_current(event.id)
    assert current.id == run.id
  end

  defp payload(created_at_source, updated_at_source \\ nil) do
    updated_at_source = updated_at_source || DateTime.add(created_at_source, 5, :minute)

    fixture(:order_completed)
    |> Map.put("date_created_gmt", woo_datetime(created_at_source))
    |> Map.put("date_modified_gmt", woo_datetime(updated_at_source))
    |> Map.put("date_completed_gmt", woo_datetime(updated_at_source))
  end

  defp mixed_payload(created_at_source, updated_at_source \\ nil) do
    updated_at_source = updated_at_source || DateTime.add(created_at_source, 5, :minute)

    fixture(:order_mixed_event)
    |> Map.put("date_created_gmt", woo_datetime(created_at_source))
    |> Map.put("date_modified_gmt", woo_datetime(updated_at_source))
    |> Map.put("date_completed_gmt", woo_datetime(updated_at_source))
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

  defp order_items(order_id) do
    OrderItem
    |> Ash.Query.filter(order_id == ^order_id)
    |> Ash.read!(domain: Sales)
    |> Enum.sort_by(& &1.woo_line_item_id)
  end

  defp coupons(order_id) do
    CouponSnapshot
    |> Ash.Query.filter(order_id == ^order_id)
    |> Ash.read!(domain: Sales)
    |> Enum.sort_by(& &1.code)
  end

  defp order_projection(order_id) do
    order_items(order_id)
    |> Enum.map(fn item ->
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
    end)
  end

  defp coupon_projection(order_id) do
    coupons(order_id)
    |> Enum.map(&Map.take(&1, [:code, :discount_amount, :discount_tax]))
  end

  defp woo_datetime(datetime) do
    datetime
    |> DateTime.to_naive()
    |> NaiveDateTime.to_iso8601()
  end

  defp tickera_event_meta(external_event_id) do
    [%{"id" => 1, "key" => "tickera_event_id", "value" => Integer.to_string(external_event_id)}]
  end

  defp fixture(name), do: FixtureHelpers.decode_json_fixture!(:woocommerce, name)
end
