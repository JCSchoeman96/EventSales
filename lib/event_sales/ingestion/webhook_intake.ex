defmodule EventSales.Ingestion.WebhookIntake do
  @moduledoc """
  Web-agnostic WooCommerce webhook intake: verify, persist, enqueue.

  HTTP mapping lives in `EventSalesWeb.WebhookController`.
  """

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{WebhookDeliveryFailure, WebhookEvent}
  alias EventSales.Ingestion.Security.WebhookSignature
  alias EventSales.Ingestion.Workers.ProcessWebhookWorker
  alias EventSales.Telemetry

  @type accept_input :: %{
          required(:path_token) => String.t(),
          required(:raw_body) => String.t(),
          required(:headers) => [{String.t(), String.t()}],
          optional(:remote_ip) => term(),
          optional(:user_agent) => String.t() | nil
        }

  @spec accept(accept_input()) ::
          {:ok, WebhookEvent.t()}
          | {:error,
             :wrong_path_token
             | :invalid_signature
             | :invalid_json
             | :no_source_system
             | :enqueue_failed}
  def accept(%{path_token: path_token, raw_body: raw_body, headers: headers} = input) do
    config = Application.get_env(:event_sales, :webhook_intake, [])
    remote_ip = Map.get(input, :remote_ip)
    user_agent = Map.get(input, :user_agent)

    with :ok <- verify_path_token(path_token, config),
         :ok <- verify_signature(raw_body, config, headers),
         {:ok, source_system} <- fetch_active_woocommerce_source_system(),
         {:ok, payload} <- decode_json(raw_body),
         {:ok, event} <-
           persist_webhook_event(source_system, raw_body, headers, payload),
         :ok <- enqueue_processing(event) do
      emit_accepted(event)
      {:ok, event}
    else
      {:error, :wrong_path_token} = error ->
        log_failure(:wrong_path_token, headers, remote_ip, user_agent, %{})
        emit_rejected(:wrong_path_token)
        error

      {:error, :invalid_signature} = error ->
        log_failure(:invalid_signature, headers, remote_ip, user_agent, %{})
        emit_rejected(:invalid_signature)
        error

      {:error, :no_source_system} = error ->
        log_failure(:no_source_system, headers, remote_ip, user_agent, %{})
        emit_rejected(:no_source_system)
        error

      {:error, :invalid_json} = error ->
        log_failure(:invalid_json, headers, remote_ip, user_agent, %{
          "byte_size" => byte_size(raw_body)
        })

        emit_rejected(:invalid_json)
        error

      {:error, :enqueue_failed} = error ->
        emit_rejected(:enqueue_failed)
        error
    end
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

  defp persist_webhook_event(source_system, raw_body, headers, payload) do
    now = DateTime.utc_now()

    attrs = %{
      source_system_id: source_system.id,
      topic: header_value(headers, "x-wc-webhook-topic") || "unknown",
      resource_type: header_value(headers, "x-wc-webhook-resource") || "unknown",
      resource_id: resource_id_from_payload(payload),
      delivery_id: header_value(headers, "x-wc-webhook-delivery-id") || "unknown",
      payload: payload,
      payload_hash: payload_hash(raw_body),
      raw_body_size: byte_size(raw_body),
      signature_validated_at: now,
      received_at: now
    }

    WebhookEvent
    |> Ash.Changeset.for_create(:receive, attrs)
    |> Ash.create(domain: Ingestion)
  end

  defp enqueue_processing(%WebhookEvent{id: id}) do
    case %{webhook_event_id: id}
         |> ProcessWebhookWorker.new()
         |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, _} -> {:error, :enqueue_failed}
    end
  end

  defp log_failure(reason, headers, remote_ip, user_agent, metadata) do
    now = DateTime.utc_now()

    attrs = %{
      reason: reason,
      topic: header_value(headers, "x-wc-webhook-topic"),
      remote_ip_hash: hash_term(remote_ip),
      user_agent_hash: hash_string(user_agent),
      metadata: metadata,
      received_at: now
    }

    WebhookDeliveryFailure
    |> Ash.Changeset.for_create(:log_failure, attrs)
    |> Ash.create(domain: Ingestion)
  end

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

  defp payload_hash(raw_body) do
    :crypto.hash(:sha256, raw_body)
    |> Base.encode16(case: :lower)
  end

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
