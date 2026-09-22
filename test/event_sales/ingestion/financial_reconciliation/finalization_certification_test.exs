defmodule EventSales.Ingestion.FinancialReconciliation.FinalizationCertificationTest do
  @moduledoc """
  M4-07 certification: Event advisory fence, bound M3 re-check, and atomic drift invalidation.

  WooCommerce cannot join the Postgres advisory transaction. Finalization only re-verifies
  durable EventSales certificate authority; source extraction remains a point-in-time observation.
  """

  use EventSales.DataCase, async: false

  require Ash.Query

  alias Ecto.Adapters.SQL.Sandbox
  alias EventSales.Ingestion
  alias EventSales.Ingestion.AnalyticsReadinessResolver
  alias EventSales.Ingestion.FinancialReconciliation.Orchestrator
  alias EventSales.Ingestion.FinancialReconciliationRuns
  alias EventSales.Ingestion.HistoricalCoverageFence
  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.Resources.{FinancialReconciliationFinding, SyncRun}
  alias EventSales.Repo
  alias EventSales.TestSupport.{FinancialReconciliationHelpers, SalesHelpers}

  defmodule SourceStub do
    def extract_for_run(_sync_run, _event, _source, _opts),
      do: Application.get_env(:event_sales, :finalization_source_result)
  end

  defmodule LocalStub do
    def extract_for_run(_sync_run, _event, _source, _opts),
      do: Application.get_env(:event_sales, :finalization_local_result)
  end

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "M4-07 Finalization"})
    sync_run = FinancialReconciliationHelpers.certified_run!(event)

    on_exit(fn ->
      Application.delete_env(:event_sales, :finalization_source_result)
      Application.delete_env(:event_sales, :finalization_local_result)
      Application.delete_env(:event_sales, :financial_reconciliation_coverage_invalidation)
      Application.delete_env(:event_sales, :financial_reconciliation_finalize_hooks)
    end)

    %{source: source, event: event, sync_run: sync_run}
  end

  test "matched flow passes and leaves M3 unchanged", %{event: event, sync_run: sync_run} do
    run = queue_run!(event)
    set_stubs!({:ok, successful_result(sync_run)}, {:ok, successful_result(sync_run)})

    assert {:ok, finalized} = run_orchestrator(run)
    assert finalized.status == :passed

    reloaded = Ash.get!(SyncRun, sync_run.id, domain: Ingestion)
    assert reloaded.order_coverage_status == :complete
    assert reloaded.refund_coverage_status == :complete
    assert is_nil(reloaded.coverage_invalidated_at)
  end

  test "numeric mismatch leaves M3 valid", %{event: event, sync_run: sync_run} do
    run = queue_run!(event)

    source =
      successful_result(sync_run, "ZAR", %{
        gross_ticket_value: Decimal.new("100.00"),
        net_ticket_value: Decimal.new("100.00")
      })

    local =
      successful_result(sync_run, "ZAR", %{
        gross_ticket_value: Decimal.new("90.00"),
        net_ticket_value: Decimal.new("90.00")
      })

    set_stubs!({:ok, source}, {:ok, local})

    assert {:ok, finalized} = run_orchestrator(run)
    assert finalized.status == :mismatched

    reloaded = Ash.get!(SyncRun, sync_run.id, domain: Ingestion)
    assert reloaded.order_coverage_status == :complete
    assert reloaded.refund_coverage_status == :complete
  end

  test "failed structural result leaves M3 valid", %{event: event, sync_run: sync_run} do
    run = queue_run!(event)

    set_stubs!(
      {:ok, successful_result(sync_run)},
      {:error, {:missing_local_fact, %{kind: :order}}}
    )

    assert {:ok, finalized} = run_orchestrator(run)
    assert finalized.status == :failed

    reloaded = Ash.get!(SyncRun, sync_run.id, domain: Ingestion)
    assert reloaded.order_coverage_status == :complete
  end

  test "source_snapshot_stale supersedes and invalidates order and refund coverage", %{
    sync_run: sync_run,
    event: event
  } do
    run = queue_run!(event)
    set_stubs!({:error, {:source_snapshot_stale, %{kind: :order}}}, {:ok, %{}})

    assert {:ok, finalized} = run_orchestrator(run)
    assert finalized.status == :superseded

    reloaded = Ash.get!(SyncRun, sync_run.id, domain: Ingestion)
    assert reloaded.order_coverage_status == :incomplete
    assert reloaded.refund_coverage_status == :incomplete
    assert reloaded.coverage_invalidation_reason == :historical_order_changed
    assert %DateTime{} = reloaded.coverage_invalidated_at

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)

    assert {:ok, readiness} = AnalyticsReadinessResolver.resolve(event.id)
    assert readiness.analytics_ready? == false
  end

  test "refund_identity_drift supersedes and invalidates refund coverage only", %{
    sync_run: sync_run,
    event: event
  } do
    run = queue_run!(event)

    set_stubs!(
      {:error, {:refund_identity_drift, %{woo_refund_ids: [1], expected_refund_ids: [2]}}},
      {:ok, %{}}
    )

    assert {:ok, finalized} = run_orchestrator(run)
    assert finalized.status == :superseded

    reloaded = Ash.get!(SyncRun, sync_run.id, domain: Ingestion)
    assert reloaded.order_coverage_status == :complete
    assert reloaded.refund_coverage_status == :incomplete
    assert reloaded.coverage_invalidation_reason == :historical_refund_changed

    assert {:error, :historical_coverage_not_current} =
             HistoricalCoverageResolver.resolve_current(event.id)

    assert {:ok, readiness} = AnalyticsReadinessResolver.resolve(event.id)
    assert readiness.analytics_ready? == false
  end

  test "lost M3 certificate before finalize supersedes matched evidence", %{
    sync_run: sync_run,
    event: event
  } do
    run = queue_run!(event)
    set_stubs!({:ok, successful_result(sync_run)}, {:ok, successful_result(sync_run)})

    invalidate_sync_run!(sync_run)

    assert {:ok, finalized} = run_orchestrator(run)
    assert finalized.status == :superseded
    refute finalized.status == :passed

    findings = list_findings(run.id)
    assert Enum.any?(findings, &(&1.category == :invalid_scope))
  end

  test "does not duplicate stale-certificate finding when already present", %{
    sync_run: sync_run,
    event: event
  } do
    run = queue_run!(event)
    {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)

    invalidate_sync_run!(sync_run)

    scope = FinancialReconciliationHelpers.scope_map(sync_run)

    assert {:ok, _} =
             FinancialReconciliationRuns.finalize_evidence(
               started,
               %{
                 disposition: :superseded,
                 comparisons: [],
                 metric_mismatches: [],
                 structural_findings: [
                   %{
                     category: :invalid_scope,
                     origin: :local,
                     scope: scope,
                     details: %{reason: :historical_certificate_not_current}
                   }
                 ]
               },
               internal?: true
             )

    assert length(list_findings(run.id)) == 1
  end

  test "older bound certificate run supersedes without rebinding", %{source: source} do
    event = SalesHelpers.create_event!(source, %{name: "Older Certificate Event"})
    older_sync_run = FinancialReconciliationHelpers.certified_run!(event)
    run = queue_run!(event)
    assert run.historical_sync_run_id == older_sync_run.id
    _newer_sync_run = FinancialReconciliationHelpers.certified_run!(event)

    set_stubs!(
      {:ok, successful_result(older_sync_run)},
      {:ok, successful_result(older_sync_run)}
    )

    assert {:ok, finalized} = run_orchestrator(run)
    assert finalized.status == :superseded
  end

  test "invalidation failure rolls back M4 evidence and leaves M3 unchanged", %{
    event: event,
    sync_run: sync_run
  } do
    run = queue_run!(event)

    Application.put_env(:event_sales, :financial_reconciliation_coverage_invalidation,
      invalidate_order_coverage: fn _sync_run -> {:error, :forced_invalidation_failure} end
    )

    {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)
    scope = FinancialReconciliationHelpers.scope_map(sync_run)

    assert {:error, :forced_invalidation_failure} =
             FinancialReconciliationRuns.finalize_evidence(
               started,
               %{
                 disposition: :superseded,
                 comparisons: [],
                 metric_mismatches: [],
                 structural_findings: [
                   %{
                     category: :source_snapshot_stale,
                     origin: :source,
                     scope: scope,
                     details: %{kind: :order}
                   }
                 ]
               },
               internal?: true
             )

    reloaded_run =
      Ash.get!(EventSales.Ingestion.Resources.FinancialReconciliationRun, run.id,
        domain: Ingestion
      )

    assert reloaded_run.status == :running
    assert list_findings(run.id) == []

    reloaded_sync = Ash.get!(SyncRun, sync_run.id, domain: Ingestion)
    assert reloaded_sync.order_coverage_status == :complete
  end

  test "metric failure after drift invalidation rolls back M3 invalidation", %{
    event: event,
    sync_run: sync_run
  } do
    run = queue_run!(event)
    {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)
    scope = FinancialReconciliationHelpers.scope_map(sync_run)

    invalid_row = %{
      currency: "ZAR",
      primitive: :gross_ticket_quantity,
      source_value: Decimal.new("1.5"),
      local_value: Decimal.new("2"),
      matched?: false
    }

    assert {:error, _} =
             FinancialReconciliationRuns.finalize_evidence(
               started,
               %{
                 disposition: :superseded,
                 comparisons: [invalid_row],
                 metric_mismatches: [
                   %{
                     category: :gross_quantity_mismatch,
                     currency: "ZAR",
                     primitive: :gross_ticket_quantity,
                     source_value: Decimal.new("1.5"),
                     local_value: Decimal.new("2"),
                     delta: Decimal.new("0.5")
                   }
                 ],
                 structural_findings: [
                   %{
                     category: :source_snapshot_stale,
                     origin: :source,
                     scope: scope,
                     details: %{kind: :order}
                   }
                 ]
               },
               internal?: true
             )

    reloaded_sync = Ash.get!(SyncRun, sync_run.id, domain: Ingestion)
    assert reloaded_sync.order_coverage_status == :complete
    assert list_findings(run.id) == []
  end

  test "mutation wins race: finalize supersedes after concurrent invalidation" do
    test_pid = self()

    with_unboxed_connection(fn ->
      source = SalesHelpers.create_source_system!()
      event = SalesHelpers.create_event!(source, %{name: "Mutation Wins Event"})
      sync_run = FinancialReconciliationHelpers.certified_run!(event)
      run = queue_run!(event)
      {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)
      owner_pid = self()

      holder =
        Task.async(fn ->
          Repo.transaction(fn ->
            assert :ok = HistoricalCoverageFence.acquire([event.id])
            send(test_pid, :mutation_holding_fence)

            Ash.update!(
              sync_run,
              %{coverage_invalidation_reason: :historical_order_changed},
              action: :invalidate_order_coverage,
              domain: Ingestion
            )

            receive do
              :release_mutation_holder -> :ok
            end
          end)
        end)

      Sandbox.allow(Repo, owner_pid, holder.pid)

      assert_receive :mutation_holding_fence, 10_000

      finalizer =
        Task.async(fn ->
          FinancialReconciliationRuns.finalize_evidence(
            started,
            %{
              disposition: :matched,
              comparisons: [],
              metric_mismatches: [],
              structural_findings: []
            },
            internal?: true
          )
        end)

      Sandbox.allow(Repo, owner_pid, finalizer.pid)

      Process.sleep(100)
      refute match?({:ok, _}, Task.yield(finalizer, 0))

      send(holder.pid, :release_mutation_holder)

      assert {:ok, finalized} = Task.await(finalizer, 10_000)
      assert {:ok, :ok} = Task.await(holder, 10_000)
      assert finalized.status == :superseded

      assert {:ok, readiness} = AnalyticsReadinessResolver.resolve(event.id)
      assert readiness.analytics_ready? == false
    end)
  end

  test "reconciliation wins race: pass then mutation blocks readiness" do
    test_pid = self()

    with_unboxed_connection(fn ->
      source = SalesHelpers.create_source_system!()
      event = SalesHelpers.create_event!(source, %{name: "Reconciliation Wins Event"})
      sync_run = FinancialReconciliationHelpers.certified_run!(event)
      run = queue_run!(event)
      {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)
      owner_pid = self()

      Application.put_env(:event_sales, :financial_reconciliation_finalize_hooks,
        after_fence: fn _event_id ->
          send(test_pid, {:finalize_holding_fence, self()})

          receive do
            :release_finalize_fence -> :ok
          end
        end
      )

      finalizer =
        Task.async(fn ->
          FinancialReconciliationRuns.finalize_evidence(
            started,
            %{
              disposition: :matched,
              comparisons: [],
              metric_mismatches: [],
              structural_findings: []
            },
            internal?: true
          )
        end)

      Sandbox.allow(Repo, owner_pid, finalizer.pid)

      assert_receive {:finalize_holding_fence, finalize_worker_pid}, 10_000

      mutation =
        Task.async(fn ->
          Repo.transaction(fn ->
            assert :ok = HistoricalCoverageFence.acquire([event.id])

            Ash.update!(
              sync_run,
              %{coverage_invalidation_reason: :historical_order_changed},
              action: :invalidate_order_coverage,
              domain: Ingestion
            )
          end)
        end)

      Sandbox.allow(Repo, owner_pid, mutation.pid)

      Process.sleep(100)
      refute match?({:ok, _}, Task.yield(mutation, 0))

      send(finalize_worker_pid, :release_finalize_fence)

      assert {:ok, finalized} = Task.await(finalizer, 10_000)
      assert finalized.status == :passed
      assert {:ok, _result} = Task.await(mutation, 10_000)

      assert {:ok, readiness} = AnalyticsReadinessResolver.resolve(event.id)
      assert readiness.analytics_ready? == false
    end)
  end

  test "different events do not block each other on the fence", %{event: event, source: source} do
    other_event = SalesHelpers.create_event!(source, %{name: "Other Fence Event"})
    parent = self()

    holder =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          Repo.transaction(fn ->
            assert :ok = HistoricalCoverageFence.acquire([event.id])
            send(parent, :event_a_held)

            receive do
              :release_a -> :ok
            end
          end)
        end)
      end)

    assert_receive :event_a_held, 5_000

    waiter =
      Task.async(fn ->
        with_unboxed_connection(fn ->
          Repo.transaction(fn ->
            assert :ok = HistoricalCoverageFence.acquire([other_event.id])
            send(parent, :event_b_acquired)
          end)
        end)
      end)

    assert_receive :event_b_acquired, 5_000
    send(holder.pid, :release_a)
    assert {:ok, :ok} = Task.await(holder, 5_000)
    assert {:ok, :event_b_acquired} = Task.await(waiter, 5_000)
  end

  test "finalize module acquires HistoricalCoverageFence before row locks" do
    source =
      File.read!(
        Path.join([
          File.cwd!(),
          "lib/event_sales/ingestion/financial_reconciliation_runs.ex"
        ])
      )

    fence_index = :binary.match(source, "HistoricalCoverageFence.acquire") |> elem(0)
    run_lock_index = :binary.match(source, "lock_run(run_id)") |> elem(0)
    assert fence_index < run_lock_index
  end

  test "rejects handcrafted superseded evidence without a recognized cause", %{
    event: event,
    sync_run: sync_run
  } do
    run = queue_run!(event)
    {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)

    assert {:error, :invalid_supersede_evidence} =
             FinancialReconciliationRuns.finalize_evidence(
               started,
               %{
                 disposition: :superseded,
                 comparisons: [],
                 metric_mismatches: [],
                 structural_findings: [
                   %{
                     category: :missing_local_fact,
                     origin: :local,
                     scope: FinancialReconciliationHelpers.scope_map(sync_run),
                     details: %{kind: :order}
                   }
                 ]
               },
               internal?: true
             )
  end

  defp queue_run!(event) do
    {:ok, %{financial_reconciliation_run: run}} =
      FinancialReconciliationRuns.queue_system_for_event(event.id,
        internal?: true,
        oban_insert: fn _ -> {:ok, %{}} end
      )

    run
  end

  defp run_orchestrator(run) do
    Orchestrator.run(run, source_extractor: SourceStub, local_totals: LocalStub)
  end

  defp set_stubs!(source, local) do
    Application.put_env(:event_sales, :finalization_source_result, source)
    Application.put_env(:event_sales, :finalization_local_result, local)
  end

  defp successful_result(sync_run, currency \\ "ZAR", overrides \\ %{}) do
    FinancialReconciliationHelpers.successful_result(sync_run, currency, overrides)
  end

  defp invalidate_sync_run!(%SyncRun{} = sync_run) do
    Ash.update!(
      sync_run,
      %{coverage_invalidation_reason: :historical_order_changed},
      action: :invalidate_order_coverage,
      domain: Ingestion
    )
  end

  defp list_findings(run_id) do
    FinancialReconciliationFinding
    |> Ash.Query.filter(financial_reconciliation_run_id == ^run_id)
    |> Ash.read!(domain: Ingestion)
  end

  defp with_unboxed_connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end
end
