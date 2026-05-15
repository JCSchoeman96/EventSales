defmodule EventSales.Sales.StatusRules do
  @moduledoc """
  Pure completed-only eligibility rules for normalized sales rows.

  Slice 4.0 provides predicates for storage and state-machine tests. Slice 9.0
  introduces `MetricRules` for analytics and dashboard math.
  """

  alias EventSales.Sales.Resources.{Order, OrderItem}

  @doc """
  Returns true when a line item should count toward sold ticket totals.
  """
  @spec counts_toward_sold_tickets?(Order.t(), OrderItem.t()) :: boolean()
  def counts_toward_sold_tickets?(%Order{status: :completed}, %OrderItem{} = item) do
    item.mapping_status == :mapped and item.quantity > 0 and item.item_kind == :ticket
  end

  def counts_toward_sold_tickets?(_order, _item), do: false

  @doc """
  Returns true when a line item should count toward completed revenue totals.
  """
  @spec counts_toward_completed_revenue?(Order.t(), OrderItem.t()) :: boolean()
  def counts_toward_completed_revenue?(order, item),
    do: counts_toward_sold_tickets?(order, item)

  @doc """
  Returns true when the order/item should remain visible in status breakdowns.
  """
  @spec visible_status?(Order.t(), OrderItem.t()) :: boolean()
  def visible_status?(_order, _item), do: true

  @doc """
  Returns true when the line is stored but excluded from sold-ticket math.
  """
  @spec excluded_from_sold?(Order.t(), OrderItem.t()) :: boolean()
  def excluded_from_sold?(order, item), do: not counts_toward_sold_tickets?(order, item)
end
