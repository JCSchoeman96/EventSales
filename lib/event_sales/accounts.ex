defmodule EventSales.Accounts do
  @moduledoc """
  Ash domain boundary for users, authentication, roles, event access, and PII visibility.

  Slice 1.0 registers the domain boundary only. Resources are added by their owning slices.
  """

  use Ash.Domain
end
