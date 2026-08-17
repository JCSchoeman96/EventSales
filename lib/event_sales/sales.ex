defmodule EventSales.Sales do
  @moduledoc """
  Ash domain boundary for normalized orders, order items, coupons, and sales status truth.
  """

  use Ash.Domain

  resources do
    resource EventSales.Sales.Resources.Order
    resource EventSales.Sales.Resources.OrderItem
    resource EventSales.Sales.Resources.CouponSnapshot
    resource EventSales.Sales.Resources.Refund
    resource EventSales.Sales.Resources.RefundLine
  end
end
