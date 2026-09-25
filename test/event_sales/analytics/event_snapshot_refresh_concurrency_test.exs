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
  alias EventSales.TestSupport.EventSnapshotRefreshTestSupport
  alias EventSales.TestSupport.{SalesHelpers, UnboxedPostgres}

  test "concurrent refresh_event calls block on the PostgreSQL session fence" do
    fixture = create_committed_fixture!()
    on_exit(fn -> cleanup_committed_fixture!(fixture) end)

    parent = self()

    holder =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          EventSnapshotRefreshFence.with_serial_event_refresh(fixture.event_id, fn ->
            send(parent, {:holder_backend, EventSnapshotRefreshFence.connection_backend_pid()})

            receive do
              :release_session_fence -> :ok
            after
              15_000 -> :timeout
            end
          end)
        end)
      end)

    assert_receive {:holder_backend, holder_backend}, 5_000

    waiter =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          waiter_backend = EventSnapshotRefreshFence.connection_backend_pid()
          send(parent, {:waiter_backend, waiter_backend})
          SnapshotRefresh.refresh_event(fixture.event_id)
        end)
      end)

    assert_receive {:waiter_backend, waiter_backend}, 5_000
    assert waiter_backend != holder_backend

    EventSnapshotRefreshTestSupport.wait_for_advisory_lock_wait!(waiter_backend)
    refute_receive {:waiter_done, _}, 200

    send(holder.pid, :release_session_fence)

    assert {:ok, snapshots} = Task.await(waiter, 15_000)
    assert length(snapshots) == 2
    assert :ok = Task.await(holder, 15_000)
  end

  test "each successful refresh replaces the full event v2 set without leaving stale currencies" do
    fixture = create_committed_fixture!()
    on_exit(fn -> cleanup_committed_fixture!(fixture) end)

    assert {:ok, snapshots} =
             UnboxedPostgres.with_connection(fn ->
               SnapshotRefresh.refresh_event(fixture.event_id)
             end)

    assert Enum.map(snapshots, & &1.currency) |> Enum.sort() == ["USD", "ZAR"]

    UnboxedPostgres.with_connection(fn ->
      delete_items_for_order!(fixture.usd_order_id)
    end)

    assert {:ok, [only_zar]} =
             UnboxedPostgres.with_connection(fn ->
               SnapshotRefresh.refresh_event(fixture.event_id)
             end)

    assert only_zar.currency == "ZAR"
    assert only_zar.gross_ticket_quantity == 1

    currencies =
      UnboxedPostgres.with_connection(fn ->
        EventAggregateSnapshot
        |> Ash.Query.filter(event_id == ^fixture.event_id and snapshot_version == 2)
        |> Ash.read!(domain: EventSales.Analytics)
        |> Enum.map(& &1.currency)
      end)

    assert currencies == ["ZAR"]
  end

  test "overlapping refresh_event uses source facts visible after acquiring the session fence" do
    fixture = create_committed_fixture!()
    on_exit(fn -> cleanup_committed_fixture!(fixture) end)

    parent = self()

    holder =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          EventSnapshotRefreshFence.with_serial_event_refresh(fixture.event_id, fn ->
            send(parent, {:holder_backend, EventSnapshotRefreshFence.connection_backend_pid()})

            receive do
              :release_session_fence -> :ok
            after
              20_000 -> :timeout
            end
          end)
        end)
      end)

    assert_receive {:holder_backend, _holder_backend}, 5_000

    waiter =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          waiter_backend = EventSnapshotRefreshFence.connection_backend_pid()
          send(parent, {:waiter_backend, waiter_backend})
          SnapshotRefresh.refresh_event(fixture.event_id)
        end)
      end)

    assert_receive {:waiter_backend, waiter_backend}, 5_000
    EventSnapshotRefreshTestSupport.wait_for_advisory_lock_wait!(waiter_backend)

    UnboxedPostgres.with_connection(fn ->
      delete_items_for_order!(fixture.usd_order_id)
    end)

    send(holder.pid, :release_session_fence)

    assert {:ok, [zar_snapshot]} = Task.await(waiter, 20_000)
    assert zar_snapshot.currency == "ZAR"
    assert zar_snapshot.gross_ticket_quantity == 1
    assert zar_snapshot.gross_ticket_value |> Decimal.compare(Decimal.new("0")) == :gt

    durable =
      UnboxedPostgres.with_connection(fn ->
        Ash.read!(
          EventAggregateSnapshot
          |> Ash.Query.filter(event_id == ^fixture.event_id and snapshot_version == 2),
          domain: EventSales.Analytics
        )
      end)

    assert length(durable) == 1
    assert hd(durable).currency == "ZAR"
    refute Enum.map(durable, & &1.currency) |> Enum.sort() == ["USD", "ZAR"]
  end

  test "two overlapping refresh_event calls serialize without leaving a mixed currency set" do
    fixture = create_committed_fixture!()
    on_exit(fn -> cleanup_committed_fixture!(fixture) end)

    parent = self()

    holder =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          EventSnapshotRefreshFence.with_serial_event_refresh(fixture.event_id, fn ->
            send(parent, :holder_ready)

            receive do
              :release_session_fence -> :ok
            after
              20_000 -> :timeout
            end
          end)
        end)
      end)

    assert_receive :holder_ready, 5_000

    UnboxedPostgres.with_connection(fn ->
      delete_items_for_order!(fixture.usd_order_id)
    end)

    first_refresh =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          backend = EventSnapshotRefreshFence.connection_backend_pid()
          send(parent, {:refresh_waiter, backend})
          SnapshotRefresh.refresh_event(fixture.event_id)
        end)
      end)

    second_refresh =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          backend = EventSnapshotRefreshFence.connection_backend_pid()
          send(parent, {:refresh_waiter, backend})
          SnapshotRefresh.refresh_event(fixture.event_id)
        end)
      end)

    assert_receive {:refresh_waiter, first_backend}, 5_000
    assert_receive {:refresh_waiter, second_backend}, 5_000
    assert first_backend != second_backend

    EventSnapshotRefreshTestSupport.wait_for_advisory_lock_wait!(first_backend)
    EventSnapshotRefreshTestSupport.wait_for_advisory_lock_wait!(second_backend)

    send(holder.pid, :release_session_fence)

    assert {:ok, first_result} = Task.await(first_refresh, 20_000)
    assert {:ok, second_result} = Task.await(second_refresh, 20_000)

    assert Enum.map(first_result, & &1.currency) == ["ZAR"]
    assert Enum.map(second_result, & &1.currency) == ["ZAR"]

    durable =
      UnboxedPostgres.with_connection(fn ->
        Ash.read!(
          EventAggregateSnapshot
          |> Ash.Query.filter(event_id == ^fixture.event_id and snapshot_version == 2),
          domain: EventSales.Analytics
        )
      end)

    assert length(durable) == 1
    assert hd(durable).currency == "ZAR"
    assert hd(durable).gross_ticket_quantity == 1
    refute Enum.map(durable, & &1.currency) == ["USD", "ZAR"]
  end

  test "two concurrent refresh_event calls on the same source leave one coherent projection set" do
    fixture = create_committed_fixture!()
    on_exit(fn -> cleanup_committed_fixture!(fixture) end)

    first =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn -> SnapshotRefresh.refresh_event(fixture.event_id) end)
      end)

    second =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn -> SnapshotRefresh.refresh_event(fixture.event_id) end)
      end)

    assert {:ok, first_snapshots} = Task.await(first, 20_000)
    assert {:ok, second_snapshots} = Task.await(second, 20_000)

    assert Enum.map(first_snapshots, & &1.currency) |> Enum.sort() == ["USD", "ZAR"]
    assert Enum.map(second_snapshots, & &1.currency) |> Enum.sort() == ["USD", "ZAR"]

    durable =
      UnboxedPostgres.with_connection(fn ->
        Ash.read!(
          EventAggregateSnapshot
          |> Ash.Query.filter(event_id == ^fixture.event_id and snapshot_version == 2)
          |> Ash.Query.sort(currency: :asc),
          domain: EventSales.Analytics
        )
      end)

    assert length(durable) == 2
    assert Enum.map(durable, & &1.currency) == ["USD", "ZAR"]
    refute Enum.any?(durable, fn row -> row.gross_ticket_quantity != 1 end)
  end

  defp create_committed_fixture! do
    suffix = System.unique_integer([:positive])

    UnboxedPostgres.with_exclusive_setup(fn ->
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
    UnboxedPostgres.with_exclusive_setup(fn ->
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

  defp delete_items_for_order!(order_id) do
    Repo.query!(
      "DELETE FROM sales_order_items WHERE order_id = $1",
      [Ecto.UUID.dump!(order_id)]
    )
  end
end
