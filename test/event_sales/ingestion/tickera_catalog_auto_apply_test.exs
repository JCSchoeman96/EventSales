defmodule EventSales.Ingestion.TickeraCatalogAutoApplyTest do
  use EventSales.DataCase, async: false

  alias EventSales.Ingestion.Resources.{TickeraCatalogAutoApplyDecision, TickeraCatalogSyncRun}
  alias EventSales.Ingestion.TickeraCatalogAutoApply
  alias EventSales.Ingestion.TickeraCatalogAutoApplyConfig
  alias EventSales.Ingestion.Workers.ApplyTickeraCatalogWorker
  alias EventSales.Repo
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
    projection = enable_auto_apply!(source)
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
          configuration_revision: projection.configuration_revision,
          configuration_fingerprint: projection.fingerprint,
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
    assert {:error, :blocking_findings} = ApplyTickeraCatalogWorker.perform(job)

    rejected =
      Ash.get!(TickeraCatalogAutoApplyDecision, linked.id, domain: EventSales.Ingestion)

    assert rejected.apply_audit_state == :not_started

    assert Ash.get!(TickeraCatalogSyncRun, run.id, domain: EventSales.Ingestion).status ==
             :dry_run_ready
  end

  test "two enqueue processes converge on the same linked job" do
    source = SalesHelpers.create_source_system!()
    projection = enable_auto_apply!(source)
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

    decision = create_pending_decision!(run, projection)

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

  test "enqueue fails atomically when configuration changes after evaluation" do
    source = SalesHelpers.create_source_system!()
    projection = enable_auto_apply!(source)
    run = ready_run!(source)
    decision = create_pending_decision!(run, projection)

    config =
      EventSales.Ingestion.Resources.TickeraCatalogAutoApplyConfig
      |> Ash.Query.limit(1)
      |> Ash.read_one!(domain: EventSales.Ingestion)

    assert {:ok, _disabled} =
             TickeraCatalogAutoApply.update_configuration(config.revision, %{
               global_mode: :disabled
             })

    assert {:error, :enqueue_revalidation_failed} =
             TickeraCatalogAutoApply.enqueue_decision(decision.id)

    reloaded =
      Ash.get!(TickeraCatalogAutoApplyDecision, decision.id, domain: EventSales.Ingestion)

    assert reloaded.enqueue_state == :pending
    assert is_nil(reloaded.apply_job_id)
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "source history uses bounded stable cursor pagination without cross-source rows" do
    source = SalesHelpers.create_source_system!()
    other = SalesHelpers.create_source_system!(%{base_url: "https://other-history.example.test"})

    run = ready_run!(source)
    other_run = ready_run!(other)

    for index <- 1..30 do
      create_history_decision!(run, index)
    end

    create_history_decision!(other_run, 99)

    assert {:ok, %{items: first, next_cursor: cursor}} =
             TickeraCatalogAutoApply.decisions_for_source(source.id)

    assert length(first) == 25
    assert is_binary(cursor)
    assert Enum.all?(first, &(&1.source_system_id == source.id))

    assert {:ok, %{items: second}} =
             TickeraCatalogAutoApply.decisions_for_source(source.id, cursor: cursor, limit: 1000)

    assert length(second) == 5
    assert Enum.all?(second, &(&1.source_system_id == source.id))
  end

  defp hash(snapshot) do
    {:ok, _bytes, hash} =
      EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizer.canonicalize(snapshot)

    hash
  end

  defp create_pending_decision!(run, projection) do
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
        configuration_revision: projection.configuration_revision,
        configuration_fingerprint: projection.fingerprint,
        enqueue_key: "#{run.id}:#{run.dry_run_hash}:conservative_auto_apply.v1"
      },
      action: :create_for_run,
      domain: EventSales.Ingestion
    )
  end

  defp enable_auto_apply!(source) do
    previous = Application.get_env(:event_sales, :catalog_auto_apply)
    Application.put_env(:event_sales, :catalog_auto_apply, hard_enabled: true, health_error: nil)
    on_exit(fn -> Application.put_env(:event_sales, :catalog_auto_apply, previous || []) end)

    source
    |> Ash.Changeset.for_update(:update, %{
      catalog_auto_apply_mode: :enabled,
      catalog_auto_apply_allowlisted: true
    })
    |> Ash.update!(domain: EventSales.Catalog)

    config =
      Ash.create!(
        EventSales.Ingestion.Resources.TickeraCatalogAutoApplyConfig,
        %{},
        action: :bootstrap,
        domain: EventSales.Ingestion
      )

    {:ok, _config} =
      TickeraCatalogAutoApply.update_configuration(config.revision, %{
        global_mode: :enabled,
        enabled_policy_versions: ["conservative_auto_apply.v1"]
      })

    {:ok, projection} = TickeraCatalogAutoApply.current_configuration(source.id)
    projection
  end

  defp ineligible_snapshot(source_id) do
    %{
      "snapshot_schema_version" => "tickera_catalog_plan.v2",
      "source_system_id" => source_id,
      "origin" => "targeted_catalog_change",
      "event_actions" => [],
      "ticket_type_actions" => [],
      "product_mapping_actions" => [],
      "findings" => [
        %{
          "severity" => "blocking",
          "code" => "missing_source_risk_data",
          "target_type" => "run",
          "target_id" => nil,
          "context" => %{}
        }
      ],
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

  defp ready_run!(source) do
    snapshot = ineligible_snapshot(source.id)

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
  end

  defp create_history_decision!(run, index) do
    Ash.create!(
      TickeraCatalogAutoApplyDecision,
      %{
        catalog_sync_run_id: run.id,
        dry_run_hash:
          String.pad_leading(Integer.to_string(index, 16), 64, "0") |> String.downcase(),
        snapshot_schema_version: "tickera_catalog_plan.v2",
        policy_version: "conservative_auto_apply.v#{index}",
        decision_result: :ineligible,
        origin: :targeted_catalog_change,
        evaluated_global_mode: :disabled,
        evaluated_source_mode: :inherit,
        effective_mode: :disabled,
        configuration_revision: 1,
        configuration_fingerprint: String.duplicate("b", 64)
      },
      action: :create_for_run,
      domain: EventSales.Ingestion
    )
  end
end
