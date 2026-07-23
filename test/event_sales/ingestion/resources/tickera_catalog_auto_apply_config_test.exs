defmodule EventSales.Ingestion.Resources.TickeraCatalogAutoApplyConfigTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog.Resources.SourceSystem

  alias EventSales.Ingestion.Resources.{
    TickeraCatalogAutoApplyConfig,
    TickeraCatalogAutoApplyDecision,
    TickeraCatalogSyncRun
  }

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
          configuration_fingerprint: String.duplicate("b", 64)
        },
        action: :create_for_run,
        domain: EventSales.Ingestion
      )

    assert decision.source_system_id == run.source_system_id
  end
end
