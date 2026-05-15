defmodule EventSales.Ingestion.WebhookIntake do
  @moduledoc """
  Web-agnostic WooCommerce webhook intake: verify, persist, enqueue.

  HTTP mapping lives in `EventSalesWeb.WebhookController`.
  """

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Ingestion
  alias EventSales.Ingestion.IntakeBackpressure
  alias EventSales.Ingestion.RedisWebhookBuffer
  alias EventSales.Ingestion.Resources.{WebhookDeliveryFailure, WebhookEvent}
  alias EventSales.Ingestion.Security.{WebhookReplayGuard, WebhookSignature}
  alias EventSales.Ingestion.WebhookEnqueue
  alias EventSales.Ingestion.WebhookEventStore
  alias EventSales.Telemetry

  @unique_delivery_id_constraint "ingestion_webhook_events_unique_delivery_id_index"

  @type accept_input :: %{
          required(:path_token) => String.t(),
          required(:raw_body) => String.t(),
          required(:headers) => [{String.t(), String.t()}],
          optional(:remote_ip) => term(),
          optional(:user_agent) => String.t() | nil
        }

  @type accept_result ::
          {:ok, WebhookEvent.t()}
          | {:ignored, :duplicate, WebhookEvent.t()}
          | {:ignored, :stale_replay}
          | {:ignored, :duplicate_payload_mismatch}
          | {:buffered, %{buffer_depth: non_neg_integer()}}
          | {:error,
             :wrong_path_token
             | :invalid_signature
             | :invalid_json
             | :no_source_system
             | :enqueue_failed
             | :persist_failed
             | :buffer_full
             | :buffer_too_large
             | :intake_unavailable}

  @spec accept(accept_input()) :: accept_result()
  def accept(%{path_token: path_token, raw_body: raw_body, headers: headers} = input) do
    config = Application.get_env(:event_sales, :webhook_intake, [])
    remote_ip = Map.get(input, :remote_ip)
    user_agent = Map.get(input, :user_agent)

    with :ok <- verify_path_token(path_token, config),
         :ok <- verify_signature(raw_body, config, headers),
         {:ok, source_system} <- fetch_active_woocommerce_source_system() do
      case decode_json(raw_body) do
        {:ok, payload} ->
          process_after_decode(%{
            source_system: source_system,
            raw_body: raw_body,
            headers: headers,
            payload: payload,
            remote_ip: remote_ip,
            user_agent: user_agent
          })

        {:error, :invalid_json} = error ->
          log_failure(:invalid_json, source_system.id, headers, remote_ip, user_agent, %{
            "byte_size" => byte_size(raw_body)
          })

          emit_rejected(:invalid_json)
          error
      end
    else
      {:error, :wrong_path_token} = error ->
        log_failure(:wrong_path_token, nil, headers, remote_ip, user_agent, %{})
        emit_rejected(:wrong_path_token)
        error

      {:error, :invalid_signature} = error ->
        log_failure(:invalid_signature, nil, headers, remote_ip, user_agent, %{})
        emit_rejected(:invalid_signature)
        error

      {:error, :no_source_system} = error ->
        log_failure(:no_source_system, nil, headers, remote_ip, user_agent, %{})
        emit_rejected(:no_source_system)
        error
    end
  end

  defp process_after_decode(ctx) do
    %{
      source_system: source_system,
      raw_body: raw_body,
      headers: headers,
      payload: payload,
      remote_ip: remote_ip,
      user_agent: user_agent
    } = ctx

    incoming_hash = WebhookReplayGuard.payload_hash(raw_body)
    delivery_id = header_value(headers, "x-wc-webhook-delivery-id") || "unknown"
    resource_type = header_value(headers, "x-wc-webhook-resource") || "unknown"
    resource_id = resource_id_from_payload(payload)

    case WebhookReplayGuard.classify_duplicate(delivery_id, incoming_hash) do
      {:duplicate, event} ->
        emit_accepted(event)
        {:ignored, :duplicate, event}

      {:duplicate_payload_mismatch, existing} ->
        log_duplicate_payload_mismatch(%{
          source_system_id: source_system.id,
          headers: headers,
          remote_ip: remote_ip,
          user_agent: user_agent,
          delivery_id: delivery_id,
          existing: existing,
          incoming_hash: incoming_hash,
          resource_type: resource_type,
          resource_id: resource_id
        })

        {:ignored, :duplicate_payload_mismatch}

      :new ->
        source_updated_at = WebhookReplayGuard.source_updated_at_from_payload(payload)

        case WebhookReplayGuard.check_stale(
               source_system.id,
               resource_type,
               resource_id,
               source_updated_at
             ) do
          {:stale_replay, metadata} ->
            log_failure(
              :stale_replay,
              source_system.id,
              headers,
              remote_ip,
              user_agent,
              Map.merge(metadata, %{
                "delivery_id" => delivery_id,
                "resource_type" => resource_type,
                "resource_id" => resource_id
              })
            )

            emit_rejected(:stale_replay)
            {:ignored, :stale_replay}

          :ok ->
            create_event_and_enqueue(%{
              source_system: source_system,
              raw_body: raw_body,
              headers: headers,
              payload: payload,
              incoming_hash: incoming_hash,
              delivery_id: delivery_id,
              resource_type: resource_type,
              resource_id: resource_id,
              source_updated_at: source_updated_at,
              remote_ip: remote_ip,
              user_agent: user_agent
            })
        end
    end
  end

  defp create_event_and_enqueue(ctx) do
    %{
      source_system: source_system,
      headers: headers,
      remote_ip: remote_ip,
      user_agent: user_agent
    } = ctx

    case persist_webhook_event(ctx) do
      {:ok, event} ->
        case enqueue_processing(event) do
          :ok ->
            emit_accepted(event)
            {:ok, event}

          {:error, :enqueue_failed} = error ->
            log_failure(:enqueue_failed, source_system.id, headers, remote_ip, user_agent, %{
              "webhook_event_id" => event.id
            })

            emit_rejected(:enqueue_failed)
            error
        end

      {:error, error} ->
        cond do
          unique_delivery_id_error?(error) ->
            resolve_duplicate_after_race(ctx)

          match?({:pool_saturated, _}, IntakeBackpressure.classify_persist_error(error)) ->
            try_buffer_fallback(ctx)

          true ->
            emit_rejected(:persist_failed)
            {:error, :persist_failed}
        end
    end
  end

  defp try_buffer_fallback(ctx) do
    entry = RedisWebhookBuffer.entry_from_intake_context(ctx)

    case RedisWebhookBuffer.push(entry) do
      :ok ->
        depth = RedisWebhookBuffer.depth()

        Telemetry.emit(
          Telemetry.webhook_buffered(),
          %{count: 1, buffer_depth: depth},
          %{adapter: RedisWebhookBuffer.adapter_name(), accepted_via: :redis_buffer}
        )

        {:buffered, %{buffer_depth: depth}}

      {:error, :full} ->
        emit_backpressure(:buffer_full)
        {:error, :buffer_full}

      {:error, :too_large} ->
        emit_backpressure(:buffer_too_large)
        {:error, :buffer_too_large}

      {:error, _} ->
        emit_backpressure(:intake_unavailable)
        {:error, :intake_unavailable}
    end
  end

  defp emit_backpressure(reason) do
    Telemetry.emit(
      Telemetry.webhook_backpressure(),
      %{count: 1},
      %{reason: reason, adapter: RedisWebhookBuffer.adapter_name()}
    )
  end

  defp resolve_duplicate_after_race(ctx) do
    %{
      source_system: source_system,
      headers: headers,
      remote_ip: remote_ip,
      user_agent: user_agent,
      delivery_id: delivery_id,
      incoming_hash: incoming_hash,
      resource_type: resource_type,
      resource_id: resource_id
    } = ctx

    case WebhookReplayGuard.classify_duplicate(delivery_id, incoming_hash) do
      {:duplicate, event} ->
        emit_accepted(event)
        {:ignored, :duplicate, event}

      {:duplicate_payload_mismatch, existing} ->
        log_duplicate_payload_mismatch(%{
          source_system_id: source_system.id,
          headers: headers,
          remote_ip: remote_ip,
          user_agent: user_agent,
          delivery_id: delivery_id,
          existing: existing,
          incoming_hash: incoming_hash,
          resource_type: resource_type,
          resource_id: resource_id
        })

        {:ignored, :duplicate_payload_mismatch}

      :new ->
        emit_rejected(:persist_failed)
        {:error, :persist_failed}
    end
  end

  defp unique_delivery_id_error?(%Ash.Error.Invalid{errors: errors}) do
    Enum.any?(errors, &unique_delivery_id_constraint_error?/1)
  end

  defp unique_delivery_id_error?(error) do
    error
    |> Ash.Error.to_error_class()
    |> case do
      %Ash.Error.Invalid{errors: errors} ->
        Enum.any?(errors, &unique_delivery_id_constraint_error?/1)

      _ ->
        false
    end
  end

  defp unique_delivery_id_constraint_error?(%Ash.Error.Changes.InvalidAttribute{
         field: :delivery_id,
         private_vars: private_vars
       }) do
    private_vars[:constraint] == @unique_delivery_id_constraint
  end

  defp unique_delivery_id_constraint_error?(_), do: false

  defp log_duplicate_payload_mismatch(ctx) do
    %{
      source_system_id: source_system_id,
      headers: headers,
      remote_ip: remote_ip,
      user_agent: user_agent,
      delivery_id: delivery_id,
      existing: existing,
      incoming_hash: incoming_hash,
      resource_type: resource_type,
      resource_id: resource_id
    } = ctx

    log_failure(
      :duplicate_payload_mismatch,
      source_system_id,
      headers,
      remote_ip,
      user_agent,
      %{
        "delivery_id" => delivery_id,
        "existing_webhook_event_id" => existing.id,
        "existing_payload_hash" => existing.payload_hash,
        "incoming_payload_hash" => incoming_hash,
        "resource_type" => resource_type,
        "resource_id" => resource_id
      }
    )
  end

  defp verify_path_token(path_token, config) do
    if path_token == Keyword.get(config, :path_token) do
      :ok
    else
      {:error, :wrong_path_token}
    end
  end

  defp verify_signature(raw_body, config, headers) do
    secret = Keyword.fetch!(config, :secret)
    signature = header_value(headers, "x-wc-webhook-signature")

    case WebhookSignature.verify(raw_body, secret, signature) do
      :ok -> :ok
      {:error, _} -> {:error, :invalid_signature}
    end
  end

  defp fetch_active_woocommerce_source_system do
    case SourceSystem
         |> Ash.Query.filter(kind == :woocommerce and active == true)
         |> Ash.Query.limit(1)
         |> Ash.read_one(domain: Catalog) do
      {:ok, %SourceSystem{} = source} -> {:ok, source}
      {:ok, nil} -> {:error, :no_source_system}
      {:error, _} -> {:error, :no_source_system}
    end
  end

  defp decode_json(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, payload} when is_map(payload) -> {:ok, payload}
      _ -> {:error, :invalid_json}
    end
  end

  defp persist_webhook_event(ctx) do
    %{
      source_system: source_system,
      raw_body: raw_body,
      headers: headers,
      payload: payload,
      resource_id: resource_id,
      delivery_id: delivery_id,
      incoming_hash: incoming_hash,
      source_updated_at: source_updated_at
    } = ctx

    now = DateTime.utc_now()

    attrs = %{
      source_system_id: source_system.id,
      topic: header_value(headers, "x-wc-webhook-topic") || "unknown",
      resource_type: header_value(headers, "x-wc-webhook-resource") || "unknown",
      resource_id: resource_id,
      delivery_id: delivery_id,
      payload: payload,
      payload_hash: incoming_hash,
      raw_body_size: byte_size(raw_body),
      signature_validated_at: now,
      received_at: now,
      source_updated_at: source_updated_at,
      sanitized_headers_snapshot: WebhookReplayGuard.sanitize_headers(headers)
    }

    WebhookEventStore.create_receive(attrs)
  end

  defp enqueue_processing(%WebhookEvent{} = event),
    do: WebhookEnqueue.enqueue_processing_once(event)

  defp log_failure(reason, source_system_id, headers, remote_ip, user_agent, metadata) do
    now = DateTime.utc_now()

    attrs =
      %{
        reason: reason,
        topic: header_value(headers, "x-wc-webhook-topic"),
        remote_ip_hash: hash_term(remote_ip),
        user_agent_hash: hash_string(user_agent),
        metadata: metadata,
        received_at: now
      }
      |> maybe_put_source_system_id(source_system_id)

    WebhookDeliveryFailure
    |> Ash.Changeset.for_create(:log_failure, attrs)
    |> Ash.create(domain: Ingestion)
  end

  defp maybe_put_source_system_id(attrs, nil), do: attrs

  defp maybe_put_source_system_id(attrs, source_system_id),
    do: Map.put(attrs, :source_system_id, source_system_id)

  defp header_value(headers, name) do
    downcased = String.downcase(name)

    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == downcased, do: value

      _ ->
        nil
    end)
  end

  defp resource_id_from_payload(%{"id" => id}) when not is_nil(id), do: to_string(id)
  defp resource_id_from_payload(_), do: "unknown"

  defp hash_term(nil), do: nil

  defp hash_term(term) do
    term
    |> :erlang.term_to_binary()
    |> hash_binary()
  end

  defp hash_string(nil), do: nil
  defp hash_string(value), do: hash_binary(value)

  defp hash_binary(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp emit_accepted(%WebhookEvent{id: id, delivery_id: delivery_id}) do
    Telemetry.emit(Telemetry.webhook_accepted(), %{count: 1}, %{
      webhook_event_id: id,
      delivery_id: delivery_id
    })
  end

  defp emit_rejected(reason) do
    Telemetry.emit(Telemetry.webhook_rejected(), %{count: 1}, %{reason: reason})
  end
end
