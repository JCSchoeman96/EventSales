defmodule EventSales.Ingestion.HistoricalEventLineSelector do
  @moduledoc """
  Selects the exact current raw WooCommerce lines attributable to one Event.

  This module is read-only. Parsing and attribution are delegated to the
  existing Woo parser and canonical mapper; selected values are always the
  original maps from the authoritative full order payload.
  """

  alias EventSales.Catalog.Resources.{Event, SourceSystem}
  alias EventSales.Ingestion.Parsers.WoocommerceOrderParser
  alias EventSales.Sales.OrderItemMapper

  @type result :: {:ok, [map()]} | {:error, term()}

  @doc "Returns the literal raw line maps currently belonging to the target Event."
  @spec select(Event.t(), SourceSystem.t(), map()) :: result()
  def select(%Event{} = event, %SourceSystem{} = source_system, payload)
      when is_map(payload) do
    with :ok <- validate_scope(event, source_system),
         {:ok, normalized} <- WoocommerceOrderParser.parse(payload),
         {:ok, raw_lines} <- raw_lines(payload) do
      select_lines(event, source_system, normalized.line_items, raw_lines)
    else
      {:error, {:invalid_order_payload, _field, _reason} = reason} ->
        {:error, {:historical_event_order_invalid, reason}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def select(_event, _source_system, _payload),
    do: {:error, :invalid_historical_event_selector_input}

  defp validate_scope(%Event{} = event, %SourceSystem{} = source_system) do
    cond do
      event.source_system_id != source_system.id ->
        {:error, :historical_event_source_mismatch}

      source_system.kind != :woocommerce or source_system.active != true ->
        {:error, :source_system_invalid}

      event.external_event_kind != :tickera_event ->
        {:error, :historical_event_kind_invalid}

      not is_integer(event.external_event_id) or event.external_event_id <= 0 ->
        {:error, :historical_event_external_id_invalid}

      true ->
        :ok
    end
  end

  defp raw_lines(%{"line_items" => raw_lines}) when is_list(raw_lines), do: {:ok, raw_lines}
  defp raw_lines(_payload), do: {:error, :historical_event_line_items_invalid}

  defp select_lines(event, source_system, normalized_lines, raw_lines) do
    Enum.reduce_while(normalized_lines, {:ok, []}, fn normalized_line, {:ok, selected} ->
      case select_line(event, source_system, normalized_line, raw_lines) do
        {:ok, :include, raw_line} -> {:cont, {:ok, [raw_line | selected]}}
        {:ok, :exclude, _raw_line} -> {:cont, {:ok, selected}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_result()
  end

  defp select_line(event, source_system, normalized_line, raw_lines) do
    case raw_line(raw_lines, normalized_line) do
      {:ok, raw_line} ->
        case resolve_line(event, source_system, normalized_line) do
          :include -> {:ok, :include, raw_line}
          :exclude -> {:ok, :exclude, raw_line}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_line(
         %Event{id: target_event_id, external_event_id: target_external_event_id},
         %SourceSystem{id: source_system_id},
         normalized_line
       ) do
    case OrderItemMapper.resolve_canonical_attribution(source_system_id, normalized_line) do
      {:ok, {_origin, %{status: :mapped, event_id: event_id}}} when is_binary(event_id) ->
        if event_id == target_event_id,
          do: :include,
          else: :exclude

      {:ok, {_origin, %{status: :pending} = resolution}} ->
        unresolved_line_decision(target_external_event_id, normalized_line, resolution)

      {:error, reason} ->
        {:error, {:historical_event_line_unresolved, line_id(normalized_line), reason}}

      _other ->
        {:error,
         {:historical_event_line_unresolved, line_id(normalized_line), :invalid_resolution}}
    end
  end

  defp unresolved_line_decision(target_external_event_id, normalized_line, resolution) do
    source_event_id = Map.get(resolution, :source_tickera_event_id)

    cond do
      source_event_id == target_external_event_id ->
        {:error,
         {:historical_event_line_unresolved, line_id(normalized_line),
          Map.get(resolution, :attribution_status_reason)}}

      is_integer(source_event_id) and source_event_id > 0 ->
        :exclude

      Map.get(resolution, :attribution_status_reason) == :invalid_source_tickera_event_id ->
        {:error,
         {:historical_event_line_unresolved, line_id(normalized_line),
          :invalid_source_tickera_event_id}}

      true ->
        {:error,
         {:historical_event_line_unresolved, line_id(normalized_line),
          Map.get(resolution, :attribution_status_reason, :unresolved)}}
    end
  end

  defp raw_line(raw_lines, normalized_line) do
    normalized_id = line_id(normalized_line)

    case Enum.find(raw_lines, fn raw -> is_map(raw) and Map.get(raw, "id") == normalized_id end) do
      raw when is_map(raw) -> {:ok, raw}
      _other -> {:error, {:historical_event_line_missing, normalized_id}}
    end
  end

  defp line_id(line), do: Map.get(line, :woo_line_item_id, Map.get(line, "woo_line_item_id"))

  defp reverse_result({:ok, lines}), do: {:ok, Enum.reverse(lines)}
  defp reverse_result({:error, _reason} = error), do: error
end
