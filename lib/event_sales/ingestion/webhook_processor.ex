defmodule EventSales.Ingestion.WebhookProcessor do
  @moduledoc """
  Processing lifecycle and idempotency shell for stored WooCommerce webhooks.

  Slice 6.0 intentionally stops at `WebhookEvent` lifecycle management. It does
  not parse Woo payloads or mutate Sales resources.
  """

  require Ash.Query

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookEvent

  @terminal_statuses [:processed, :failed, :ignored]
  @supported_order_topics ~w(order.created order.updated)
  @max_error_message_length 512

  @type process_result ::
          :ok
          | {:discard, :not_found}
          | {:error, {:transient, term()}}

  @doc """
  Processes a stored webhook event lifecycle without mutating Sales resources.
  """
  @spec process(Ecto.UUID.t(), keyword()) :: process_result()
  def process(webhook_event_id, opts \\ []) when is_binary(webhook_event_id) do
    handler = Keyword.get(opts, :handler, fn _event -> :ok end)

    case load_event(webhook_event_id) do
      nil -> process_missing_event()
      %WebhookEvent{status: status} when status in @terminal_statuses -> :ok
      %WebhookEvent{} = event -> process_loaded_event(event, handler)
    end
  end

  defp process_missing_event, do: {:discard, :not_found}

  defp process_loaded_event(%WebhookEvent{} = event, handler) when is_function(handler, 1) do
    event
    |> mark_processing()
    |> classify_or_handle(handler)
  end

  defp classify_or_handle(%WebhookEvent{} = event, handler) do
    cond do
      unsupported_topic?(event.topic) ->
        mark_ignored(event, :unsupported_topic)

      duplicate_processed_resource_hash?(event) ->
        mark_ignored(event, :duplicate_resource_hash)

      stale_against_processed_event?(event) ->
        mark_ignored(event, :stale_source_version)

      true ->
        handle_supported_event(event, handler)
    end
  end

  defp handle_supported_event(%WebhookEvent{} = event, handler) do
    case handler.(event) do
      :ok ->
        mark_processed(event)

      {:error, {:permanent, reason}} ->
        mark_failed(event, reason)

      {:error, {:transient, reason}} ->
        {:error, {:transient, reason}}
    end
  end

  defp load_event(webhook_event_id) do
    case Ash.get(WebhookEvent, webhook_event_id, domain: Ingestion) do
      {:ok, event} -> event
      {:error, _reason} -> nil
    end
  end

  defp unsupported_topic?(topic), do: topic not in @supported_order_topics

  defp duplicate_processed_resource_hash?(%WebhookEvent{} = event) do
    WebhookEvent
    |> Ash.Query.filter(
      id != ^event.id and
        source_system_id == ^event.source_system_id and
        resource_type == ^event.resource_type and
        resource_id == ^event.resource_id and
        payload_hash == ^event.payload_hash and
        status == :processed
    )
    |> Ash.Query.limit(1)
    |> Ash.exists?(domain: Ingestion)
  end

  defp stale_against_processed_event?(%WebhookEvent{source_updated_at: nil}), do: false

  defp stale_against_processed_event?(
         %WebhookEvent{source_updated_at: %DateTime{} = incoming} = event
       ) do
    WebhookEvent
    |> Ash.Query.filter(
      id != ^event.id and
        source_system_id == ^event.source_system_id and
        resource_type == ^event.resource_type and
        resource_id == ^event.resource_id and
        status == :processed and
        not is_nil(source_updated_at) and
        source_updated_at > ^incoming
    )
    |> Ash.Query.limit(1)
    |> Ash.exists?(domain: Ingestion)
  end

  defp mark_processing(%WebhookEvent{} = event) do
    Ash.update!(
      event,
      %{
        processing_attempt_count: event.processing_attempt_count + 1,
        processing_started_at: DateTime.utc_now()
      },
      action: :mark_processing,
      domain: Ingestion
    )
  end

  defp mark_processed(%WebhookEvent{} = event) do
    Ash.update!(
      event,
      %{
        processed_at: DateTime.utc_now(),
        failed_at: nil,
        error_message: nil,
        ignore_reason: nil
      },
      action: :mark_processed,
      domain: Ingestion
    )

    :ok
  end

  defp mark_failed(%WebhookEvent{} = event, reason) do
    Ash.update!(
      event,
      %{
        failed_at: DateTime.utc_now(),
        error_message: bounded_error_message(reason)
      },
      action: :mark_failed,
      domain: Ingestion
    )

    :ok
  end

  defp mark_ignored(%WebhookEvent{} = event, reason) do
    Ash.update!(
      event,
      %{
        ignore_reason: reason,
        processed_at: DateTime.utc_now()
      },
      action: :mark_ignored,
      domain: Ingestion
    )

    :ok
  end

  defp bounded_error_message(reason) do
    reason
    |> inspect()
    |> String.slice(0, @max_error_message_length)
  end
end
