defmodule EventSales.Catalog.Changes.InvalidateEventOnboardingAfterMappingChange do
  @moduledoc """
  Invalidates onboarding for structural ProductMapping changes before commit.

  The Event rows are locked before the mapping write so certification and mapping
  mutation use the same Event-first lock order.
  """

  use Ash.Resource.Change

  alias EventSales.Catalog.EventOnboarding
  alias EventSales.Catalog.Resources.ProductMapping

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&lock_structural_events/1)
    |> Ash.Changeset.after_action(&after_mapping_action/2)
  end

  defp after_mapping_action(changeset, %ProductMapping{} = mapping) do
    if structural_changed?(changeset, mapping) do
      invalidate_mapping_events(changeset, mapping)
    else
      {:ok, mapping}
    end
  end

  defp invalidate_mapping_events(changeset, mapping) do
    case EventOnboarding.invalidate_many(event_ids(changeset, mapping)) do
      :ok -> {:ok, mapping}
      {:error, _reason} -> {:error, :event_onboarding_invalidation_failed}
    end
  end

  defp lock_structural_events(changeset) do
    case EventOnboarding.lock_events(event_ids(changeset, prospective_mapping(changeset))) do
      :ok ->
        changeset

      {:error, _reason} ->
        Ash.Changeset.add_error(changeset,
          field: :event_id,
          message: "could not lock Event onboarding state"
        )
    end
  end

  defp structural_changed?(%{action: %{type: :create}}, _mapping), do: true

  defp structural_changed?(changeset, %ProductMapping{} = mapping) do
    structural_tuple(changeset.data) != structural_tuple(mapping)
  end

  defp event_ids(%{action: %{type: :create}}, %ProductMapping{event_id: event_id}),
    do: [event_id]

  defp event_ids(changeset, %ProductMapping{} = mapping) do
    old_event_id = Map.get(changeset.data, :event_id)
    new_event_id = mapping.event_id

    if structural_changed?(changeset, mapping), do: [old_event_id, new_event_id], else: []
  end

  defp prospective_mapping(changeset) do
    %ProductMapping{
      source_system_id: Ash.Changeset.get_attribute(changeset, :source_system_id),
      event_id: Ash.Changeset.get_attribute(changeset, :event_id),
      ticket_type_id: Ash.Changeset.get_attribute(changeset, :ticket_type_id),
      woo_product_id: Ash.Changeset.get_attribute(changeset, :woo_product_id),
      woo_variation_id: Ash.Changeset.get_attribute(changeset, :woo_variation_id),
      active: Ash.Changeset.get_attribute(changeset, :active)
    }
  end

  defp structural_tuple(%ProductMapping{} = mapping) do
    {
      mapping.source_system_id,
      mapping.event_id,
      mapping.ticket_type_id,
      mapping.woo_product_id,
      mapping.woo_variation_id,
      mapping.active
    }
  end
end
