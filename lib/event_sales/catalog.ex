defmodule EventSales.Catalog do
  @moduledoc """
  Ash domain boundary for source systems, events, ticket types, mappings, and dashboard settings.

  Slice 1.0 registers the domain boundary only. Resources are added by their owning slices.
  """

  use Ash.Domain
end
