defmodule EventSales.Catalog.Changes.InvalidateEventOnboardingAfterTicketTypeChange do
  @moduledoc """
  Invalidates mapped Event onboarding for structural TicketType changes.

  Mapping lookup is constrained by the exact TicketType id. Event rows are locked
  before the TicketType write to preserve the Event-first certification lock order.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.EventOnboarding
  alias EventSales.Catalog.Resources.{ProductMapping, TicketType}

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&lock_mapped_events/1)
    |> Ash.Changeset.after_action(&after_ticket_type_action/2)
  end

  defp after_ticket_type_action(changeset, %TicketType{} = ticket_type) do
    if structural_changed?(changeset, ticket_type) do
      invalidate_ticket_type_events(ticket_type)
    else
      {:ok, ticket_type}
    end
  end

  defp invalidate_ticket_type_events(%TicketType{id: ticket_type_id} = ticket_type) do
    case active_mapping_event_ids(ticket_type_id) do
      {:ok, event_ids} -> invalidate_events(event_ids, ticket_type)
      {:error, _reason} -> {:error, :event_onboarding_invalidation_failed}
    end
  end

  defp invalidate_events(event_ids, ticket_type) do
    case EventOnboarding.invalidate_many(event_ids) do
      :ok -> {:ok, ticket_type}
      {:error, _reason} -> {:error, :event_onboarding_invalidation_failed}
    end
  end

  defp lock_mapped_events(changeset) do
    if structural_changed?(changeset, prospective_ticket_type(changeset)) do
      with {:ok, event_ids} <- active_mapping_event_ids(changeset.data.id),
           :ok <- EventOnboarding.lock_events(event_ids) do
        changeset
      else
        _other ->
          Ash.Changeset.add_error(changeset,
            field: :active,
            message: "could not lock mapped Event onboarding state"
          )
      end
    else
      changeset
    end
  end

  defp active_mapping_event_ids(ticket_type_id) do
    ProductMapping
    |> Ash.Query.filter(ticket_type_id == ^ticket_type_id and active == true)
    |> Ash.Query.select([:event_id])
    |> Ash.read(domain: Catalog)
    |> case do
      {:ok, mappings} -> {:ok, mappings |> Enum.map(& &1.event_id) |> Enum.uniq()}
      _other -> {:error, :event_onboarding_invalidation_failed}
    end
  end

  defp structural_changed?(%{action: %{type: :create}}, _ticket_type), do: true

  defp structural_changed?(changeset, %TicketType{} = ticket_type) do
    structural_tuple(changeset.data) != structural_tuple(ticket_type)
  end

  defp prospective_ticket_type(changeset) do
    %TicketType{
      active: Ash.Changeset.get_attribute(changeset, :active),
      external_ticket_type_id: Ash.Changeset.get_attribute(changeset, :external_ticket_type_id),
      external_ticket_type_kind:
        Ash.Changeset.get_attribute(changeset, :external_ticket_type_kind),
      external_product_id: Ash.Changeset.get_attribute(changeset, :external_product_id),
      external_variation_id: Ash.Changeset.get_attribute(changeset, :external_variation_id)
    }
  end

  defp structural_tuple(%TicketType{} = ticket_type) do
    {
      ticket_type.active,
      ticket_type.external_ticket_type_id,
      ticket_type.external_ticket_type_kind,
      ticket_type.external_product_id,
      ticket_type.external_variation_id
    }
  end
end
