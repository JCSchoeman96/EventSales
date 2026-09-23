defmodule EventSales.Analytics.EventSnapshotRefreshConcurrencyTest do
  use ExUnit.Case, async: false

  import Ecto.Query

  require Ash.Query

  alias EventSales.Analytics.{EventSnapshotRefreshFence, SnapshotRefresh}
  alias EventSales.Analytics.Resources.EventAggregateSnapshot
  alias EventSales.Catalog.Resources.{Event, SourceSystem, TicketType}
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.{SalesHelpers, UnboxedPostgres}

  test "concurrent refresh_event calls serialize on the same event" do
    fixture = create_committed_fixture!()
    on_exit(fn -> cleanup_committed_fixture!(fixture) end)

    parent = self()

    holder =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          Repo.transaction(fn ->
            assert :ok = EventSnapshotRefreshFence.acquire(fixture.event_id)
            send(parent, {:refresh_fence_held, self()})

            receive do
              :release_refresh_fence -> :ok
            after
              15_000 -> Repo.rollback(:refresh_fence_release_timeout)
            end
          end)
        end)
      end)

    assert_receive {:refresh_fence_held, _holder_pid}, 5_000

    waiter =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          result = SnapshotRefresh.refresh_event(fixture.event_id)
          send(parent, {:waiter_refresh, result})
          result
        end)
      end)

    refute_receive {:waiter_refresh, _}, 250
    send(holder.pid, :release_refresh_fence)

    assert {:ok, snapshots} = Task.await(waiter, 15_000)
    assert is_list(snapshots)
    assert {:ok, :ok} = Task.await(holder, 15_000)
  end

  test "each successful refresh replaces the full event v2 set without leaving stale currencies" do
    fixture = create_committed_fixture!()
    on_exit(fn -> cleanup_committed_fixture!(fixture) end)

    assert {:ok, snapshots} =
             with_unboxed_connection(fn -> SnapshotRefresh.refresh_event(fixture.event_id) end)

    assert Enum.map(snapshots, & &1.currency) |> Enum.sort() == ["USD", "ZAR"]

    with_unboxed_connection(fn ->
      delete_items_for_order!(fixture.usd_order_id)
    end)

    assert {:ok, [only_zar]} =
             with_unboxed_connection(fn -> SnapshotRefresh.refresh_event(fixture.event_id) end)

    assert only_zar.currency == "ZAR"

    currencies =
      with_unboxed_connection(fn ->
        EventAggregateSnapshot
        |> Ash.Query.filter(event_id == ^fixture.event_id and snapshot_version == 2)
        |> Ash.read!(domain: EventSales.Analytics)
        |> Enum.map(& &1.currency)
      end)

    assert currencies == ["ZAR"]
  end

  test "overlapping refreshes with different canonical currency sets cannot commit a mixed union" do
    fixture = create_committed_fixture!()
    on_exit(fn -> cleanup_committed_fixture!(fixture) end)

    parent = self()

    holder =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          Repo.transaction(fn ->
            assert :ok = EventSnapshotRefreshFence.acquire(fixture.event_id)
            send(parent, {:refresh_fence_held, self()})

            receive do
              :release_refresh_fence -> :ok
            after
              15_000 -> Repo.rollback(:refresh_fence_release_timeout)
            end
          end)
        end)
      end)

    assert_receive {:refresh_fence_held, _holder_pid}, 5_000

    with_unboxed_connection(fn ->
      delete_items_for_order!(fixture.usd_order_id)
    end)

    waiter =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          SnapshotRefresh.refresh_event(fixture.event_id)
        end)
      end)

    refute_receive {:waiter_refresh, _}, 250
    send(holder.pid, :release_refresh_fence)

    assert {:ok, [zar_snapshot]} = Task.await(waiter, 15_000)
    assert zar_snapshot.currency == "ZAR"
    assert {:ok, :ok} = Task.await(holder, 15_000)

    restore_usd_line_item!(fixture)

    assert {:ok, [usd_snapshot]} =
             with_unboxed_connection(fn ->
               delete_items_for_order!(fixture.zar_order_id)
               SnapshotRefresh.refresh_event(fixture.event_id)
             end)

    assert usd_snapshot.currency == "USD"

    durable_currencies =
      with_unboxed_connection(fn ->
        EventAggregateSnapshot
        |> Ash.Query.filter(event_id == ^fixture.event_id and snapshot_version == 2)
        |> Ash.Query.sort(currency: :asc)
        |> Ash.read!(domain: EventSales.Analytics)
        |> Enum.map(& &1.currency)
      end)

    assert durable_currencies == ["USD"]
    refute durable_currencies == ["USD", "ZAR"]
  end

  defp create_committed_fixture! do
    suffix = System.unique_integer([:positive])

    with_unboxed_connection(fn ->
      source =
        SalesHelpers.create_source_system!(%{
          name: "Refresh race source #{suffix}",
          base_url: "https://refresh-race-#{suffix}.example.test"
        })

      event =
        SalesHelpers.create_event!(source, %{
          name: "Refresh race event #{suffix}",
          slug: "refresh-race-#{suffix}"
        })

      ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

      zar_order =
        create_order!(source, :completed,
          woo_order_id: 93_001 + suffix,
          currency: "ZAR",
          completed_at: ~U[2026-05-17 08:00:00.000000Z]
        )

      usd_order =
        create_order!(source, :completed,
          woo_order_id: 93_002 + suffix,
          currency: "USD",
          completed_at: ~U[2026-05-17 08:00:00.000000Z]
        )

      create_item!(zar_order, event, ticket,
        woo_line_item_id: 1,
        quantity: 1,
        line_total: Decimal.new("450.00"),
        line_total_tax: Decimal.new("67.50")
      )

      create_item!(usd_order, event, ticket,
        woo_line_item_id: 2,
        quantity: 1,
        line_total: Decimal.new("50.00"),
        line_total_tax: Decimal.new("7.50")
      )

      %{
        event_id: event.id,
        source_id: source.id,
        ticket_type_id: ticket.id,
        zar_order_id: zar_order.id,
        usd_order_id: usd_order.id
      }
    end)
  end

  defp create_order!(source, status, attrs) do
    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "RR-#{System.unique_integer([:positive])}",
      status: status,
      currency: "ZAR",
      completed_at: ~U[2026-05-17 08:00:00.000000Z],
      created_at_source: ~U[2026-05-17 07:00:00.000000Z],
      updated_at_source: ~U[2026-05-17 08:00:00.000000Z],
      raw_total: Decimal.new("0"),
      raw_discount_total: Decimal.new("0"),
      raw_tax_total: Decimal.new("0")
    }

    Ash.create!(Order, Map.merge(defaults, Map.new(attrs)),
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

    Ash.create!(OrderItem, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp cleanup_committed_fixture!(%{event_id: event_id, source_id: source_id}) do
    with_unboxed_connection(fn ->
      Repo.delete_all(
        from(snapshot in EventAggregateSnapshot, where: snapshot.event_id == ^event_id)
      )

      Repo.delete_all(from(item in OrderItem, where: item.event_id == ^event_id))
      Repo.delete_all(from(order in Order, where: order.source_system_id == ^source_id))
      Repo.delete_all(from(tt in TicketType, where: tt.event_id == ^event_id))
      Repo.delete_all(from(event in Event, where: event.id == ^event_id))
      Repo.delete_all(from(source in SourceSystem, where: source.id == ^source_id))
    end)
  end

  defp with_unboxed_connection(fun), do: UnboxedPostgres.with_connection(fun)

  defp delete_items_for_order!(order_id) do
    Repo.query!(
      "DELETE FROM sales_order_items WHERE order_id = $1",
      [Ecto.UUID.dump!(order_id)]
    )
  end

  defp restore_usd_line_item!(fixture) do
    with_unboxed_connection(fn ->
      event = Ash.get!(Event, fixture.event_id, domain: EventSales.Catalog)
      ticket = Ash.get!(TicketType, fixture.ticket_type_id, domain: EventSales.Catalog)
      order = Ash.get!(Order, fixture.usd_order_id, domain: Sales)

      delete_items_for_order!(fixture.usd_order_id)

      create_item!(order, event, ticket,
        woo_line_item_id: 2,
        quantity: 1,
        line_total: Decimal.new("50.00"),
        line_total_tax: Decimal.new("7.50")
      )
    end)
  end
end
