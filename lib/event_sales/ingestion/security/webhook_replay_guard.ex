defmodule EventSales.Ingestion.Security.WebhookReplayGuard do
  @moduledoc """
  Intake-time replay guard: duplicate delivery classification and stale resource detection.

  Does not mutate sales state; processing-time idempotency lives in Slice 6.0.
  """

  require Ash.Query

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookEvent

  @sensitive_header_names ~w(authorization cookie set-cookie x-api-key)

  @spec payload_hash(binary()) :: String.t()
  def payload_hash(raw_body) when is_binary(raw_body) do
    :crypto.hash(:sha256, raw_body)
    |> Base.encode16(case: :lower)
  end

  @spec classify_duplicate(String.t(), String.t()) ::
          :new
          | {:duplicate, WebhookEvent.t()}
          | {:duplicate_payload_mismatch, WebhookEvent.t()}
  def classify_duplicate(delivery_id, incoming_payload_hash)
      when is_binary(delivery_id) and is_binary(incoming_payload_hash) do
    case fetch_by_delivery_id(delivery_id) do
      nil ->
        :new

      %WebhookEvent{payload_hash: ^incoming_payload_hash} = event ->
        {:duplicate, event}

      %WebhookEvent{} = event ->
        {:duplicate_payload_mismatch, event}
    end
  end

  @spec check_stale(Ecto.UUID.t(), String.t(), String.t(), DateTime.t() | nil) ::
          :ok | {:stale_replay, map()}
  def check_stale(_source_system_id, _resource_type, _resource_id, nil), do: :ok

  def check_stale(source_system_id, resource_type, resource_id, %DateTime{} = incoming) do
    case latest_source_updated_at(source_system_id, resource_type, resource_id) do
      nil ->
        :ok

      {latest_at, latest_event_id} ->
        if DateTime.compare(incoming, latest_at) == :lt do
          {:stale_replay,
           %{
             "incoming_source_updated_at" => DateTime.to_iso8601(incoming),
             "latest_source_updated_at" => DateTime.to_iso8601(latest_at),
             "latest_webhook_event_id" => latest_event_id
           }}
        else
          :ok
        end
    end
  end

  @spec source_updated_at_from_payload(map()) :: DateTime.t() | nil
  def source_updated_at_from_payload(payload) when is_map(payload) do
    payload
    |> Map.get("date_modified_gmt")
    |> case do
      nil -> Map.get(payload, "date_modified")
      value -> value
    end
    |> parse_woo_datetime()
  end

  def source_updated_at_from_payload(_), do: nil

  @spec sanitize_headers([{String.t(), String.t()}]) :: map()
  def sanitize_headers(headers) when is_list(headers) do
    headers
    |> Enum.map(&sanitize_header_pair/1)
    |> Map.new()
  end

  defp sanitize_header_pair({name, value}) when is_binary(name) and is_binary(value) do
    downcased = String.downcase(name)

    cond do
      downcased == "x-wc-webhook-signature" ->
        {downcased, "[redacted]"}

      downcased in @sensitive_header_names ->
        {downcased, "[redacted]"}

      true ->
        {downcased, value}
    end
  end

  defp sanitize_header_pair({name, value}), do: {to_string(name), to_string(value)}

  defp fetch_by_delivery_id(delivery_id) do
    WebhookEvent
    |> Ash.Query.filter(delivery_id == ^delivery_id)
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Ingestion)
    |> case do
      {:ok, event} -> event
      _ -> nil
    end
  end

  defp latest_source_updated_at(source_system_id, resource_type, resource_id) do
    WebhookEvent
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and
        resource_type == ^resource_type and
        resource_id == ^resource_id and
        not is_nil(source_updated_at)
    )
    |> Ash.Query.sort(source_updated_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Ingestion)
    |> case do
      {:ok, %WebhookEvent{id: id, source_updated_at: %DateTime{} = at}} -> {at, id}
      _ -> nil
    end
  end

  defp parse_woo_datetime(value) when is_binary(value) do
    value = String.trim(value)

    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        datetime

      {:error, _} ->
        parse_woo_datetime_as_utc(value)
    end
  end

  defp parse_woo_datetime(_), do: nil

  defp parse_woo_datetime_as_utc(value) do
    case NaiveDateTime.from_iso8601(value) do
      {:ok, naive} ->
        DateTime.from_naive!(naive, "Etc/UTC")

      {:error, _} ->
        nil
    end
  rescue
    ArgumentError -> nil
  end
end
