defmodule EventSales.Analytics.EventSnapshotRefreshFenceTest do
  use ExUnit.Case, async: false

  alias EventSales.Analytics.EventSnapshotRefreshFence
  alias EventSales.Repo
  alias EventSales.TestSupport.EventSnapshotRefreshTestSupport
  alias EventSales.TestSupport.UnboxedPostgres

  test "unboxed refresh transaction uses repeatable read after the session fence" do
    event_id = Ecto.UUID.generate()

    UnboxedPostgres.with_connection(fn ->
      assert EventSnapshotRefreshFence.use_repeatable_read_isolation?()

      EventSnapshotRefreshFence.with_serial_event_refresh(event_id, fn ->
        transaction_opts =
          [timeout: 30_000] ++ EventSnapshotRefreshFence.coherent_transaction_opts()

        assert {:ok, :ok} =
                 Repo.transaction(
                   fn ->
                     level = EventSnapshotRefreshTestSupport.transaction_isolation_level()
                     assert String.downcase(level) == "repeatable read"
                     :ok
                   end,
                   transaction_opts
                 )
      end)
    end)
  end

  test "session fence blocks a second connection until the holder releases the lock" do
    event_id = Ecto.UUID.generate()
    parent = self()

    holder =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          holder_backend = EventSnapshotRefreshFence.connection_backend_pid()

          EventSnapshotRefreshFence.with_serial_event_refresh(event_id, fn ->
            send(parent, {:holder_ready, holder_backend})

            receive do
              :release_session_fence -> :ok
            after
              15_000 -> :timeout
            end
          end)
        end)
      end)

    assert_receive {:holder_ready, holder_backend}, 5_000

    waiter =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          waiter_backend = EventSnapshotRefreshFence.connection_backend_pid()
          send(parent, {:waiter_backend, waiter_backend})

          EventSnapshotRefreshFence.with_serial_event_refresh(event_id, fn ->
            send(parent, :waiter_acquired)
            :ok
          end)
        end)
      end)

    assert_receive {:waiter_backend, waiter_backend}, 5_000
    assert waiter_backend != holder_backend

    EventSnapshotRefreshTestSupport.wait_for_advisory_lock_wait!(waiter_backend)
    refute_receive :waiter_acquired, 200

    send(holder.pid, :release_session_fence)
    assert_receive :waiter_acquired, 5_000

    assert :ok = Task.await(holder, 5_000)
    assert :ok = Task.await(waiter, 5_000)
  end

  test "rejects malformed event ids" do
    assert {:error, :invalid_event_id} =
             EventSnapshotRefreshFence.with_serial_event_refresh("not-a-uuid", fn -> :ok end)
  end

  test "successful fenced callback releases the session lock" do
    event_id = Ecto.UUID.generate()
    assert {:ok, key} = EventSnapshotRefreshFence.lock_key(event_id)

    UnboxedPostgres.with_connection(fn ->
      assert :ok =
               EventSnapshotRefreshFence.with_serial_event_refresh(event_id, fn -> :ok end)

      assert session_lock_available?(key)
    end)
  end

  test "raised fenced callback still releases the session lock for another backend" do
    event_id = Ecto.UUID.generate()
    assert {:ok, key} = EventSnapshotRefreshFence.lock_key(event_id)

    UnboxedPostgres.with_connection(fn ->
      assert {:error, :event_snapshot_refresh_fence_failed} =
               EventSnapshotRefreshFence.with_serial_event_refresh(event_id, fn ->
                 raise "boom"
               end)

      assert session_lock_available?(key)
    end)

    parent = self()

    releaser =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          backend = EventSnapshotRefreshFence.connection_backend_pid()
          send(parent, {:releaser_backend, backend})

          EventSnapshotRefreshFence.with_serial_event_refresh(event_id, fn ->
            send(parent, :reacquired)
            :ok
          end)
        end)
      end)

    assert_receive {:releaser_backend, _backend}, 5_000
    assert_receive :reacquired, 5_000
    assert :ok = Task.await(releaser, 5_000)
  end

  defp session_lock_available?(key) do
    case Repo.query("SELECT pg_try_advisory_lock($1::bigint)", [key]) do
      {:ok, %{rows: [[true]]}} ->
        Repo.query!("SELECT pg_advisory_unlock($1::bigint)", [key])
        true

      _ ->
        false
    end
  end
end
