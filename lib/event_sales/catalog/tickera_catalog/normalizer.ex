defmodule EventSales.Catalog.TickeraCatalog.Normalizer do
  @moduledoc """
  Pure normalization for Tickera Bridge catalog discovery results.
  """

  alias EventSales.Catalog.TickeraCatalog.{CatalogRow, DiscoveryResult, Finding}

  @published "publish"

  @spec normalize(DiscoveryResult.t()) ::
          {:ok, %{rows: [CatalogRow.t()], findings: [Finding.t()]}}
  def normalize(%DiscoveryResult{} = result) do
    events = Enum.map(result.events, &string_key_map/1)
    rows = Enum.map(result.catalog_rows, &string_key_map/1)

    normalized_rows =
      rows
      |> Enum.filter(&published_row?/1)
      |> Enum.map(&to_catalog_row/1)
      |> dedupe_rows()
      |> drop_parent_rows_when_variations_exist()

    findings =
      []
      |> Enum.concat(non_published_event_findings(events))
      |> Enum.concat(zero_product_findings(events, normalized_rows))
      |> Enum.concat(duplicate_findings(rows))
      |> Enum.concat(variation_findings(normalized_rows))

    {:ok, %{rows: normalized_rows, findings: findings}}
  end

  defp published_row?(row) do
    row["event_status"] == @published and row["product_status"] == @published and
      variation_published?(row)
  end

  defp variation_published?(%{"woo_variation_id" => nil}), do: true
  defp variation_published?(%{"woo_variation_id" => ""}), do: true
  defp variation_published?(%{"woo_variation_id" => value}) when is_nil(value), do: true
  defp variation_published?(row), do: row["variation_status"] in [nil, "", @published]

  defp to_catalog_row(row) do
    variation_id = int(row["woo_variation_id"])

    %CatalogRow{
      tickera_event_id: int(row["tickera_event_id"]),
      event_title: clean(row["event_title"]),
      event_slug: clean(row["event_slug"]),
      event_status: clean(row["event_status"]),
      event_source_updated_at: parse_datetime(row["event_source_updated_at"]),
      woo_product_id: int(row["woo_product_id"]),
      product_title: clean(row["product_title"]),
      product_slug: clean(row["product_slug"]),
      product_status: clean(row["product_status"]),
      product_source_updated_at: parse_datetime(row["product_source_updated_at"]),
      ticket_display_name: clean(row["ticket_display_name"]),
      ticket_type_name: ticket_type_name(row, variation_id),
      ticket_type_kind: if(is_nil(variation_id), do: :woo_product, else: :woo_variation),
      price: clean(row["price"]),
      regular_price: clean(row["regular_price"]),
      ticket_template_id: clean(row["ticket_template_id"]),
      woo_variation_id: variation_id,
      variation_title: clean(row["variation_title"]),
      variation_status: clean(row["variation_status"]),
      variation_source_updated_at: parse_datetime(row["variation_source_updated_at"])
    }
  end

  defp dedupe_rows(rows) do
    rows
    |> Enum.reduce(%{}, fn row, acc ->
      Map.put_new(acc, identity(row), row)
    end)
    |> Map.values()
    |> Enum.sort_by(&{&1.tickera_event_id, &1.woo_product_id, &1.woo_variation_id || 0})
  end

  defp drop_parent_rows_when_variations_exist(rows) do
    rows
    |> Enum.group_by(&{&1.tickera_event_id, &1.woo_product_id})
    |> Enum.flat_map(fn {_identity, grouped_rows} ->
      if Enum.any?(grouped_rows, & &1.woo_variation_id) do
        Enum.reject(grouped_rows, &is_nil(&1.woo_variation_id))
      else
        grouped_rows
      end
    end)
    |> Enum.sort_by(&{&1.tickera_event_id, &1.woo_product_id, &1.woo_variation_id || 0})
  end

  defp duplicate_findings(rows) do
    rows
    |> Enum.map(fn row ->
      {int(row["tickera_event_id"]), int(row["woo_product_id"]), int(row["woo_variation_id"])}
    end)
    |> Enum.frequencies()
    |> Enum.filter(fn {_identity, count} -> count > 1 end)
    |> Enum.map(fn {{event_id, product_id, variation_id}, _count} ->
      finding(:info, :duplicate_meta_collapsed, "Duplicate Tickera/Woo meta rows were collapsed.",
        tickera_event_id: event_id,
        woo_product_id: product_id,
        woo_variation_id: variation_id
      )
    end)
  end

  defp variation_findings(rows) do
    rows
    |> Enum.reject(&is_nil(&1.woo_variation_id))
    |> Enum.group_by(&{&1.tickera_event_id, &1.woo_product_id})
    |> Enum.map(fn {{event_id, product_id}, _rows} ->
      finding(
        :warning,
        :variation_mapping_required,
        "Published product variations require variation-level mappings.",
        tickera_event_id: event_id,
        woo_product_id: product_id
      )
    end)
  end

  defp non_published_event_findings(events) do
    events
    |> Enum.reject(&(&1["event_status"] == @published))
    |> Enum.map(fn event ->
      status = clean(event["event_status"]) || "unknown"
      code = if status == "private", do: :private_event_skipped, else: :draft_event_skipped

      finding(:info, code, "Tickera event is not published and was skipped.",
        tickera_event_id: int(event["tickera_event_id"]),
        metadata: %{"event_status" => status}
      )
    end)
  end

  defp zero_product_findings(events, rows) do
    row_event_ids = rows |> Enum.map(& &1.tickera_event_id) |> MapSet.new()

    events
    |> Enum.filter(&(&1["event_status"] == @published))
    |> Enum.reject(&MapSet.member?(row_event_ids, int(&1["tickera_event_id"])))
    |> Enum.map(fn event ->
      finding(
        :warning,
        :published_event_without_ticket_products,
        "Published Tickera event has no eligible published ticket products.",
        tickera_event_id: int(event["tickera_event_id"])
      )
    end)
  end

  defp ticket_type_name(row, nil) do
    clean(row["ticket_display_name"]) || clean(row["product_title"])
  end

  defp ticket_type_name(row, _variation_id) do
    clean(row["ticket_display_name"]) || clean(row["variation_title"]) ||
      clean(row["product_title"])
  end

  defp identity(row), do: {row.tickera_event_id, row.woo_product_id, row.woo_variation_id}

  defp finding(severity, code, message, opts) do
    %Finding{
      severity: severity,
      code: code,
      message: message,
      tickera_event_id: Keyword.get(opts, :tickera_event_id),
      woo_product_id: Keyword.get(opts, :woo_product_id),
      woo_variation_id: Keyword.get(opts, :woo_variation_id),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  defp string_key_map(%{} = map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp clean(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp clean(value), do: value

  defp int(nil), do: nil
  defp int(""), do: nil
  defp int(value) when is_integer(value), do: value

  defp int(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp int(_value), do: nil

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
