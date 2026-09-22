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
    source =
      SalesHelpers.create_source_system!(%{
        base_url: "https://m407-#{Ecto.UUID.generate()}.example.test"
      })

    event = SalesHelpers.create_event!(source, %{name: "M4-07 Finalization"})
    sync_run = FinancialReconciliationHelpers.certified_run!(event)

    prev_finalize_hooks =
      Application.get_env(:event_sales, :financial_reconciliation_finalize_hooks)

    prev_invalidation =
      Application.get_env(:event_sales, :financial_reconciliation_coverage_invalidation)

    on_exit(fn ->
      Application.delete_env(:event_sales, :finalization_source_result)
      Application.delete_env(:event_sales, :finalization_local_result)

      restore_env(:financial_reconciliation_coverage_invalidation, prev_invalidation)
      restore_env(:financial_reconciliation_finalize_hooks, prev_finalize_hooks)
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

  test "does not duplicate stale-certificate finding when certificate already lost", %{
    sync_run: sync_run,
    event: event
  } do
    run = queue_run!(event)
    {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)
    invalidate_sync_run!(sync_run)

    assert {:ok, _} =
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

    assert length(list_findings(run.id)) == 1
  end

  test "M3 lookup failure rolls back without terminalizing or persisting evidence", %{
    event: event,
    sync_run: sync_run
  } do
    run = queue_run!(event)
    {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)

    Application.put_env(:event_sales, :financial_reconciliation_finalize_hooks,
      resolve_current: fn _event_id -> {:error, :historical_coverage_lookup_failed} end
    )

    assert {:error, :historical_coverage_recheck_failed} =
             FinancialReconciliationRuns.finalize_evidence(
               started,
               drift_evidence(:matched, sync_run, :source_snapshot_stale),
               internal?: true
             )

    assert_run_running!(run.id)
    assert_sync_unchanged!(sync_run.id)
    assert list_findings(run.id) == []
    assert list_metrics(run.id) == []
  end

  test "resolver historical_coverage_not_current yields superseded", %{event: event} do
    run = queue_run!(event)
    {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)

    Application.put_env(:event_sales, :financial_reconciliation_finalize_hooks,
      resolve_current: fn _event_id -> {:error, :historical_coverage_not_current} end
    )

    assert {:ok, finalized} =
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

    assert finalized.status == :superseded
    assert canonical_stale_certificate_count(list_findings(run.id)) == 1
  end

  for disposition <- [:matched, :failed] do
    test "not_current preserves non-drift structural finding for #{disposition} disposition",
         %{event: event, sync_run: sync_run} do
      run = queue_run!(event)
      {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)
      scope = FinancialReconciliationHelpers.scope_map(sync_run)

      Application.put_env(:event_sales, :financial_reconciliation_finalize_hooks,
        resolve_current: fn _event_id -> {:error, :historical_coverage_not_current} end
      )

      assert {:ok, finalized} =
               FinancialReconciliationRuns.finalize_evidence(
                 started,
                 %{
                   disposition: unquote(disposition),
                   comparisons: [],
                   metric_mismatches: [],
                   structural_findings: [
                     %{
                       category: :missing_local_fact,
                       origin: :local,
                       scope: scope,
                       details: %{kind: :order}
                     }
                   ]
                 },
                 internal?: true
               )

      assert finalized.status == :superseded

      findings = list_findings(run.id)
      assert Enum.any?(findings, &(&1.category == :missing_local_fact and &1.origin == :local))
      assert canonical_stale_certificate_count(findings) == 1
    end
  end

  test "not_current with existing canonical stale finding in evidence yields exactly one stale finding",
       %{event: event, sync_run: sync_run} do
    run = queue_run!(event)
    {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)
    scope = FinancialReconciliationHelpers.scope_map(sync_run)

    Application.put_env(:event_sales, :financial_reconciliation_finalize_hooks,
      resolve_current: fn _event_id -> {:error, :historical_coverage_not_current} end
    )

    assert {:ok, finalized} =
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

    assert finalized.status == :superseded
    assert canonical_stale_certificate_count(list_findings(run.id)) == 1
  end

  test "not_current replaces malformed stale-looking finding with canonical finalizer finding", %{
    event: event,
    sync_run: sync_run
  } do
    run = queue_run!(event)
    {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)
    scope = FinancialReconciliationHelpers.scope_map(sync_run)
    wrong_scope = Map.put(scope, :sync_run_id, Ecto.UUID.generate())

    Application.put_env(:event_sales, :financial_reconciliation_finalize_hooks,
      resolve_current: fn _event_id -> {:error, :historical_coverage_not_current} end
    )

    assert {:ok, finalized} =
             FinancialReconciliationRuns.finalize_evidence(
               started,
               %{
                 disposition: :matched,
                 comparisons: [],
                 metric_mismatches: [],
                 structural_findings: [
                   %{
                     category: :invalid_scope,
                     origin: :source,
                     scope: scope,
                     details: %{reason: :historical_certificate_not_current}
                   },
                   %{
                     category: :invalid_scope,
                     origin: :local,
                     scope: wrong_scope,
                     details: %{reason: :historical_certificate_not_current}
                   }
                 ]
               },
               internal?: true
             )

    assert finalized.status == :superseded

    findings = list_findings(run.id)
    assert canonical_stale_certificate_count(findings) == 1
    refute Enum.any?(findings, &(&1.origin == :source))
  end

  test "current M3 rejects handcrafted historical_certificate_not_current finding", %{
    event: event,
    sync_run: sync_run
  } do
    run = queue_run!(event)
    {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)
    scope = FinancialReconciliationHelpers.scope_map(sync_run)

    assert {:error, :contradictory_stale_certificate_finding} =
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

    assert_run_running!(run.id)
    assert_sync_unchanged!(sync_run.id)
  end

  for {disposition, category} <- [
        {:matched, :source_snapshot_stale},
        {:failed, :source_snapshot_stale},
        {:matched, :refund_identity_drift},
        {:failed, :refund_identity_drift}
      ] do
    test "blocks #{disposition} with #{category} drift finding", %{
      event: event,
      sync_run: sync_run
    } do
      run = queue_run!(event)
      {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)

      assert {:error, :inconsistent_drift_evidence} =
               FinancialReconciliationRuns.finalize_evidence(
                 started,
                 drift_evidence(unquote(disposition), sync_run, unquote(category)),
                 internal?: true
               )

      assert_run_running!(run.id)
      assert_sync_unchanged!(sync_run.id)
    end
  end

  for {origin, category} <- [
        {:local, :source_snapshot_stale},
        {:comparator, :source_snapshot_stale},
        {:local, :refund_identity_drift},
        {:comparator, :refund_identity_drift}
      ] do
    test "blocks #{origin} origin for #{category}", %{event: event, sync_run: sync_run} do
      run = queue_run!(event)
      {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)
      scope = FinancialReconciliationHelpers.scope_map(sync_run)

      assert {:error, :inconsistent_drift_evidence} =
               FinancialReconciliationRuns.finalize_evidence(
                 started,
                 %{
                   disposition: :superseded,
                   comparisons: [],
                   metric_mismatches: [],
                   structural_findings: [
                     %{
                       category: unquote(category),
                       origin: unquote(origin),
                       scope: scope,
                       details: %{kind: :order}
                     }
                   ]
                 },
                 internal?: true
               )

      assert_run_running!(run.id)
      assert_sync_unchanged!(sync_run.id)
    end
  end

  test "finding persistence failure after drift invalidation rolls back M3", %{
    event: event,
    sync_run: sync_run
  } do
    run = queue_run!(event)
    {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)

    Application.put_env(:event_sales, :financial_reconciliation_finalize_hooks,
      persist_structural_finding: fn _run, _finding -> {:error, :forced_finding_failure} end
    )

    assert {:error, :forced_finding_failure} =
             FinancialReconciliationRuns.finalize_evidence(
               started,
               drift_evidence(:superseded, sync_run, :source_snapshot_stale),
               internal?: true
             )

    assert_run_running!(run.id)
    assert_sync_unchanged!(sync_run.id)
    assert list_findings(run.id) == []
    assert list_metrics(run.id) == []
  end

  test "terminal transition failure after drift invalidation rolls back M3", %{
    event: event,
    sync_run: sync_run
  } do
    run = queue_run!(event)
    {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)

    Application.put_env(:event_sales, :financial_reconciliation_finalize_hooks,
      before_terminal_transition: fn _event_id -> {:error, :forced_terminal_failure} end
    )

    assert {:error, :forced_terminal_failure} =
             FinancialReconciliationRuns.finalize_evidence(
               started,
               drift_evidence(:superseded, sync_run, :source_snapshot_stale),
               internal?: true
             )

    assert_run_running!(run.id)
    assert_sync_unchanged!(sync_run.id)
    assert list_findings(run.id) == []
    assert list_metrics(run.id) == []
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

    assert_run_running!(run.id)
    assert_sync_unchanged!(sync_run.id)
    assert list_findings(run.id) == []
    assert list_metrics(run.id) == []
  end

  test "mutation wins race: finalize supersedes after concurrent invalidation" do
    test_pid = self()

    fixture =
      with_unboxed_connection(fn ->
        source =
          SalesHelpers.create_source_system!(%{
            base_url: "https://m407-race-#{Ecto.UUID.generate()}.example.test"
          })

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

        %{source: source, event: event}
      end)

    cleanup_unboxed_m407_fixture!(fixture)
  end

  test "reconciliation wins race: pass then mutation blocks readiness" do
    test_pid = self()

    fixture =
      with_unboxed_connection(fn ->
        source =
          SalesHelpers.create_source_system!(%{
            base_url: "https://m407-race2-#{Ecto.UUID.generate()}.example.test"
          })

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

        %{source: source, event: event}
      end)

    cleanup_unboxed_m407_fixture!(fixture)
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

  test "rejects superseded evidence without authoritative source drift while M3 is current", %{
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

  defp list_metrics(run_id) do
    EventSales.Ingestion.Resources.FinancialReconciliationMetric
    |> Ash.Query.filter(financial_reconciliation_run_id == ^run_id)
    |> Ash.read!(domain: Ingestion)
  end

  defp drift_evidence(disposition, sync_run, category, opts \\ []) do
    details = Keyword.get(opts, :details, %{kind: :order})

    %{
      disposition: disposition,
      comparisons: [],
      metric_mismatches: [],
      structural_findings: [
        %{
          category: category,
          origin: :source,
          scope: FinancialReconciliationHelpers.scope_map(sync_run),
          details: details
        }
      ]
    }
  end

  defp assert_run_running!(run_id) do
    run =
      Ash.get!(EventSales.Ingestion.Resources.FinancialReconciliationRun, run_id,
        domain: Ingestion
      )

    assert run.status == :running
  end

  defp assert_sync_unchanged!(sync_run_id) do
    sync = Ash.get!(SyncRun, sync_run_id, domain: Ingestion)
    assert sync.order_coverage_status == :complete
    assert sync.refund_coverage_status == :complete
    assert is_nil(sync.coverage_invalidated_at)
    assert is_nil(sync.coverage_invalidation_reason)
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)

  defp with_unboxed_connection(fun) do
    :ok = Sandbox.checkout(Repo, sandbox: false)

    try do
      fun.()
    after
      Sandbox.checkin(Repo)
    end
  end

  defp cleanup_unboxed_m407_fixture!(%{source: source, event: event}) do
    with_unboxed_connection(fn ->
      event_id = uuid_binary(event.id)
      source_id = uuid_binary(source.id)

      Repo.query!(
        """
        DELETE FROM ingestion_financial_reconciliation_findings
        WHERE financial_reconciliation_run_id IN (
          SELECT id FROM ingestion_financial_reconciliation_runs WHERE event_id = $1
        )
        """,
        [event_id]
      )

      Repo.query!(
        """
        DELETE FROM ingestion_financial_reconciliation_metrics
        WHERE financial_reconciliation_run_id IN (
          SELECT id FROM ingestion_financial_reconciliation_runs WHERE event_id = $1
        )
        """,
        [event_id]
      )

      Repo.query!("DELETE FROM ingestion_financial_reconciliation_runs WHERE event_id = $1", [
        event_id
      ])

      Repo.query!("DELETE FROM ingestion_sync_runs WHERE event_id = $1", [event_id])
      Repo.query!("DELETE FROM catalog_events WHERE id = $1", [event_id])
      Repo.query!("DELETE FROM catalog_source_systems WHERE id = $1", [source_id])
    end)
  end

  defp uuid_binary(uuid), do: Ecto.UUID.dump!(uuid)

  defp canonical_stale_certificate_count(findings) when is_list(findings) do
    Enum.count(findings, &persisted_canonical_stale_certificate?/1)
  end

  defp persisted_canonical_stale_certificate?(finding) do
    finding.category == :invalid_scope and finding.origin == :local and
      historical_certificate_not_current_reason?(finding.details)
  end

  defp historical_certificate_not_current_reason?(details) when is_map(details) do
    Map.get(details, :reason) == :historical_certificate_not_current or
      Map.get(details, "reason") == "historical_certificate_not_current"
  end

  defp historical_certificate_not_current_reason?(_details), do: false
end
