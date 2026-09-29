defmodule EventSales.Analytics.EventSnapshotRefreshEnqueueConcurrencyTest do
  use ExUnit.Case, async: false

  alias EventSales.Analytics.Workers.RefreshSnapshotWorker
  alias EventSales.Repo
  alias EventSales.TestSupport.{SalesHelpers, UnboxedPostgres}

  setup do
    fixture = create_committed_fixture!()
    event_ids = fixture.event_ids

    on_exit(fn -> cleanup_committed_fixture!(fixture) end)

    %{event_ids: event_ids, fixture: fixture}
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
      conf = production_oban_conf()
      insert_job = production_insert_job(conf, self(), :executing)

      assert :ok = RefreshSnapshotWorker.enqueue_event(event_id, oban_insert: insert_job)
      [first] = event_jobs(event_id)

      assert {:ok, %{num_rows: 1}} =
               Repo.query("UPDATE oban_jobs SET state = 'executing' WHERE id = $1", [first.id])

      assert :ok = RefreshSnapshotWorker.enqueue_event(event_id, oban_insert: insert_job)

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

  test "production Basic uniqueness returns an idless conflict when another transaction owns the lock",
       %{
         event_ids: [event_id | _]
       } do
    conf = production_oban_conf()
    changeset = event_job_changeset(event_id)
    parent = self()

    holder =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          result =
            Repo.transaction(fn ->
              insert_result = Oban.Engines.Basic.insert_job(conf, changeset, [])
              send(parent, {:production_lock_acquired, insert_result})

              receive do
                :release_production_lock -> :committed
              after
                15_000 -> Repo.rollback(:holder_timeout)
              end
            end)

          send(parent, {:production_holder_finished, result})
        end)
      end)

    assert_receive {:production_lock_acquired, {:ok, %Oban.Job{id: persisted_id}}}, 5_000
    assert is_integer(persisted_id)

    contender =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          result = Oban.Engines.Basic.insert_job(conf, event_job_changeset(event_id), [])
          send(parent, {:production_contention_result, result})
        end)
      end)

    assert_receive {:production_contention_result, {:ok, %Oban.Job{id: nil, conflict?: true}}},
                   5_000

    send(holder.pid, :release_production_lock)
    assert_receive {:production_holder_finished, {:ok, :committed}}, 5_000
    assert {:production_holder_finished, {:ok, :committed}} = Task.await(holder, 5_000)

    assert {:production_contention_result, {:ok, %Oban.Job{id: nil, conflict?: true}}} =
             Task.await(contender, 5_000)
  end

  test "same-event production enqueue waits, then coalesces after TX-A commits", %{
    event_ids: [event_id | _],
    fixture: fixture
  } do
    conf = production_oban_conf()
    parent = self()

    holder =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          holder_backend_pid = backend_pid()

          result =
            Repo.transaction(fn ->
              order_id = insert_aggregate_order!(fixture, event_id)

              assert :ok =
                       RefreshSnapshotWorker.enqueue_event(
                         event_id,
                         oban_insert: production_insert_job(conf, parent, :tx_a)
                       )

              send(parent, {:tx_a_ready, holder_backend_pid, order_id})

              receive do
                :release_tx_a -> :committed
              after
                15_000 -> Repo.rollback(:holder_timeout)
              end
            end)

          send(parent, {:tx_a_finished, result})
        end)
      end)

    assert_receive {:insert_request, :tx_a, ^event_id, tx_a_request_id}, 5_000
    assert_receive {:tx_a_ready, holder_backend_pid, tx_a_order_id}, 5_000

    contender =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          contender_backend_pid = backend_pid()
          send(parent, {:tx_b_started, contender_backend_pid})

          result =
            Repo.transaction(fn ->
              order_id = insert_aggregate_order!(fixture, event_id)

              case RefreshSnapshotWorker.enqueue_event(
                     event_id,
                     oban_insert: production_insert_job(conf, parent, :tx_b)
                   ) do
                :ok ->
                  send(parent, {:tx_b_enqueued, order_id})
                  :committed

                {:error, reason} ->
                  Repo.rollback(reason)
              end
            end)

          send(parent, {:tx_b_finished, result})
        end)
      end)

    assert_receive {:tx_b_started, contender_backend_pid}, 5_000

    try do
      wait_for_advisory_block!(contender_backend_pid, holder_backend_pid)
      refute_receive {:tx_b_finished, _result}, 0
    after
      send(holder.pid, :release_tx_a)
    end

    assert_receive {:tx_a_finished, {:ok, :committed}}, 5_000
    assert_receive {:tx_b_enqueued, tx_b_order_id}, 5_000
    assert_receive {:insert_request, :tx_b, ^event_id, tx_b_request_id}, 5_000
    assert_receive {:tx_b_finished, {:ok, :committed}}, 5_000

    assert {:tx_a_finished, {:ok, :committed}} = Task.await(holder, 5_000)
    assert {:tx_b_finished, {:ok, :committed}} = Task.await(contender, 5_000)
    assert tx_b_request_id != tx_a_request_id

    [job] = UnboxedPostgres.with_connection(fn -> event_jobs(event_id) end)
    assert job.meta["refresh_request_id"] == tx_b_request_id
    assert order_exists?(fixture.source_system_id, tx_a_order_id)
    assert order_exists?(fixture.source_system_id, tx_b_order_id)
  end

  test "same-event production enqueue survives TX-A rollback by inserting its own intent", %{
    event_ids: [event_id | _],
    fixture: fixture
  } do
    conf = production_oban_conf()
    parent = self()

    holder =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          holder_backend_pid = backend_pid()

          result =
            Repo.transaction(fn ->
              order_id = insert_aggregate_order!(fixture, event_id)

              assert :ok =
                       RefreshSnapshotWorker.enqueue_event(
                         event_id,
                         oban_insert: production_insert_job(conf, parent, :rollback_a)
                       )

              send(parent, {:rollback_a_ready, holder_backend_pid, order_id})

              receive do
                :rollback_tx_a -> Repo.rollback(:forced_rollback)
              after
                15_000 -> Repo.rollback(:holder_timeout)
              end
            end)

          send(parent, {:rollback_a_finished, result})
        end)
      end)

    assert_receive {:insert_request, :rollback_a, ^event_id, _tx_a_request_id}, 5_000
    assert_receive {:rollback_a_ready, holder_backend_pid, tx_a_order_id}, 5_000

    contender =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          contender_backend_pid = backend_pid()
          send(parent, {:rollback_b_started, contender_backend_pid})

          result =
            Repo.transaction(fn ->
              order_id = insert_aggregate_order!(fixture, event_id)

              case RefreshSnapshotWorker.enqueue_event(
                     event_id,
                     oban_insert: production_insert_job(conf, parent, :rollback_b)
                   ) do
                :ok ->
                  send(parent, {:rollback_b_enqueued, order_id})
                  :committed

                {:error, reason} ->
                  Repo.rollback(reason)
              end
            end)

          send(parent, {:rollback_b_finished, result})
        end)
      end)

    assert_receive {:rollback_b_started, contender_backend_pid}, 5_000

    try do
      wait_for_advisory_block!(contender_backend_pid, holder_backend_pid)
      refute_receive {:rollback_b_finished, _result}, 0
    after
      send(holder.pid, :rollback_tx_a)
    end

    assert_receive {:rollback_a_finished, {:error, :forced_rollback}}, 5_000
    assert_receive {:rollback_b_enqueued, tx_b_order_id}, 5_000
    assert_receive {:insert_request, :rollback_b, ^event_id, tx_b_request_id}, 5_000
    assert_receive {:rollback_b_finished, {:ok, :committed}}, 5_000

    assert {:rollback_a_finished, {:error, :forced_rollback}} = Task.await(holder, 5_000)
    assert {:rollback_b_finished, {:ok, :committed}} = Task.await(contender, 5_000)
    refute order_exists?(fixture.source_system_id, tx_a_order_id)
    assert order_exists?(fixture.source_system_id, tx_b_order_id)

    [job] = UnboxedPostgres.with_connection(fn -> event_jobs(event_id) end)
    assert job.meta["refresh_request_id"] == tx_b_request_id
  end

  test "an event-scoped scheduler lock does not block a different event", %{
    event_ids: [event_a, event_b | _],
    fixture: fixture
  } do
    conf = production_oban_conf()
    parent = self()

    holder =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          result =
            Repo.transaction(fn ->
              _order_id = insert_aggregate_order!(fixture, event_a)

              assert :ok =
                       RefreshSnapshotWorker.enqueue_event(
                         event_a,
                         oban_insert: production_insert_job(conf, parent, :event_a)
                       )

              send(parent, {:event_a_held, backend_pid()})

              receive do
                :release_event_a -> :committed
              after
                15_000 -> Repo.rollback(:holder_timeout)
              end
            end)

          send(parent, {:event_a_finished, result})
        end)
      end)

    assert_receive {:insert_request, :event_a, ^event_a, _request_id}, 5_000
    assert_receive {:event_a_held, holder_backend_pid}, 5_000

    contender =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          result =
            Repo.transaction(fn ->
              order_id = insert_aggregate_order!(fixture, event_b)

              assert :ok =
                       RefreshSnapshotWorker.enqueue_event(
                         event_b,
                         oban_insert: production_insert_job(conf, parent, :event_b)
                       )

              send(parent, {:event_b_committed_order, order_id})
              :committed
            end)

          send(parent, {:event_b_finished, result})
        end)
      end)

    assert_receive {:event_b_committed_order, event_b_order_id}, 5_000
    assert_receive {:insert_request, :event_b, ^event_b, _request_id}, 5_000
    assert_receive {:event_b_finished, {:ok, :committed}}, 5_000
    assert order_exists?(fixture.source_system_id, event_b_order_id)
    assert Process.alive?(holder.pid)

    send(holder.pid, :release_event_a)
    assert_receive {:event_a_finished, {:ok, :committed}}, 5_000
    assert {:event_a_finished, {:ok, :committed}} = Task.await(holder, 5_000)
    assert {:event_b_finished, {:ok, :committed}} = Task.await(contender, 5_000)
    assert is_integer(holder_backend_pid)
  end

  test "opposite multi-event inputs acquire scheduler locks in normalized order", %{
    event_ids: [event_a, event_b | _]
  } do
    conf = production_oban_conf()
    [first_event, second_event] = Enum.sort([event_a, event_b])
    parent = self()

    first =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          callback =
            production_insert_job(conf, parent, :multi_a, fn event_id ->
              if event_id == first_event do
                send(parent, {:multi_a_first_locked, backend_pid()})

                receive do
                  :release_multi_a -> :ok
                after
                  15_000 -> Repo.rollback(:holder_timeout)
                end
              end
            end)

          result =
            Repo.transaction(fn ->
              RefreshSnapshotWorker.enqueue_events([event_a, event_b], oban_insert: callback)
            end)

          send(parent, {:multi_a_finished, result})
        end)
      end)

    assert_receive {:insert_request, :multi_a, ^first_event, _request_id}, 5_000
    assert_receive {:multi_a_first_locked, holder_backend_pid}, 5_000

    second =
      Task.async(fn ->
        UnboxedPostgres.with_connection(fn ->
          contender_backend_pid = backend_pid()
          send(parent, {:multi_b_started, contender_backend_pid})

          callback = production_insert_job(conf, parent, :multi_b)

          result =
            Repo.transaction(fn ->
              RefreshSnapshotWorker.enqueue_events([second_event, first_event],
                oban_insert: callback
              )
            end)

          send(parent, {:multi_b_finished, result})
        end)
      end)

    assert_receive {:multi_b_started, contender_backend_pid}, 5_000

    try do
      wait_for_advisory_block!(contender_backend_pid, holder_backend_pid)
      refute_receive {:insert_request, :multi_b, _event_id, _request_id}, 0
    after
      send(first.pid, :release_multi_a)
    end

    assert_receive {:insert_request, :multi_a, ^second_event, _request_id}, 5_000
    assert_receive {:multi_a_finished, {:ok, :ok}}, 5_000
    assert_receive {:insert_request, :multi_b, ^first_event, _request_id}, 5_000
    assert_receive {:insert_request, :multi_b, ^second_event, _request_id}, 5_000
    assert_receive {:multi_b_finished, {:ok, :ok}}, 5_000
    assert {:multi_a_finished, {:ok, :ok}} = Task.await(first, 5_000)
    assert {:multi_b_finished, {:ok, :ok}} = Task.await(second, 5_000)
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

  defp production_oban_conf do
    %{Oban.config() | testing: :disabled}
  end

  defp production_insert_job(conf, parent, label),
    do: production_insert_job(conf, parent, label, fn _event_id -> :ok end)

  defp production_insert_job(conf, parent, label, callback) do
    fn changeset ->
      event_id = Ecto.Changeset.get_field(changeset, :args)["event_id"]
      request_id = Ecto.Changeset.get_field(changeset, :meta)["refresh_request_id"]
      send(parent, {:insert_request, label, event_id, request_id})
      callback.(event_id)
      Oban.Engines.Basic.insert_job(conf, changeset, retry: false)
    end
  end

  defp create_committed_fixture! do
    UnboxedPostgres.with_connection(fn ->
      source = SalesHelpers.create_source_system!()

      events =
        Enum.map(1..3, fn index ->
          event =
            SalesHelpers.create_event!(source, %{
              name: "Snapshot enqueue event #{index}",
              slug: "snapshot-enqueue-#{Ecto.UUID.generate()}",
              external_event_id: System.unique_integer([:positive]),
              external_event_kind: :tickera_event
            })

          ticket = SalesHelpers.create_ticket_type!(event, %{name: "Test ticket #{index}"})
          {event.id, ticket.id}
        end)

      %{
        source_system_id: source.id,
        event_ids: Enum.map(events, &elem(&1, 0)),
        ticket_type_ids: Map.new(events)
      }
    end)
  end

  defp cleanup_committed_fixture!(fixture) do
    UnboxedPostgres.with_connection(fn ->
      Enum.each(fixture.event_ids, &delete_event_jobs/1)

      Repo.query!(
        "DELETE FROM sales_order_items WHERE order_id IN (SELECT id FROM sales_orders WHERE source_system_id = $1)",
        [dump_uuid(fixture.source_system_id)]
      )

      Repo.query!("DELETE FROM sales_orders WHERE source_system_id = $1", [
        dump_uuid(fixture.source_system_id)
      ])

      Enum.each(fixture.event_ids, fn event_id ->
        Repo.query!("DELETE FROM catalog_ticket_types WHERE event_id = $1", [dump_uuid(event_id)])
        Repo.query!("DELETE FROM catalog_events WHERE id = $1", [dump_uuid(event_id)])
      end)

      Repo.query!("DELETE FROM catalog_source_systems WHERE id = $1", [
        dump_uuid(fixture.source_system_id)
      ])
    end)
  end

  defp insert_aggregate_order!(fixture, event_id) do
    woo_order_id = System.unique_integer([:positive])
    ticket_type_id = Map.fetch!(fixture.ticket_type_ids, event_id)

    %{rows: [[order_id]]} =
      Repo.query!(
        """
        INSERT INTO sales_orders (
          woo_order_id, status, currency, created_at_source, updated_at_source,
          raw_total, source_system_id
        )
        VALUES ($1, 'completed', 'USD', NOW(), NOW(), 100.00, $2)
        RETURNING id
        """,
        [woo_order_id, dump_uuid(fixture.source_system_id)]
      )

    Repo.query!(
      """
      INSERT INTO sales_order_items (
        woo_line_item_id, woo_product_id, quantity, line_subtotal, line_total,
        item_kind, mapping_status, order_id, event_id, ticket_type_id
      )
      VALUES ($1, 7001, 1, 100.00, 100.00, 'ticket', 'mapped', $2, $3, $4)
      """,
      [woo_order_id, dump_uuid(order_id), dump_uuid(event_id), dump_uuid(ticket_type_id)]
    )

    order_id
  end

  defp order_exists?(source_system_id, order_id) do
    UnboxedPostgres.with_connection(fn ->
      %{rows: [[count]]} =
        Repo.query!(
          "SELECT count(*) FROM sales_orders WHERE source_system_id = $1 AND id = $2",
          [dump_uuid(source_system_id), dump_uuid(order_id)]
        )

      count == 1
    end)
  end

  defp dump_uuid(<<_uuid::binary-size(16)>> = uuid), do: uuid
  defp dump_uuid(uuid), do: Ecto.UUID.dump!(uuid)

  defp wait_for_advisory_block!(backend_pid, blocking_backend_pid, timeout_ms \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    wait_for_advisory_block_until!(backend_pid, blocking_backend_pid, deadline)
  end

  defp wait_for_advisory_block_until!(backend_pid, blocking_backend_pid, deadline) do
    case advisory_blockers(backend_pid) do
      {blocking_pids, true} ->
        if blocking_backend_pid in blocking_pids do
          :ok
        else
          retry_advisory_block_wait!(backend_pid, blocking_backend_pid, deadline)
        end

      _other ->
        retry_advisory_block_wait!(backend_pid, blocking_backend_pid, deadline)
    end
  end

  defp retry_advisory_block_wait!(backend_pid, blocking_backend_pid, deadline) do
    if System.monotonic_time(:millisecond) < deadline do
      receive do
      after
        15 -> wait_for_advisory_block_until!(backend_pid, blocking_backend_pid, deadline)
      end
    else
      flunk(
        "expected backend #{backend_pid} to wait on scheduler advisory lock held by #{blocking_backend_pid}"
      )
    end
  end

  defp advisory_blockers(backend_pid) do
    UnboxedPostgres.with_connection(fn ->
      %{rows: [[blocking_pids, wait_event_type, wait_event]]} =
        Repo.query!(
          """
          SELECT pg_blocking_pids($1), wait_event_type, wait_event
          FROM pg_stat_activity
          WHERE pid = $1
          """,
          [backend_pid]
        )

      {blocking_pids,
       wait_event_type == "Lock" and is_binary(wait_event) and
         String.contains?(wait_event, "advisory")}
    end)
  end

  defp event_job_changeset(event_id) do
    RefreshSnapshotWorker.new(%{"scope" => "event", "event_id" => event_id},
      schedule_in: 1,
      meta: %{"refresh_request_id" => Ecto.UUID.generate()}
    )
  end

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
