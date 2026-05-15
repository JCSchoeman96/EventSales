defmodule EventSales.Ingestion.RedisWebhookBuffer do
  @moduledoc """
  Optional degraded-mode webhook buffer when Postgres intake is pool-saturated.

  Not durable truth. Explicitly enabled via application config only.
  """

  @entry_version 1

  @type buffer_entry :: map()
  @type push_error :: :disabled | :too_large | :full | :unavailable

  @doc false
  @spec redix_name() :: atom()
  def redix_name, do: :event_sales_redis

  @doc false
  @spec max_entries() :: non_neg_integer()
  def max_entries do
    config() |> Keyword.get(:max_entries, 5_000)
  end

  @doc false
  @spec max_entry_bytes() :: non_neg_integer()
  def max_entry_bytes do
    config() |> Keyword.get(:max_entry_bytes, 256_000)
  end

  @doc false
  @spec key(String.t()) :: String.t()
  def key(suffix) when is_binary(suffix) do
    prefix = config() |> Keyword.get(:key_prefix, "eventsales:webhook_buffer:v1")
    "#{prefix}:#{suffix}"
  end

  @doc false
  @spec adapter_name() :: String.t()
  def adapter_name do
    adapter_module() |> Module.split() |> List.last()
  end

  @doc """
  Pushes a structured buffer entry after gates and size checks.
  """
  @spec push(buffer_entry()) :: :ok | {:error, push_error()}
  def push(entry) when is_map(entry) do
    with :ok <- gate_enabled(),
         {:ok, encoded} <- encode_entry(entry),
         :ok <- size_check(encoded) do
      adapter_module().push(encoded)
    end
  end

  @doc "Claims the next pending entry into the processing list."
  @spec claim() :: {:ok, binary()} | :empty
  def claim, do: adapter_module().claim()

  @doc "Acknowledges successful drain of a processing entry."
  @spec ack(binary()) :: :ok
  def ack(entry) when is_binary(entry), do: adapter_module().ack(entry)

  @doc "Returns a processing entry to pending when retryable."
  @spec requeue(binary()) :: :ok | {:error, :full | :unavailable}
  def requeue(entry) when is_binary(entry), do: adapter_module().requeue(entry)

  @doc "Pending queue depth."
  @spec depth() :: non_neg_integer()
  def depth, do: adapter_module().depth()

  @doc "Processing (in-flight) depth."
  @spec processing_depth() :: non_neg_integer()
  def processing_depth, do: adapter_module().processing_depth()

  @doc """
  Builds a versioned JSON buffer entry from intake context.
  """
  @spec entry_from_intake_context(map()) :: buffer_entry()
  def entry_from_intake_context(ctx) when is_map(ctx) do
    now = DateTime.utc_now()

    %{
      "v" => @entry_version,
      "delivery_id" => Map.fetch!(ctx, :delivery_id),
      "buffered_at" => DateTime.to_iso8601(now),
      "intake" => intake_payload(ctx, now)
    }
  end

  @doc """
  Decodes and validates a buffer entry. Returns poison errors for invalid payloads.
  """
  @spec decode_entry(binary()) :: {:ok, map()} | {:error, :poison}
  def decode_entry(encoded) when is_binary(encoded) do
    with {:ok, map} <- Jason.decode(encoded),
         :ok <- validate_entry(map) do
      {:ok, map}
    else
      _ -> {:error, :poison}
    end
  end

  defp intake_payload(ctx, now) do
    %{
      source_system: source_system,
      raw_body: raw_body,
      headers: headers,
      payload: payload,
      incoming_hash: incoming_hash,
      delivery_id: delivery_id,
      resource_type: resource_type,
      resource_id: resource_id,
      source_updated_at: source_updated_at
    } = ctx

    %{
      "source_system_id" => source_system.id,
      "topic" => header_value(headers, "x-wc-webhook-topic") || "unknown",
      "resource_type" => resource_type,
      "resource_id" => resource_id,
      "delivery_id" => delivery_id,
      "payload" => payload,
      "payload_hash" => incoming_hash,
      "raw_body_size" => byte_size(raw_body),
      "signature_validated_at" => DateTime.to_iso8601(now),
      "received_at" => DateTime.to_iso8601(now),
      "source_updated_at" => optional_iso8601(source_updated_at),
      "sanitized_headers_snapshot" =>
        EventSales.Ingestion.Security.WebhookReplayGuard.sanitize_headers(headers)
    }
  end

  defp validate_entry(%{"v" => @entry_version, "delivery_id" => delivery_id, "intake" => intake})
       when is_binary(delivery_id) and is_map(intake) do
    required = ~w(
      source_system_id topic resource_type resource_id delivery_id payload payload_hash
      raw_body_size signature_validated_at received_at sanitized_headers_snapshot
    )

    if Enum.all?(required, &Map.has_key?(intake, &1)) do
      :ok
    else
      {:error, :invalid}
    end
  end

  defp validate_entry(_), do: {:error, :invalid}

  defp encode_entry(entry) do
    case Jason.encode(entry) do
      {:ok, encoded} -> {:ok, encoded}
      {:error, _} -> {:error, :too_large}
    end
  end

  defp size_check(encoded) do
    if byte_size(encoded) > max_entry_bytes(), do: {:error, :too_large}, else: :ok
  end

  defp gate_enabled do
    cfg = config()

    cond do
      not Keyword.get(cfg, :enabled, false) -> {:error, :disabled}
      not Keyword.get(cfg, :durability_accepted, false) -> {:error, :disabled}
      true -> :ok
    end
  end

  defp adapter_module do
    config() |> Keyword.get(:adapter, EventSales.Ingestion.RedisWebhookBuffer.RedixAdapter)
  end

  defp config, do: Application.get_env(:event_sales, :redis_webhook_buffer, [])

  defp header_value(headers, name) do
    downcased = String.downcase(name)

    Enum.find_value(headers, fn
      {key, value} when is_binary(key) ->
        if String.downcase(key) == downcased, do: value

      _ ->
        nil
    end)
  end

  defp optional_iso8601(nil), do: nil
  defp optional_iso8601(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
