defmodule EventSales.Ingestion.Handlers.ProductUpdatedHandler do
  @moduledoc """
  Handles WooCommerce product.updated webhooks as metadata-only events.
  """

  alias EventSales.Analytics.DashboardCache
  alias EventSales.Catalog.CacheInvalidation
  alias EventSales.Catalog.ProductMetadataUpdater
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{WebhookDeliveryFailure, WebhookEvent}

  @retryable_postgres_codes [
    :connection_exception,
    :connection_does_not_exist,
    :connection_failure,
    :sqlclient_unable_to_establish_sqlconnection,
    :sqlserver_rejected_establishment_of_sqlconnection,
    :transaction_resolution_unknown,
    :protocol_violation,
    :serialization_failure,
    :deadlock_detected,
    :query_canceled,
    :lock_not_available
  ]

  @doc """
  Processes a stored product.updated webhook without changing sales truth.
  """
  @spec handle(WebhookEvent.t()) ::
          :ok
          | {:ignored, :unknown_product}
          | {:error, {:permanent, term()} | {:transient, term()}}
  def handle(%WebhookEvent{topic: "product.updated"} = event) do
    case ProductMetadataUpdater.update_from_payload(event.source_system_id, event.payload) do
      {:ok, %{status: :updated, mapping: mapping}} ->
        DashboardCache.invalidate_event(mapping.event_id, :product_metadata_updated)
        CacheInvalidation.emit_for_event(mapping.event_id, :product_metadata_updated)
        :ok

      {:ok, %{status: :unchanged}} ->
        :ok

      {:ignored, :unknown_product, metadata} ->
        log_unknown_product(event, metadata)
        {:ignored, :unknown_product}

      {:error, {:invalid_product_payload, _field, _reason} = reason} ->
        {:error, {:permanent, reason}}

      {:error, reason} ->
        classify_error(reason)
    end
  end

  def handle(%WebhookEvent{}), do: {:error, {:permanent, :unsupported_topic}}

  defp log_unknown_product(%WebhookEvent{} = event, metadata) do
    attrs = %{
      reason: :unknown_product,
      topic: event.topic,
      source_system_id: event.source_system_id,
      metadata: %{
        "webhook_event_id" => event.id,
        "resource_id" => event.resource_id,
        "woo_product_id" => metadata.woo_product_id
      },
      received_at: DateTime.utc_now()
    }

    WebhookDeliveryFailure
    |> Ash.Changeset.for_create(:log_failure, attrs)
    |> Ash.create(domain: Ingestion)
    |> case do
      {:ok, _failure} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp classify_error(%Ash.Error.Invalid{} = reason), do: {:error, {:permanent, reason}}

  defp classify_error(%DBConnection.ConnectionError{} = reason),
    do: {:error, {:transient, reason}}

  defp classify_error(%Postgrex.Error{postgres: %{code: code}} = reason)
       when code in @retryable_postgres_codes,
       do: {:error, {:transient, reason}}

  defp classify_error(%Postgrex.Error{} = reason), do: {:error, {:permanent, reason}}
  defp classify_error(reason), do: {:error, {:permanent, reason}}
end
