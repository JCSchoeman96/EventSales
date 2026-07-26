defmodule EventSales.Ingestion.Resources.TickeraCatalogAutoApplyConfigTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog.Resources.SourceSystem

  alias EventSales.Ingestion.Resources.{
    TickeraCatalogAutoApplyConfig,
    TickeraCatalogAutoApplyDecision,
    TickeraCatalogSyncRun
  }

  alias EventSales.Ingestion.TickeraCatalogAutoApply
  alias EventSales.TestSupport.SalesHelpers

  test "configuration bootstrap is a database singleton with disabled defaults" do
    config =
      Ash.create!(TickeraCatalogAutoApplyConfig, %{},
        action: :bootstrap,
        domain: EventSales.Ingestion
      )

    assert config.singleton_key == "global"
    assert config.global_mode == :disabled
    assert config.enabled_policy_versions == []
    assert config.revision == 1

    assert {:error, _error} =
             Ash.create(TickeraCatalogAutoApplyConfig, %{},
               action: :bootstrap,
               domain: EventSales.Ingestion
             )
  end

  test "run origins and source defaults fail closed" do
    source = SalesHelpers.create_source_system!()
    source = Ash.get!(SourceSystem, source.id, domain: EventSales.Catalog)

    assert source.catalog_auto_apply_mode == :inherit
    refute source.catalog_auto_apply_allowlisted

    run =
      Ash.create!(
        TickeraCatalogSyncRun,
        %{source_system_id: source.id, scope: %{}},
        action: :create_dry_run,
        domain: EventSales.Ingestion
      )

    assert run.origin == :legacy_unknown
  end

  test "configuration updates require the expected revision and no-op does not increment" do
    config =
      Ash.create!(TickeraCatalogAutoApplyConfig, %{},
        action: :bootstrap,
        domain: EventSales.Ingestion
      )

    assert {:ok, unchanged} =
             TickeraCatalogAutoApply.update_configuration(config.revision, %{
               global_mode: :disabled,
               enabled_policy_versions: [],
               supported_snapshot_versions: ["tickera_catalog_plan.v2"]
             })

    assert unchanged.revision == 1

    assert {:ok, changed} =
             TickeraCatalogAutoApply.update_configuration(1, %{
               global_mode: :observe
             })

    assert changed.revision == 2
    assert changed.global_mode == :observe

    assert {:error, :configuration_revision_conflict} =
             TickeraCatalogAutoApply.update_configuration(1, %{global_mode: :enabled})

    reloaded =
      Ash.get!(TickeraCatalogAutoApplyConfig, changed.id, domain: EventSales.Ingestion)

    assert reloaded.revision == 2
    assert reloaded.global_mode == :observe
  end

  test "decision copies source ownership from its run and relationships are immutable" do
    source = SalesHelpers.create_source_system!()

    run =
      Ash.create!(
        TickeraCatalogSyncRun,
        %{
          source_system_id: source.id,
          scope: %{},
          origin: :targeted_catalog_change
        },
        action: :create_dry_run,
        domain: EventSales.Ingestion
      )

    decision =
      Ash.create!(
        TickeraCatalogAutoApplyDecision,
        %{
          catalog_sync_run_id: run.id,
          dry_run_hash: String.duplicate("a", 64),
          snapshot_schema_version: "tickera_catalog_plan.v2",
          policy_version: "conservative_auto_apply.v1",
          decision_result: :ineligible,
          enqueue_state: :not_applicable,
          apply_audit_state: :not_started,
          origin: :targeted_catalog_change,
          evaluated_global_mode: :disabled,
          evaluated_source_mode: :inherit,
          effective_mode: :disabled,
          configuration_revision: 1,
          configuration_fingerprint: String.duplicate("b", 64),
          action_summary: action_summary(),
          finding_summary: finding_summary(),
          historical_summary: historical_summary()
        },
        action: :create_for_run,
        domain: EventSales.Ingestion
      )

    assert decision.source_system_id == run.source_system_id
  end

  test "decision rejects arbitrary, missing, and protected summary fields" do
    source = SalesHelpers.create_source_system!()

    run =
      Ash.create!(
        TickeraCatalogSyncRun,
        %{source_system_id: source.id, scope: %{}, origin: :targeted_catalog_change},
        action: :create_dry_run,
        domain: EventSales.Ingestion
      )

    base = %{
      catalog_sync_run_id: run.id,
      dry_run_hash: String.duplicate("a", 64),
      snapshot_schema_version: "tickera_catalog_plan.v2",
      policy_version: "conservative_auto_apply.v1",
      decision_result: :ineligible,
      origin: :targeted_catalog_change,
      evaluated_global_mode: :disabled,
      evaluated_source_mode: :inherit,
      effective_mode: :disabled,
      configuration_revision: 1,
      configuration_fingerprint: String.duplicate("b", 64),
      action_summary: action_summary(),
      finding_summary: finding_summary(),
      historical_summary: historical_summary()
    }

    for {field, invalid} <- [
          {:action_summary, Map.put(action_summary(), "customer_email", "private@example.test")},
          {:finding_summary, Map.delete(finding_summary(), "unknown")},
          {:historical_summary, Map.put(historical_summary(), "order_payload", %{})}
        ] do
      assert {:error, _error} =
               Ash.create(TickeraCatalogAutoApplyDecision, Map.put(base, field, invalid),
                 action: :create_for_run,
                 domain: EventSales.Ingestion
               )
    end

    for protected_key <-
          ~w(customer email order payment card token ticket_token wordpress_credentials raw_source exception stacktrace) do
      assert {:error, _error} =
               Ash.create(
                 TickeraCatalogAutoApplyDecision,
                 Map.put(
                   base,
                   :action_summary,
                   Map.put(action_summary(), protected_key, 0)
                 ),
                 action: :create_for_run,
                 domain: EventSales.Ingestion
               )
    end
  end

  defp action_summary do
    %{
      "event_create" => 0,
      "event_reuse" => 0,
      "ticket_type_create" => 0,
      "ticket_type_reuse" => 0,
      "product_mapping_create" => 0,
      "total" => 0
    }
  end

  defp finding_summary,
    do: %{"total" => 0, "info" => 0, "warning" => 0, "blocking" => 0, "unknown" => 0}

  defp historical_summary do
    %{
      "affected_pending_lines" => 0,
      "affected_quantity" => 0,
      "eligible_lines" => 0,
      "deferred_lines" => 0,
      "conflicting_lines" => 0,
      "already_mapped_lines" => 0,
      "warning_count" => 0,
      "unresolved_destination_count" => 0,
      "unknown_classification_count" => 0
    }
  end
end
