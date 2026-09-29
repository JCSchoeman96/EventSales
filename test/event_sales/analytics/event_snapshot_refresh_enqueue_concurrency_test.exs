defmodule EventSales.Analytics.EventSnapshotRefreshEnqueueConcurrencyTest do
  use ExUnit.Case, async: false

  alias EventSales.Analytics.Workers.RefreshSnapshotWorker
  alias EventSales.Repo
  alias EventSales.TestSupport.UnboxedPostgres

  setup do
    event_ids = Enum.map(1..3, fn _ -> Ecto.UUID.generate() end)

    on_exit(fn ->
      UnboxedPostgres.with_connection(fn ->
        Enum.each(event_ids, &delete_event_jobs/1)
      end)
    end)

    %{event_ids: event_ids}
  end

  test "pending event refresh requests coalesce without moving the debounce", %{
    event_ids: [event_id | _]
  } do
    UnboxedPostgres.with_connection(fn ->
      assert :ok = RefreshSnapshotWorker.enqueue_event(event_id)
      [first] = event_jobs(event_id)

      assert first.state == "scheduled"
      first_request_id = first.meta["refresh_request_id"]

      assert :ok = RefreshSnapshotWorker.enqueue_event(event_id)
      [second] = event_jobs(event_id)

      assert second.id == first.id
      assert second.state == "scheduled"
      assert second.scheduled_at == first.scheduled_at
      assert second.meta["refresh_request_id"] != first_request_id
    end)
  end

  test "different events retain separate pending jobs", %{event_ids: [first_id, second_id | _]} do
    UnboxedPostgres.with_connection(fn ->
      assert :ok = RefreshSnapshotWorker.enqueue_events([second_id, first_id])

      assert Enum.map(event_jobs(first_id), & &1.args["event_id"]) == [first_id]
      assert Enum.map(event_jobs(second_id), & &1.args["event_id"]) == [second_id]
    end)
  end

  test "an executing event job permits a trailing pending job", %{event_ids: [event_id | _]} do
    UnboxedPostgres.with_connection(fn ->
      assert :ok = RefreshSnapshotWorker.enqueue_event(event_id)
      [first] = event_jobs(event_id)

      assert {:ok, %{num_rows: 1}} =
               Repo.query("UPDATE oban_jobs SET state = 'executing' WHERE id = $1", [first.id])

      assert :ok = RefreshSnapshotWorker.enqueue_event(event_id)

      jobs = event_jobs(event_id)
      assert length(jobs) == 2
      assert Enum.any?(jobs, &(&1.id == first.id and &1.state == "executing"))
      assert Enum.any?(jobs, &(&1.id != first.id and &1.state == "scheduled"))
    end)
  end

  test "an outer transaction rollback removes its refresh job", %{event_ids: [event_id | _]} do
    UnboxedPostgres.with_connection(fn ->
      assert {:error, :forced_rollback} =
               Repo.transaction(fn ->
                 assert :ok = RefreshSnapshotWorker.enqueue_event(event_id)
                 Repo.rollback(:forced_rollback)
               end)

      assert event_jobs(event_id) == []
    end)
  end

  test "a pending conflict holds the job row lock through the outer transaction", %{
    event_ids: [event_id | _]
  } do
    UnboxedPostgres.with_connection(fn ->
      assert :ok = RefreshSnapshotWorker.enqueue_event(event_id)
    end)

    [job] = UnboxedPostgres.with_connection(fn -> event_jobs(event_id) end)
    parent = self()

    holder =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          holder_backend_pid = backend_pid()

          result =
            Repo.transaction(fn ->
              assert :ok = RefreshSnapshotWorker.enqueue_event(event_id)
              send(parent, {:pending_conflict_touched, holder_backend_pid})

              receive do
                :release_holder -> :committed
              after
                15_000 -> Repo.rollback(:holder_timeout)
              end
            end)

          send(parent, {:holder_finished, result})
        end)
      end)

    assert_receive {:pending_conflict_touched, holder_backend_pid}, 5_000

    contender =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          contender_backend_pid = backend_pid()
          send(parent, {:claim_started, contender_backend_pid})

          result =
            Repo.query!(
              "UPDATE oban_jobs SET state = 'executing' WHERE id = $1 RETURNING id",
              [job.id]
            )

          send(parent, {:claim_finished, result.num_rows})
        end)
      end)

    assert_receive {:claim_started, contender_backend_pid}, 5_000

    try do
      blockers = wait_for_row_lock_wait!(contender_backend_pid)
      assert holder_backend_pid in blockers
      refute_receive {:claim_finished, _count}, 0
    after
      send(holder.pid, :release_holder)
    end

    assert_receive {:holder_finished, {:ok, :committed}}, 5_000
    assert_receive {:claim_finished, 1}, 5_000
    assert {:holder_finished, {:ok, :committed}} = Task.await(holder, 5_000)
    assert {:claim_finished, 1} = Task.await(contender, 5_000)

    [claimed] = UnboxedPostgres.with_connection(fn -> event_jobs(event_id) end)
    assert claimed.state == "executing"
  end

  test "a claim between uniqueness lookup and replacement leaves a trailing refresh", %{
    event_ids: [event_id | _]
  } do
    UnboxedPostgres.with_connection(fn ->
      assert :ok = RefreshSnapshotWorker.enqueue_event(event_id)
    end)

    [job] = UnboxedPostgres.with_connection(fn -> event_jobs(event_id) end)
    parent = self()

    holder =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          holder_backend_pid = backend_pid()

          result =
            Repo.transaction(fn ->
              assert {:ok, %{num_rows: 1}} =
                       Repo.query("UPDATE oban_jobs SET state = 'executing' WHERE id = $1", [
                         job.id
                       ])

              send(parent, {:claim_row_locked, holder_backend_pid})

              receive do
                :release_holder -> :claimed
              after
                15_000 -> Repo.rollback(:holder_timeout)
              end
            end)

          send(parent, {:claim_holder_finished, result})
        end)
      end)

    assert_receive {:claim_row_locked, holder_backend_pid}, 5_000

    contender =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          contender_backend_pid = backend_pid()
          send(parent, {:enqueue_started, contender_backend_pid})

          result =
            Repo.transaction(fn ->
              assert :ok = RefreshSnapshotWorker.enqueue_event(event_id)
              :enqueued
            end)

          send(parent, {:enqueue_finished, result})
        end)
      end)

    assert_receive {:enqueue_started, contender_backend_pid}, 5_000

    try do
      blockers = wait_for_row_lock_wait!(contender_backend_pid)
      assert holder_backend_pid in blockers
    after
      send(holder.pid, :release_holder)
    end

    assert_receive {:claim_holder_finished, {:ok, :claimed}}, 5_000
    assert_receive {:enqueue_finished, {:ok, :enqueued}}, 5_000
    assert {:claim_holder_finished, {:ok, :claimed}} = Task.await(holder, 5_000)
    assert {:enqueue_finished, {:ok, :enqueued}} = Task.await(contender, 5_000)

    jobs = UnboxedPostgres.with_connection(fn -> event_jobs(event_id) end)
    assert length(jobs) == 2
    assert Enum.any?(jobs, &(&1.id == job.id and &1.state == "executing"))
    assert Enum.any?(jobs, &(&1.id != job.id and &1.state == "scheduled"))
  end

  defp event_jobs(event_id) do
    result =
      Repo.query!(
        """
        SELECT id, state, args, meta, scheduled_at
        FROM oban_jobs
        WHERE worker = $1 AND args ->> 'scope' = 'event' AND args ->> 'event_id' = $2
        ORDER BY id
        """,
        [worker_name(), event_id]
      )

    Enum.map(result.rows, fn [id, state, args, meta, scheduled_at] ->
      %{id: id, state: state, args: args, meta: meta, scheduled_at: scheduled_at}
    end)
  end

  defp delete_event_jobs(event_id) do
    Repo.query!(
      "DELETE FROM oban_jobs WHERE worker = $1 AND args ->> 'event_id' = $2",
      [worker_name(), event_id]
    )
  end

  defp worker_name, do: Keyword.fetch!(RefreshSnapshotWorker.__opts__(), :worker)

  defp backend_pid do
    %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
    backend_pid
  end

  defp wait_for_row_lock_wait!(backend_pid, timeout_ms \\ 5_000) do
    wait_for_row_lock_wait_until!(backend_pid, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp wait_for_row_lock_wait_until!(backend_pid, deadline) do
    case row_lock_blockers(backend_pid) do
      [_ | _] = blockers ->
        blockers

      [] ->
        if System.monotonic_time(:millisecond) < deadline do
          receive do
          after
            15 -> wait_for_row_lock_wait_until!(backend_pid, deadline)
          end
        else
          flunk("expected backend #{backend_pid} to wait on the pending refresh row lock")
        end
    end
  end

  defp row_lock_blockers(backend_pid) do
    UnboxedPostgres.with_connection(fn ->
      %{rows: [[blockers]]} = Repo.query!("SELECT pg_blocking_pids($1)", [backend_pid])
      blockers
    end)
  end
end
