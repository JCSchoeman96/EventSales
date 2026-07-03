defmodule EventSales.Catalog.TickeraCatalog.DiscoveryResult do
  @moduledoc """
  Sanitized source discovery result for Tickera Bridge catalog sync.
  """

  @type t :: %__MODULE__{
          events: [map()],
          catalog_rows: [map()],
          source_snapshot_at: DateTime.t() | nil
        }

  defstruct events: [], catalog_rows: [], source_snapshot_at: nil
end
