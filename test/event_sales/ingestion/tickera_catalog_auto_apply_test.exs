defmodule EventSales.Ingestion.TickeraCatalogAutoApplyTest do
  use EventSales.DataCase, async: false

  alias EventSales.Ingestion.TickeraCatalogAutoApply
  alias EventSales.Ingestion.TickeraCatalogAutoApplyConfig
  alias EventSales.Ingestion.Resources.{TickeraCatalogAutoApplyDecision, TickeraCatalogSyncRun}
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

    assert 1 ==
             TickeraCatalogAutoApplyDecision
             |> Ash.count!(domain: EventSales.Ingestion)
  end

  defp hash(snapshot) do
    {:ok, _bytes, hash} =
      EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizer.canonicalize(snapshot)

    hash
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
