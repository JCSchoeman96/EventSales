defmodule EventSales.Analytics.EventSnapshotRefreshFenceTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.EventSnapshotRefreshFence
  alias EventSales.Repo
  alias EventSales.TestSupport.UnboxedPostgres

  test "requires an active PostgreSQL transaction" do
    assert {:error, :event_snapshot_refresh_fence_transaction_required} =
             EventSnapshotRefreshFence.acquire(Ecto.UUID.generate())
  end

  test "rejects malformed event ids" do
    assert {:ok, {:error, :invalid_event_id}} =
             Repo.transaction(fn -> EventSnapshotRefreshFence.acquire("not-a-uuid") end)
  end

  test "holds the refresh fence until the physical transaction commits" do
    event_id = Ecto.UUID.generate()
    parent = self()

    holder =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          Repo.transaction(fn ->
            assert :ok = EventSnapshotRefreshFence.acquire(event_id)
            send(parent, :refresh_fence_held)

            receive do
              :release_refresh_fence -> :ok
            end
          end)
        end)
      end)

    assert_receive :refresh_fence_held, 5_000

    waiter =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          Repo.transaction(fn ->
            assert :ok = EventSnapshotRefreshFence.acquire(event_id)
            send(parent, :waiter_acquired)
            :ok
          end)
        end)
      end)

    refute_receive :waiter_acquired, 250
    send(holder.pid, :release_refresh_fence)
    assert_receive :waiter_acquired, 5_000

    assert {:ok, :ok} = Task.await(holder, 5_000)
    assert {:ok, :ok} = Task.await(waiter, 5_000)
  end

  defp with_unboxed_connection(fun), do: UnboxedPostgres.with_connection(fun)
end
