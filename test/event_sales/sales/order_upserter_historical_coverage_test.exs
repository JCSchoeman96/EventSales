defmodule EventSales.Sales.OrderUpserterHistoricalCoverageTest do
  use EventSales.DataCase, async: false

  import Ecto.Query

  require Ash.Query

  alias EventSales.Analytics.Workers.RefreshSnapshotWorker
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{ProductMapping, TicketType}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalCoverageInvalidator
  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.Parsers.WoocommerceOrderParser
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.OrderUpserter
  alias EventSales.Sales.Resources.{CouponSnapshot, Order, OrderItem, Refund, RefundLine}
  alias EventSales.TestSupport.{FixtureHelpers, HistoricalCoverageHelpers, SalesHelpers}

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

  test "a new aggregate-relevant Order requests its exact Event refresh", %{
    source: source,
    event: event
  } do
    test_pid = self()

    scheduler = fn event_ids ->
      send(test_pid, {:snapshot_refresh_requested, event_ids})
      :ok
    end

    assert {:ok, _order} =
             OrderUpserter.upsert_order(
               source.id,
               payload(@historical_created_at),
               snapshot_refresh_scheduler: scheduler
             )

    assert_receive {:snapshot_refresh_requested, [event_id]}
    assert event_id == event.id
  end

  test "OrderItem Event A to B mutation invalidates both certificates through D2", %{
    source: source,
    event: event_a
  } do
    event_b =
      SalesHelpers.create_event!(source, %{
        name: "D2 Event B",
        external_event_id: 109_141,
        external_event_kind: :tickera_event
      })

    ticket_b = SalesHelpers.create_variation_ticket_type!(event_b, 502, 602)
    create_mapping!(source, event_b, ticket_b, %{woo_product_id: 502, woo_variation_id: 602})

    initial_payload = payload(@historical_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)
    assert [%OrderItem{} = item] = order_items(order.id)
    _refund = create_refund!(source, order, item)
    event_a_run = certified_run!(event_a)
    event_b_run = certified_run!(event_b)

    corrected_payload =
      initial_payload
      |> Map.put("date_modified_gmt", woo_datetime(~U[2026-08-05 13:00:00.000000Z]))
      |> Map.put("total", "901.00")
      |> put_in(["line_items", Access.at(0), "product_id"], 502)
      |> put_in(["line_items", Access.at(0), "variation_id"], 602)
      |> put_in(["line_items", Access.at(0), "meta_data"], tickera_event_meta(109_141))

    [corrected_line] = corrected_payload["line_items"]

    assert {:ok, _reconciled} =
             OrderUpserter.reconcile_event_order(
               source.id,
               event_b.id,
               corrected_payload,
               [corrected_line],
               snapshot_refresh_scheduler: fn event_ids ->
                 send(self(), {:snapshot_refresh_requested, event_ids})
                 :ok
               end
             )

    assert_receive {:snapshot_refresh_requested, event_ids}
    assert event_ids == Enum.sort([event_a.id, event_b.id])

    for run_id <- [event_a_run.id, event_b_run.id] do
      invalidated = Ash.get!(SyncRun, run_id, domain: Ingestion)
      assert invalidated.order_coverage_status == :incomplete
      assert invalidated.refund_coverage_status == :incomplete
      assert %DateTime{} = invalidated.coverage_invalidated_at
    end

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event_a.id)

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event_b.id)
  end

  test "source-absent deletion explicitly marks RefundLines unresolved before D2", %{
    source: source,
    event: event
  } do
    initial_payload = payload(@historical_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)
    assert [%OrderItem{} = item] = order_items(order.id)
    run = certified_run!(event)
    refund = create_refund!(source, order, item)
    [line_before] = refund_lines(refund.id)

    assert {:ok, _reconciled} =
             OrderUpserter.reconcile_event_order(source.id, event.id, initial_payload, [])

    assert order_items(order.id) == []
    assert [%RefundLine{} = line_after] = refund_lines(refund.id)
    assert line_after.order_item_id == nil
    assert line_after.binding_reason == "order_item_not_found"
    assert line_after.validation_reason == nil
    assert line_after.woo_refunded_item_id == line_before.woo_refunded_item_id
    assert line_after.woo_product_id == line_before.woo_product_id
    assert line_after.woo_variation_id == line_before.woo_variation_id
    assert line_after.refunded_quantity == line_before.refunded_quantity
    assert line_after.refund_subtotal_amount == line_before.refund_subtotal_amount
    assert line_after.refund_total_amount == line_before.refund_total_amount
    assert line_after.refund_total_tax == line_before.refund_total_tax

    invalidated = Ash.get!(SyncRun, run.id, domain: Ingestion)
    assert invalidated.order_coverage_status == :incomplete
    assert invalidated.refund_coverage_status == :incomplete
    assert %DateTime{} = invalidated.coverage_invalidated_at

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)
  end

  test "unmapped OrderItem becomes mapped through OrderUpserter and D2 invalidates both Events",
       %{
         source: source,
         event: event_a
       } do
    event_b =
      SalesHelpers.create_event!(source, %{
        name: "D2 Unmapped Event B",
        external_event_id: 109_142,
        external_event_kind: :tickera_event
      })

    ticket_b = SalesHelpers.create_variation_ticket_type!(event_b, 502, 602)
    create_mapping!(source, event_b, ticket_b, %{woo_product_id: 502, woo_variation_id: 602})

    initial_payload = payload(@historical_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)
    assert [%OrderItem{} = item] = order_items(order.id)
    assert {:ok, pending} = Ash.update(item, %{}, action: :remap, domain: Sales)
    assert pending.mapping_status == :pending_mapping_resolution

    assert {:ok, unmapped} = Ash.update(pending, %{}, action: :mark_unmapped, domain: Sales)
    assert unmapped.mapping_status == :unmapped

    event_a_run = certified_run!(event_a)
    event_b_run = certified_run!(event_b)

    corrected_payload =
      initial_payload
      |> Map.put("date_modified_gmt", woo_datetime(~U[2026-08-05 13:00:00.000000Z]))
      |> Map.put("total", "901.00")
      |> put_in(["line_items", Access.at(0), "product_id"], 502)
      |> put_in(["line_items", Access.at(0), "variation_id"], 602)
      |> put_in(["line_items", Access.at(0), "meta_data"], tickera_event_meta(109_142))

    [corrected_line] = corrected_payload["line_items"]

    assert {:ok, _updated} =
             OrderUpserter.reconcile_event_order(
               source.id,
               event_b.id,
               corrected_payload,
               [corrected_line]
             )

    event_b_id = event_b.id
    assert [%OrderItem{mapping_status: :mapped, event_id: ^event_b_id}] = order_items(order.id)

    for run_id <- [event_a_run.id, event_b_run.id] do
      invalidated = Ash.get!(SyncRun, run_id, domain: Ingestion)
      assert invalidated.order_coverage_status == :incomplete
      assert invalidated.refund_coverage_status == :incomplete
      assert %DateTime{} = invalidated.coverage_invalidated_at
    end
  end

  test "source-absent deletion marks every RefundLine for the OrderItem", %{
    source: source,
    event: event
  } do
    initial_payload = payload(@historical_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)
    assert [%OrderItem{} = item] = order_items(order.id)
    refund = create_refund!(source, order, item)

    Ash.create!(
      RefundLine,
      %{
        refund_id: refund.id,
        order_item_id: item.id,
        woo_refund_line_item_id: 992_002,
        woo_refunded_item_id: item.woo_line_item_id,
        refunded_quantity: 1,
        refund_total_amount: Decimal.new("5.00"),
        refund_total_tax: Decimal.new("0.50"),
        binding_reason: nil,
        validation_reason: nil
      },
      action: :create_normalized,
      domain: Sales
    )

    assert {:ok, _reconciled} =
             OrderUpserter.reconcile_event_order(source.id, event.id, initial_payload, [])

    assert [%RefundLine{} = first, %RefundLine{} = second] = refund_lines(refund.id)
    assert Enum.all?([first, second], &is_nil(&1.order_item_id))
    assert Enum.all?([first, second], &(&1.binding_reason == "order_item_not_found"))
  end

  test "a RefundLine unbind failure rolls back every line and the OrderItem", %{
    source: source,
    event: event
  } do
    initial_payload = payload(@historical_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)
    assert [%OrderItem{} = item] = order_items(order.id)
    refund = create_refund!(source, order, item)

    second_line =
      Ash.create!(
        RefundLine,
        %{
          refund_id: refund.id,
          order_item_id: item.id,
          woo_refund_line_item_id: 992_003,
          woo_refunded_item_id: item.woo_line_item_id,
          refunded_quantity: 1,
          refund_total_amount: Decimal.new("5.00"),
          refund_total_tax: Decimal.new("0.50"),
          binding_reason: nil,
          validation_reason: nil
        },
        action: :create_normalized,
        domain: Sales
      )

    unbinder = fn line, _action, ash_opts ->
      if line.id == second_line.id do
        {:error, :forced_unbind_failure}
      else
        Ash.update(line, %{}, ash_opts)
      end
    end

    assert {:error, :forced_unbind_failure} =
             OrderUpserter.reconcile_event_order(
               source.id,
               event.id,
               initial_payload,
               [],
               refund_line_unbinder: unbinder,
               historical_coverage_invalidator: fn _order, _event_ids ->
                 flunk("D2 must not run after RefundLine unbind failure")
               end
             )

    item_id = item.id
    assert [%OrderItem{id: ^item_id}] = order_items(order.id)

    assert Enum.all?(refund_lines(refund.id), fn line ->
             line.order_item_id == item.id and is_nil(line.binding_reason)
           end)
  end

  test "D2 failure rolls back explicit unbind, deletion, and coverage state", %{
    source: source,
    event: event
  } do
    initial_payload = payload(@historical_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)
    assert [%OrderItem{} = item] = order_items(order.id)
    run = certified_run!(event)
    refund = create_refund!(source, order, item)

    assert {:error, :forced_d2_failure} =
             OrderUpserter.reconcile_event_order(
               source.id,
               event.id,
               initial_payload,
               [],
               historical_coverage_invalidator: fn _order, _event_ids ->
                 {:error, :forced_d2_failure}
               end
             )

    item_id = item.id
    assert [%OrderItem{id: ^item_id}] = order_items(order.id)
    assert [%RefundLine{order_item_id: ^item_id, binding_reason: nil}] = refund_lines(refund.id)
    restored = Ash.get!(SyncRun, run.id, domain: Ingestion)
    assert restored.order_coverage_status == :complete
    assert restored.refund_coverage_status == :complete
    assert is_nil(restored.coverage_invalidated_at)
    assert {:ok, _current} = HistoricalCoverageResolver.resolve_current(event.id)
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

    test_pid = self()

    assert {:ok, changed} =
             OrderUpserter.upsert_order(
               source.id,
               removed_payload,
               snapshot_refresh_scheduler: fn event_ids ->
                 send(test_pid, {:snapshot_refresh_requested, event_ids})
                 :ok
               end
             )

    assert_receive {:snapshot_refresh_requested, [scheduled_event_id]}
    assert scheduled_event_id == event.id
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

    scheduler = fn event_ids ->
      send(test_pid, {:snapshot_refresh_requested, event_ids})
      :ok
    end

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
               historical_coverage_invalidator: invalidator,
               snapshot_refresh_scheduler: scheduler
             )

    assert reconciled.id == order.id

    expected_event_ids = Enum.sort(Enum.map(events, & &1.id))
    assert_receive {:snapshot_refresh_requested, ^expected_event_ids}
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

  test "same-event ticket_type_id change requests snapshot refresh for that event", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    alternate_ticket =
      SalesHelpers.create_ticket_type!(event, %{name: "Alternate Ticket Type"})

    initial_payload = payload(@historical_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)
    assert [%OrderItem{ticket_type_id: ticket_id}] = order_items(order.id)
    assert ticket_id == ticket.id
    before_certificate = dimension_identity_certificate_fields(hd(order_items(order.id)))
    before_order = Ash.get!(Order, order.id, domain: Sales)
    _run = certified_run!(event)

    {:ok, normalized} = WoocommerceOrderParser.parse(initial_payload)
    [item] = order_items(order.id)

    replay_normalized =
      normalized
      |> Map.put(:updated_at_source, ~U[2026-08-05 13:00:00.000000Z])
      |> put_in(
        [:line_items, Access.at(0)],
        mapped_import_line_from_item(item, %{ticket_type_id: alternate_ticket.id})
      )

    test_pid = self()

    assert {:ok, updated} =
             OrderUpserter.upsert_normalized_order(
               source.id,
               replay_normalized,
               snapshot_refresh_scheduler: fn event_ids ->
                 send(test_pid, {:snapshot_refresh_requested, event_ids})
                 :ok
               end
             )

    assert updated.id == order.id
    assert updated.raw_total == before_order.raw_total
    assert updated.status == before_order.status

    assert_receive {:snapshot_refresh_requested, [event_id]}
    assert event_id == event.id

    after_item = hd(order_items(order.id))

    assert_only_certificate_field_changed!(
      before_certificate,
      after_item,
      :ticket_type_id,
      alternate_ticket.id
    )
  end

  test "same-event woo_product_id change requests snapshot refresh for that event", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    initial_payload = payload(@historical_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)
    before_certificate = dimension_identity_certificate_fields(hd(order_items(order.id)))
    _run = certified_run!(event)

    mapping =
      ProductMapping
      |> Ash.Query.filter(
        source_system_id == ^source.id and woo_product_id == 501 and woo_variation_id == 601
      )
      |> Ash.read_one!(domain: Catalog)

    clear_ticket_type_parent_product_identity!(ticket.id)

    Ash.update!(mapping, %{woo_product_id: 777}, action: :remap, domain: Catalog)

    test_pid = self()

    replay_payload =
      initial_payload
      |> Map.put("date_modified_gmt", woo_datetime(~U[2026-08-05 13:00:00.000000Z]))
      |> put_in(["line_items", Access.at(0), "product_id"], 777)

    assert {:ok, _updated} =
             OrderUpserter.upsert_order(
               source.id,
               replay_payload,
               snapshot_refresh_scheduler: fn event_ids ->
                 send(test_pid, {:snapshot_refresh_requested, event_ids})
                 :ok
               end
             )

    assert_receive {:snapshot_refresh_requested, [event_id]}
    assert event_id == event.id

    after_item = hd(order_items(order.id))
    assert_only_certificate_field_changed!(before_certificate, after_item, :woo_product_id, 777)
  end

  test "same-event woo_variation_id change requests snapshot refresh for that event", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    initial_payload = payload(@historical_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)
    before_certificate = dimension_identity_certificate_fields(hd(order_items(order.id)))
    _run = certified_run!(event)

    mapping =
      ProductMapping
      |> Ash.Query.filter(
        source_system_id == ^source.id and woo_product_id == 501 and woo_variation_id == 601
      )
      |> Ash.read_one!(domain: Catalog)

    set_ticket_type_woo_variation_identity!(ticket.id, 501, 888)

    Ash.update!(mapping, %{woo_variation_id: 888}, action: :remap, domain: Catalog)

    test_pid = self()

    replay_payload =
      initial_payload
      |> Map.put("date_modified_gmt", woo_datetime(~U[2026-08-05 13:00:00.000000Z]))
      |> put_in(["line_items", Access.at(0), "variation_id"], 888)

    assert {:ok, _updated} =
             OrderUpserter.upsert_order(
               source.id,
               replay_payload,
               snapshot_refresh_scheduler: fn event_ids ->
                 send(test_pid, {:snapshot_refresh_requested, event_ids})
                 :ok
               end
             )

    assert_receive {:snapshot_refresh_requested, [event_id]}
    assert event_id == event.id

    after_item = hd(order_items(order.id))
    assert_only_certificate_field_changed!(before_certificate, after_item, :woo_variation_id, 888)
  end

  test "ProductMapping-only mutation does not enqueue analytics snapshot refresh", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    initial_payload = payload(@historical_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)
    _run = certified_run!(event)
    jobs_before = refresh_job_count(event.id)
    test_pid = self()

    other_ticket =
      SalesHelpers.create_variation_ticket_type!(event, 909, 919, %{
        name: "Mapping-only Ticket"
      })

    Ash.create!(
      ProductMapping,
      %{
        source_system_id: source.id,
        event_id: event.id,
        ticket_type_id: other_ticket.id,
        woo_product_id: 909,
        woo_variation_id: 919,
        original_label: "New mapping",
        current_label: "New mapping",
        active: true
      },
      action: :create,
      domain: Catalog
    )

    assert {:ok, replayed} =
             OrderUpserter.upsert_order(
               source.id,
               initial_payload,
               snapshot_refresh_scheduler: fn event_ids ->
                 send(test_pid, {:unexpected_snapshot_refresh, event_ids})
                 :ok
               end
             )

    assert replayed.id == order.id
    refute_receive {:unexpected_snapshot_refresh, _}
    assert refresh_job_count(event.id) == jobs_before
  end

  test "TicketType catalogue-only mutation does not enqueue analytics snapshot refresh", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    initial_payload = payload(@historical_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)
    _run = certified_run!(event)
    jobs_before = refresh_job_count(event.id)
    test_pid = self()

    Ash.update!(
      ticket,
      %{name: "Renamed Ticket", capacity: 99, active: false},
      action: :update,
      domain: Catalog
    )

    assert {:ok, replayed} =
             OrderUpserter.upsert_order(
               source.id,
               initial_payload,
               snapshot_refresh_scheduler: fn event_ids ->
                 send(test_pid, {:unexpected_snapshot_refresh, event_ids})
                 :ok
               end
             )

    assert replayed.id == order.id
    refute_receive {:unexpected_snapshot_refresh, _}
    assert refresh_job_count(event.id) == jobs_before
    assert Ash.get!(TicketType, ticket.id, domain: Catalog).name == "Renamed Ticket"
  end

  test "identical replay and updated_at_source-only advancement do not invalidate", %{
    source: source,
    event: event
  } do
    initial_payload = payload(@historical_created_at)
    assert {:ok, order} = OrderUpserter.upsert_order(source.id, initial_payload)
    run = certified_run!(event)
    test_pid = self()

    scheduler = fn event_ids ->
      send(test_pid, {:snapshot_refresh_requested, event_ids})
      :ok
    end

    candidate_resolver = fn _order, _before_snapshot, _after_snapshot, _explicit_event_ids ->
      send(test_pid, :unexpected_candidate_resolver_call)
      {:error, :unexpected_candidate_resolver_call}
    end

    assert {:ok, replayed} =
             OrderUpserter.upsert_order(
               source.id,
               initial_payload,
               snapshot_refresh_scheduler: scheduler,
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
               snapshot_refresh_scheduler: scheduler,
               historical_order_coverage_candidate_resolver: candidate_resolver
             )

    assert advanced.id == order.id
    refute_receive :unexpected_candidate_resolver_call
    refute_receive {:snapshot_refresh_requested, _event_ids}

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
               historical_coverage_invalidator: invalidator,
               snapshot_refresh_scheduler: fn event_ids ->
                 send(self(), {:unexpected_snapshot_refresh, event_ids})
                 {:error, :unexpected_snapshot_refresh}
               end
             )

    refute_receive {:unexpected_snapshot_refresh, _event_ids}
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

  test "snapshot enqueue failure rolls back Order and coverage invalidation", %{
    source: source,
    event: event
  } do
    initial_payload = payload(@historical_created_at)

    assert {:ok, order} =
             OrderUpserter.upsert_order(
               source.id,
               initial_payload,
               snapshot_refresh_scheduler: fn _event_ids -> :ok end
             )

    run = certified_run!(event)
    before_order = Ash.get!(Order, order.id, domain: Sales)
    before_items = order_projection(order.id)
    before_certificate = Ash.get!(SyncRun, run.id, domain: Ingestion)

    changed_payload =
      initial_payload
      |> Map.put("date_modified_gmt", woo_datetime(~U[2026-08-05 13:00:00.000000Z]))
      |> Map.put("total", "901.00")
      |> put_in(["line_items", Access.at(0), "total"], "901.00")

    scheduler = fn event_ids ->
      assert event_ids == [event.id]
      assert :ok = RefreshSnapshotWorker.enqueue_events(event_ids)
      {:error, :snapshot_refresh_failed_after_insert}
    end

    assert {:error, :snapshot_refresh_failed_after_insert} =
             OrderUpserter.upsert_order(
               source.id,
               changed_payload,
               snapshot_refresh_scheduler: scheduler
             )

    assert Ash.get!(Order, order.id, domain: Sales) == before_order
    assert order_projection(order.id) == before_items
    assert Ash.get!(SyncRun, run.id, domain: Ingestion) == before_certificate
    assert refresh_job_count(event.id) == 0
  end

  test "an outer transaction rollback removes an OrderUpserter refresh job", %{
    source: source,
    event: event
  } do
    woo_order_id = 981_267
    test_pid = self()

    payload =
      payload(@historical_created_at)
      |> Map.put("id", woo_order_id)
      |> Map.put("number", "RSW-#{woo_order_id}")

    assert {:error, :outer_rollback} =
             Repo.transaction(fn ->
               assert {:ok, order} = OrderUpserter.upsert_order(source.id, payload)
               send(test_pid, {:uncommitted_order_id, order.id})
               Repo.rollback(:outer_rollback)
             end)

    assert_receive {:uncommitted_order_id, order_id}

    assert {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{}]}} =
             Ash.get(Order, order_id, domain: Sales)

    assert refresh_job_count(event.id) == 0
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
        refunds_covered_through: @sales_covered_through,
        coverage_evidence: HistoricalCoverageHelpers.certified_evidence()
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

  defp create_refund!(source, order, item) do
    refund =
      Ash.create!(
        Refund,
        %{
          source_system_id: source.id,
          order_id: order.id,
          woo_order_id: order.woo_order_id,
          woo_refund_id: System.unique_integer([:positive]),
          currency: "ZAR",
          source_state: :active,
          detail_status: :complete,
          summary_total_amount: Decimal.new("10.00"),
          header_amount: Decimal.new("10.00"),
          unallocated_header_amount: Decimal.new("0.00"),
          source_created_at: @historical_created_at
        },
        action: :create_normalized,
        domain: Sales
      )

    Ash.create!(
      RefundLine,
      %{
        refund_id: refund.id,
        order_item_id: item.id,
        woo_refund_line_item_id: System.unique_integer([:positive]),
        woo_refunded_item_id: item.woo_line_item_id,
        woo_product_id: item.woo_product_id,
        woo_variation_id: item.woo_variation_id,
        refunded_quantity: 1,
        refund_subtotal_amount: Decimal.new("12.00"),
        refund_total_amount: Decimal.new("10.00"),
        refund_total_tax: Decimal.new("0.00"),
        binding_reason: nil,
        validation_reason: nil
      },
      action: :create_normalized,
      domain: Sales
    )

    refund
  end

  defp refund_lines(refund_id) do
    RefundLine
    |> Ash.Query.filter(refund_id == ^refund_id)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read!(domain: Sales)
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

  defp dimension_identity_certificate_fields(%OrderItem{} = item) do
    %{
      event_id: item.event_id,
      ticket_type_id: item.ticket_type_id,
      woo_product_id: item.woo_product_id,
      woo_variation_id: item.woo_variation_id,
      quantity: item.quantity,
      line_total: item.line_total,
      line_total_tax: item.line_total_tax,
      mapping_status: item.mapping_status,
      item_kind: item.item_kind
    }
  end

  defp assert_only_certificate_field_changed!(
         before_fields,
         %OrderItem{} = after_item,
         field,
         expected_value
       ) do
    after_fields = dimension_identity_certificate_fields(after_item)
    assert Map.fetch!(after_fields, field) == expected_value

    unchanged_keys = Map.keys(before_fields) -- [field]
    assert Map.take(after_fields, unchanged_keys) == Map.take(before_fields, unchanged_keys)
  end

  defp clear_ticket_type_parent_product_identity!(ticket_id) do
    Repo.query!(
      """
      UPDATE catalog_ticket_types
      SET external_product_id = NULL
      WHERE id = $1
      """,
      [Ecto.UUID.dump!(ticket_id)]
    )
  end

  defp set_ticket_type_woo_variation_identity!(ticket_id, woo_product_id, woo_variation_id) do
    Repo.query!(
      """
      UPDATE catalog_ticket_types
      SET external_ticket_type_kind = 'woo_variation',
          external_ticket_type_id = $2,
          external_product_id = $1,
          external_variation_id = $2
      WHERE id = $3
      """,
      [woo_product_id, woo_variation_id, Ecto.UUID.dump!(ticket_id)]
    )
  end

  defp mapped_import_line_from_item(%OrderItem{} = item, overrides) when is_map(overrides) do
    %{
      woo_line_item_id: item.woo_line_item_id,
      woo_product_id: item.woo_product_id,
      woo_variation_id: item.woo_variation_id,
      name: item.name,
      quantity: item.quantity,
      line_subtotal: item.line_subtotal,
      line_total: item.line_total,
      line_total_tax: item.line_total_tax,
      discount_total: item.discount_total,
      event_id: item.event_id,
      ticket_type_id: item.ticket_type_id,
      item_kind: item.item_kind,
      mapping_status: item.mapping_status,
      source_tickera_event_id: item.source_tickera_event_id,
      attribution_status_reason: item.attribution_status_reason
    }
    |> Map.merge(overrides)
  end

  defp refresh_job_count(event_id) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(*)
        FROM oban_jobs
        WHERE worker = $1
          AND args ->> 'scope' = 'event'
          AND args ->> 'event_id' = $2
        """,
        [Keyword.fetch!(RefreshSnapshotWorker.__opts__(), :worker), event_id]
      )

    count
  end

  defp fixture(name), do: FixtureHelpers.decode_json_fixture!(:woocommerce, name)
end
