defmodule EventSales.Catalog.OrderAttributionResolver do
  @moduledoc """
  Resolves ticket order attribution from a line-level Tickera event identity.

  Event identity is authoritative when present. Woo product and variation IDs
  are resolved inside that event bucket, and stale ProductMappings are reported
  as review context instead of overriding the source event.
  """

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, ProductMapping, TicketType}

  @type result :: %{
          status: :mapped | :pending,
          event_id: Ecto.UUID.t() | nil,
          ticket_type_id: Ecto.UUID.t() | nil,
          source_tickera_event_id: pos_integer() | nil,
          attribution_status_reason: atom() | nil
        }

  @spec resolve(Ecto.UUID.t(), pos_integer() | nil, integer(), integer() | nil) ::
          {:ok, result()} | {:error, term()}
  def resolve(_source_system_id, nil, _woo_product_id, _woo_variation_id) do
    {:ok, pending(nil, nil)}
  end

  def resolve(source_system_id, source_tickera_event_id, woo_product_id, woo_variation_id)
      when is_binary(source_system_id) and is_integer(source_tickera_event_id) and
             is_integer(woo_product_id) do
    with {:ok, %Event{} = event} <- source_event(source_system_id, source_tickera_event_id),
         {:ok, %TicketType{} = ticket_type} <-
           ticket_type(event, woo_product_id, woo_variation_id),
         {:ok, mapping} <- product_mapping(source_system_id, woo_product_id, woo_variation_id) do
      {:ok, mapped(event, ticket_type, source_tickera_event_id, mapping)}
    else
      {:ok, nil} ->
        {:ok, pending(source_tickera_event_id, :source_event_not_found)}

      {:missing_ticket_type, nil} ->
        {:ok, pending(source_tickera_event_id, :source_ticket_type_not_found)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp source_event(source_system_id, source_tickera_event_id) do
    Event
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and
        external_event_kind == :tickera_event and
        external_event_id == ^source_tickera_event_id
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Catalog)
  end

  defp ticket_type(%Event{id: event_id}, woo_product_id, nil) do
    TicketType
    |> Ash.Query.filter(
      event_id == ^event_id and
        active == true and
        external_ticket_type_kind == :woo_product and
        external_ticket_type_id == ^woo_product_id
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Catalog)
    |> case do
      {:ok, nil} -> {:missing_ticket_type, nil}
      result -> result
    end
  end

  defp ticket_type(%Event{id: event_id}, _woo_product_id, woo_variation_id) do
    TicketType
    |> Ash.Query.filter(
      event_id == ^event_id and
        active == true and
        external_ticket_type_kind == :woo_variation and
        external_ticket_type_id == ^woo_variation_id
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Catalog)
    |> case do
      {:ok, nil} -> {:missing_ticket_type, nil}
      result -> result
    end
  end

  defp product_mapping(source_system_id, woo_product_id, nil) do
    ProductMapping
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and
        woo_product_id == ^woo_product_id and
        is_nil(woo_variation_id) and
        active == true
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Catalog)
  end

  defp product_mapping(source_system_id, woo_product_id, woo_variation_id) do
    ProductMapping
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and
        woo_product_id == ^woo_product_id and
        woo_variation_id == ^woo_variation_id and
        active == true
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Catalog)
  end

  defp mapped(%Event{} = event, %TicketType{} = ticket_type, source_tickera_event_id, nil) do
    mapped_result(event, ticket_type, source_tickera_event_id, :missing_product_mapping)
  end

  defp mapped(
         %Event{} = event,
         %TicketType{} = ticket_type,
         source_tickera_event_id,
         %ProductMapping{
           event_id: event_id,
           ticket_type_id: ticket_type_id
         }
       )
       when event_id == event.id and ticket_type_id == ticket_type.id do
    mapped_result(event, ticket_type, source_tickera_event_id, nil)
  end

  defp mapped(
         %Event{} = event,
         %TicketType{} = ticket_type,
         source_tickera_event_id,
         %ProductMapping{}
       ) do
    mapped_result(event, ticket_type, source_tickera_event_id, :order_event_mapping_conflict)
  end

  defp mapped_result(event, ticket_type, source_tickera_event_id, reason) do
    %{
      status: :mapped,
      event_id: event.id,
      ticket_type_id: ticket_type.id,
      source_tickera_event_id: source_tickera_event_id,
      attribution_status_reason: reason
    }
  end

  defp pending(source_tickera_event_id, reason) do
    %{
      status: :pending,
      event_id: nil,
      ticket_type_id: nil,
      source_tickera_event_id: source_tickera_event_id,
      attribution_status_reason: reason
    }
  end
end
