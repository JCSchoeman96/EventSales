defmodule EventSales.Analytics.EventDimensionSnapshotRefreshTest do
  use EventSales.DataCase, async: false

  import Ecto.Query

  require Ash.Query

  alias EventSales.Analytics.{DashboardCache, SnapshotRefresh}
  alias EventSales.Analytics.Resources.{EventAggregateSnapshot, EventDimensionAggregateSnapshot}
  alias EventSales.Catalog.Resources.{Event, SourceSystem, TicketType}
  alias EventSales.Repo
  alias EventSales.Sales
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
