defmodule EventSales.Ingestion.TickeraCatalogAutoApplyTest do
  use EventSales.DataCase, async: false

  alias EventSales.Ingestion.Resources.{TickeraCatalogAutoApplyDecision, TickeraCatalogSyncRun}
  alias EventSales.Ingestion.TickeraCatalogAutoApply
  alias EventSales.Ingestion.TickeraCatalogAutoApplyConfig
  alias EventSales.Ingestion.Workers.ApplyTickeraCatalogWorker
  alias EventSales.TestSupport.SalesHelpers

  test "mode composition is conservative and configuration fingerprints are deterministic" do
    projection = %{
      hard_kill_enabled: true,
      global_mode: :enabled,
      source_mode: :inherit,
      source_allowlisted: true,
      enabled_policy_versions: ["b", "a", "a"],
      supported_snapshot_versions: ["v2"],
      configuration_revision: 2
    }

    assert TickeraCatalogAutoApplyConfig.effective_mode(projection) == :enabled

    assert TickeraCatalogAutoApplyConfig.effective_mode(%{projection | global_mode: :observe}) ==
             :observe

    assert TickeraCatalogAutoApplyConfig.effective_mode(%{projection | hard_kill_enabled: false}) ==
             :disabled

    fingerprint = TickeraCatalogAutoApplyConfig.fingerprint(projection)

    assert fingerprint ==
             TickeraCatalogAutoApplyConfig.fingerprint(%{
               projection
               | enabled_policy_versions: ["a", "b"]
             })
  end

  test "evaluation persists one idempotent fail-closed decision" do
    handler_id = "auto-apply-decision-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:event_sales, :catalog_auto_apply, :decision],
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:decision_telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    source = SalesHelpers.create_source_system!()
    snapshot = ineligible_snapshot(source.id)

    run =
      Ash.create!(
        TickeraCatalogSyncRun,
        %{source_system_id: source.id, scope: %{}, origin: :targeted_catalog_change},
        action: :create_dry_run,
        domain: EventSales.Ingestion
      )

    run =
      run
      |> Ash.Changeset.for_update(:mark_discovering, %{owner_attempt: 1, owner_max_attempts: 3})
      |> Ash.update!(domain: EventSales.Ingestion)
      |> Ash.Changeset.for_update(:mark_dry_run_ready, %{
        dry_run_hash: hash(snapshot),
        summary: %{},
        plan_snapshot: snapshot
      })
      |> Ash.update!(domain: EventSales.Ingestion)

    assert {:ok, first} = TickeraCatalogAutoApply.evaluate_run(run.id)
    assert {:ok, second} = TickeraCatalogAutoApply.evaluate_run(run.id)
    assert first.id == second.id
    assert first.source_system_id == source.id
    assert first.decision_result == :ineligible
    assert first.effective_mode == :disabled
    assert_receive {:decision_telemetry, %{count: 1}, metadata}

    assert Map.keys(metadata) |> Enum.sort() ==
             [
               :decision_result,
               :effective_mode,
               :enqueue_outcome,
               :policy_version,
               :snapshot_version
             ]

    refute Map.has_key?(metadata, :run_id)
    refute Map.has_key?(metadata, :source_system_id)

    assert 1 ==
             TickeraCatalogAutoApplyDecision
             |> Ash.count!(domain: EventSales.Ingestion)
  end

  test "atomic enqueue links exactly one Apply job and consumes attempt one" do
    source = SalesHelpers.create_source_system!()
    snapshot = ineligible_snapshot(source.id)

    run =
      Ash.create!(
        TickeraCatalogSyncRun,
        %{source_system_id: source.id, scope: %{}, origin: :targeted_catalog_change},
        action: :create_dry_run,
        domain: EventSales.Ingestion
      )
      |> Ash.Changeset.for_update(:mark_discovering, %{owner_attempt: 1, owner_max_attempts: 3})
      |> Ash.update!(domain: EventSales.Ingestion)
      |> Ash.Changeset.for_update(:mark_dry_run_ready, %{
        dry_run_hash: hash(snapshot),
        summary: %{},
        plan_snapshot: snapshot
      })
      |> Ash.update!(domain: EventSales.Ingestion)

    decision =
      Ash.create!(
        TickeraCatalogAutoApplyDecision,
        %{
          catalog_sync_run_id: run.id,
          dry_run_hash: run.dry_run_hash,
          snapshot_schema_version: "tickera_catalog_plan.v2",
          policy_version: "conservative_auto_apply.v1",
          decision_result: :eligible,
          enqueue_state: :pending,
          apply_audit_state: :not_started,
          origin: :targeted_catalog_change,
          evaluated_global_mode: :enabled,
          evaluated_source_mode: :enabled,
          effective_mode: :enabled,
          configuration_revision: 1,
          configuration_fingerprint: String.duplicate("b", 64),
          enqueue_key: "#{run.id}:#{run.dry_run_hash}:conservative_auto_apply.v1"
        },
        action: :create_for_run,
        domain: EventSales.Ingestion
      )

    assert {:ok, linked} = TickeraCatalogAutoApply.enqueue_decision(decision.id)
    assert linked.enqueue_state == :enqueued
    assert linked.enqueue_attempts == 1
    assert is_integer(linked.apply_job_id)

    assert {:ok, same} = TickeraCatalogAutoApply.enqueue_decision(decision.id)
    assert same.apply_job_id == linked.apply_job_id
    assert EventSales.Repo.aggregate(Oban.Job, :count) == 1

    job = EventSales.Repo.get!(Oban.Job, linked.apply_job_id)
    assert :discard = ApplyTickeraCatalogWorker.perform(job)

    rejected =
      Ash.get!(TickeraCatalogAutoApplyDecision, linked.id, domain: EventSales.Ingestion)

    assert rejected.apply_audit_state == :claim_rejected

    assert Ash.get!(TickeraCatalogSyncRun, run.id, domain: EventSales.Ingestion).status ==
             :dry_run_ready
  end

  test "two enqueue processes converge on the same linked job" do
    source = SalesHelpers.create_source_system!()
    snapshot = ineligible_snapshot(source.id)

    run =
      Ash.create!(
        TickeraCatalogSyncRun,
        %{source_system_id: source.id, scope: %{}, origin: :targeted_catalog_change},
        action: :create_dry_run,
        domain: EventSales.Ingestion
      )
      |> Ash.Changeset.for_update(:mark_discovering, %{owner_attempt: 1, owner_max_attempts: 3})
      |> Ash.update!(domain: EventSales.Ingestion)
      |> Ash.Changeset.for_update(:mark_dry_run_ready, %{
        dry_run_hash: hash(snapshot),
        summary: %{},
        plan_snapshot: snapshot
      })
      |> Ash.update!(domain: EventSales.Ingestion)

    decision =
      create_pending_decision!(run)

    owner = self()

    tasks =
      for _index <- 1..2 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(EventSales.Repo, owner, self())
          TickeraCatalogAutoApply.enqueue_decision(decision.id)
        end)
      end

    results = Task.await_many(tasks)
    assert Enum.all?(results, &match?({:ok, _decision}, &1))

    assert results |> Enum.map(fn {:ok, item} -> item.apply_job_id end) |> Enum.uniq() |> length() ==
             1

    assert EventSales.Repo.aggregate(Oban.Job, :count) == 1
  end

  defp hash(snapshot) do
    {:ok, _bytes, hash} =
      EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizer.canonicalize(snapshot)

    hash
  end

  defp create_pending_decision!(run) do
    Ash.create!(
      TickeraCatalogAutoApplyDecision,
      %{
        catalog_sync_run_id: run.id,
        dry_run_hash: run.dry_run_hash,
        snapshot_schema_version: "tickera_catalog_plan.v2",
        policy_version: "conservative_auto_apply.v1",
        decision_result: :eligible,
        enqueue_state: :pending,
        apply_audit_state: :not_started,
        origin: :targeted_catalog_change,
        evaluated_global_mode: :enabled,
        evaluated_source_mode: :enabled,
        effective_mode: :enabled,
        configuration_revision: 1,
        configuration_fingerprint: String.duplicate("b", 64),
        enqueue_key: "#{run.id}:#{run.dry_run_hash}:conservative_auto_apply.v1"
      },
      action: :create_for_run,
      domain: EventSales.Ingestion
    )
  end

  defp ineligible_snapshot(source_id) do
    %{
      "snapshot_schema_version" => "tickera_catalog_plan.v2",
      "source_system_id" => source_id,
      "origin" => "targeted_catalog_change",
      "event_actions" => [],
      "ticket_type_actions" => [],
      "product_mapping_actions" => [],
      "findings" => [%{"code" => "missing_source_risk_data"}],
      "source_risks" => [],
      "historical_impact" => %{
        "totals" => %{
          "affected_pending_lines" => 0,
          "affected_quantity" => 0,
          "eligible_lines" => 0,
          "eligible_quantity" => 0,
          "deferred_lines" => 0,
          "deferred_quantity" => 0,
          "conflicting_lines" => 0,
          "conflicting_quantity" => 0,
          "already_mapped_lines" => 0,
          "already_mapped_quantity" => 0
        },
        "warning_count" => 0,
        "unresolved_destination_count" => 0,
        "unknown_classification_count" => 0,
        "destinations" => []
      },
      "identity_membership_proof" => %{
        "events" => [],
        "ticket_types" => [],
        "product_mappings" => []
      },
      "touched_identifiers" => %{
        "event_ids" => [],
        "ticket_type_ids" => [],
        "mapping_ids" => [],
        "product_keys" => []
      }
    }
  end
end
