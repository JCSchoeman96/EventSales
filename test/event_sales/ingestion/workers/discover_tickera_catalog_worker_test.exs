defmodule EventSales.Ingestion.Workers.DiscoverTickeraCatalogWorkerTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  require Ash.Query

  alias EventSales.Catalog.TickeraCatalog.DiscoveryResult
  alias EventSales.Catalog.TickeraCatalog.PubSub
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.{CanonicalFact, FindingPolicy}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{TickeraCatalogSyncFinding, TickeraCatalogSyncRun}
  alias EventSales.Ingestion.Workers.DiscoverTickeraCatalogWorker
  alias EventSales.Ingestion.Workers.EvaluateTickeraCatalogAutoApplyWorker
  alias EventSales.TestSupport.{CatalogSyncRunHelpers, SalesHelpers, TickeraCatalogFixtures}

  defmodule NativeV3DiscoverySource do
    @behaviour EventSales.Catalog.TickeraCatalog.DiscoverySource

    alias EventSales.Catalog.TickeraCatalog.DiscoveryResult
    alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.{CanonicalFact, FindingPolicy}
    alias EventSales.TestSupport.TickeraCatalogFixtures

    @impl true
    def discover(_source_system_id, _scope) do
      {:ok,
       %DiscoveryResult{
         schema_version: "2026-08-07.v3",
         auto_apply_proof_complete?: false,
         origin: :human_admin,
         events: [TickeraCatalogFixtures.zero_product_event()],
         catalog_rows: [TickeraCatalogFixtures.vwg_row()],
         source_snapshot_at: ~U[2026-08-07 09:00:00Z],
         canonical_contract_version: "source_risk.v3",
         producer_version: "2026-08-07.1",
         source_system_id: "wordpress_tickera:" <> String.duplicate("a", 64),
         discovery_snapshot_id: "native-snapshot-1",
         normalization_mode: :native_v3_review,
         evidence_origin: :native,
         canonical_source_risk_facts: [fact()],
         canonical_source_risk_findings: [FindingPolicy.evaluate(fact())]
       }}
    end

    def fact do
      %CanonicalFact{
        run_id: "native-snapshot-1",
        dimension: "lifecycle",
        semantic_scope: "parent_product",
        target: %{woo_product_id: 109_740},
        authority_slot: "slot.lifecycle.wp_post_status",
        authority: "auth.wp_post_status",
        state: "present",
        completeness: "exhaustive",
        origin: "native",
        value: "draft",
        provenance: [
          %{
            "discovery_snapshot_id" => "native-snapshot-1",
            "producer_version" => "2026-08-07.1",
            "producer_source_key" => "wp_posts.post_status",
            "woo_product_id" => 109_740
          }
        ]
      }
    end
  end

  defmodule UnpersistableNativeFindingDiscoverySource do
    @behaviour EventSales.Catalog.TickeraCatalog.DiscoverySource

    alias EventSales.Catalog.TickeraCatalog.DiscoveryResult
    alias EventSales.TestSupport.TickeraCatalogFixtures

    @impl true
    def discover(_source_system_id, _scope) do
      {:ok,
       %DiscoveryResult{
         schema_version: "2026-08-07.v3",
         auto_apply_proof_complete?: false,
         origin: :human_admin,
         events: [TickeraCatalogFixtures.zero_product_event()],
         catalog_rows: [TickeraCatalogFixtures.vwg_row()],
         source_snapshot_at: ~U[2026-08-07 09:00:00Z],
         canonical_contract_version: "source_risk.v3",
         producer_version: "2026-08-07.1",
         source_system_id: "wordpress_tickera:" <> String.duplicate("a", 64),
         discovery_snapshot_id: "native-snapshot-oversized",
         normalization_mode: :native_v3_review,
         evidence_origin: :native,
         canonical_source_risk_facts: [],
         canonical_source_risk_findings: [
           %{
             disposition: "explicit_risk",
             severity: :blocking,
             qualified_finding_id: "source_risk." <> String.duplicate("x", 120),
             dimension_local_only?: false,
             implies_apply_eligible?: false
           }
         ]
       }}
    end
  end

  defmodule FailingDiscoverySource do
    @behaviour EventSales.Catalog.TickeraCatalog.DiscoverySource

    @impl true
    def discover(_source_system_id, _scope) do
      {:error, Application.fetch_env!(:event_sales, :discover_worker_failure_reason)}
    end
  end

  defmodule SequencedDiscoverySource do
    @behaviour EventSales.Catalog.TickeraCatalog.DiscoverySource

    @impl true
    def discover(_source_system_id, _scope) do
      agent = Application.fetch_env!(:event_sales, :discover_worker_sequence_agent)
      parent = Application.fetch_env!(:event_sales, :discover_worker_test_pid)

      call = Agent.get_and_update(agent, fn call -> {call, call + 1} end)
      send(parent, {:discovery_entered, call, self()})

      if call == 0 do
        receive do
          :release_discovery -> {:error, :misconfigured}
        end
      else
        {:ok, %DiscoveryResult{events: [], catalog_rows: []}}
      end
    end
  end

  setup do
    original_adapter = Application.get_env(:event_sales, :tickera_catalog_discovery_source)
    original_reason = Application.get_env(:event_sales, :discover_worker_failure_reason)

    original_sequence_agent =
      Application.get_env(:event_sales, :discover_worker_sequence_agent)

    original_test_pid = Application.get_env(:event_sales, :discover_worker_test_pid)

    on_exit(fn ->
      restore_env(:tickera_catalog_discovery_source, original_adapter)
      restore_env(:discover_worker_failure_reason, original_reason)
      restore_env(:discover_worker_sequence_agent, original_sequence_agent)
      restore_env(:discover_worker_test_pid, original_test_pid)
    end)
  end

  test "same-attempt duplicate discards without failing the live discovery owner" do
    source = SalesHelpers.create_source_system!()

    run =
      CatalogSyncRunHelpers.create_queued_catalog_sync_run!(
        source.id,
        %{"kind" => "wordpress_feed", "mode" => "full"}
      )

    PubSub.subscribe(run.id)
    {:ok, sequence_agent} = Agent.start_link(fn -> 0 end)

    Application.put_env(:event_sales, :tickera_catalog_discovery_source, SequencedDiscoverySource)
    Application.put_env(:event_sales, :discover_worker_sequence_agent, sequence_agent)
    Application.put_env(:event_sales, :discover_worker_test_pid, self())

    owner =
      Task.async(fn ->
        DiscoverTickeraCatalogWorker.perform(%Oban.Job{
          args: %{"run_id" => run.id},
          attempt: 1,
          max_attempts: 1
        })
      end)

    assert_receive {:discovery_entered, 0, owner_pid}, 1_000
    assert_receive {:catalog_sync_started, %{run_id: run_id}}
    assert run_id == run.id

    before_duplicate = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)

    assert :discard =
             DiscoverTickeraCatalogWorker.perform(%Oban.Job{
               args: %{"run_id" => run.id},
               attempt: 1,
               max_attempts: 1
             })

    after_duplicate = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)

    assert Map.take(after_duplicate, [
             :status,
             :started_at,
             :finished_at,
             :retry_attempt,
             :retry_max_attempts,
             :last_error
           ]) ==
             Map.take(before_duplicate, [
               :status,
               :started_at,
               :finished_at,
               :retry_attempt,
               :retry_max_attempts,
               :last_error
             ])

    refute_receive {:discovery_entered, 1, _pid}
    refute_receive {:catalog_sync_failed, _payload}

    send(owner_pid, :release_discovery)
    assert :discard = Task.await(owner)
  end

  test "higher attempt supersedes a stale discovering owner and fences its outcome" do
    source = SalesHelpers.create_source_system!()

    run =
      CatalogSyncRunHelpers.create_queued_catalog_sync_run!(
        source.id,
        %{"kind" => "wordpress_feed", "mode" => "full"}
      )

    PubSub.subscribe(run.id)
    {:ok, sequence_agent} = Agent.start_link(fn -> 0 end)

    Application.put_env(:event_sales, :tickera_catalog_discovery_source, SequencedDiscoverySource)
    Application.put_env(:event_sales, :discover_worker_sequence_agent, sequence_agent)
    Application.put_env(:event_sales, :discover_worker_test_pid, self())

    stale_owner =
      Task.async(fn ->
        DiscoverTickeraCatalogWorker.perform(%Oban.Job{
          args: %{"run_id" => run.id},
          attempt: 1,
          max_attempts: 3
        })
      end)

    assert_receive {:discovery_entered, 0, stale_pid}, 1_000
    assert_receive {:catalog_sync_started, %{run_id: _run_id}}

    assert :ok =
             DiscoverTickeraCatalogWorker.perform(%Oban.Job{
               args: %{"run_id" => run.id},
               attempt: 2,
               max_attempts: 3
             })

    assert_receive {:discovery_entered, 1, _current_pid}
    assert_receive {:catalog_sync_started, %{run_id: _run_id}}
    assert_receive {:catalog_sync_preview_ready, %{run_id: _run_id}}

    ready = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)
    assert ready.status == :dry_run_ready
    assert is_nil(ready.retry_attempt)
    assert is_nil(ready.retry_max_attempts)

    send(stale_pid, :release_discovery)
    assert :discard = Task.await(stale_owner)
    refute_receive {:catalog_sync_failed, _payload}
  end

  test "pre-final claim failure retries without mutating the durable run" do
    source = SalesHelpers.create_source_system!()
    run = CatalogSyncRunHelpers.create_queued_catalog_sync_run!(source.id)

    assert {:error, :catalog_sync_claim_failed} =
             DiscoverTickeraCatalogWorker.perform(
               %Oban.Job{args: %{"run_id" => run.id}, attempt: 1, max_attempts: 3},
               before_claim_update: fn -> {:error, :forced_claim_failure} end
             )

    unchanged = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)

    assert Map.take(unchanged, [
             :status,
             :started_at,
             :finished_at,
             :retry_attempt,
             :retry_max_attempts,
             :last_error,
             :updated_at
           ]) ==
             Map.take(run, [
               :status,
               :started_at,
               :finished_at,
               :retry_attempt,
               :retry_max_attempts,
               :last_error,
               :updated_at
             ])
  end

  test "final claim failure atomically fails a still-claimable run" do
    source = SalesHelpers.create_source_system!()
    run = CatalogSyncRunHelpers.create_queued_catalog_sync_run!(source.id)
    PubSub.subscribe(run.id)

    assert :discard =
             DiscoverTickeraCatalogWorker.perform(
               %Oban.Job{args: %{"run_id" => run.id}, attempt: 3, max_attempts: 3},
               before_claim_update: fn -> {:error, :forced_claim_failure} end
             )

    failed = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)
    assert failed.status == :failed
    assert failed.last_error == "catalog_sync_claim_failed"
    assert failed.retry_attempt == 3
    assert failed.retry_max_attempts == 3
    assert failed.finished_at
    assert_receive {:catalog_sync_failed, %{run_id: run_id}}
    assert run_id == run.id
  end

  test "final claim failure reconciles retry-scheduled and stale discovering runs" do
    for status <- [:retry_scheduled, :discovering] do
      source = SalesHelpers.create_source_system!()

      discovering =
        source.id
        |> CatalogSyncRunHelpers.create_queued_catalog_sync_run!()
        |> CatalogSyncRunHelpers.mark_discovering!(1)

      run =
        if status == :retry_scheduled do
          CatalogSyncRunHelpers.mark_retry_scheduled!(discovering, %{
            last_error: "catalog_feed_timeout",
            retry_attempt: 1,
            retry_max_attempts: 3
          })
        else
          discovering
        end

      assert :discard =
               DiscoverTickeraCatalogWorker.perform(
                 %Oban.Job{args: %{"run_id" => run.id}, attempt: 3, max_attempts: 3},
                 before_claim_update: fn -> {:error, :forced_claim_failure} end
               )

      failed = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)
      assert failed.status == :failed
      assert failed.last_error == "catalog_sync_claim_failed"
      assert failed.retry_attempt == 3
      assert failed.retry_max_attempts == 3
      assert failed.finished_at
    end
  end

  test "post-commit failures are independent and cannot reopen ready lifecycle" do
    source = SalesHelpers.create_source_system!()

    run =
      CatalogSyncRunHelpers.create_queued_catalog_sync_run!(source.id, %{
        "kind" => "manual_rows",
        "events" => [TickeraCatalogFixtures.zero_product_event()],
        "catalog_rows" => [TickeraCatalogFixtures.vwg_row()]
      })

    Ash.create!(
      TickeraCatalogSyncFinding,
      %{
        run_id: run.id,
        severity: :warning,
        code: "stale_partial_finding",
        message: "stale partial finding"
      },
      action: :create,
      domain: Ingestion
    )

    parent = self()

    assert :ok =
             DiscoverTickeraCatalogWorker.perform(
               %Oban.Job{args: %{"run_id" => run.id}, attempt: 1, max_attempts: 3},
               notify: fn ->
                 send(parent, :notify_attempted)
                 {:error, :forced_notify_failure}
               end,
               cache: fn ->
                 send(parent, :cache_attempted)
                 raise "forced cache failure"
               end,
               pubsub: fn ->
                 send(parent, :pubsub_attempted)
                 {:error, :forced_pubsub_failure}
               end
             )

    assert_receive :notify_attempted
    assert_receive :cache_attempted
    assert_receive :pubsub_attempted

    ready = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)
    findings = Ash.read!(TickeraCatalogSyncFinding, domain: Ingestion)

    assert ready.status == :dry_run_ready
    assert is_nil(ready.retry_attempt)
    assert is_nil(ready.retry_max_attempts)
    refute Enum.any?(findings, &(&1.code == "stale_partial_finding"))
    refute_receive {:catalog_sync_failed, _payload}
  end

  test "discovers manual rows, persists plan snapshot/findings, and broadcasts ready" do
    source = SalesHelpers.create_source_system!()

    run =
      CatalogSyncRunHelpers.create_queued_catalog_sync_run!(source.id, %{
        "kind" => "manual_rows",
        "events" => [TickeraCatalogFixtures.zero_product_event()],
        "catalog_rows" => [TickeraCatalogFixtures.vwg_row()]
      })

    PubSub.subscribe(run.id)

    assert :ok = DiscoverTickeraCatalogWorker.perform(%Oban.Job{args: %{"run_id" => run.id}})

    updated = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)
    findings = Ash.read!(TickeraCatalogSyncFinding, domain: Ingestion)

    assert updated.status == :dry_run_ready
    assert is_binary(updated.dry_run_hash)
    assert is_map(updated.plan_snapshot)
    assert Enum.any?(findings, &(&1.code == "published_event_without_ticket_products"))

    assert_receive {:catalog_sync_started, %{run_id: run_id}}
    assert run_id == run.id
    assert_receive {:catalog_sync_preview_ready, %{run_id: run_id}}
    assert run_id == run.id
  end

  test "v2 ready plans still enqueue the AutoApply evaluation job" do
    source = SalesHelpers.create_source_system!()

    run =
      CatalogSyncRunHelpers.create_queued_catalog_sync_run!(source.id, %{
        "kind" => "manual_rows",
        "events" => [TickeraCatalogFixtures.zero_product_event()],
        "catalog_rows" => [TickeraCatalogFixtures.vwg_row()]
      })

    assert :ok = DiscoverTickeraCatalogWorker.perform(%Oban.Job{args: %{"run_id" => run.id}})

    ready = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)

    assert_enqueued(
      worker: EvaluateTickeraCatalogAutoApplyWorker,
      args: %{"run_id" => run.id, "dry_run_hash" => ready.dry_run_hash}
    )
  end

  test "native v3 ready plans are review-only with durable findings and no AutoApply job" do
    source = SalesHelpers.create_source_system!()

    Application.put_env(:event_sales, :tickera_catalog_discovery_source, NativeV3DiscoverySource)

    run =
      CatalogSyncRunHelpers.create_queued_catalog_sync_run!(
        source.id,
        %{"kind" => "wordpress_feed", "mode" => "full"}
      )

    PubSub.subscribe(run.id)

    assert :ok =
             DiscoverTickeraCatalogWorker.perform(%Oban.Job{
               args: %{"run_id" => run.id},
               attempt: 1,
               max_attempts: 3
             })

    ready = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)

    assert ready.status == :dry_run_ready
    assert ready.plan_snapshot["snapshot_schema_version"] == "tickera_catalog_plan.v3"
    assert is_binary(ready.dry_run_hash)

    refute_enqueued(worker: EvaluateTickeraCatalogAutoApplyWorker)

    codes = run_finding_codes(run.id)
    assert "source_risk.lifecycle_draft" in codes
    assert Enum.all?(codes, &is_binary/1)

    persisted =
      TickeraCatalogSyncFinding
      |> Ash.Query.filter(run_id == ^run.id and code == "source_risk.lifecycle_draft")
      |> Ash.read_one!(domain: Ingestion)

    assert persisted.severity == :blocking
    assert persisted.metadata["disposition"] == "explicit_risk"

    assert_receive {:catalog_sync_preview_ready, %{run_id: ready_id}}
    assert ready_id == run.id
  end

  test "unpersistable native finding codes never become falsely dry_run_ready" do
    source = SalesHelpers.create_source_system!()

    Application.put_env(
      :event_sales,
      :tickera_catalog_discovery_source,
      UnpersistableNativeFindingDiscoverySource
    )

    run =
      CatalogSyncRunHelpers.create_queued_catalog_sync_run!(
        source.id,
        %{"kind" => "wordpress_feed", "mode" => "full"}
      )

    assert :discard =
             DiscoverTickeraCatalogWorker.perform(%Oban.Job{
               args: %{"run_id" => run.id},
               attempt: 1,
               max_attempts: 3
             })

    failed = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)

    assert failed.status == :failed
    refute failed.status == :dry_run_ready
    assert run_finding_codes(run.id) == []
    refute_enqueued(worker: EvaluateTickeraCatalogAutoApplyWorker)
  end

  test "native v3 retry replaces stale durable findings instead of duplicating them" do
    source = SalesHelpers.create_source_system!()

    Application.put_env(:event_sales, :tickera_catalog_discovery_source, NativeV3DiscoverySource)

    run =
      source.id
      |> CatalogSyncRunHelpers.create_queued_catalog_sync_run!(%{
        "kind" => "wordpress_feed",
        "mode" => "full"
      })
      |> CatalogSyncRunHelpers.mark_discovering!(1)
      |> CatalogSyncRunHelpers.mark_retry_scheduled!(%{
        last_error: "catalog_feed_timeout",
        retry_attempt: 1,
        retry_max_attempts: 3
      })

    for code <- ["source_risk.lifecycle_draft", "stale_partial_finding"] do
      Ash.create!(
        TickeraCatalogSyncFinding,
        %{run_id: run.id, severity: :warning, code: code, message: "stale #{code}"},
        action: :create,
        domain: Ingestion
      )
    end

    assert :ok =
             DiscoverTickeraCatalogWorker.perform(%Oban.Job{
               args: %{"run_id" => run.id},
               attempt: 2,
               max_attempts: 3
             })

    codes = run_finding_codes(run.id)

    assert Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion).status == :dry_run_ready
    refute "stale_partial_finding" in codes
    assert Enum.count(codes, &(&1 == "source_risk.lifecycle_draft")) == 1
    refute_enqueued(worker: EvaluateTickeraCatalogAutoApplyWorker)
  end

  test "stores bounded feed discovery errors" do
    cases = [
      {:misconfigured, "catalog_feed_misconfigured"},
      {:unauthorized, "catalog_feed_unauthorized"},
      {:forbidden, "catalog_feed_forbidden"},
      {:timeout, "catalog_feed_timeout"},
      {:pagination_limit, "catalog_feed_pagination_limit"},
      {:invalid_feed_response, "invalid_catalog_feed_response"},
      {:invalid_json, "invalid_catalog_feed_response"},
      {:rate_limited, "catalog_feed_rate_limited"},
      {:server_error, "catalog_feed_server_error"},
      {:transport_error, "catalog_feed_transport_error"}
    ]

    for {reason, expected_error} <- cases do
      source = SalesHelpers.create_source_system!()
      Application.put_env(:event_sales, :tickera_catalog_discovery_source, FailingDiscoverySource)
      Application.put_env(:event_sales, :discover_worker_failure_reason, reason)

      run =
        CatalogSyncRunHelpers.create_queued_catalog_sync_run!(
          source.id,
          %{"kind" => "wordpress_feed", "mode" => "full"}
        )

      result =
        DiscoverTickeraCatalogWorker.perform(%Oban.Job{
          args: %{"run_id" => run.id},
          attempt: 1,
          max_attempts: 3
        })

      updated = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)

      if reason in [:timeout, :rate_limited, :server_error, :transport_error] do
        assert {:error, ^reason} = result
        assert updated.status == :retry_scheduled
        assert updated.retry_attempt == 1
        assert updated.retry_max_attempts == 3
      else
        assert :discard = result
        assert updated.status == :failed
      end

      assert updated.last_error == expected_error
    end
  end

  test "does not retry deterministic planner failures" do
    refute DiscoverTickeraCatalogWorker.retryable_failure?(
             {:historical_impact_scope_too_large,
              %{observed_pairs: 5_001, max_total_pairs: 5_000}}
           )

    for reason <- [:timeout, :rate_limited, :server_error, :transport_error] do
      assert DiscoverTickeraCatalogWorker.retryable_failure?(reason)
    end
  end

  defp run_finding_codes(run_id) do
    TickeraCatalogSyncFinding
    |> Ash.Query.filter(run_id == ^run_id)
    |> Ash.read!(domain: Ingestion)
    |> Enum.map(& &1.code)
    |> Enum.sort()
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)
end
