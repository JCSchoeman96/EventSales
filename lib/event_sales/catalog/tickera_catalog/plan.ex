defmodule EventSales.Catalog.TickeraCatalog.Plan do
  @moduledoc """
  Deterministic dry-run plan for Tickera catalog sync.
  """

  @type t :: %__MODULE__{
          event_changes: [map()],
          ticket_type_changes: [map()],
          product_mapping_changes: [map()],
          findings: [EventSales.Catalog.TickeraCatalog.Finding.t()],
          touched_event_ids: [String.t()],
          touched_product_keys: [[integer() | nil]],
          summary: map(),
          dry_run_hash: String.t() | nil,
          plan_snapshot: map() | nil
        }

  defstruct event_changes: [],
            ticket_type_changes: [],
            product_mapping_changes: [],
            findings: [],
            touched_event_ids: [],
            touched_product_keys: [],
            summary: %{},
            dry_run_hash: nil,
            plan_snapshot: nil
end
