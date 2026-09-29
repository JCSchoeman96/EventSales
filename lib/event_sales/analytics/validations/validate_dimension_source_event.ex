defmodule EventSales.Analytics.Validations.ValidateDimensionSourceEvent do
  @moduledoc false

  use Ash.Resource.Validation

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event

  @product_grains [:source_product, :source_variation]

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    dimension_kind = Ash.Changeset.get_attribute(changeset, :dimension_kind)

    if dimension_kind in @product_grains do
      validate_source_event(changeset)
    else
      :ok
    end
  end

  defp validate_source_event(changeset) do
    source_system_id = Ash.Changeset.get_attribute(changeset, :source_system_id)
    event_id = Ash.Changeset.get_attribute(changeset, :event_id)

    if is_nil(source_system_id) or is_nil(event_id) do
      :ok
    else
      case Ash.get(Event, event_id, domain: Catalog) do
        {:ok, %{source_system_id: ^source_system_id}} ->
          :ok

        {:ok, _event} ->
          {:error,
           field: :source_system_id,
           message: "must match the event source system for product or variation dimensions"}

        {:error, _} ->
          {:error, field: :event_id, message: "is invalid"}
      end
    end
  end
end
