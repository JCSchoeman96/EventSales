defmodule EventSales.Ingestion.CatalogChangeContract do
  @moduledoc "Strict PII-free contract for WordPress catalogue change signals."

  @version "2026-07-20.v1"
  @keys ~w(version signal_id source target_type target_id source_updated_at reason)
  @targets %{"event" => :event, "product" => :product, "variation" => :variation}
  @reasons %{
    "saved" => :saved,
    "metadata_changed" => :metadata_changed,
    "status_changed" => :status_changed,
    "trashed" => :trashed,
    "restored" => :restored,
    "deleted" => :deleted
  }
  @uuid ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[47][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/
  @rfc3339 ~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/

  @spec parse(map()) :: {:ok, map()} | {:error, :invalid_signal}
  def parse(payload) when is_map(payload) do
    with true <- Enum.sort(Map.keys(payload)) == Enum.sort(@keys),
         @version <- payload["version"],
         "wordpress_tickera" <- payload["source"],
         signal_id when is_binary(signal_id) <- payload["signal_id"],
         true <- Regex.match?(@uuid, signal_id),
         {:ok, target_type} <- Map.fetch(@targets, payload["target_type"]),
         target_id when is_integer(target_id) and target_id > 0 <- payload["target_id"],
         true <- target_id <= 9_223_372_036_854_775_807,
         {:ok, reason} <- Map.fetch(@reasons, payload["reason"]),
         source_updated_at when is_binary(source_updated_at) <- payload["source_updated_at"],
         true <- Regex.match?(@rfc3339, source_updated_at),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(source_updated_at) do
      {:ok,
       %{
         version: @version,
         signal_id: signal_id,
         source: :wordpress_tickera,
         target_type: target_type,
         target_id: target_id,
         source_updated_at: datetime,
         reason: reason
       }}
    else
      _ -> {:error, :invalid_signal}
    end
  end

  def parse(_payload), do: {:error, :invalid_signal}
end
