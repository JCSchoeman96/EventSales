defmodule EventSales.Catalog.TickeraCatalog.DiscoveryResult do
  @moduledoc """
  Sanitized source discovery result for Tickera Bridge catalog sync.

  Sole operational carrier for both `legacy_v2_operational` and `native_v3_review`.
  """

  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.CanonicalFact

  @type normalization_mode :: :legacy_v2_operational | :native_v3_review
  @type evidence_origin :: :native | nil

  @type t :: %__MODULE__{
          schema_version: String.t() | nil,
          auto_apply_proof_complete?: boolean(),
          origin: :human_admin | :targeted_catalog_change | :legacy_unknown,
          events: [map()],
          catalog_rows: [map()],
          source_snapshot_at: DateTime.t() | nil,
          canonical_contract_version: String.t() | nil,
          producer_version: String.t() | nil,
          source_system_id: String.t() | nil,
          discovery_snapshot_id: String.t() | nil,
          normalization_mode: normalization_mode(),
          evidence_origin: evidence_origin(),
          canonical_source_risk_facts: [CanonicalFact.t()],
          canonical_source_risk_findings: [map()]
        }

  defstruct schema_version: nil,
            auto_apply_proof_complete?: false,
            origin: :legacy_unknown,
            events: [],
            catalog_rows: [],
            source_snapshot_at: nil,
            canonical_contract_version: nil,
            producer_version: nil,
            source_system_id: nil,
            discovery_snapshot_id: nil,
            normalization_mode: :legacy_v2_operational,
            evidence_origin: nil,
            canonical_source_risk_facts: [],
            canonical_source_risk_findings: []
end
