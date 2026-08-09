defmodule EventSales.Catalog.TickeraCatalog.SourceRiskV3.DiscoveryIntegrity do
  @moduledoc """
  Pure native `2026-08-07.v3` discovery integrity checks.

  Owns cross-page agreement, page-sequence completeness, snapshot stability,
  and derive-only producer `source_system_id` verification. Does not decide
  semantic findings, Planner status, or Apply eligibility.
  """

  @native_schema_version "2026-08-07.v3"
  @canonical_contract_version "source_risk.v3"
  @producer_version "2026-08-07.1"
  @source "wordpress_tickera"

  @max_per_page 100
  @max_evidence_per_page 500
  @max_catalog_rows_per_page 100

  @type page :: %{
          required(:schema_version) => String.t(),
          required(:canonical_contract_version) => String.t() | nil,
          required(:producer_version) => String.t() | nil,
          required(:source_system_id) => String.t() | nil,
          required(:discovery_snapshot_id) => String.t() | nil,
          required(:source_snapshot_at) => DateTime.t() | nil,
          required(:page) => pos_integer(),
          required(:per_page) => pos_integer(),
          required(:has_more) => boolean(),
          required(:filters) => map() | nil,
          required(:catalog_rows) => list(),
          required(:evidence) => list(),
          optional(:generated_at) => DateTime.t() | nil,
          optional(atom()) => term()
        }

  @spec native_schema_version() :: String.t()
  def native_schema_version, do: @native_schema_version

  @spec canonical_contract_version() :: String.t()
  def canonical_contract_version, do: @canonical_contract_version

  @spec producer_version() :: String.t()
  def producer_version, do: @producer_version

  @spec source() :: String.t()
  def source, do: @source

  @spec max_per_page() :: 100
  def max_per_page, do: @max_per_page

  @spec max_evidence_per_page() :: 500
  def max_evidence_per_page, do: @max_evidence_per_page

  @spec max_catalog_rows_per_page() :: 100
  def max_catalog_rows_per_page, do: @max_catalog_rows_per_page

  @spec normalize_base_url(String.t()) :: {:ok, String.t()} | {:error, :invalid_base_url}
  def normalize_base_url(url) when is_binary(url) do
    with {:ok, uri} <- URI.new(url),
         scheme when scheme in ["http", "https"] <- downcase_present(uri.scheme),
         host when is_binary(host) and host != "" <- downcase_present(uri.host) do
      port = normalize_port(scheme, uri.port)
      path = normalize_path(uri.path)

      base =
        case port do
          nil -> "#{scheme}://#{host}"
          port -> "#{scheme}://#{host}:#{port}"
        end

      {:ok, base <> path}
    else
      _ -> {:error, :invalid_base_url}
    end
  end

  def normalize_base_url(_), do: {:error, :invalid_base_url}

  @spec expected_source_system_id(String.t()) ::
          {:ok, String.t()} | {:error, :invalid_base_url}
  def expected_source_system_id(base_url) when is_binary(base_url) do
    with {:ok, normalized} <- normalize_base_url(base_url) do
      hash =
        :crypto.hash(:sha256, normalized)
        |> Base.encode16(case: :lower)

      {:ok, "wordpress_tickera:" <> hash}
    end
  end

  def expected_source_system_id(_), do: {:error, :invalid_base_url}

  @spec verify_source_system_id(String.t(), String.t()) ::
          :ok | {:error, :source_system_id_mismatch | :invalid_base_url}
  def verify_source_system_id(base_url, wire_source_system_id)
      when is_binary(base_url) and is_binary(wire_source_system_id) do
    with {:ok, expected} <- expected_source_system_id(base_url) do
      if expected == wire_source_system_id do
        :ok
      else
        {:error, :source_system_id_mismatch}
      end
    end
  end

  def verify_source_system_id(_, _), do: {:error, :source_system_id_mismatch}

  @spec validate_page_bounds(page()) :: :ok | {:error, atom()}
  def validate_page_bounds(page) when is_map(page) do
    cond do
      not (is_integer(page.per_page) and page.per_page >= 1 and page.per_page <= @max_per_page) ->
        {:error, :invalid_per_page}

      length(page.evidence) > @max_evidence_per_page ->
        {:error, :evidence_page_limit_exceeded}

      length(page.catalog_rows) > @max_catalog_rows_per_page ->
        {:error, :catalog_rows_page_limit_exceeded}

      true ->
        :ok
    end
  end

  @spec validate_discovery_pages([page()]) ::
          {:ok, :complete} | {:error, atom()}
  def validate_discovery_pages([]), do: {:error, :empty_discovery}

  def validate_discovery_pages(pages) when is_list(pages) do
    with :ok <- require_native_pages(pages),
         :ok <- validate_all_page_bounds(pages),
         :ok <- require_cross_page_agreement(pages),
         :ok <- require_complete_page_sequence(pages) do
      {:ok, :complete}
    end
  end

  def validate_discovery_pages(_), do: {:error, :invalid_discovery_pages}

  defp require_native_pages(pages) do
    if Enum.all?(pages, &(&1.schema_version == @native_schema_version)) do
      :ok
    else
      {:error, :mixed_or_unknown_schema}
    end
  end

  defp validate_all_page_bounds(pages) do
    Enum.reduce_while(pages, :ok, fn page, :ok ->
      case validate_page_bounds(page) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp require_cross_page_agreement([first | rest]) do
    Enum.reduce_while(rest, :ok, fn page, :ok ->
      case page_agreement_error(page, first) do
        nil -> {:cont, :ok}
        reason -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      :ok -> first_page_version_ok(first)
      other -> other
    end
  end

  defp page_agreement_error(page, first) do
    with nil <-
           field_mismatch(page.schema_version, first.schema_version, :schema_version_mismatch),
         nil <-
           field_mismatch(
             page.canonical_contract_version,
             first.canonical_contract_version,
             :canonical_contract_version_mismatch
           ),
         nil <-
           field_mismatch(
             page.producer_version,
             first.producer_version,
             :producer_version_mismatch
           ),
         nil <-
           field_mismatch(
             page.source_system_id,
             first.source_system_id,
             :source_system_id_mismatch
           ),
         nil <-
           field_mismatch(
             page.discovery_snapshot_id,
             first.discovery_snapshot_id,
             :discovery_snapshot_id_mismatch
           ),
         nil <-
           unless_true(
             datetime_equal?(page.source_snapshot_at, first.source_snapshot_at),
             :source_snapshot_at_mismatch
           ),
         nil <-
           unless_true(filters_equal?(page.filters, first.filters), :filters_mismatch),
         nil <- field_mismatch(page.per_page, first.per_page, :per_page_mismatch) do
      page_contract_version_error(page)
    end
  end

  defp field_mismatch(left, right, reason) when left != right, do: reason
  defp field_mismatch(_left, _right, _reason), do: nil

  defp unless_true(true, _reason), do: nil
  defp unless_true(false, reason), do: reason

  defp page_contract_version_error(page) do
    with nil <-
           field_mismatch(
             page.canonical_contract_version,
             @canonical_contract_version,
             :invalid_canonical_contract_version
           ) do
      field_mismatch(
        page.producer_version,
        @producer_version,
        :invalid_producer_version
      )
    end
  end

  defp first_page_version_ok(first) do
    case page_contract_version_error(first) do
      nil -> :ok
      reason -> {:error, reason}
    end
  end

  defp require_complete_page_sequence(pages) do
    page_numbers = Enum.map(pages, & &1.page)
    expected = Enum.to_list(1..length(pages))

    cond do
      Enum.any?(page_numbers, &(not is_integer(&1) or &1 < 1)) ->
        {:error, :invalid_page_number}

      length(page_numbers) != MapSet.size(MapSet.new(page_numbers)) ->
        {:error, :duplicate_page}

      page_numbers == expected ->
        final = List.last(pages)

        if final.has_more == false and
             Enum.all?(Enum.drop(pages, -1), &(&1.has_more == true)) do
          :ok
        else
          {:error, :incomplete_page_sequence}
        end

      Enum.sort(page_numbers) == expected ->
        {:error, :out_of_order_page}

      true ->
        {:error, :page_gap_or_incomplete_sequence}
    end
  end

  defp datetime_equal?(nil, nil), do: true

  defp datetime_equal?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp datetime_equal?(_, _), do: false

  defp filters_equal?(left, right), do: canonicalize_filters(left) == canonicalize_filters(right)

  defp canonicalize_filters(nil), do: %{}

  defp canonicalize_filters(filters) when is_map(filters) do
    filters
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Map.new()
  end

  defp canonicalize_filters(_), do: :invalid

  defp downcase_present(nil), do: nil
  defp downcase_present(value) when is_binary(value), do: String.downcase(value)

  defp normalize_port("http", 80), do: nil
  defp normalize_port("https", 443), do: nil
  defp normalize_port(_scheme, port) when is_integer(port), do: port
  defp normalize_port(_scheme, _), do: nil

  defp normalize_path(nil), do: ""
  defp normalize_path(""), do: ""
  defp normalize_path("/"), do: ""

  defp normalize_path(path) when is_binary(path) do
    trimmed = String.trim_trailing(path, "/")

    case trimmed do
      "" -> ""
      other -> other
    end
  end
end
