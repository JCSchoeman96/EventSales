defmodule EventSales.Maintenance.RawPayloadPurger do
  @moduledoc """
  Redacts old raw webhook payloads while preserving durable webhook metadata.
  """

  require Ash.Query
  import Ash.Expr

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Telemetry

  @default_retention_days 90
  @default_batch_size 500

  @type result :: %{
          cutoff_at: DateTime.t(),
          retention_days: pos_integer(),
          affected_count: non_neg_integer(),
          batch_size: pos_integer()
        }

  @spec purge(keyword()) :: {:ok, result()} | {:error, term()}
  def purge(opts \\ []) do
    started_at = System.monotonic_time()

    with {:ok, retention_days} <-
           positive_integer(
             opts,
             :retention_days,
             config(:raw_payload_retention_days, @default_retention_days)
           ),
         {:ok, batch_size} <-
           positive_integer(
             opts,
             :batch_size,
             config(:raw_payload_purge_batch_size, @default_batch_size)
           ),
         now <- Keyword.get(opts, :now, DateTime.utc_now()),
         cutoff_at <- DateTime.add(now, -retention_days, :day) do
      metadata = %{
        worker: :raw_payload_purger,
        cutoff_at: cutoff_at,
        retention_days: retention_days,
        batch_size: batch_size
      }

      Telemetry.emit(Telemetry.maintenance_raw_payload_purge_start(), %{count: 1}, metadata)

      case purge_batch(cutoff_at, batch_size, now) do
        {:ok, affected_count} ->
          result = %{
            cutoff_at: cutoff_at,
            retention_days: retention_days,
            affected_count: affected_count,
            batch_size: batch_size
          }

          Telemetry.emit(
            Telemetry.maintenance_raw_payload_purge_stop(),
            %{count: affected_count, duration: System.monotonic_time() - started_at},
            Map.put(metadata, :affected_count, affected_count)
          )

          {:ok, result}

        {:error, reason} ->
          emit_exception(reason, metadata)
          {:error, reason}
      end
    else
      {:error, reason} ->
        emit_exception(reason, %{worker: :raw_payload_purger})
        {:error, reason}
    end
  rescue
    error ->
      emit_exception(error, %{worker: :raw_payload_purger})
      {:error, error}
  end

  defp purge_batch(cutoff_at, batch_size, now) do
    marker = redaction_marker(now)

    WebhookEvent
    |> Ash.Query.filter(
      expr(
        received_at < ^cutoff_at and
          fragment("(?->>'redacted') IS DISTINCT FROM 'true'", payload)
      )
    )
    |> Ash.Query.sort(received_at: :asc, id: :asc)
    |> Ash.Query.limit(batch_size)
    |> Ash.Query.select([:id])
    |> Ash.read(domain: Ingestion)
    |> case do
      {:ok, events} -> redact_events(events, marker)
      {:error, reason} -> {:error, reason}
    end
  end

  defp redact_events(events, marker) do
    Enum.reduce_while(events, {:ok, 0}, fn event, {:ok, count} ->
      case Ash.update(event, %{payload: marker}, action: :redact_payload, domain: Ingestion) do
        {:ok, _event} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp redaction_marker(now) do
    %{
      "redacted" => true,
      "redacted_reason" => "raw_payload_retention",
      "redacted_at" => DateTime.to_iso8601(now)
    }
  end

  defp positive_integer(opts, key, default) do
    value = Keyword.get(opts, key, default)

    if is_integer(value) and value > 0 do
      {:ok, value}
    else
      {:error, {:invalid_config, key}}
    end
  end

  defp config(key, default) do
    :event_sales
    |> Application.get_env(:maintenance, [])
    |> Keyword.get(key, default)
  end

  defp emit_exception(reason, metadata) do
    Telemetry.emit(Telemetry.maintenance_raw_payload_purge_exception(), %{count: 1}, %{
      worker: Map.get(metadata, :worker, :raw_payload_purger),
      cutoff_at: Map.get(metadata, :cutoff_at),
      retention_days: Map.get(metadata, :retention_days),
      batch_size: Map.get(metadata, :batch_size),
      reason: low_cardinality_reason(reason)
    })
  end

  defp low_cardinality_reason(reason) when is_atom(reason), do: reason
  defp low_cardinality_reason({reason, _detail}) when is_atom(reason), do: reason
  defp low_cardinality_reason(%module{}), do: module
  defp low_cardinality_reason(_reason), do: :error
end
