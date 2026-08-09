defmodule EventSales.Catalog.TickeraCatalog.WordPressFeedResponse do
  @moduledoc """
  Validates and aggregates VS-26C WordPress Tickera catalog feed pages.

  Exact schema dispatch:
  - legacy `2026-07-22.v2` / `2026-07-08.v1` / `2026-07-05.v1` unchanged
  - native `2026-08-07.v3` transport parsing + DiscoveryIntegrity aggregation
  """

  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.ContractRegistry
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.DiscoveryIntegrity
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.Evidence

  # Constant MapSet envelope key sets conflict with MapSet's opaque stdlib contracts.
  @dialyzer {:nowarn_function, require_exact_keys: 2}

  @schema_version "2026-07-22.v2"
  @legacy_schema_versions ["2026-07-08.v1", "2026-07-05.v1"]
  @native_schema_version "2026-08-07.v3"
  @source "wordpress_tickera"
  @native_canonical_contract_version "source_risk.v3"
  @native_producer_version "2026-08-07.1"
  @native_max_per_page 100
  @native_max_evidence_per_page 500
  @native_max_catalog_rows_per_page 100

  @native_envelope_keys MapSet.new([
                          "schema_version",
                          "canonical_contract_version",
                          "producer_version",
                          "source",
                          "source_system_id",
                          "discovery_snapshot_id",
                          "source_snapshot_at",
                          "generated_at",
                          "page",
                          "per_page",
                          "has_more",
                          "filters",
                          "events",
                          "catalog_rows",
                          "evidence"
                        ])

  @native_filter_keys MapSet.new([
                        "updated_since",
                        "product_id",
                        "variation_id",
                        "event_id",
                        "include_private"
                      ])

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
          catalog_rows: [map()],
          canonical_contract_version: String.t() | nil,
          producer_version: String.t() | nil,
          source_system_id: String.t() | nil,
          discovery_snapshot_id: String.t() | nil,
          generated_at: DateTime.t() | nil,
          filters: map() | nil,
          evidence: [Evidence.t()]
        }

  defstruct schema_version: nil,
            auto_apply_proof_complete?: false,
            source_snapshot_at: nil,
            page: 1,
            per_page: 100,
            has_more: false,
            events: [],
            catalog_rows: [],
            canonical_contract_version: nil,
            producer_version: nil,
            source_system_id: nil,
            discovery_snapshot_id: nil,
            generated_at: nil,
            filters: nil,
            evidence: []

  @spec parse_page(term()) :: {:ok, t()} | {:error, :invalid_feed_response}
  def parse_page(%{} = decoded) do
    case Map.get(decoded, "schema_version") do
      @native_schema_version ->
        parse_native_page(decoded)

      schema_version when schema_version in [@schema_version | @legacy_schema_versions] ->
        parse_legacy_page(decoded, schema_version)

      _other ->
        {:error, :invalid_feed_response}
    end
  end

  def parse_page(_decoded), do: {:error, :invalid_feed_response}

  @spec aggregate_pages([t()]) :: {:ok, t()} | {:error, :invalid_feed_response}
  def aggregate_pages([%__MODULE__{schema_version: @native_schema_version} | _] = pages) do
    with :ok <- require_all_native(pages),
         {:ok, :complete} <- DiscoveryIntegrity.validate_discovery_pages(pages),
         {:ok, aggregate} <- aggregate_native_pages(pages) do
      {:ok, aggregate}
    else
      _ -> {:error, :invalid_feed_response}
    end
  end

  def aggregate_pages([%__MODULE__{} | _rest] = pages) do
    if one_schema_version?(pages) and not Enum.any?(pages, &native?/1) do
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

  defp parse_legacy_page(decoded, schema_version) do
    with true <- decoded["source"] == @source,
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

  defp parse_native_page(decoded) do
    with :ok <- require_string_keys(decoded),
         :ok <- require_exact_keys(decoded, @native_envelope_keys),
         true <- decoded["source"] == @source,
         true <- decoded["canonical_contract_version"] == @native_canonical_contract_version,
         true <- decoded["producer_version"] == @native_producer_version,
         source_system_id when is_binary(source_system_id) and source_system_id != "" <-
           decoded["source_system_id"],
         {:ok, discovery_snapshot_id} <-
           require_discovery_snapshot_id(decoded["discovery_snapshot_id"]),
         {:ok, source_snapshot_at} <- require_native_utc_z_datetime(decoded["source_snapshot_at"]),
         {:ok, generated_at} <- require_native_utc_z_datetime(decoded["generated_at"]),
         page when is_integer(page) and page > 0 <- decoded["page"],
         per_page
         when is_integer(per_page) and per_page >= 1 and per_page <= @native_max_per_page <-
           decoded["per_page"],
         has_more when is_boolean(has_more) <- decoded["has_more"],
         {:ok, filters} <- validate_filters(decoded["filters"]),
         events when is_list(events) <- decoded["events"],
         rows when is_list(rows) <- decoded["catalog_rows"],
         evidence_raw when is_list(evidence_raw) <- decoded["evidence"],
         true <- length(rows) <= @native_max_catalog_rows_per_page,
         true <- length(evidence_raw) <= @native_max_evidence_per_page,
         true <- length(events) <= per_page,
         true <- Enum.all?(events, &is_map/1),
         true <- Enum.all?(events, &valid_native_event_identity?/1),
         true <- Enum.all?(rows, &is_map/1),
         {:ok, evidence} <- validate_evidence_list(evidence_raw) do
      {:ok,
       %__MODULE__{
         schema_version: @native_schema_version,
         auto_apply_proof_complete?: false,
         source_snapshot_at: source_snapshot_at,
         page: page,
         per_page: per_page,
         has_more: has_more,
         events: events,
         catalog_rows: rows,
         canonical_contract_version: @native_canonical_contract_version,
         producer_version: @native_producer_version,
         source_system_id: source_system_id,
         discovery_snapshot_id: discovery_snapshot_id,
         generated_at: generated_at,
         filters: filters,
         evidence: evidence
       }}
    else
      _error -> {:error, :invalid_feed_response}
    end
  end

  defp validate_evidence_list(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case Evidence.validate(item) do
        {:ok, evidence} -> {:cont, {:ok, [evidence | acc]}}
        {:error, _reason} -> {:halt, {:error, :invalid_evidence}}
      end
    end)
    |> case do
      {:ok, evidence} -> {:ok, Enum.reverse(evidence)}
      other -> other
    end
  end

  defp validate_filters(filters) when is_map(filters) do
    with :ok <- require_string_keys(filters),
         true <- MapSet.subset?(MapSet.new(Map.keys(filters)), @native_filter_keys),
         :ok <- validate_filter_values(filters) do
      {:ok, filters}
    else
      _ -> {:error, :invalid_filters}
    end
  end

  defp validate_filters(_), do: {:error, :invalid_filters}

  defp validate_filter_values(filters) do
    Enum.reduce_while(filters, :ok, fn {key, value}, :ok ->
      case validate_filter_entry(key, value) do
        :ok -> {:cont, :ok}
        :error -> {:halt, {:error, :invalid_filters}}
      end
    end)
  end

  defp validate_filter_entry("updated_since", nil), do: :ok

  defp validate_filter_entry("updated_since", value) when is_binary(value) do
    case require_native_utc_z_datetime(value) do
      {:ok, _} -> :ok
      _ -> :error
    end
  end

  defp validate_filter_entry("product_id", nil), do: :ok
  defp validate_filter_entry("product_id", id) when is_integer(id) and id > 0, do: :ok
  defp validate_filter_entry("variation_id", nil), do: :ok
  defp validate_filter_entry("variation_id", id) when is_integer(id) and id > 0, do: :ok
  defp validate_filter_entry("event_id", nil), do: :ok
  defp validate_filter_entry("event_id", id) when is_integer(id) and id > 0, do: :ok
  defp validate_filter_entry("include_private", value) when is_boolean(value), do: :ok
  defp validate_filter_entry(_key, _value), do: :error

  defp aggregate_native_pages(pages) do
    first = hd(pages)
    last = List.last(pages)

    with {:ok, events} <- aggregate_native_events(Enum.flat_map(pages, & &1.events)) do
      {:ok,
       %__MODULE__{
         schema_version: first.schema_version,
         auto_apply_proof_complete?: false,
         source_snapshot_at: first.source_snapshot_at,
         page: last.page,
         per_page: last.per_page,
         has_more: last.has_more,
         events: events,
         catalog_rows: Enum.flat_map(pages, & &1.catalog_rows),
         canonical_contract_version: first.canonical_contract_version,
         producer_version: first.producer_version,
         source_system_id: first.source_system_id,
         discovery_snapshot_id: first.discovery_snapshot_id,
         generated_at: last.generated_at,
         filters: first.filters,
         evidence: Enum.flat_map(pages, & &1.evidence)
       }}
    end
  end

  # Transport-only integrity for native pages:
  # exact complete-map duplicates collapse to the first occurrence;
  # any structural map difference for the same tickera_event_id fails closed.
  defp aggregate_native_events(events) do
    Enum.reduce_while(events, {:ok, {[], %{}}}, fn event, {:ok, acc} ->
      merge_native_event(acc, event)
    end)
    |> case do
      {:ok, {acc, _by_id}} -> {:ok, Enum.reverse(acc)}
      {:error, :conflicting_event} = error -> error
    end
  end

  defp merge_native_event({acc, by_id}, %{"tickera_event_id" => id} = event)
       when is_integer(id) and id > 0 do
    case Map.fetch(by_id, id) do
      :error ->
        {:cont, {:ok, {[event | acc], Map.put(by_id, id, event)}}}

      {:ok, ^event} ->
        {:cont, {:ok, {acc, by_id}}}

      {:ok, _other} ->
        {:halt, {:error, :conflicting_event}}
    end
  end

  defp merge_native_event(_acc, _event), do: {:halt, {:error, :conflicting_event}}

  defp valid_native_event_identity?(%{"tickera_event_id" => id})
       when is_integer(id) and id > 0,
       do: true

  defp valid_native_event_identity?(_event), do: false

  defp require_all_native(pages) do
    if Enum.all?(pages, &native?/1), do: :ok, else: {:error, :mixed_schema}
  end

  defp native?(%__MODULE__{schema_version: @native_schema_version}), do: true
  defp native?(_), do: false

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

  defp require_string_keys(map) do
    if Enum.all?(Map.keys(map), &is_binary/1), do: :ok, else: {:error, :non_string_map_keys}
  end

  defp require_exact_keys(map, allowed) do
    keys = MapSet.new(Map.keys(map))

    if MapSet.equal?(keys, allowed) do
      :ok
    else
      {:error, :invalid_envelope_keys}
    end
  end

  defp parse_datetime(nil), do: {:ok, nil}

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _other -> {:error, :invalid}
    end
  end

  defp parse_datetime(_value), do: {:error, :invalid}

  defp require_discovery_snapshot_id(value) when is_binary(value) and value != "" do
    case ContractRegistry.validate_bounded_string(value, 128) do
      :ok -> {:ok, value}
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_discovery_snapshot_id(_), do: {:error, :invalid}

  defp require_native_utc_z_datetime(value) when is_binary(value) do
    if Regex.match?(~r/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/, value) do
      case DateTime.from_iso8601(value) do
        {:ok, datetime, 0} -> {:ok, datetime}
        _other -> {:error, :invalid}
      end
    else
      {:error, :invalid}
    end
  end

  defp require_native_utc_z_datetime(_value), do: {:error, :invalid}

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
          {[event | acc], MapSet.put(seen, key)}
        end
      end)

    Enum.reverse(deduped)
  end
end
