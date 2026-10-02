defmodule EventSales.Analytics.Validations.ValidateContributionFactIdentity do
  @moduledoc false

  use Ash.Resource.Validation

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Catalog.Resources.TicketType

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    event_id = Ash.Changeset.get_attribute(changeset, :event_id)
    ticket_type_id = Ash.Changeset.get_attribute(changeset, :ticket_type_id)
    source_system_id = Ash.Changeset.get_attribute(changeset, :source_system_id)

    with :ok <- validate_ticket_type_event(event_id, ticket_type_id) do
      validate_event_source(event_id, source_system_id)
    end
  end

  defp validate_ticket_type_event(nil, _ticket_type_id), do: :ok
  defp validate_ticket_type_event(_event_id, nil), do: :ok

  defp validate_ticket_type_event(event_id, ticket_type_id) do
    case Ash.get(TicketType, ticket_type_id, domain: Catalog) do
      {:ok, %{event_id: ^event_id}} ->
        :ok

      {:ok, _ticket_type} ->
        {:error, field: :ticket_type_id, message: "must belong to the same event as the fact"}

      {:error, _} ->
        {:error, field: :ticket_type_id, message: "is invalid"}
    end
  end

  defp validate_event_source(nil, _source_system_id), do: :ok
  defp validate_event_source(_event_id, nil), do: :ok

  defp validate_event_source(event_id, source_system_id) do
    case Ash.get(Event, event_id, domain: Catalog) do
      {:ok, %{source_system_id: ^source_system_id}} ->
        :ok

      {:ok, _event} ->
        {:error, field: :source_system_id, message: "must match the event source system"}

      {:error, _} ->
        {:error, field: :event_id, message: "is invalid"}
    end
  end
end
