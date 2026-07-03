defmodule EventSales.Catalog.TickeraCatalog.Finding do
  @moduledoc """
  Sanitized catalog sync dry-run finding.
  """

  @enforce_keys [:severity, :code, :message]
  @type t :: %__MODULE__{
          severity: :info | :warning | :blocking,
          code: atom(),
          message: String.t(),
          tickera_event_id: integer() | nil,
          woo_product_id: integer() | nil,
          woo_variation_id: integer() | nil,
          metadata: map()
        }

  defstruct [
    :severity,
    :code,
    :message,
    :tickera_event_id,
    :woo_product_id,
    :woo_variation_id,
    metadata: %{}
  ]
end
