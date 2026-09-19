defmodule EventSales.Sales.FinancialPrimitives do
  @moduledoc """
  Pure M1-06 financial primitive arithmetic for Path 1 reconciliation.

  This module encodes contract recognition and additive primitive formulas
  without database access, Woo parsing, or legacy `MetricRules` behavior.
  """

  @primitives [
    :gross_ticket_quantity,
    :gross_ticket_value,
    :refund_ticket_quantity,
    :refund_ticket_value,
    :net_ticket_quantity,
    :net_ticket_value
  ]

  @quantity_primitives [
    :gross_ticket_quantity,
    :refund_ticket_quantity,
    :net_ticket_quantity
  ]

  @type primitive :: unquote(Enum.reduce(@primitives, &{:|, [], [&1, &2]}))
  @type totals :: %{primitive() => Decimal.t()}

  @zero Decimal.new("0")

  @doc "Returns the locked C17 primitive names in deterministic order."
  @spec primitives() :: [primitive()]
  def primitives, do: @primitives

  @doc "Returns true when a durable Order historically reached recognised sale evidence."
  @spec historically_recognised_order?(atom(), DateTime.t() | nil) :: boolean()
  def historically_recognised_order?(status, completed_at) when is_atom(status) do
    status == :completed or match?(%DateTime{}, completed_at)
  end

  @doc "Returns true when a Woo order payload carries historical completion evidence."
  @spec historically_recognised_source_order?(String.t(), DateTime.t() | nil) :: boolean()
  def historically_recognised_source_order?(status, completed_at) when is_binary(status) do
    status == "completed" or match?(%DateTime{}, completed_at)
  end

  @doc "Returns an empty zeroed primitive totals map."
  @spec empty_totals() :: totals()
  def empty_totals do
    Map.new(@primitives, &{&1, @zero})
  end

  @doc "Adds two primitive totals maps together without clamping net results."
  @spec add_totals(totals(), totals()) :: totals()
  def add_totals(left, right) do
    Enum.reduce(@primitives, %{}, fn primitive, acc ->
      Map.put(
        acc,
        primitive,
        Decimal.add(Map.fetch!(left, primitive), Map.fetch!(right, primitive))
      )
    end)
  end

  @doc "Returns gross ticket quantity for a positive ticket line quantity."
  @spec gross_ticket_quantity(integer()) :: Decimal.t()
  def gross_ticket_quantity(quantity) when is_integer(quantity) and quantity > 0,
    do: Decimal.new(quantity)

  def gross_ticket_quantity(_quantity), do: @zero

  @doc "Returns tax-inclusive gross ticket value from ex-tax line total and tax."
  @spec gross_ticket_value(Decimal.t() | number() | nil, Decimal.t() | number() | nil) ::
          Decimal.t()
  def gross_ticket_value(line_total, line_total_tax) do
    Decimal.add(decimal(line_total), decimal(line_total_tax))
  end

  @doc "Returns positive refunded ticket quantity magnitude."
  @spec refund_ticket_quantity(integer() | nil) :: Decimal.t()
  def refund_ticket_quantity(quantity) when is_integer(quantity) and quantity > 0,
    do: Decimal.new(quantity)

  def refund_ticket_quantity(_quantity), do: @zero

  @doc "Returns positive tax-inclusive ticket refund value magnitude."
  @spec refund_ticket_value(Decimal.t() | number() | nil, Decimal.t() | number() | nil) ::
          Decimal.t()
  def refund_ticket_value(refund_total, refund_total_tax) do
    Decimal.add(decimal(refund_total), decimal(refund_total_tax))
  end

  @doc "Derives net ticket quantity as gross minus refund without clamping."
  @spec net_ticket_quantity(Decimal.t(), Decimal.t()) :: Decimal.t()
  def net_ticket_quantity(gross_quantity, refund_quantity) do
    Decimal.sub(gross_quantity, refund_quantity)
  end

  @doc "Derives net ticket value as gross minus refund without clamping."
  @spec net_ticket_value(Decimal.t(), Decimal.t()) :: Decimal.t()
  def net_ticket_value(gross_value, refund_value) do
    Decimal.sub(gross_value, refund_value)
  end

  @doc "Builds a complete totals map from gross and refund component totals."
  @spec derive_net_totals(totals()) :: totals()
  def derive_net_totals(totals) do
    gross_qty = Map.fetch!(totals, :gross_ticket_quantity)
    refund_qty = Map.fetch!(totals, :refund_ticket_quantity)
    gross_val = Map.fetch!(totals, :gross_ticket_value)
    refund_val = Map.fetch!(totals, :refund_ticket_value)

    totals
    |> Map.put(:net_ticket_quantity, net_ticket_quantity(gross_qty, refund_qty))
    |> Map.put(:net_ticket_value, net_ticket_value(gross_val, refund_val))
  end

  @doc "Returns true when a Decimal represents a non-negative integral quantity."
  @spec integral_quantity?(Decimal.t()) :: boolean()
  def integral_quantity?(%Decimal{} = value) do
    Decimal.compare(value, @zero) != :lt and
      Decimal.equal?(Decimal.rem(value, 1), @zero)
  end

  def integral_quantity?(_value), do: false

  @doc "Returns true when the primitive stores quantity semantics."
  @spec quantity_primitive?(primitive()) :: boolean()
  def quantity_primitive?(primitive), do: primitive in @quantity_primitives

  defp decimal(%Decimal{} = value), do: value
  defp decimal(nil), do: @zero
  defp decimal(value) when is_integer(value), do: Decimal.new(value)
  defp decimal(value) when is_binary(value), do: Decimal.new(value)
end
