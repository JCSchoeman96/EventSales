defmodule EventSales.Analytics.Validations.ValidateContributionFactShape do
  @moduledoc false

  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    kind = Ash.Changeset.get_attribute(changeset, :contribution_kind)

    attributes = %{
      gross_quantity: Ash.Changeset.get_attribute(changeset, :gross_ticket_quantity),
      gross_value: Ash.Changeset.get_attribute(changeset, :gross_ticket_value),
      refund_quantity: Ash.Changeset.get_attribute(changeset, :refund_ticket_quantity),
      refund_value: Ash.Changeset.get_attribute(changeset, :refund_ticket_value)
    }

    validate_shape(kind, attributes)
  end

  defp validate_shape(nil, _attributes), do: :ok
  defp validate_shape(:sale, attributes), do: result(valid_sale?(attributes))
  defp validate_shape(:refund, attributes), do: result(valid_refund?(attributes))
  defp validate_shape(_other, _attributes), do: invalid_shape()

  defp valid_sale?(attributes) do
    attributes.gross_quantity > 0 and nonnegative?(attributes.gross_value) and
      attributes.refund_quantity == 0 and zero?(attributes.refund_value)
  end

  defp valid_refund?(attributes) do
    attributes.gross_quantity == 0 and zero?(attributes.gross_value) and
      attributes.refund_quantity >= 0 and nonnegative?(attributes.refund_value) and
      (attributes.refund_quantity > 0 or positive?(attributes.refund_value))
  end

  defp result(true), do: :ok
  defp result(false), do: invalid_shape()

  defp nonnegative?(value), do: Decimal.compare(value, Decimal.new("0")) in [:eq, :gt]
  defp positive?(value), do: Decimal.compare(value, Decimal.new("0")) == :gt
  defp zero?(value), do: Decimal.compare(value, Decimal.new("0")) == :eq

  defp invalid_shape do
    {:error,
     field: :contribution_kind, message: "does not match the gross and refund primitive shape"}
  end
end
