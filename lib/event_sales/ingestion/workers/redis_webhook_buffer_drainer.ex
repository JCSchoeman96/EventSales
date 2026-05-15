defmodule EventSales.Ingestion.Workers.RedisWebhookBufferDrainer do
  @moduledoc """
  Drains Redis/memory webhook buffer entries into Postgres and enqueues processing.

  Invoked manually, by scheduler, or directly in tests — not from the saturated intake path.
  """

  use Oban.Worker, queue: :default, max_attempts: 5

  require Logger

  alias EventSales.Ingestion.IntakeBackpressure
  alias EventSales.Ingestion.RedisWebhookBuffer
  alias EventSales.Ingestion.Security.WebhookReplayGuard
  alias EventSales.Ingestion.WebhookEnqueue
  alias EventSales.Ingestion.WebhookEventStore
  alias EventSales.Telemetry

  @batch_size 50

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    drain_batch(@batch_size)
  end

  @spec drain_batch(non_neg_integer()) :: :ok | {:error, :retry}
  def drain_batch(limit) when is_integer(limit) and limit > 0 do
    do_drain_batch(limit, 0)
  end

  defp do_drain_batch(0, _drained), do: :ok

  defp do_drain_batch(remaining, drained) do
    case RedisWebhookBuffer.claim() do
      :empty ->
        emit_drained(drained)
        :ok

      {:ok, entry} ->
        case drain_one(entry) do
          :acked ->
            do_drain_batch(remaining - 1, drained + 1)

          {:retryable, _} ->
            emit_drained(drained)
            {:error, :retry}
        end
    end
  end

  defp drain_one(entry) do
    case RedisWebhookBuffer.decode_entry(entry) do
      {:ok, decoded} ->
        drain_decoded(entry, decoded)

      {:error, :poison} ->
        log_poison(entry)
        emit_backpressure(:poison_buffer_entry)
        ack_or_retry(entry)
    end
  end

  defp drain_decoded(entry, %{"delivery_id" => delivery_id, "intake" => intake}) do
    payload_hash = Map.fetch!(intake, "payload_hash")

    case WebhookReplayGuard.classify_duplicate(delivery_id, payload_hash) do
      {:duplicate, event} ->
        finalize_duplicate(entry, event)

      {:duplicate_payload_mismatch, _existing} ->
        log_poison(entry)
        emit_backpressure(:poison_buffer_entry)
        ack_or_retry(entry)

      :new ->
        persist_and_enqueue(entry, intake)
    end
  end

  defp finalize_duplicate(entry, event) do
    case WebhookEnqueue.enqueue_processing_once(event) do
      :ok ->
        ack_or_retry(entry)

      {:error, :enqueue_failed} ->
        handle_transient_failure(entry)
    end
  end

  defp persist_and_enqueue(entry, intake) do
    attrs = receive_attrs_from_intake(intake)

    case WebhookEventStore.create_receive(attrs) do
      {:ok, event} ->
        case WebhookEnqueue.enqueue_processing_once(event) do
          :ok ->
            ack_or_retry(entry)

          {:error, :enqueue_failed} ->
            handle_transient_failure(entry)
        end

      {:error, error} ->
        case IntakeBackpressure.classify_persist_error(error) do
          {:pool_saturated, _} ->
            handle_transient_failure(entry)

          {:other, _} ->
            log_poison(entry)
            emit_backpressure(:poison_buffer_entry)
            ack_or_retry(entry)
        end
    end
  end

  defp ack_or_retry(entry) do
    case RedisWebhookBuffer.ack(entry) do
      :ok ->
        :acked

      {:error, :unavailable} ->
        emit_backpressure(:ack_failed)
        {:retryable, :ack_failed}
    end
  end

  defp handle_transient_failure(entry) do
    case RedisWebhookBuffer.requeue(entry) do
      :ok ->
        {:retryable, :transient}

      {:error, :full} ->
        emit_backpressure(:requeue_failed)
        {:retryable, :requeue_failed}

      {:error, :unavailable} ->
        emit_backpressure(:requeue_failed)
        {:retryable, :unavailable}
    end
  end

  defp receive_attrs_from_intake(intake) do
    %{
      source_system_id: Map.fetch!(intake, "source_system_id"),
      topic: Map.fetch!(intake, "topic"),
      resource_type: Map.fetch!(intake, "resource_type"),
      resource_id: Map.fetch!(intake, "resource_id"),
      delivery_id: Map.fetch!(intake, "delivery_id"),
      payload: Map.fetch!(intake, "payload"),
      payload_hash: Map.fetch!(intake, "payload_hash"),
      raw_body_size: Map.fetch!(intake, "raw_body_size"),
      signature_validated_at: parse_datetime!(Map.fetch!(intake, "signature_validated_at")),
      received_at: parse_datetime!(Map.fetch!(intake, "received_at")),
      source_updated_at: optional_datetime(Map.get(intake, "source_updated_at")),
      sanitized_headers_snapshot: Map.fetch!(intake, "sanitized_headers_snapshot"),
      accepted_via: :redis_buffer
    }
  end

  defp parse_datetime!(iso8601) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _} -> dt
      _ -> raise ArgumentError, "invalid datetime in buffer entry"
    end
  end

  defp optional_datetime(nil), do: nil

  defp optional_datetime(iso8601) when is_binary(iso8601) do
    case DateTime.from_iso8601(iso8601) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp log_poison(entry) do
    Logger.warning(
      "redis_webhook_buffer_poison_entry adapter=#{RedisWebhookBuffer.adapter_name()} byte_size=#{byte_size(entry)}"
    )
  end

  defp emit_backpressure(reason) do
    Telemetry.emit(
      Telemetry.webhook_backpressure(),
      %{count: 1},
      %{reason: reason, adapter: RedisWebhookBuffer.adapter_name()}
    )
  end

  defp emit_drained(count) when count > 0 do
    Telemetry.emit(
      Telemetry.webhook_drained(),
      %{count: count},
      %{adapter: RedisWebhookBuffer.adapter_name(), accepted_via: :redis_buffer}
    )
  end

  defp emit_drained(_), do: :ok
end
