defmodule EventSales.Ingestion.Workers.RecoverTickeraCatalogAutoApplyWorkerTest do
  use EventSales.DataCase, async: false

  import Ecto.Query

  alias EventSales.Ingestion.Resources.{TickeraCatalogAutoApplyDecision, TickeraCatalogSyncRun}
  alias EventSales.Ingestion.TickeraCatalogAutoApply
  alias EventSales.Ingestion.Workers.RecoverTickeraCatalogAutoApplyWorker
  alias EventSales.Repo
  alias EventSales.TestSupport.SalesHelpers

  test "discarded linked job waits for deterministic backoff then retries the same job" do
    {decision, job} = linked_decision!()
    now = ~U[2026-07-23 10:00:00Z]
    Repo.update_all(from(item in Oban.Job, where: item.id == ^job.id), set: [state: "discarded"])

    assert {:ok, scheduled} =
             RecoverTickeraCatalogAutoApplyWorker.reconcile_decision(decision.id, now: now)

    assert scheduled.enqueue_state == :retryable_failure
    assert scheduled.enqueue_attempts == 2
    assert scheduled.next_attempt_at == ~U[2026-07-23 10:01:00.000000Z]
    assert Repo.get!(Oban.Job, job.id).state == "discarded"

    assert {:ok, waiting} =
             RecoverTickeraCatalogAutoApplyWorker.reconcile_decision(decision.id,
               now: ~U[2026-07-23 10:00:59Z]
             )

    assert waiting.enqueue_state == :retryable_failure

    assert {:ok, retried} =
             RecoverTickeraCatalogAutoApplyWorker.reconcile_decision(decision.id,
               now: ~U[2026-07-23 10:01:00Z]
             )

    assert retried.enqueue_state == :enqueued
    assert retried.apply_job_id == job.id
    assert Repo.get!(Oban.Job, job.id).state == "available"
  end

  test "attempt 20 and missing linked jobs terminate without replacement" do
    {decision, job} = linked_decision!()

    Repo.update_all(
      from(item in TickeraCatalogAutoApplyDecision, where: item.id == ^decision.id),
      set: [enqueue_attempts: 20]
    )

    Repo.update_all(from(item in Oban.Job, where: item.id == ^job.id), set: [state: "discarded"])

    assert {:ok, terminal} =
             RecoverTickeraCatalogAutoApplyWorker.reconcile_decision(decision.id)

    assert terminal.enqueue_state == :terminal_failure
    assert terminal.enqueue_attempts == 20
    assert is_nil(terminal.next_attempt_at)
    assert Repo.aggregate(Oban.Job, :count) == 1

    {other, other_job} = linked_decision!()
    Repo.delete!(other_job)

    assert {:ok, missing} =
             RecoverTickeraCatalogAutoApplyWorker.reconcile_decision(other.id)

    assert missing.enqueue_state == :terminal_failure
    assert "linked_job_missing" in missing.reason_codes
  end

  defp linked_decision! do
    source = SalesHelpers.create_source_system!()
    snapshot = snapshot(source.id)

    {:ok, _bytes, hash} =
      EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizer.canonicalize(snapshot)

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
        dry_run_hash: hash,
        summary: %{},
        plan_snapshot: snapshot
      })
      |> Ash.update!(domain: EventSales.Ingestion)

    decision =
      Ash.create!(
        TickeraCatalogAutoApplyDecision,
        %{
          catalog_sync_run_id: run.id,
          dry_run_hash: hash,
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
          enqueue_key: "#{run.id}:#{hash}:conservative_auto_apply.v1"
        },
        action: :create_for_run,
        domain: EventSales.Ingestion
      )

    {:ok, linked} = TickeraCatalogAutoApply.enqueue_decision(decision.id)
    {linked, Repo.get!(Oban.Job, linked.apply_job_id)}
  end

  defp snapshot(source_id) do
    %{
      "snapshot_schema_version" => "tickera_catalog_plan.v2",
      "source_system_id" => source_id,
      "origin" => "targeted_catalog_change",
      "event_actions" => [],
      "ticket_type_actions" => [],
      "product_mapping_actions" => [],
      "findings" => [],
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
