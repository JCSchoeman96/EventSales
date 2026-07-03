defmodule EventSales.Catalog.TickeraCatalog.ManualRowsDiscoverySource do
  @moduledoc """
  Manual sanitized-row discovery adapter for the VS-26A pilot.
  """

  @behaviour EventSales.Catalog.TickeraCatalog.DiscoverySource

  alias EventSales.Catalog.TickeraCatalog.DiscoveryResult

  @impl true
  def discover(_source_system_id, scope) when is_map(scope) do
    rows = list_value(scope, "catalog_rows")
    supplied_events = list_value(scope, "events")

    events =
      supplied_events
      |> Enum.concat(Enum.map(rows, &event_from_row/1))
      |> Enum.reject(&is_nil/1)
      |> dedupe_events()

    {:ok,
     %DiscoveryResult{
       events: events,
       catalog_rows: Enum.map(rows, &string_key_map/1),
       source_snapshot_at: parse_datetime(value(scope, "source_snapshot_at"))
     }}
  end

  defp list_value(scope, key) do
    case value(scope, key) do
      values when is_list(values) -> Enum.map(values, &string_key_map/1)
      _other -> []
    end
  end

  defp event_from_row(row) do
    row = string_key_map(row)

    case row["tickera_event_id"] do
      nil ->
        nil

      event_id ->
        %{
          "tickera_event_id" => event_id,
          "event_title" => row["event_title"],
          "event_slug" => row["event_slug"],
          "event_status" => row["event_status"],
          "event_source_updated_at" => row["event_source_updated_at"]
        }
    end
  end

  defp dedupe_events(events) do
    events
    |> Enum.reduce(%{}, fn event, acc ->
      Map.put_new(acc, to_string(event["tickera_event_id"]), event)
    end)
    |> Map.values()
  end

  defp string_key_map(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp string_key_map(_value), do: %{}

  defp value(map, key) do
    atom_key =
      try do
        String.to_existing_atom(key)
      rescue
        ArgumentError -> nil
      end

    Map.get(map, key) || (atom_key && Map.get(map, atom_key))
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
