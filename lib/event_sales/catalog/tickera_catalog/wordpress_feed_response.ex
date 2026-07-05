defmodule EventSales.Catalog.TickeraCatalog.WordPressFeedResponse do
  @moduledoc """
  Validates and aggregates VS-26C WordPress Tickera catalog feed pages.
  """

  @schema_version "2026-07-05.v1"
  @source "wordpress_tickera"

  @type t :: %__MODULE__{
          source_snapshot_at: DateTime.t() | nil,
          page: pos_integer(),
          per_page: pos_integer(),
          has_more: boolean(),
          events: [map()],
          catalog_rows: [map()]
        }

  defstruct source_snapshot_at: nil,
            page: 1,
            per_page: 100,
            has_more: false,
            events: [],
            catalog_rows: []

  @spec parse_page(term()) :: {:ok, t()} | {:error, :invalid_feed_response}
  def parse_page(%{} = decoded) do
    with true <- decoded["schema_version"] == @schema_version,
         true <- decoded["source"] == @source,
         events when is_list(events) <- decoded["events"],
         rows when is_list(rows) <- decoded["catalog_rows"],
         page when is_integer(page) and page > 0 <- decoded["page"],
         per_page when is_integer(per_page) and per_page > 0 <- decoded["per_page"],
         has_more when is_boolean(has_more) <- decoded["has_more"],
         {:ok, source_snapshot_at} <- parse_datetime(decoded["source_snapshot_at"]) do
      {:ok,
       %__MODULE__{
         source_snapshot_at: source_snapshot_at,
         page: page,
         per_page: per_page,
         has_more: has_more,
         events: events,
         catalog_rows: rows
       }}
    else
      _error -> {:error, :invalid_feed_response}
    end
  end

  def parse_page(_decoded), do: {:error, :invalid_feed_response}

  @spec aggregate_pages([t()]) :: {:ok, t()} | {:error, :invalid_feed_response}
  def aggregate_pages([%__MODULE__{} | _rest] = pages) do
    aggregate =
      Enum.reduce(pages, %__MODULE__{events: [], catalog_rows: []}, fn page,
                                                                       %__MODULE__{} = acc ->
        %__MODULE__{
          acc
          | source_snapshot_at: latest_datetime(acc.source_snapshot_at, page.source_snapshot_at),
            page: page.page,
            per_page: page.per_page,
            has_more: page.has_more,
            events: dedupe_events(acc.events ++ page.events),
            catalog_rows: acc.catalog_rows ++ page.catalog_rows
        }
      end)

    {:ok, aggregate}
  end

  def aggregate_pages(_pages), do: {:error, :invalid_feed_response}

  defp parse_datetime(nil), do: {:ok, nil}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _other -> {:error, :invalid}
    end
  end

  defp parse_datetime(_value), do: {:error, :invalid}

  defp latest_datetime(nil, datetime), do: datetime
  defp latest_datetime(datetime, nil), do: datetime

  defp latest_datetime(%DateTime{} = left, %DateTime{} = right) do
    case DateTime.compare(left, right) do
      :lt -> right
      _other -> left
    end
  end

  defp dedupe_events(events) do
    {deduped, _seen} =
      Enum.reduce(events, {[], MapSet.new()}, fn event, {acc, seen} ->
        key = to_string(event["tickera_event_id"])

        if MapSet.member?(seen, key) do
          {acc, seen}
        else
          {acc ++ [event], MapSet.put(seen, key)}
        end
      end)

    deduped
  end
end
