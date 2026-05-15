defmodule EventSales.Catalog.Changes.ValidateTicketTypeEvent do
  @moduledoc false

  use Ash.Resource.Change

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.TicketType

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &validate_ticket_type_event/1)
  end

  defp validate_ticket_type_event(changeset) do
    event_id = Ash.Changeset.get_attribute(changeset, :event_id)
    ticket_type_id = Ash.Changeset.get_attribute(changeset, :ticket_type_id)

    if present_ids?(event_id, ticket_type_id) do
      validate_matching_event(changeset, event_id, ticket_type_id)
    else
      changeset
    end
  end

  defp present_ids?(event_id, ticket_type_id),
    do: not is_nil(event_id) and not is_nil(ticket_type_id)

  defp validate_matching_event(changeset, event_id, ticket_type_id) do
    case Ash.get(TicketType, ticket_type_id, domain: Catalog) do
      {:ok, %{event_id: ^event_id}} ->
        changeset

      {:ok, _ticket_type} ->
        Ash.Changeset.add_error(changeset,
          field: :ticket_type_id,
          message: "must belong to the same event as the mapping"
        )

      {:error, _} ->
        Ash.Changeset.add_error(changeset, field: :ticket_type_id, message: "is invalid")
    end
  end
end
