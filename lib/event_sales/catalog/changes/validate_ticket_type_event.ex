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
    woo_product_id = Ash.Changeset.get_attribute(changeset, :woo_product_id)
    woo_variation_id = Ash.Changeset.get_attribute(changeset, :woo_variation_id)

    if present_ids?(event_id, ticket_type_id) do
      validate_ticket_type(changeset, event_id, ticket_type_id, woo_product_id, woo_variation_id)
    else
      changeset
    end
  end

  defp present_ids?(event_id, ticket_type_id),
    do: not is_nil(event_id) and not is_nil(ticket_type_id)

  defp validate_ticket_type(changeset, event_id, ticket_type_id, woo_product_id, woo_variation_id) do
    case Ash.get(TicketType, ticket_type_id, domain: Catalog) do
      {:ok, ticket_type} ->
        changeset
        |> validate_matching_event(event_id, ticket_type)
        |> validate_matching_parent(woo_product_id, ticket_type)
        |> validate_variation_identity(woo_variation_id, ticket_type)

      {:error, _} ->
        Ash.Changeset.add_error(changeset, field: :ticket_type_id, message: "is invalid")
    end
  end

  defp validate_matching_event(changeset, event_id, %{event_id: event_id}), do: changeset

  defp validate_matching_event(changeset, _event_id, _ticket_type) do
    Ash.Changeset.add_error(changeset,
      field: :ticket_type_id,
      message: "must belong to the same event as the mapping"
    )
  end

  defp validate_matching_parent(changeset, _woo_product_id, %{external_product_id: nil}),
    do: changeset

  defp validate_matching_parent(changeset, woo_product_id, %{external_product_id: woo_product_id})
       when not is_nil(woo_product_id),
       do: changeset

  defp validate_matching_parent(changeset, woo_product_id, %{external_product_id: _parent})
       when not is_nil(woo_product_id) do
    Ash.Changeset.add_error(changeset,
      field: :woo_product_id,
      message: "must match the ticket type parent product"
    )
  end

  defp validate_matching_parent(changeset, _woo_product_id, _ticket_type), do: changeset

  defp validate_variation_identity(changeset, woo_variation_id, ticket_type)
       when not is_nil(woo_variation_id) do
    case ticket_type do
      %{
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: ^woo_variation_id,
        external_variation_id: mirror
      }
      when is_nil(mirror) or mirror == woo_variation_id ->
        changeset

      _ ->
        Ash.Changeset.add_error(changeset,
          field: :woo_variation_id,
          message: "must match the ticket type variation"
        )
    end
  end

  defp validate_variation_identity(changeset, nil, %{external_ticket_type_kind: :woo_variation}) do
    Ash.Changeset.add_error(changeset,
      field: :woo_variation_id,
      message: "must match the ticket type variation"
    )
  end

  defp validate_variation_identity(changeset, _woo_variation_id, _ticket_type), do: changeset
end
