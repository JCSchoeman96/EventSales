defmodule EventSales.Audit do
  @moduledoc """
  Ash domain boundary for operational audit logs and PaperTrail-backed resource history.

  Slice 1.0 registers the domain boundary only. Resources are added by their owning slices.
  """

  use Ash.Domain
end
