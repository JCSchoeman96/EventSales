defmodule EventSales.Analytics.EventSnapshotRefreshRollbackTest do
  use ExUnit.Case, async: false

  require Ash.Query

  alias EventSales.Analytics.{DashboardCache, SnapshotRefresh}
  alias EventSales.Analytics.Resources.EventAggregateSnapshot
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.TestSupport.{SalesHelpers, UnboxedPostgres}

  setup do
    DashboardCache.ensure_table!()
    :ok
  end

  test "failed multi-currency refresh rolls back and leaves cache intact" do
    with_unboxed_connection(fn ->
      source = SalesHelpers.create_source_system!()

      event =
        SalesHelpers.create_event!(source, %{
          name: "Rollback Event",
          slug: "rollback-#{System.unique_integer([:positive])}"
        })

      ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

      assert {:ok, zar} =
               Ash.create(
                 EventAggregateSnapshot,
                 snapshot_attrs(event.id, "ZAR", 9),
                 action: :create_snapshot,
                 domain: EventSales.Analytics
               )

      assert {:ok, usd} =
               Ash.create(
                 EventAggregateSnapshot,
                 snapshot_attrs(event.id, "USD", 3),
                 action: :create_snapshot,
                 domain: EventSales.Analytics
               )

      zar_order =
        create_order!(source, :completed,
          woo_order_id: 94_001,
          currency: "ZAR",
          completed_at: ~U[2026-05-17 08:00:00.000000Z]
        )

      usd_order =
        create_order!(source, :completed,
          woo_order_id: 94_002,
          currency: "USD",
          completed_at: ~U[2026-05-17 08:00:00.000000Z]
        )

      create_item!(zar_order, event, ticket,
        woo_line_item_id: 1,
        line_total: Decimal.new("450.00"),
        line_total_tax: Decimal.new("67.50")
      )

      create_item!(usd_order, event, ticket,
        woo_line_item_id: 2,
        line_total: Decimal.new("50.00"),
        line_total_tax: Decimal.new("7.50")
      )

      assert :ok = DashboardCache.put_event_summary(event.id, %{total_sold: 42})

      constraint = "evt_snap_block_usd_#{System.unique_integer([:positive])}"

      try do
        Repo.query!(
          "ALTER TABLE analytics_event_aggregate_snapshots ADD CONSTRAINT #{constraint} CHECK (NOT (currency = 'USD' AND snapshot_version = 2)) NOT VALID"
        )

        assert {:error, _reason} = SnapshotRefresh.refresh_event(event.id)

        assert {:ok, persisted_zar} =
                 Ash.get(EventAggregateSnapshot, zar.id, domain: EventSales.Analytics)

        assert {:ok, persisted_usd} =
                 Ash.get(EventAggregateSnapshot, usd.id, domain: EventSales.Analytics)

        assert persisted_zar.gross_ticket_quantity == 9
        assert persisted_usd.gross_ticket_quantity == 3
        assert {:ok, cached} = DashboardCache.get_event_summary(event.id)
        assert cached.total_sold == 42
      after
        Repo.query!(
          "ALTER TABLE analytics_event_aggregate_snapshots DROP CONSTRAINT IF EXISTS #{constraint}"
        )

        cleanup_unboxed_fixture!(event.id, source.id, [zar.id, usd.id])
      end
    end)
  end

  defp cleanup_unboxed_fixture!(event_id, source_id, snapshot_ids) do
    import Ecto.Query

    alias EventSales.Catalog.Resources.{Event, SourceSystem, TicketType}
    alias EventSales.Sales.Resources.{Order, OrderItem}

    Repo.delete_all(from(snapshot in EventAggregateSnapshot, where: snapshot.id in ^snapshot_ids))
    Repo.delete_all(from(item in OrderItem, where: item.event_id == ^event_id))
    Repo.delete_all(from(order in Order, where: order.source_system_id == ^source_id))
    Repo.delete_all(from(tt in TicketType, where: tt.event_id == ^event_id))
    Repo.delete_all(from(event in Event, where: event.id == ^event_id))
    Repo.delete_all(from(source in SourceSystem, where: source.id == ^source_id))
  end

  defp snapshot_attrs(event_id, currency, gross_qty) do
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
      currency: currency,
      business_timezone: "Africa/Johannesburg",
      refreshed_at: ~U[2026-05-18 08:00:00.000000Z],
      source_row_count: 0,
      snapshot_version: 2
    }
  end

  defp create_order!(source, status, attrs) do
    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "RB-#{System.unique_integer([:positive])}",
      status: status,
      currency: "ZAR",
      completed_at: ~U[2026-05-17 08:00:00.000000Z],
      created_at_source: ~U[2026-05-17 07:00:00.000000Z],
      updated_at_source: ~U[2026-05-17 08:00:00.000000Z],
      raw_total: Decimal.new("0"),
      raw_discount_total: Decimal.new("0"),
      raw_tax_total: Decimal.new("0")
    }

    Ash.create!(EventSales.Sales.Resources.Order, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_item!(order, event, ticket, attrs) do
    defaults = %{
      order_id: order.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_line_item_id: System.unique_integer([:positive]),
      woo_product_id: System.unique_integer([:positive]),
      name: "Ticket",
      quantity: 1,
      line_subtotal: Decimal.new("450.00"),
      line_total: Decimal.new("450.00"),
      line_total_tax: Decimal.new("0"),
      discount_total: Decimal.new("0"),
      item_kind: :ticket,
      mapping_status: :mapped
    }

    Ash.create!(EventSales.Sales.Resources.OrderItem, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp with_unboxed_connection(fun), do: UnboxedPostgres.with_connection(fun)
end
