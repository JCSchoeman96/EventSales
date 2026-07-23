defmodule EventSales.Catalog.TickeraCatalog.WordPressFeedResponse do
  @moduledoc """
  Validates and aggregates VS-26C WordPress Tickera catalog feed pages.
  """

  @schema_version "2026-07-22.v2"
  @legacy_schema_versions ["2026-07-08.v1", "2026-07-05.v1"]
  @supported_schema_versions [@schema_version | @legacy_schema_versions]
  @source "wordpress_tickera"
  @statuses ["publish", "private", "draft", "trash", "deleted", "unknown"]
  @observations ["present", "trashed", "deleted", "unknown"]
  @semantic_values ["present", "absent", "unknown"]
  @subscription_values ["subscription", "not_subscription", "unknown"]

  @type t :: %__MODULE__{
          schema_version: String.t(),
          auto_apply_proof_complete?: boolean(),
          source_snapshot_at: DateTime.t() | nil,
          page: pos_integer(),
          per_page: pos_integer(),
          has_more: boolean(),
          events: [map()],
          catalog_rows: [map()]
        }

  defstruct schema_version: nil,
            auto_apply_proof_complete?: false,
            source_snapshot_at: nil,
            page: 1,
            per_page: 100,
            has_more: false,
            events: [],
            catalog_rows: []

  @spec parse_page(term()) :: {:ok, t()} | {:error, :invalid_feed_response}
  def parse_page(%{} = decoded) do
    with schema_version when schema_version in @supported_schema_versions <-
           decoded["schema_version"],
         true <- decoded["source"] == @source,
         events when is_list(events) <- decoded["events"],
         rows when is_list(rows) <- decoded["catalog_rows"],
         true <- valid_payload?(schema_version, events, rows),
         page when is_integer(page) and page > 0 <- decoded["page"],
         per_page when is_integer(per_page) and per_page > 0 <- decoded["per_page"],
         has_more when is_boolean(has_more) <- decoded["has_more"],
         {:ok, source_snapshot_at} <- parse_datetime(decoded["source_snapshot_at"]) do
      {:ok,
       %__MODULE__{
         schema_version: schema_version,
         auto_apply_proof_complete?: schema_version == @schema_version,
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
    if one_schema_version?(pages) do
      aggregate =
        Enum.reduce(pages, %__MODULE__{events: [], catalog_rows: []}, fn page,
                                                                         %__MODULE__{} = acc ->
          %__MODULE__{
            acc
            | schema_version: page.schema_version,
              auto_apply_proof_complete?: page.auto_apply_proof_complete?,
              source_snapshot_at:
                latest_datetime(acc.source_snapshot_at, page.source_snapshot_at),
              page: page.page,
              per_page: page.per_page,
              has_more: page.has_more,
              events: dedupe_events(acc.events ++ page.events),
              catalog_rows: acc.catalog_rows ++ page.catalog_rows
          }
        end)

      {:ok, aggregate}
    else
      {:error, :invalid_feed_response}
    end
  end

  def aggregate_pages(_pages), do: {:error, :invalid_feed_response}

  defp one_schema_version?(pages) do
    pages |> Enum.map(& &1.schema_version) |> Enum.uniq() |> length() == 1
  end

  defp valid_payload?(schema_version, _events, _rows)
       when schema_version in @legacy_schema_versions,
       do: true

  defp valid_payload?(@schema_version, events, rows) do
    Enum.all?(events, &valid_v2_event?/1) and Enum.all?(rows, &valid_v2_row?/1)
  end

  defp valid_v2_event?(event) when is_map(event) do
    has_exact_required_keys?(event, [
      "tickera_event_id",
      "event_status_classification",
      "target_observation",
      "risk_codes"
    ]) and
      positive_integer?(event["tickera_event_id"]) and
      event["event_status_classification"] in @statuses and
      event["target_observation"] in @observations and
      string_list?(event["risk_codes"])
  end

  defp valid_v2_event?(_event), do: false

  defp valid_v2_row?(row) when is_map(row) do
    valid_v2_row_shape?(row) and valid_v2_row_identity?(row) and valid_v2_row_risk?(row)
  end

  defp valid_v2_row?(_row), do: false

  defp valid_v2_row_shape?(row) do
    has_exact_required_keys?(row, [
      "woo_product_id",
      "woo_variation_id",
      "product_status_classification",
      "variation_status_classification",
      "product_type",
      "ticket_template_present",
      "subscription_classification",
      "product_semantics",
      "target_observation",
      "risk_codes"
    ])
  end

  defp valid_v2_row_identity?(row) do
    positive_integer?(row["woo_product_id"]) and
      optional_positive_integer?(row["woo_variation_id"]) and
      valid_variation_status?(row["woo_variation_id"], row["variation_status_classification"])
  end

  defp valid_v2_row_risk?(row) do
    row["product_status_classification"] in @statuses and
      present_binary?(row["product_type"]) and
      is_boolean(row["ticket_template_present"]) and
      row["subscription_classification"] in @subscription_values and
      valid_product_semantics?(row["product_semantics"]) and
      row["target_observation"] in @observations and
      string_list?(row["risk_codes"])
  end

  defp valid_variation_status?(nil, nil), do: true

  defp valid_variation_status?(variation_id, status),
    do: positive_integer?(variation_id) and status in @statuses

  defp valid_product_semantics?(semantics) when is_map(semantics) do
    Enum.sort(Map.keys(semantics)) ==
      Enum.sort(["payment_plan", "membership", "bundle", "add_on"]) and
      Enum.all?(Map.values(semantics), &(&1 in @semantic_values))
  end

  defp valid_product_semantics?(_semantics), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp optional_positive_integer?(nil), do: true
  defp optional_positive_integer?(value), do: positive_integer?(value)
  defp present_binary?(value), do: is_binary(value) and value != ""
  defp string_list?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)
  defp has_exact_required_keys?(map, keys), do: Enum.all?(keys, &Map.has_key?(map, &1))

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
