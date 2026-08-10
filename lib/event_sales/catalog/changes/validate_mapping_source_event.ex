defmodule EventSales.Catalog.Changes.ValidateMappingSourceEvent do
  @moduledoc false

  use Ash.Resource.Change

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &validate_mapping_source_event/1)
  end

  defp validate_mapping_source_event(changeset) do
    source_system_id = Ash.Changeset.get_attribute(changeset, :source_system_id)
    event_id = Ash.Changeset.get_attribute(changeset, :event_id)

    if present_ids?(source_system_id, event_id) do
      validate_matching_source(changeset, source_system_id, event_id)
    else
      changeset
    end
  end

  defp present_ids?(source_system_id, event_id),
    do: not is_nil(source_system_id) and not is_nil(event_id)

  defp validate_matching_source(changeset, source_system_id, event_id) do
    case Ash.get(Event, event_id, domain: Catalog) do
      {:ok, %{source_system_id: ^source_system_id}} ->
        changeset

      {:ok, _event} ->
        Ash.Changeset.add_error(changeset,
          field: :event_id,
          message: "must belong to the same source system as the mapping"
        )

      {:error, _} ->
        Ash.Changeset.add_error(changeset, field: :event_id, message: "is invalid")
    end
  end
end
