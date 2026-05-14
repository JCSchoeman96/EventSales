defmodule EventSales.Sales do
  @moduledoc """
  Ash domain boundary for normalized orders, order items, coupons, and sales status truth.

  Slice 1.0 registers the domain boundary only. Resources are added by their owning slices.
  """

  use Ash.Domain
end
