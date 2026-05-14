defmodule EventSales.TestSupport.FixtureVerificationHelpers do
  @moduledoc """
  Test-only helpers for Slice 1.6 WooCommerce fixture verification.
  """

  @type fixture_kind :: :order | :product
  @type required_case ::
          :completed_order
          | :pending_order
          | :refunded_order
          | :mixed_event_order
          | :variation_ticket_order
          | :non_ticket_product_order
          | :product_updated
          | :variation_updated

  @type fixture :: %{
          case: required_case() | atom(),
          file: String.t(),
          kind: fixture_kind(),
          path: String.t()
        }

  @allowed_statuses ["real_sanitized", "synthetic_placeholder"]
  @parser_stop_decision "STOP - Slice 7.0 parser work is blocked until real sanitized payload evidence exists"

  @required_fixtures [
    %{case: :completed_order, file: "order_completed.json", kind: :order},
    %{case: :pending_order, file: "order_pending.json", kind: :order},
    %{case: :refunded_order, file: "order_refunded.json", kind: :order},
    %{case: :mixed_event_order, file: "order_mixed_event.json", kind: :order},
    %{case: :variation_ticket_order, file: "order_variation_ticket.json", kind: :order},
    %{case: :non_ticket_product_order, file: "order_with_non_ticket_item.json", kind: :order},
    %{case: :product_updated, file: "product_updated.json", kind: :product},
    %{case: :variation_updated, file: "product_variation_updated.json", kind: :product}
  ]

  @future_placeholder_files MapSet.new([
                              "order_out_of_order_newer_update.json",
                              "order_out_of_order_older_update.json",
                              "order_with_unknown_product.json",
                              "product_missing_then_recovered.json"
                            ])

  @required_order_paths [
    ["_event_sales_fixture_status"],
    ["id"],
    ["number"],
    ["status"],
    ["currency"],
    ["date_created_gmt"],
    ["date_modified_gmt"],
    ["discount_total"],
    ["total"],
    ["line_items"],
    ["line_items", 0, "id"],
    ["line_items", 0, "product_id"],
    ["line_items", 0, "variation_id"],
    ["line_items", 0, "quantity"],
    ["line_items", 0, "subtotal"],
    ["line_items", 0, "total"]
  ]

  @required_product_paths [
    ["_event_sales_fixture_status"],
    ["id"],
    ["name"],
    ["status"],
    ["date_created_gmt"],
    ["date_modified_gmt"],
    ["type"],
    ["meta_data"]
  ]

  @required_variation_paths [["parent_id"], ["sku"], ["price"], ["regular_price"]]

  @sensitive_key_patterns [
    ~r/\Aauthorization\z/i,
    ~r/cookie/i,
    ~r/webhook.*secret/i,
    ~r/\Asecret\z/i,
    ~r/api.*key/i,
    ~r/consumer.*key/i,
    ~r/consumer.*secret/i,
    ~r/customer.*ip/i
  ]

  @sensitive_value_patterns [
    {:email, ~r/[A-Z0-9._%+-]+@(?!example\.test\b)[A-Z0-9.-]+\.[A-Z]{2,}/i},
    {:phone, ~r/(?:\+\d[\d .()-]{7,}\d|\b\d{3,}[\s().-]\d{3,}[\s().-]\d{3,}\b)/},
    {:production_url, ~r/https?:\/\/(?![^\/\s]*\.example\.test\b)[^\s"]+/i},
    {:authorization_header, ~r/\b(?:bearer|basic)\s+[a-z0-9._~+\/=-]+/i},
    {:api_key, ~r/\b(?:ck|cs|sk|pk)_[a-z0-9_]{12,}\b/i},
    {:ip_address, ~r/\b(?!(?:192\.0\.2|198\.51\.100|203\.0\.113)\.)\d{1,3}(?:\.\d{1,3}){3}\b/}
  ]

  @spec required_fixtures() :: [fixture()]
  def required_fixtures do
    Enum.map(@required_fixtures, &with_path/1)
  end

  @spec required_fixtures(fixture_kind()) :: [fixture()]
  def required_fixtures(kind) do
    @required_fixtures
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.map(&with_path/1)
  end

  @spec required_fixture!(required_case()) :: fixture()
  def required_fixture!(required_case) do
    @required_fixtures
    |> Enum.find(&(&1.case == required_case))
    |> case do
      nil -> raise ArgumentError, "unknown required fixture case: #{inspect(required_case)}"
      fixture -> with_path(fixture)
    end
  end

  @spec committed_woocommerce_fixtures() :: [fixture()]
  def committed_woocommerce_fixtures do
    fixtures_dir()
    |> Path.join("*.json")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.map(fn path ->
      file = Path.basename(path)
      required = Enum.find(@required_fixtures, &(&1.file == file))

      %{
        case: if(required, do: required.case, else: :future_slice),
        file: file,
        kind: if(required, do: required.kind, else: :order),
        path: path
      }
    end)
  end

  @spec decode_fixture!(fixture()) :: map()
  def decode_fixture!(fixture) do
    fixture.path
    |> File.read!()
    |> Jason.decode!()
  end

  @spec missing_order_paths(map()) :: [String.t()]
  def missing_order_paths(payload) do
    Enum.flat_map(@required_order_paths, &missing_path(payload, &1))
  end

  @spec missing_product_paths(map(), fixture()) :: [String.t()]
  def missing_product_paths(payload, fixture) do
    extra_paths =
      if fixture.case == :variation_updated do
        @required_variation_paths
      else
        []
      end

    (@required_product_paths ++ extra_paths)
    |> Enum.flat_map(&missing_path(payload, &1))
  end

  @spec sensitive_findings(fixture()) :: [map()]
  def sensitive_findings(fixture) do
    fixture
    |> decode_fixture!()
    |> flatten_json()
    |> Enum.flat_map(fn {path, value} ->
      sensitive_key_findings(fixture, path) ++ sensitive_value_findings(fixture, path, value)
    end)
  end

  @spec format_finding(map()) :: String.t()
  def format_finding(%{file: file, path: path, reason: reason}) do
    "#{file}: #{path} matched #{reason}"
  end

  @spec future_placeholder_allowed?(fixture()) :: boolean()
  def future_placeholder_allowed?(fixture) do
    MapSet.member?(@future_placeholder_files, fixture.file) and
      placeholder_fixture?(decode_fixture!(fixture))
  end

  @spec parser_work_blocked?() :: boolean()
  def parser_work_blocked? do
    fixture_verification_doc()
    |> File.read!()
    |> String.contains?(@parser_stop_decision)
  end

  @spec parser_work_allowed?() :: boolean()
  def parser_work_allowed? do
    not parser_work_blocked?()
  end

  defp with_path(fixture) do
    Map.put(fixture, :path, Path.join(fixtures_dir(), fixture.file))
  end

  defp fixtures_dir do
    Path.expand("../fixtures/woocommerce", __DIR__)
  end

  defp fixture_verification_doc do
    Path.expand("../../docs/architecture/fixture-verification.md", __DIR__)
  end

  defp missing_path(payload, path) do
    if path_exists?(payload, path), do: [], else: [format_path(path)]
  end

  defp path_exists?(_value, []), do: true

  defp path_exists?(value, [key | rest]) when is_binary(key) and is_map(value) do
    Map.has_key?(value, key) and path_exists?(Map.get(value, key), rest)
  end

  defp path_exists?(value, [index | rest]) when is_integer(index) and is_list(value) do
    case Enum.at(value, index) do
      nil -> false
      item -> path_exists?(item, rest)
    end
  end

  defp path_exists?(_value, _path), do: false

  defp format_path(path) do
    Enum.map_join(path, ".", &to_string/1)
  end

  defp placeholder_fixture?(%{"placeholder" => _}), do: true

  defp placeholder_fixture?(%{"_event_sales_fixture_status" => status}) do
    status in @allowed_statuses
  end

  defp placeholder_fixture?(_payload), do: false

  defp flatten_json(value, path \\ [])

  defp flatten_json(value, path) when is_map(value) do
    Enum.flat_map(value, fn {key, nested_value} ->
      flatten_json(nested_value, path ++ [key])
    end)
  end

  defp flatten_json(value, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.flat_map(fn {nested_value, index} ->
      flatten_json(nested_value, path ++ [index])
    end)
  end

  defp flatten_json(value, path), do: [{format_path(path), value}]

  defp sensitive_key_findings(fixture, path) do
    if Enum.any?(@sensitive_key_patterns, &Regex.match?(&1, path)) do
      [%{file: fixture.file, path: path, reason: "sensitive key"}]
    else
      []
    end
  end

  defp sensitive_value_findings(fixture, path, value) when is_binary(value) do
    Enum.flat_map(@sensitive_value_patterns, fn {reason, pattern} ->
      if Regex.match?(pattern, value) do
        [%{file: fixture.file, path: path, reason: reason}]
      else
        []
      end
    end)
  end

  defp sensitive_value_findings(_fixture, _path, _value), do: []
end
