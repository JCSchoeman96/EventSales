defmodule EventSales.Ingestion.HistoricalCoverageFenceTest do
  use EventSales.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalCoverageFence
  alias EventSales.Ingestion.HistoricalCoverageInvalidator
  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.HistoricalRefundCoverageInvalidator
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.Order
  alias EventSales.TestSupport.{HistoricalCoverageHelpers, SalesHelpers}

  @coverage_start ~U[2026-08-01 08:00:00.000000Z]
  @sales_covered_through ~U[2026-08-09 23:59:59.999999Z]
  @refunds_covered_through ~U[2026-08-13 12:00:00.000000Z]

  test "requires an active PostgreSQL transaction" do
    assert {:error, :historical_coverage_fence_transaction_required} =
             HistoricalCoverageFence.acquire([Ecto.UUID.generate()])
  end

  test "rejects malformed Event IDs before acquiring any fence" do
    assert {:error, :invalid_event_id} =
             Repo.transaction(fn ->
               HistoricalCoverageFence.acquire([Ecto.UUID.generate(), "not-an-event-uuid"])
             end)
             |> unwrap_transaction_result()
  end

  test "holds a fence until the physical transaction commits" do
    event_id = Ecto.UUID.generate()
    parent = self()

    holder =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          Repo.transaction(fn ->
            assert :ok = HistoricalCoverageFence.acquire([event_id])
            send(parent, :fence_held)

            receive do
              :release_fence -> :ok
            end
          end)
        end)
      end)

    assert_receive :fence_held, 5_000

    waiter =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          Repo.transaction(fn ->
            assert :ok = HistoricalCoverageFence.acquire([event_id])
            send(parent, :waiter_acquired)
          end)
        end)
      end)

    refute_receive :waiter_acquired, 250
    send(holder.pid, :release_fence)
    assert_receive :waiter_acquired, 5_000

    assert {:ok, :ok} = Task.await(holder, 5_000)
    assert {:ok, :waiter_acquired} = Task.await(waiter, 5_000)
  end

  test "a nested D2A transaction keeps the fence until its outer writer commits" do
    event_id = Ecto.UUID.generate()
    parent = self()

    order = %Order{
      id: Ecto.UUID.generate(),
      source_system_id: Ecto.UUID.generate(),
      created_at_source: ~U[2026-08-05 12:00:00Z]
    }

    holder =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          Repo.transaction(fn ->
            assert {:ok, %{invalidated_event_ids: [], skipped: [%{reason: :no_current_coverage}]}} =
                     HistoricalCoverageInvalidator.invalidate_order_change(order, [event_id])

            send(parent, :invalidator_returned)

            receive do
              :commit_writer -> :ok
            end
          end)
        end)
      end)

    assert_receive :invalidator_returned, 5_000

    waiter =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          Repo.transaction(fn ->
            assert :ok = HistoricalCoverageFence.acquire([event_id])
            send(parent, :waiter_acquired_after_outer_commit)
          end)
        end)
      end)

    refute_receive :waiter_acquired_after_outer_commit, 250
    send(holder.pid, :commit_writer)

    assert_receive :waiter_acquired_after_outer_commit, 5_000
    assert {:ok, :ok} = Task.await(holder, 5_000)
    assert {:ok, :waiter_acquired_after_outer_commit} = Task.await(waiter, 5_000)
  end

  test "a nested D3B transaction keeps the fence until its outer writer commits" do
    event_id = Ecto.UUID.generate()
    source_system_id = Ecto.UUID.generate()
    parent = self()

    snapshot = %{
      refund_truth: %{
        source_system_id: source_system_id,
        source_created_at: ~U[2026-08-05 14:00:00Z]
      },
      refund_line_truth: [],
      parent_order_evidence: %{
        id: Ecto.UUID.generate(),
        source_system_id: source_system_id,
        created_at_source: ~U[2026-08-05 12:00:00Z]
      },
      parent_order_item_evidence: []
    }

    holder =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          Repo.transaction(fn ->
            assert {:ok, %{invalidated_event_ids: [], skipped: [%{reason: :no_current_coverage}]}} =
                     HistoricalRefundCoverageInvalidator.invalidate_refund_change(
                       nil,
                       snapshot,
                       [event_id]
                     )

            send(parent, :refund_invalidator_returned)

            receive do
              :commit_refund_writer -> :ok
            end
          end)
        end)
      end)

    assert_receive :refund_invalidator_returned, 5_000

    waiter =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          Repo.transaction(fn ->
            assert :ok = HistoricalCoverageFence.acquire([event_id])
            send(parent, :refund_waiter_acquired_after_outer_commit)
          end)
        end)
      end)

    refute_receive :refund_waiter_acquired_after_outer_commit, 250
    send(holder.pid, :commit_refund_writer)

    assert_receive :refund_waiter_acquired_after_outer_commit, 5_000
    assert {:ok, :ok} = Task.await(holder, 5_000)
    assert {:ok, :refund_waiter_acquired_after_outer_commit} = Task.await(waiter, 5_000)
  end

  test "a rolled back transaction releases the fence" do
    event_id = Ecto.UUID.generate()

    assert {:error, :forced_rollback} =
             with_unboxed_connection(fn ->
               Repo.transaction(fn ->
                 assert :ok = HistoricalCoverageFence.acquire([event_id])
                 Repo.rollback(:forced_rollback)
               end)
             end)

    assert {:ok, :acquired} =
             with_unboxed_connection(fn ->
               Repo.transaction(fn ->
                 assert :ok = HistoricalCoverageFence.acquire([event_id])
                 :acquired
               end)
             end)
  end

  test "reversed multi-Event input completes without a PostgreSQL deadlock" do
    event_a = Ecto.UUID.generate()
    event_b = Ecto.UUID.generate()
    parent = self()

    tasks =
      for event_ids <- [[event_b, event_a], [event_a, event_b]] do
        Task.async(fn ->
          with_unboxed_connection(fn ->
            send(parent, {:ready_for_multi_event_fence, self()})

            receive do
              :acquire_multi_event_fence -> :ok
            end

            Repo.transaction(fn -> HistoricalCoverageFence.acquire(event_ids) end)
          end)
        end)
      end

    assert_receive {:ready_for_multi_event_fence, first_pid}, 5_000
    assert_receive {:ready_for_multi_event_fence, second_pid}, 5_000
    send(first_pid, :acquire_multi_event_fence)
    send(second_pid, :acquire_multi_event_fence)

    assert [{:ok, :ok}, {:ok, :ok}] = Enum.map(tasks, &Task.await(&1, 5_000))
  end

  test "overlapping Event sets serialize while disjoint sets can proceed" do
    event_a = Ecto.UUID.generate()
    event_b = Ecto.UUID.generate()
    event_c = Ecto.UUID.generate()
    event_d = Ecto.UUID.generate()
    parent = self()

    holder =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          Repo.transaction(fn ->
            assert :ok = HistoricalCoverageFence.acquire([event_a, event_b])
            send(parent, :overlap_holder_ready)

            receive do
              :release_overlap_holder -> :ok
            end
          end)
        end)
      end)

    assert_receive :overlap_holder_ready, 5_000

    overlapping =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          Repo.transaction(fn ->
            assert :ok = HistoricalCoverageFence.acquire([event_b, event_c])
            send(parent, :overlapping_acquired)
          end)
        end)
      end)

    disjoint =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          Repo.transaction(fn ->
            assert :ok = HistoricalCoverageFence.acquire([event_d])
            send(parent, :disjoint_acquired)
          end)
        end)
      end)

    assert_receive :disjoint_acquired, 5_000
    refute_receive :overlapping_acquired, 250
    send(holder.pid, :release_overlap_holder)
    assert_receive :overlapping_acquired, 5_000

    assert {:ok, :ok} = Task.await(holder, 5_000)
    assert {:ok, :overlapping_acquired} = Task.await(overlapping, 5_000)
    assert {:ok, :disjoint_acquired} = Task.await(disjoint, 5_000)
  end

  test "mutation-first certification reads corrected committed truth" do
    with_committed_coverage_fixture(fn fixture ->
      parent = self()
      corrected_at = ~U[2026-08-20 10:05:00.000000Z]

      mutation =
        Task.async(fn ->
          with_unboxed_connection(fn ->
            Repo.transaction(fn ->
              corrected_order =
                Ash.update!(
                  fixture.order,
                  %{updated_at_source: corrected_at},
                  action: :sync_from_normalized,
                  domain: Sales
                )

              assert {:ok, %{invalidated_event_ids: [_event_id], skipped: []}} =
                       HistoricalCoverageInvalidator.invalidate_order_change(
                         corrected_order,
                         [fixture.event.id]
                       )

              send(parent, :mutation_holds_fence)

              receive do
                :commit_mutation -> :ok
              end
            end)
          end)
        end)

      assert_receive :mutation_holds_fence, 5_000

      certification =
        Task.async(fn ->
          with_unboxed_connection(fn ->
            Repo.transaction(fn ->
              backend_pid = backend_pid!()
              send(parent, {:certification_waiting_for_mutation, backend_pid})
              assert :ok = HistoricalCoverageFence.acquire([fixture.event.id])

              order_after_mutation = Ash.get!(Order, fixture.order.id, domain: Sales)

              send(
                parent,
                {:certification_saw_order_time, order_after_mutation.updated_at_source}
              )

              certified =
                Ash.update!(
                  fixture.run_b,
                  certification_attrs(),
                  action: :record_coverage_certification,
                  domain: Ingestion
                )

              Ash.update!(certified, %{}, action: :complete, domain: Ingestion)
            end)
          end)
        end)

      assert_receive {:certification_waiting_for_mutation, backend_pid}, 5_000
      assert_backend_waiting_on_lock!(backend_pid)
      send(mutation.pid, :commit_mutation)

      assert_receive {:certification_saw_order_time, ^corrected_at}, 5_000
      assert {:ok, :ok} = Task.await(mutation, 5_000)
      assert {:ok, _} = Task.await(certification, 5_000)

      assert {:ok, current} =
               with_unboxed_connection(fn ->
                 HistoricalCoverageResolver.resolve_current(fixture.event.id)
               end)

      assert current.id == fixture.run_b.id
    end)
  end

  test "certification-first mutation re-resolves and invalidates the newer certificate" do
    with_committed_coverage_fixture(fn fixture ->
      parent = self()
      corrected_at = ~U[2026-08-20 10:10:00.000000Z]

      certification =
        Task.async(fn ->
          with_unboxed_connection(fn ->
            Repo.transaction(fn ->
              assert :ok = HistoricalCoverageFence.acquire([fixture.event.id])

              certified =
                Ash.update!(
                  fixture.run_b,
                  certification_attrs(),
                  action: :record_coverage_certification,
                  domain: Ingestion
                )

              Ash.update!(certified, %{}, action: :complete, domain: Ingestion)
              send(parent, :new_certificate_published)

              receive do
                :commit_certification -> :ok
              end
            end)
          end)
        end)

      assert_receive :new_certificate_published, 5_000

      mutation =
        Task.async(fn ->
          with_unboxed_connection(fn ->
            Repo.transaction(fn ->
              corrected_order =
                Ash.update!(
                  fixture.order,
                  %{updated_at_source: corrected_at},
                  action: :sync_from_normalized,
                  domain: Sales
                )

              backend_pid = backend_pid!()
              send(parent, {:mutation_waiting_for_certificate, backend_pid})

              result =
                HistoricalCoverageInvalidator.invalidate_order_change(
                  corrected_order,
                  [fixture.event.id]
                )

              send(parent, {:mutation_invalidated, result})
              result
            end)
          end)
        end)

      assert_receive {:mutation_waiting_for_certificate, backend_pid}, 5_000
      assert_backend_waiting_on_lock!(backend_pid)
      send(certification.pid, :commit_certification)

      assert_receive {:mutation_invalidated,
                      {:ok, %{invalidated_event_ids: [event_id], skipped: []}}},
                     5_000

      assert event_id == fixture.event.id
      assert {:ok, :ok} = Task.await(certification, 5_000)
      assert {:ok, {:ok, _}} = Task.await(mutation, 5_000)

      assert {:error, :historical_coverage_not_current} =
               with_unboxed_connection(fn ->
                 HistoricalCoverageResolver.resolve_current(fixture.event.id)
               end)

      invalidated_run =
        with_unboxed_connection(fn -> Ash.get!(SyncRun, fixture.run_b.id, domain: Ingestion) end)

      assert invalidated_run.order_coverage_status == :incomplete
      assert invalidated_run.refund_coverage_status == :incomplete

      persisted_order =
        with_unboxed_connection(fn -> Ash.get!(Order, fixture.order.id, domain: Sales) end)

      assert persisted_order.updated_at_source == corrected_at
    end)
  end

  defp unwrap_transaction_result({:ok, result}), do: result
  defp unwrap_transaction_result({:error, reason}), do: {:error, reason}

  defp certification_attrs do
    %{
      coverage_start: @coverage_start,
      sales_covered_through: @sales_covered_through,
      refunds_covered_through: @refunds_covered_through,
      coverage_evidence: HistoricalCoverageHelpers.certified_evidence()
    }
  end

  defp with_committed_coverage_fixture(fun) do
    fixture = with_unboxed_connection(&create_coverage_fixture!/0)

    try do
      fun.(fixture)
    after
      cleanup_coverage_fixture!(fixture)
    end
  end

  defp create_coverage_fixture! do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Fence Concurrency Event"})

    order =
      Ash.create!(
        Order,
        %{
          source_system_id: source.id,
          woo_order_id: System.unique_integer([:positive]),
          status: :completed,
          currency: "ZAR",
          created_at_source: ~U[2026-08-05 12:00:00.000000Z],
          updated_at_source: ~U[2026-08-05 12:00:00.000000Z],
          raw_total: Decimal.new("100.00")
        },
        action: :create_normalized,
        domain: Sales
      )

    run_a =
      SyncRun
      |> Ash.Changeset.for_create(:queue_historical_backfill, %{
        event_id: event.id,
        date_to: @sales_covered_through
      })
      |> Ash.Changeset.force_change_attribute(:source_system_id, source.id)
      |> Ash.Changeset.force_change_attribute(:date_from, @coverage_start)
      |> Ash.create!(domain: Ingestion)
      |> Ash.update!(%{}, action: :start, domain: Ingestion)
      |> Ash.update!(certification_attrs(),
        action: :record_coverage_certification,
        domain: Ingestion
      )
      |> Ash.update!(%{}, action: :complete, domain: Ingestion)

    run_b =
      SyncRun
      |> Ash.Changeset.for_create(:queue_historical_backfill, %{
        event_id: event.id,
        date_to: @sales_covered_through
      })
      |> Ash.Changeset.force_change_attribute(:source_system_id, source.id)
      |> Ash.Changeset.force_change_attribute(:date_from, @coverage_start)
      |> Ash.create!(domain: Ingestion)
      |> Ash.update!(%{}, action: :start, domain: Ingestion)

    %{source: source, event: event, order: order, run_a: run_a, run_b: run_b}
  end

  defp cleanup_coverage_fixture!(fixture) do
    with_unboxed_connection(fn ->
      Repo.query!("DELETE FROM ingestion_sync_runs WHERE event_id = $1", [
        uuid_binary(fixture.event.id)
      ])

      Repo.query!("DELETE FROM sales_orders WHERE id = $1", [uuid_binary(fixture.order.id)])
      Repo.query!("DELETE FROM catalog_events WHERE id = $1", [uuid_binary(fixture.event.id)])

      Repo.query!("DELETE FROM catalog_source_systems WHERE id = $1", [
        uuid_binary(fixture.source.id)
      ])
    end)
  end

  defp assert_backend_waiting_on_lock!(backend_pid, attempts \\ 80)

  defp assert_backend_waiting_on_lock!(_backend_pid, 0),
    do: flunk("connection never entered a PostgreSQL lock wait")

  defp assert_backend_waiting_on_lock!(backend_pid, attempts) do
    waiting? =
      with_unboxed_connection(fn ->
        %{rows: [[wait_event_type]]} =
          Repo.query!("SELECT wait_event_type FROM pg_stat_activity WHERE pid = $1", [backend_pid])

        wait_event_type == "Lock"
      end)

    if waiting? do
      :ok
    else
      receive do
      after
        25 -> assert_backend_waiting_on_lock!(backend_pid, attempts - 1)
      end
    end
  end

  defp backend_pid! do
    %{rows: [[backend_pid]]} = Repo.query!("SELECT pg_backend_pid()")
    backend_pid
  end

  defp uuid_binary(uuid), do: Ecto.UUID.dump!(uuid)

  defp with_unboxed_connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end
end
