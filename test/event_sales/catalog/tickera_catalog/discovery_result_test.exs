defmodule EventSales.Catalog.TickeraCatalog.DiscoveryResultTest do
  use ExUnit.Case, async: true

  alias EventSales.Catalog.TickeraCatalog.DiscoveryResult
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.CanonicalFact

  test "preserves legacy fields and defaults for new v3 carrier fields" do
    result = %DiscoveryResult{
      schema_version: "2026-07-22.v2",
      auto_apply_proof_complete?: true,
      origin: :human_admin,
      events: [%{"tickera_event_id" => 1}],
      catalog_rows: [%{"woo_product_id" => 2}],
      source_snapshot_at: ~U[2026-07-22 10:00:00Z]
    }

    assert result.schema_version == "2026-07-22.v2"
    assert result.auto_apply_proof_complete?
    assert result.origin == :human_admin
    assert result.events == [%{"tickera_event_id" => 1}]
    assert result.catalog_rows == [%{"woo_product_id" => 2}]
    assert result.source_snapshot_at == ~U[2026-07-22 10:00:00Z]

    assert result.canonical_contract_version == nil
    assert result.producer_version == nil
    assert result.source_system_id == nil
    assert result.discovery_snapshot_id == nil
    assert result.normalization_mode == :legacy_v2_operational
    assert result.evidence_origin == nil
    assert result.canonical_source_risk_facts == []
    assert result.canonical_source_risk_findings == []
  end

  test "carries native v3 review fields on the same DiscoveryResult" do
    fact = %CanonicalFact{
      run_id: "snap-1",
      dimension: "lifecycle",
      semantic_scope: "parent_product",
      target: %{woo_product_id: 1},
      authority_slot: "slot.lifecycle.wp_post_status",
      authority: "auth.wp_post_status",
      state: "present",
      completeness: "partial",
      origin: "native",
      value: "publish"
    }

    finding = %{disposition: "explicit_risk", severity: :blocking}

    result = %DiscoveryResult{
      schema_version: "2026-08-07.v3",
      auto_apply_proof_complete?: false,
      origin: :legacy_unknown,
      events: [],
      catalog_rows: [],
      source_snapshot_at: ~U[2026-08-07 10:00:00Z],
      canonical_contract_version: "source_risk.v3",
      producer_version: "2026-08-07.1",
      source_system_id: "wordpress_tickera:abc",
      discovery_snapshot_id: "snap-1",
      normalization_mode: :native_v3_review,
      evidence_origin: :native,
      canonical_source_risk_facts: [fact],
      canonical_source_risk_findings: [finding]
    }

    assert result.normalization_mode == :native_v3_review
    assert result.evidence_origin == :native
    assert result.canonical_contract_version == "source_risk.v3"
    assert result.producer_version == "2026-08-07.1"
    assert result.source_system_id == "wordpress_tickera:abc"
    assert result.discovery_snapshot_id == "snap-1"
    assert result.canonical_source_risk_facts == [fact]
    assert result.canonical_source_risk_findings == [finding]
    refute result.auto_apply_proof_complete?

    refute Code.ensure_loaded?(EventSales.Catalog.TickeraCatalog.NativeDiscoveryResult)
    refute Code.ensure_loaded?(EventSales.Catalog.TickeraCatalog.SourceRiskDiscoveryResult)
    refute Code.ensure_loaded?(EventSales.Catalog.TickeraCatalog.V3DiscoveryResult)
  end
end
