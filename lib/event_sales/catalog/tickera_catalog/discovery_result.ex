defmodule EventSales.Catalog.TickeraCatalog.DiscoveryResult do
  @moduledoc """
  Sanitized source discovery result for Tickera Bridge catalog sync.
  """

  @type t :: %__MODULE__{
          schema_version: String.t() | nil,
          auto_apply_proof_complete?: boolean(),
          origin: :human_admin | :targeted_catalog_change | :legacy_unknown,
          events: [map()],
          catalog_rows: [map()],
          source_snapshot_at: DateTime.t() | nil
        }

  defstruct schema_version: nil,
            auto_apply_proof_complete?: false,
            origin: :legacy_unknown,
            events: [],
            catalog_rows: [],
            source_snapshot_at: nil
end
