defmodule EventSales.Analytics.Validations.ValidateDimensionAggregateGrain do
  @moduledoc false

  use Ash.Resource.Validation

  @dimension_kinds [:ticket_type, :source_product, :source_variation]

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    dimension_kind = Ash.Changeset.get_attribute(changeset, :dimension_kind)

    case dimension_kind do
      kind when kind in @dimension_kinds ->
        validate_shape(changeset, kind)

      nil ->
        :ok

      _other ->
        {:error,
         field: :dimension_kind,
         message: "must be ticket_type, source_product, or source_variation"}
    end
  end

  defp validate_shape(changeset, :ticket_type) do
    cond do
      missing?(changeset, :ticket_type_id) ->
        {:error, field: :ticket_type_id, message: "is required for ticket_type dimension"}

      present?(changeset, :source_system_id) or present?(changeset, :woo_product_id) or
          present?(changeset, :woo_variation_id) ->
        {:error,
         field: :dimension_kind,
         message: "ticket_type rows must not include source or product identity fields"}

      true ->
        :ok
    end
  end

  defp validate_shape(changeset, :source_product) do
    cond do
      present?(changeset, :ticket_type_id) ->
        {:error, field: :ticket_type_id, message: "must be absent for source_product dimension"}

      missing?(changeset, :source_system_id) ->
        {:error, field: :source_system_id, message: "is required for source_product dimension"}

      missing?(changeset, :woo_product_id) ->
        {:error, field: :woo_product_id, message: "is required for source_product dimension"}

      present?(changeset, :woo_variation_id) ->
        {:error, field: :woo_variation_id, message: "must be absent for source_product dimension"}

      true ->
        :ok
    end
  end

  defp validate_shape(changeset, :source_variation) do
    cond do
      present?(changeset, :ticket_type_id) ->
        {:error, field: :ticket_type_id, message: "must be absent for source_variation dimension"}

      missing?(changeset, :source_system_id) ->
        {:error, field: :source_system_id, message: "is required for source_variation dimension"}

      missing?(changeset, :woo_product_id) ->
        {:error, field: :woo_product_id, message: "is required for source_variation dimension"}

      missing?(changeset, :woo_variation_id) ->
        {:error, field: :woo_variation_id, message: "is required for source_variation dimension"}

      true ->
        :ok
    end
  end

  defp present?(changeset, field) do
    not missing?(changeset, field)
  end

  defp missing?(changeset, field) do
    Ash.Changeset.get_attribute(changeset, field) |> is_nil()
  end
end
