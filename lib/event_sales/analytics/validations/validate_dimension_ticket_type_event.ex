defmodule EventSales.Analytics.Validations.ValidateDimensionTicketTypeEvent do
  @moduledoc false

  use Ash.Resource.Validation

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.TicketType

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    if Ash.Changeset.get_attribute(changeset, :dimension_kind) == :ticket_type do
      validate_ticket_type_event(changeset)
    else
      :ok
    end
  end

  defp validate_ticket_type_event(changeset) do
    event_id = Ash.Changeset.get_attribute(changeset, :event_id)
    ticket_type_id = Ash.Changeset.get_attribute(changeset, :ticket_type_id)

    if is_nil(event_id) or is_nil(ticket_type_id) do
      :ok
    else
      case Ash.get(TicketType, ticket_type_id, domain: Catalog) do
        {:ok, %{event_id: ^event_id}} ->
          :ok

        {:ok, _ticket_type} ->
          {:error,
           field: :ticket_type_id,
           message: "must belong to the same event as the dimensional snapshot"}

        {:error, _} ->
          {:error, field: :ticket_type_id, message: "is invalid"}
      end
    end
  end
end
