defmodule EventSales.Analytics.EventDimensionSnapshotRefreshTest do
  use EventSales.DataCase, async: false

  import Ecto.Query

  require Ash.Query

  alias EventSales.Analytics.Aggregators.DimensionAggregator
  alias EventSales.Analytics.{DashboardCache, SnapshotRefresh}
  alias EventSales.Analytics.Resources.{EventAggregateSnapshot, EventDimensionAggregateSnapshot}
  alias EventSales.Catalog.Resources.{Event, SourceSystem, TicketType}
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.RefundUpserter
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.{SalesHelpers, UnboxedPostgres}

  setup do
    DashboardCache.ensure_table!()
    :ok
  end

  test "initial refresh persists ticket, product, and variation dimensional rows" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    create_item!(order, event, ticket,
      woo_product_id: 501,
      woo_variation_id: 601,
      quantity: 2,
      line_total: Decimal.new("20.00"),
      line_total_tax: Decimal.new("2.00")
    )

    assert {:ok, _snapshots} = SnapshotRefresh.refresh_event(event.id)

    rows = dimension_rows!(event.id)
    assert length(rows) == 3

    assert Enum.any?(
             rows,
             &(&1.dimension_kind == :ticket_type and &1.ticket_type_id == ticket.id)
           )

    assert Enum.any?(rows, &(&1.dimension_kind == :source_product and &1.woo_product_id == 501))

    assert Enum.any?(
             rows,
             &(&1.dimension_kind == :source_variation and &1.woo_variation_id == 601)
           )
  end

  test "initial refresh persists refund primitives for every applicable variation grain" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    item =
      create_item!(order, event, ticket,
        woo_line_item_id: 70_001,
        woo_product_id: 501,
        woo_variation_id: 601,
        quantity: 2,
        line_total: Decimal.new("20.00"),
        line_total_tax: Decimal.new("2.00")
      )

    assert {:ok, _refund} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(80_001, [normalized_refund_line(90_001, item)])
             )

    assert {:ok, _snapshots} = SnapshotRefresh.refresh_event(event.id)

    rows = dimension_rows!(event.id)
    assert {:ok, aggregate_rows} = DimensionAggregator.financial_rows_for_event(event.id)
    assert length(aggregate_rows) == 3

    for aggregate <- aggregate_rows do
      assert persisted =
               Enum.find(rows, fn row ->
                 row.currency == aggregate.currency and
                   row.dimension_kind == aggregate.dimension_kind and
                   row.ticket_type_id == aggregate.ticket_type_id and
                   row.source_system_id == aggregate.source_system_id and
                   row.woo_product_id == aggregate.woo_product_id and
                   row.woo_variation_id == aggregate.woo_variation_id
               end)

      assert persisted.gross_ticket_quantity == aggregate.gross_ticket_quantity
      assert Decimal.equal?(persisted.gross_ticket_value, aggregate.gross_ticket_value)
      assert persisted.refund_ticket_quantity == aggregate.refund_ticket_quantity
      assert Decimal.equal?(persisted.refund_ticket_value, aggregate.refund_ticket_value)
    end

    for kind <- [:ticket_type, :source_product, :source_variation] do
      row = Enum.find(rows, &(&1.dimension_kind == kind))

      assert row.gross_ticket_quantity == 2
      assert Decimal.equal?(row.gross_ticket_value, Decimal.new("22.00"))
      assert row.refund_ticket_quantity == 1
      assert Decimal.equal?(row.refund_ticket_value, Decimal.new("6.00"))
    end
  end

  test "repeated same-grain source rows aggregate into one dimensional row per grain" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    create_item!(order, event, ticket,
      woo_product_id: 501,
      woo_variation_id: 601,
      quantity: 1,
      line_total: Decimal.new("10.00"),
      line_total_tax: Decimal.new("1.00")
    )

    create_item!(order, event, ticket,
      woo_product_id: 501,
      woo_variation_id: 601,
      quantity: 3,
      line_total: Decimal.new("30.00"),
      line_total_tax: Decimal.new("3.00")
    )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)

    rows = dimension_rows!(event.id)
    ticket_row = Enum.find(rows, &(&1.dimension_kind == :ticket_type))
    assert ticket_row.gross_ticket_quantity == 4
    assert Decimal.equal?(ticket_row.gross_ticket_value, Decimal.new("44.00"))
  end

  test "product-only line creates ticket and product rows without variation" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    create_item!(order, event, ticket,
      woo_product_id: 777,
      woo_variation_id: nil,
      quantity: 1,
      line_total: Decimal.new("15.00"),
      line_total_tax: Decimal.new("0.00")
    )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)

    rows = dimension_rows!(event.id)
    kinds = Enum.map(rows, & &1.dimension_kind) |> Enum.sort()
    assert kinds == [:source_product, :ticket_type]
  end

  test "product-only refund persists on ticket and product grains without variation" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    item =
      create_item!(order, event, ticket,
        woo_line_item_id: 70_002,
        woo_product_id: 777,
        woo_variation_id: nil,
        quantity: 1,
        line_total: Decimal.new("15.00"),
        line_total_tax: Decimal.new("0.00")
      )

    assert {:ok, _refund} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(80_002, [normalized_refund_line(90_002, item)])
             )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)

    rows = dimension_rows!(event.id)
    assert Enum.map(rows, & &1.dimension_kind) |> Enum.sort() == [:source_product, :ticket_type]

    for kind <- [:ticket_type, :source_product] do
      row = Enum.find(rows, &(&1.dimension_kind == kind))
      assert row.refund_ticket_quantity == 1
      assert Decimal.equal?(row.refund_ticket_value, Decimal.new("6.00"))
    end

    refute Enum.any?(rows, &(&1.dimension_kind == :source_variation))
  end

  test "value-only refund persists a positive value with zero refund quantity" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    item =
      create_item!(order, event, ticket,
        woo_line_item_id: 70_003,
        woo_product_id: 778,
        woo_variation_id: 602,
        quantity: 1,
        line_total: Decimal.new("15.00"),
        line_total_tax: Decimal.new("0.00")
      )

    assert {:ok, _refund} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(
                 80_003,
                 [
                   normalized_refund_line(90_003, item,
                     refunded_quantity: 0,
                     refund_subtotal_amount: Decimal.new("30.00"),
                     refund_total_amount: Decimal.new("30.00"),
                     refund_total_tax: Decimal.new("4.50")
                   )
                 ],
                 header_amount: Decimal.new("34.50")
               )
             )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)

    rows = dimension_rows!(event.id)

    assert Enum.all?(rows, fn row ->
             row.refund_ticket_quantity == 0 and
               Decimal.equal?(row.refund_ticket_value, Decimal.new("34.50"))
           end)
  end

  test "header-only refund does not allocate dimensional ticket refunds" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    create_item!(order, event, ticket,
      woo_product_id: 784,
      woo_variation_id: 607,
      quantity: 1,
      line_total: Decimal.new("15.00"),
      line_total_tax: Decimal.new("1.50")
    )

    assert {:ok, _refund} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(
                 80_007,
                 [],
                 header_amount: Decimal.new("20.00"),
                 unallocated_header_amount: Decimal.new("20.00")
               )
             )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)

    assert Enum.all?(dimension_rows!(event.id), fn row ->
             row.refund_ticket_quantity == 0 and
               Decimal.equal?(row.refund_ticket_value, Decimal.new("0"))
           end)
  end

  test "voided refund refresh removes dimensional refund primitives and keeps gross" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    item =
      create_item!(order, event, ticket,
        woo_line_item_id: 70_004,
        woo_product_id: 779,
        woo_variation_id: 603,
        quantity: 2,
        line_total: Decimal.new("20.00"),
        line_total_tax: Decimal.new("2.00")
      )

    assert {:ok, refund} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(80_004, [normalized_refund_line(90_004, item)])
             )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)
    assert Enum.any?(dimension_rows!(event.id), &(&1.refund_ticket_quantity == 1))

    assert {:ok, %{source_state: :voided}} =
             RefundUpserter.mark_source_deleted(
               source.id,
               order.woo_order_id,
               refund.woo_refund_id,
               ~U[2026-05-17 11:00:00.000000Z]
             )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)

    assert Enum.all?(dimension_rows!(event.id), fn row ->
             row.gross_ticket_quantity == 2 and
               Decimal.equal?(row.gross_ticket_value, Decimal.new("22.00")) and
               row.refund_ticket_quantity == 0 and
               Decimal.equal?(row.refund_ticket_value, Decimal.new("0"))
           end)
  end

  test "unresolved refund refresh removes prior dimensional refund primitives" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    item =
      create_item!(order, event, ticket,
        woo_line_item_id: 70_005,
        woo_product_id: 780,
        woo_variation_id: 604,
        quantity: 2,
        line_total: Decimal.new("20.00"),
        line_total_tax: Decimal.new("2.00")
      )

    assert {:ok, refund} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(80_005, [normalized_refund_line(90_005, item)])
             )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)
    assert Enum.any?(dimension_rows!(event.id), &(&1.refund_ticket_quantity == 1))

    assert {:ok, %{detail_status: :unresolved}} =
             RefundUpserter.upsert_refund(
               source.id,
               order.woo_order_id,
               malformed_refund_payload(refund.woo_refund_id)
             )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)

    assert Enum.all?(dimension_rows!(event.id), fn row ->
             row.gross_ticket_quantity == 2 and row.refund_ticket_quantity == 0 and
               Decimal.equal?(row.refund_ticket_value, Decimal.new("0"))
           end)
  end

  test "full replacement removes a refund-only grain when source aggregation no longer returns it" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    item =
      create_item!(order, event, ticket,
        woo_line_item_id: 70_006,
        woo_product_id: 781,
        woo_variation_id: nil,
        quantity: 1,
        line_total: Decimal.new("25.00"),
        line_total_tax: Decimal.new("2.50")
      )

    assert {:ok, refund} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               order.woo_order_id,
               normalized_refund(80_006, [normalized_refund_line(90_006, item)])
             )

    Repo.query!("UPDATE sales_order_items SET quantity = 0 WHERE id = $1", [
      Ecto.UUID.dump!(item.id)
    ])

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)

    assert Enum.any?(dimension_rows!(event.id), fn row ->
             row.dimension_kind == :source_product and row.refund_ticket_quantity == 1
           end)

    assert {:ok, %{source_state: :voided}} =
             RefundUpserter.mark_source_deleted(
               source.id,
               order.woo_order_id,
               refund.woo_refund_id,
               ~U[2026-05-17 12:00:00.000000Z]
             )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)

    refute Enum.any?(dimension_rows!(event.id), &(&1.woo_product_id == 781))
  end

  test "multi-currency dimensional rows and event snapshots share one generation" do
    %{source: source, event: event, ticket: ticket, second_ticket: second_ticket} = fixture!()
    zar_order = create_order!(source, :completed, currency: "ZAR")
    usd_order = create_order!(source, :completed, currency: "USD")

    create_item!(zar_order, event, ticket,
      woo_product_id: 782,
      woo_variation_id: 605,
      quantity: 1,
      line_total: Decimal.new("10.00"),
      line_total_tax: Decimal.new("1.00")
    )

    create_item!(usd_order, event, second_ticket,
      woo_product_id: 783,
      woo_variation_id: 606,
      quantity: 1,
      line_total: Decimal.new("20.00"),
      line_total_tax: Decimal.new("2.00")
    )

    generation = ~U[2026-06-01 10:00:00.000000Z]
    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id, refreshed_at: generation)

    dimensions = dimension_rows!(event.id)

    snapshots =
      EventAggregateSnapshot
      |> Ash.Query.filter(event_id == ^event.id and snapshot_version == 2)
      |> Ash.read!(domain: EventSales.Analytics)

    assert Enum.map(dimensions, & &1.currency) |> Enum.uniq() |> Enum.sort() == ["USD", "ZAR"]
    assert Enum.all?(dimensions, &(&1.refreshed_at == generation))
    assert Enum.all?(snapshots, &(&1.refreshed_at == generation))
    assert Enum.map(snapshots, & &1.currency) |> Enum.sort() == ["USD", "ZAR"]
  end

  test "second refresh removes obsolete dimensional grains" do
    %{source: source, event: event, ticket: ticket, second_ticket: second_ticket} = fixture!()
    order = create_order!(source, :completed)

    create_item!(order, event, ticket,
      woo_product_id: 501,
      woo_variation_id: 601,
      quantity: 1,
      line_total: Decimal.new("10.00"),
      line_total_tax: Decimal.new("0.00")
    )

    usd_order =
      create_order!(source, :completed,
        currency: "USD",
        woo_order_id: System.unique_integer([:positive])
      )

    create_item!(usd_order, event, second_ticket,
      woo_product_id: 502,
      woo_variation_id: 602,
      quantity: 1,
      line_total: Decimal.new("5.00"),
      line_total_tax: Decimal.new("0.00")
    )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)
    assert length(dimension_rows!(event.id)) == 6

    Repo.delete_all(from(oi in OrderItem, where: oi.order_id == ^usd_order.id))

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)

    rows = dimension_rows!(event.id)
    assert Enum.all?(rows, &(&1.currency == "ZAR"))
    refute Enum.any?(rows, &(&1.ticket_type_id == second_ticket.id))
    refute Enum.any?(rows, &(&1.woo_product_id == 502))
  end

  test "zero recognised sales purges every prior dimension row" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    create_item!(order, event, ticket,
      woo_product_id: 501,
      woo_variation_id: 601,
      quantity: 1,
      line_total: Decimal.new("10.00"),
      line_total_tax: Decimal.new("0.00")
    )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)
    assert dimension_rows!(event.id) != []

    Repo.delete_all(from(oi in OrderItem, where: oi.event_id == ^event.id))

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)
    assert dimension_rows!(event.id) == []
  end

  test "every dimensional row from one refresh shares the same refreshed_at" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    create_item!(order, event, ticket,
      woo_product_id: 501,
      woo_variation_id: 601,
      quantity: 1,
      line_total: Decimal.new("10.00"),
      line_total_tax: Decimal.new("1.00")
    )

    fixed_refreshed_at = ~U[2026-06-01 10:00:00.000000Z]

    assert {:ok, _} =
             SnapshotRefresh.refresh_event(event.id, refreshed_at: fixed_refreshed_at)

    refreshed_values =
      dimension_rows!(event.id)
      |> Enum.map(& &1.refreshed_at)
      |> Enum.uniq()

    assert refreshed_values == [fixed_refreshed_at]

    rows = dimension_rows!(event.id)
    assert Enum.all?(rows, fn row -> row.inserted_at == row.updated_at end)
    refute Enum.any?(rows, fn row -> row.inserted_at == fixed_refreshed_at end)
  end

  test "cross-event TicketType mismatch fails closed without persisting dimensions" do
    UnboxedPostgres.with_exclusive_setup(fn ->
      suffix = System.unique_integer([:positive])
      source = SalesHelpers.create_source_system!(%{name: "Dim xref src #{suffix}"})

      event_a =
        SalesHelpers.create_event!(source, %{name: "Dim xref event a #{suffix}"})

      other_event =
        SalesHelpers.create_event!(source, %{name: "Dim xref other #{suffix}"})

      ticket_a = SalesHelpers.create_ticket_type!(event_a, %{name: "Dim xref ticket a"})
      other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Dim xref foreign"})

      order = create_order!(source, :completed)
      item = create_item!(order, event_a, ticket_a)

      Repo.update_all(
        from(oi in OrderItem, where: oi.id == ^item.id),
        set: [ticket_type_id: Ecto.UUID.dump!(other_ticket.id)]
      )

      dimension_snapshot = seed_dimension_snapshot!(event_a.id, ticket_a.id)
      event_snapshot = seed_event_snapshot!(event_a.id, gross_qty: 11)

      assert :ok = DashboardCache.put_event_summary(event_a.id, %{total_sold: 99})

      cleanup_ctx = %{
        event_ids: [event_a.id, other_event.id],
        order_ids: [order.id],
        source_system_ids: [source.id],
        ticket_type_ids: [ticket_a.id, other_ticket.id],
        event_snapshot_ids: [event_snapshot.id],
        dimension_snapshot_ids: [dimension_snapshot.id],
        cache_event_ids: [event_a.id]
      }

      try do
        assert {:error, :dimension_ticket_type_event_mismatch} =
                 SnapshotRefresh.refresh_event(event_a.id)

        assert [%{gross_ticket_quantity: 11}] = event_snapshot_quantities!(event_a.id)
        assert length(dimension_rows!(event_a.id)) == 1
        assert {:ok, cached} = DashboardCache.get_event_summary(event_a.id)
        assert cached.total_sold == 99
      after
        cleanup_unboxed_invariant_fixture!(cleanup_ctx)
      end
    end)
  end

  test "cross-source Event mismatch fails closed without persisting dimensions" do
    UnboxedPostgres.with_exclusive_setup(fn ->
      suffix = System.unique_integer([:positive])
      source_a = SalesHelpers.create_source_system!(%{name: "Dim xsrc a #{suffix}"})
      source_b = SalesHelpers.create_source_system!(%{name: "Dim xsrc b #{suffix}"})

      event_a =
        SalesHelpers.create_event!(source_a, %{name: "Dim xsrc event #{suffix}"})

      ticket_a = SalesHelpers.create_ticket_type!(event_a, %{name: "Dim xsrc ticket"})

      order =
        create_order!(source_a, :completed, woo_order_id: System.unique_integer([:positive]))

      create_item!(order, event_a, ticket_a,
        woo_product_id: 901,
        woo_variation_id: nil,
        quantity: 1,
        line_total: Decimal.new("10.00"),
        line_total_tax: Decimal.new("0.00")
      )

      Repo.update_all(
        from(o in Order, where: o.id == ^order.id),
        set: [source_system_id: Ecto.UUID.dump!(source_b.id)]
      )

      dimension_snapshot = seed_dimension_snapshot!(event_a.id, ticket_a.id)
      event_snapshot = seed_event_snapshot!(event_a.id, gross_qty: 12)

      cleanup_ctx = %{
        event_ids: [event_a.id],
        order_ids: [order.id],
        source_system_ids: [source_a.id, source_b.id],
        ticket_type_ids: [ticket_a.id],
        event_snapshot_ids: [event_snapshot.id],
        dimension_snapshot_ids: [dimension_snapshot.id],
        cache_event_ids: []
      }

      try do
        assert {:error, :dimension_source_event_mismatch} =
                 SnapshotRefresh.refresh_event(event_a.id)

        assert [%{gross_ticket_quantity: 12}] = event_snapshot_quantities!(event_a.id)
        assert length(dimension_rows!(event_a.id)) == 1
      after
        cleanup_unboxed_invariant_fixture!(cleanup_ctx)
      end
    end)
  end

  defp fixture! do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Dimension Refresh Event"})
    other_event = SalesHelpers.create_event!(source, %{name: "Other Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    second_ticket = SalesHelpers.create_ticket_type!(event, %{name: "VIP"})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Foreign Ticket"})

    %{
      source: source,
      event: event,
      other_event: other_event,
      ticket: ticket,
      second_ticket: second_ticket,
      other_ticket: other_ticket
    }
  end

  defp create_order!(source, status, opts \\ []) do
    timestamp = ~U[2026-05-17 08:00:00.000000Z]

    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "dim-refresh-#{System.unique_integer([:positive])}",
      status: status,
      currency: "ZAR",
      completed_at: timestamp,
      created_at_source: ~U[2026-05-17 07:00:00.000000Z],
      updated_at_source: timestamp,
      raw_total: Decimal.new("0"),
      raw_discount_total: Decimal.new("0"),
      raw_tax_total: Decimal.new("0")
    }

    Ash.create!(Order, Map.merge(defaults, Map.new(opts)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_item!(order, event, ticket, opts \\ []) do
    defaults = %{
      order_id: order.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_line_item_id: System.unique_integer([:positive]),
      woo_product_id: System.unique_integer([:positive]),
      woo_variation_id: nil,
      name: "Ticket",
      quantity: 1,
      line_subtotal: Decimal.new("10.00"),
      line_total: Decimal.new("10.00"),
      line_total_tax: Decimal.new("0.00"),
      discount_total: Decimal.new("0.00"),
      item_kind: :ticket,
      mapping_status: :mapped
    }

    Ash.create!(OrderItem, Map.merge(defaults, Map.new(opts)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp normalized_refund(refund_id, line_items, attrs \\ []) do
    defaults = %{
      woo_refund_id: refund_id,
      header_amount: Decimal.new("6.00"),
      reason: "customer request",
      source_created_at: ~U[2026-05-17 10:00:00.000000Z],
      line_items: line_items,
      shipping_refund_amount: nil,
      shipping_refund_tax: nil,
      fee_refund_amount: nil,
      fee_refund_tax: nil,
      unallocated_header_amount: Decimal.new("0.00")
    }

    Map.merge(defaults, Map.new(attrs))
  end

  defp normalized_refund_line(line_id, item, attrs \\ []) do
    defaults = %{
      woo_refund_line_item_id: line_id,
      woo_refunded_item_id: item.woo_line_item_id,
      woo_product_id: item.woo_product_id,
      woo_variation_id: item.woo_variation_id,
      refunded_quantity: 1,
      refund_subtotal_amount: Decimal.new("5.00"),
      refund_total_amount: Decimal.new("5.00"),
      refund_total_tax: Decimal.new("1.00"),
      binding_reason: nil,
      validation_reason: nil
    }

    Map.merge(defaults, Map.new(attrs))
  end

  defp malformed_refund_payload(refund_id) do
    %{
      "id" => refund_id,
      "amount" => "6.00",
      "line_items" => "not-a-list"
    }
  end

  defp dimension_rows!(event_id) do
    EventDimensionAggregateSnapshot
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.Query.sort([:currency, :dimension_kind])
    |> Ash.read!(domain: EventSales.Analytics)
  end

  defp seed_dimension_snapshot!(event_id, ticket_type_id) do
    Ash.create!(
      EventDimensionAggregateSnapshot,
      %{
        event_id: event_id,
        currency: "ZAR",
        dimension_kind: :ticket_type,
        ticket_type_id: ticket_type_id,
        gross_ticket_quantity: 1,
        gross_ticket_value: Decimal.new("1"),
        refreshed_at: ~U[2026-05-01 08:00:00.000000Z]
      },
      action: :create_snapshot,
      domain: EventSales.Analytics
    )
  end

  defp seed_event_snapshot!(event_id, opts) do
    gross_qty = Keyword.fetch!(opts, :gross_qty)

    Ash.create!(
      EventAggregateSnapshot,
      %{
        event_id: event_id,
        total_sold: 0,
        total_revenue: Decimal.new("0"),
        today_sold: 0,
        today_revenue: Decimal.new("0"),
        gross_ticket_quantity: gross_qty,
        refund_ticket_quantity: 0,
        gross_ticket_value: Decimal.new("100"),
        refund_ticket_value: Decimal.new("0"),
        recognised_order_count: 1,
        currency: "ZAR",
        business_timezone: "Africa/Johannesburg",
        refreshed_at: ~U[2026-05-01 08:00:00.000000Z],
        source_row_count: 0,
        snapshot_version: 2
      },
      action: :create_snapshot,
      domain: EventSales.Analytics
    )
  end

  defp event_snapshot_quantities!(event_id) do
    EventAggregateSnapshot
    |> Ash.Query.filter(event_id == ^event_id and snapshot_version == 2)
    |> Ash.read!(domain: EventSales.Analytics)
    |> Enum.map(&Map.take(&1, [:gross_ticket_quantity]))
  end

  defp cleanup_unboxed_invariant_fixture!(ctx) do
    invalidate_unboxed_cache_keys!(ctx)
    delete_unboxed_snapshot_rows!(ctx)
    delete_unboxed_order_rows!(ctx)
    delete_unboxed_catalog_rows!(ctx)
  end

  defp invalidate_unboxed_cache_keys!(ctx) do
    Enum.each(ctx[:cache_event_ids] || [], &DashboardCache.invalidate_event(&1, :test_teardown))
  end

  defp delete_unboxed_snapshot_rows!(ctx) do
    delete_ids!(EventDimensionAggregateSnapshot, ctx[:dimension_snapshot_ids])
    delete_ids!(EventAggregateSnapshot, ctx[:event_snapshot_ids])

    event_ids = ctx[:event_ids] || []

    if event_ids != [] do
      Repo.delete_all(from(d in EventDimensionAggregateSnapshot, where: d.event_id in ^event_ids))
      Repo.delete_all(from(d in EventAggregateSnapshot, where: d.event_id in ^event_ids))
    end
  end

  defp delete_unboxed_order_rows!(ctx) do
    order_ids = ctx[:order_ids] || []

    if order_ids != [] do
      Repo.delete_all(from(oi in OrderItem, where: oi.order_id in ^order_ids))
      Repo.delete_all(from(o in Order, where: o.id in ^order_ids))
    end
  end

  defp delete_unboxed_catalog_rows!(ctx) do
    delete_ids!(TicketType, ctx[:ticket_type_ids])
    delete_ids!(Event, ctx[:event_ids])
    delete_ids!(SourceSystem, ctx[:source_system_ids])
  end

  defp delete_ids!(schema, ids) when ids in [nil, []], do: :ok

  defp delete_ids!(schema, ids) do
    Repo.delete_all(from(row in schema, where: row.id in ^ids))
  end
end
