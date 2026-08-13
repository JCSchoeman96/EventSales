defmodule EventSales.Ingestion.Clients.WooOrderIndexClient do
  @moduledoc """
  One-request client for the authenticated Woo order-index manifest boundary.

  The client owns request authentication and strict response validation only.
  It never loads EventSales resources, retries manifest creation, or traverses
  more than one source page per call.
  """

  alias EventSales.Ingestion.Clients.HttpcTransport
  alias EventSales.Ingestion.Clients.WooOrderIndexError
  alias EventSales.Telemetry

  @manifest_path "/wp-json/eventsales/v1/woo-order-index/manifests"
  @schema_version "2026-08-12.v1"
  @phase "manifest_enumerate"
  @default_limit 100
  @max_page_items 100
  @default_timeout_ms 7_000
  @max_boundary_token_bytes 128
  @max_cursor_bytes 512

  @common_response_keys MapSet.new([
                          "schema_version",
                          "phase",
                          "boundary_token",
                          "manifest_hash",
                          "manifest_expires_at_gmt",
                          "source_observed_at_gmt",
                          "items",
                          "has_more"
                        ])
  @nonterminal_response_keys MapSet.put(@common_response_keys, "next_cursor")
  @terminal_response_keys MapSet.put(@common_response_keys, "terminal_evidence")
  @item_keys MapSet.new([
               "source_order_id",
               "source_created_at_gmt",
               "source_modified_at_gmt"
             ])
  @boundary_token_regex ~r/\A[A-Za-z0-9._-]+\z/
  @positive_decimal_regex ~r/\A[1-9][0-9]*\z/
  @utc_wire_regex ~r/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z\z/

  @known_503_reasons [
    :capture_budget_exceeded,
    :manifest_storage_failed,
    :manifest_finalize_failed,
    :source_authority_changed,
    :source_preflight_failed,
    :source_snapshot_failed,
    :lock_unavailable,
    :manifest_unavailable
  ]

  defmodule Page do
    @moduledoc "Validated metadata-only order-index manifest page."

    @type item :: %{
            required(String.t()) => String.t()
          }

    @type t :: %__MODULE__{
            schema_version: String.t(),
            phase: String.t(),
            boundary_token: String.t(),
            manifest_hash: String.t(),
            manifest_expires_at: DateTime.t(),
            source_observed_at: DateTime.t(),
            items: [item()],
            has_more: boolean(),
            next_cursor: String.t() | nil,
            terminal_evidence: String.t() | nil
          }

    defstruct [
      :schema_version,
      :phase,
      :boundary_token,
      :manifest_hash,
      :manifest_expires_at,
      :source_observed_at,
      :items,
      :has_more,
      :next_cursor,
      :terminal_evidence
    ]
  end

  @type result :: {:ok, Page.t()} | {:error, WooOrderIndexError.t()}
  @type method :: :get | :post | String.t()

  @doc "Creates and validates exactly one immutable manifest page."
  @spec create_manifest(
          String.t(),
          DateTime.t() | String.t(),
          DateTime.t() | String.t(),
          pos_integer(),
          keyword()
        ) :: result()
  def create_manifest(
        source_system_id,
        backfill_start,
        backfill_cutoff,
        limit \\ @default_limit,
        opts \\ []
      ) do
    with {:ok, source_system_id} <- validate_source_system_id(source_system_id),
         {:ok, start_wire, start_at} <- normalize_wire_timestamp(backfill_start),
         {:ok, cutoff_wire, cutoff_at} <- normalize_wire_timestamp(backfill_cutoff),
         :ok <- validate_bounds(start_at, cutoff_at),
         :ok <- validate_limit(limit),
         {:ok, config} <- config(:create_manifest, opts) do
      body = encode_manifest_request(source_system_id, start_wire, cutoff_wire, limit)

      request(:create_manifest, :post, @manifest_path, "", body, config, limit, nil)
    end
  end

  @doc "Fetches and validates exactly one immutable manifest page."
  @spec fetch_manifest_page(String.t(), String.t() | nil, keyword()) :: result()
  def fetch_manifest_page(boundary_token, cursor \\ nil, opts \\ []) do
    with :ok <- validate_boundary_token(boundary_token),
         :ok <- validate_cursor(cursor),
         {:ok, config} <- config(:fetch_manifest_page, opts) do
      path = @manifest_path <> "/" <> boundary_token
      query = if is_nil(cursor), do: "", else: canonical_query_string(%{"cursor" => cursor})
      request(:fetch_manifest_page, :get, path, query, "", config, nil, boundary_token)
    else
      :error -> emit_exception(:fetch_manifest_page, :invalid_request)
      {:error, %WooOrderIndexError{} = error} -> {:error, error}
    end
  end

  @doc "Validates order-index configuration without performing a request."
  @spec validate_configuration(keyword()) :: :ok | {:error, WooOrderIndexError.t()}
  def validate_configuration(opts \\ []) do
    case config(:validate_configuration, opts) do
      {:ok, _config} -> :ok
      {:error, %WooOrderIndexError{} = error} -> {:error, error}
    end
  end

  @doc "Returns the validated, canonical order-index base URL without credentials."
  @spec configured_base_url(keyword()) :: {:ok, String.t()} | {:error, WooOrderIndexError.t()}
  def configured_base_url(opts \\ []) do
    case config(:configured_base_url, opts) do
      {:ok, %{base_url: base_url}} -> {:ok, base_url}
      {:error, %WooOrderIndexError{} = error} -> {:error, error}
    end
  end

  @doc false
  @spec canonical_query_string(map() | keyword()) :: String.t()
  def canonical_query_string(query) when is_map(query) or is_list(query) do
    query
    |> Enum.map(fn {key, value} -> {to_string(key), canonical_query_value(value)} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join("&", fn {key, value} ->
      rfc3986_encode(key) <> "=" <> rfc3986_encode(value)
    end)
  end

  def canonical_query_string(_query), do: ""

  @doc false
  @spec canonical_signature_input(
          method(),
          String.t(),
          String.t(),
          binary(),
          String.t(),
          String.t()
        ) :: String.t()
  def canonical_signature_input(method, path, canonical_query, raw_body, timestamp, key_id) do
    Enum.join(
      [
        method |> to_string() |> String.upcase(),
        path,
        "query=" <> canonical_query,
        "body_sha256=" <> sha256_hex(raw_body),
        "timestamp=" <> timestamp,
        "key_id=" <> key_id
      ],
      "\n"
    )
  end

  @doc false
  @spec signature(method(), String.t(), String.t(), binary(), String.t(), String.t(), binary()) ::
          String.t()
  def signature(method, path, canonical_query, raw_body, timestamp, key_id, secret) do
    input = canonical_signature_input(method, path, canonical_query, raw_body, timestamp, key_id)
    "v1=" <> hmac_hex(input, secret)
  end

  defp request(
         operation,
         method,
         path,
         canonical_query,
         raw_body,
         config,
         requested_limit,
         requested_boundary
       ) do
    case request_timestamp(config.clock) do
      {:ok, timestamp} ->
        request_with_timestamp(
          operation,
          method,
          path,
          canonical_query,
          raw_body,
          config,
          {requested_limit, requested_boundary},
          timestamp
        )

      :error ->
        emit_exception(operation, :misconfigured)
    end
  end

  defp request_with_timestamp(
         operation,
         method,
         path,
         canonical_query,
         raw_body,
         config,
         {requested_limit, requested_boundary},
         timestamp
       ) do
    url = config.base_url <> path <> query_suffix(canonical_query)
    transport_body = if method == :post, do: raw_body, else: nil
    headers = request_headers(method, path, canonical_query, raw_body, timestamp, config)
    started_at = System.monotonic_time(:microsecond)

    case transport_request(
           config.transport,
           method,
           url,
           headers,
           transport_body,
           config.timeout_ms
         ) do
      {:ok, status, _response_headers, response_body} ->
        handle_response(
          operation,
          method,
          status,
          response_body,
          requested_limit,
          requested_boundary,
          System.monotonic_time(:microsecond) - started_at
        )

      {:error, :timeout} ->
        failure(operation, method, :transport, :timeout, nil)

      {:error, _reason} ->
        failure(operation, method, :transport, :transport_error, nil)
    end
  end

  defp handle_response(
         operation,
         method,
         status,
         response_body,
         requested_limit,
         requested_boundary,
         duration
       ) do
    emit_stop(operation, status, duration)

    case status in 200..299 do
      true ->
        handle_success_response(
          operation,
          method,
          status,
          response_body,
          requested_limit,
          requested_boundary
        )

      false ->
        failure_from_status(operation, method, status, response_body)
    end
  end

  defp handle_success_response(
         operation,
         method,
         status,
         response_body,
         requested_limit,
         requested_boundary
       ) do
    case decode_success(response_body, requested_limit, requested_boundary) do
      {:ok, page} -> {:ok, page}
      {:error, reason} -> failure(operation, method, :invalid_success, reason, status)
    end
  end

  defp transport_request(transport, method, url, headers, body, timeout_ms) do
    case transport.request(method, url, headers, body, timeout_ms: timeout_ms) do
      {:ok, status, response_headers, response_body}
      when is_integer(status) and is_list(response_headers) and is_binary(response_body) ->
        {:ok, status, response_headers, response_body}

      {:error, reason} ->
        {:error, reason}

      _other ->
        {:error, :invalid_transport_response}
    end
  rescue
    _error -> {:error, :transport_failure}
  catch
    :exit, _reason -> {:error, :transport_failure}
    :throw, _value -> {:error, :transport_failure}
  end

  defp decode_success(body, requested_limit, requested_boundary) do
    with {:ok, decoded} <- Jason.decode(body),
         {:ok, page} <- validate_page(decoded, requested_limit, requested_boundary) do
      {:ok, page}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, :invalid_response} -> {:error, :invalid_response}
    end
  end

  defp validate_page(decoded, requested_limit, requested_boundary) when is_map(decoded) do
    with :ok <- validate_response_keys(decoded),
         true <- decoded["schema_version"] == @schema_version,
         true <- decoded["phase"] == @phase,
         :ok <- validate_boundary_token(decoded["boundary_token"]),
         :ok <- validate_requested_boundary(decoded["boundary_token"], requested_boundary),
         :ok <- validate_manifest_hash(decoded["manifest_hash"]),
         {:ok, manifest_expires_at} <- parse_wire_timestamp(decoded["manifest_expires_at_gmt"]),
         {:ok, source_observed_at} <- parse_wire_timestamp(decoded["source_observed_at_gmt"]),
         {:ok, items} <- validate_items(decoded["items"], requested_limit),
         {:ok, page} <- validate_paging(decoded, manifest_expires_at, source_observed_at, items) do
      {:ok, page}
    else
      _error -> {:error, :invalid_response}
    end
  end

  defp validate_page(_decoded, _requested_limit, _requested_boundary),
    do: {:error, :invalid_response}

  defp validate_response_keys(decoded) do
    keys = MapSet.new(Map.keys(decoded))

    if MapSet.equal?(keys, @common_response_keys) or
         MapSet.equal?(keys, @nonterminal_response_keys) or
         MapSet.equal?(keys, @terminal_response_keys) do
      :ok
    else
      :error
    end
  end

  defp validate_requested_boundary(_boundary_token, nil), do: :ok

  defp validate_requested_boundary(boundary_token, requested_boundary)
       when boundary_token == requested_boundary,
       do: :ok

  defp validate_requested_boundary(_boundary_token, _requested_boundary), do: :error

  defp validate_manifest_hash(value) when is_binary(value) and byte_size(value) == 64 do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value), do: :ok, else: :error
  end

  defp validate_manifest_hash(_value), do: :error

  defp validate_items(items, requested_limit) when is_list(items) do
    if length(items) <= @max_page_items and
         (is_nil(requested_limit) or length(items) <= requested_limit) do
      validate_item_list(items)
    else
      {:error, :invalid_response}
    end
  end

  defp validate_items(_items, _requested_limit), do: {:error, :invalid_response}

  defp validate_item_list(items) do
    items
    |> Enum.reduce_while({:ok, []}, &validate_item_acc/2)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _reason} = error -> error
    end
  end

  defp validate_item_acc(item, {:ok, acc}) do
    case validate_item(item) do
      :ok -> {:cont, {:ok, [item | acc]}}
      :error -> {:halt, {:error, :invalid_response}}
    end
  end

  defp validate_item(item) when is_map(item) do
    if MapSet.equal?(MapSet.new(Map.keys(item)), @item_keys) and
         positive_decimal?(item["source_order_id"]) and
         match?({:ok, _}, parse_wire_timestamp(item["source_created_at_gmt"])) and
         match?({:ok, _}, parse_wire_timestamp(item["source_modified_at_gmt"])) do
      :ok
    else
      :error
    end
  end

  defp validate_item(_item), do: :error

  defp validate_paging(decoded, manifest_expires_at, source_observed_at, items) do
    common = %Page{
      schema_version: decoded["schema_version"],
      phase: decoded["phase"],
      boundary_token: decoded["boundary_token"],
      manifest_hash: decoded["manifest_hash"],
      manifest_expires_at: manifest_expires_at,
      source_observed_at: source_observed_at,
      items: items,
      has_more: decoded["has_more"],
      next_cursor: nil,
      terminal_evidence: nil
    }

    case decoded["has_more"] do
      true ->
        with cursor when is_binary(cursor) <- decoded["next_cursor"],
             :ok <- validate_cursor(cursor),
             nil <- decoded["terminal_evidence"] do
          {:ok, %{common | next_cursor: cursor, has_more: true}}
        else
          _error -> {:error, :invalid_response}
        end

      false ->
        with evidence when is_binary(evidence) and evidence != "" <- decoded["terminal_evidence"],
             nil <- decoded["next_cursor"] do
          {:ok, %{common | terminal_evidence: evidence, has_more: false}}
        else
          _error -> {:error, :invalid_response}
        end

      _other ->
        {:error, :invalid_response}
    end
  end

  defp failure(operation, :post, :invalid_success, _reason, status),
    do: emit_exception(operation, :ambiguous_create, status)

  defp failure(operation, :post, :transport, _reason, _status),
    do: emit_exception(operation, :ambiguous_create)

  defp failure(operation, :get, :invalid_success, reason, _status),
    do: emit_exception(operation, reason)

  defp failure(operation, :get, :transport, reason, _status),
    do: emit_exception(operation, reason)

  defp request_headers(method, path, canonical_query, raw_body, timestamp, config) do
    signature =
      signature(
        method,
        path,
        canonical_query,
        raw_body,
        timestamp,
        config.key_id,
        config.secret
      )

    headers = [
      {"accept", "application/json"},
      {"x-eventsales-key-id", config.key_id},
      {"x-eventsales-timestamp", timestamp},
      {"x-eventsales-signature", signature}
    ]

    if method == :post do
      [{"content-type", "application/json"} | headers]
    else
      headers
    end
  end

  defp query_suffix(""), do: ""
  defp query_suffix(query), do: "?" <> query

  defp encode_manifest_request(source_system_id, start_wire, cutoff_wire, limit) do
    [
      "{\"source_system\":",
      Jason.encode!(source_system_id),
      ",\"backfill_start\":",
      Jason.encode!(start_wire),
      ",\"backfill_cutoff\":",
      Jason.encode!(cutoff_wire),
      ",\"limit\":",
      Jason.encode!(limit),
      "}"
    ]
    |> IO.iodata_to_binary()
  end

  defp config(operation, opts) when is_list(opts) do
    app_config =
      :event_sales
      |> Application.get_env(:woo_order_index, [])
      |> Keyword.merge(opts)

    with {:ok, base_url} <- required(app_config, :base_url),
         base_url <- normalize_base_url(base_url),
         {:ok, key_id} <- required(app_config, :key_id),
         {:ok, secret} <- required(app_config, :secret),
         :ok <- validate_base_url(base_url),
         {:ok, timeout_ms} <-
           validate_timeout(Keyword.get(app_config, :timeout_ms, @default_timeout_ms)),
         transport when is_atom(transport) <-
           Keyword.get(app_config, :transport, HttpcTransport),
         clock when is_function(clock, 0) <-
           Keyword.get(app_config, :clock, fn -> System.system_time(:second) end) do
      {:ok,
       %{
         base_url: base_url,
         key_id: key_id,
         secret: secret,
         timeout_ms: timeout_ms,
         transport: transport,
         clock: clock
       }}
    else
      _error -> emit_exception(operation, :misconfigured)
    end
  rescue
    _error -> emit_exception(operation, :misconfigured)
  end

  defp config(operation, _opts), do: emit_exception(operation, :misconfigured)

  defp required(config, key) do
    case Keyword.get(config, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> :error
    end
  end

  defp normalize_base_url(base_url) when is_binary(base_url) do
    base_url
    |> String.trim()
    |> String.trim_trailing("/")
  end

  defp validate_timeout(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp validate_timeout(_value), do: :error

  defp validate_base_url(base_url) do
    uri = URI.parse(base_url)

    cond do
      uri.scheme not in ["http", "https"] or not is_binary(uri.host) -> :error
      Application.get_env(:event_sales, :env, :dev) == :prod and uri.scheme != "https" -> :error
      true -> :ok
    end
  end

  defp validate_source_system_id(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> emit_exception(:create_manifest, :invalid_request)
    end
  end

  defp validate_source_system_id(_value), do: emit_exception(:create_manifest, :invalid_request)

  defp normalize_wire_timestamp(value) when is_binary(value) do
    case parse_wire_timestamp(value) do
      {:ok, datetime} -> {:ok, value, datetime}
      :error -> emit_exception(:create_manifest, :invalid_request)
    end
  end

  defp normalize_wire_timestamp(%DateTime{} = value) do
    if value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0 do
      wire = DateTime.to_iso8601(value)

      case parse_wire_timestamp(wire) do
        {:ok, datetime} -> {:ok, wire, datetime}
        :error -> emit_exception(:create_manifest, :invalid_request)
      end
    else
      emit_exception(:create_manifest, :invalid_request)
    end
  end

  defp normalize_wire_timestamp(_value), do: emit_exception(:create_manifest, :invalid_request)

  defp parse_wire_timestamp(value) when is_binary(value) do
    with true <- Regex.match?(@utc_wire_regex, value),
         {:ok, datetime, 0} <- DateTime.from_iso8601(value) do
      {:ok, datetime}
    else
      _error -> :error
    end
  end

  defp parse_wire_timestamp(_value), do: :error

  defp validate_bounds(start_at, cutoff_at) do
    if DateTime.compare(start_at, cutoff_at) in [:lt, :eq] do
      :ok
    else
      emit_exception(:create_manifest, :invalid_request)
    end
  end

  defp validate_limit(value) when is_integer(value) and value in 1..@max_page_items, do: :ok
  defp validate_limit(_value), do: emit_exception(:create_manifest, :invalid_request)

  defp validate_boundary_token(value)
       when is_binary(value) and byte_size(value) >= 1 and
              byte_size(value) <= @max_boundary_token_bytes do
    if Regex.match?(@boundary_token_regex, value), do: :ok, else: :error
  end

  defp validate_boundary_token(_value), do: :error

  defp validate_cursor(nil), do: :ok

  defp validate_cursor(value)
       when is_binary(value) and byte_size(value) in 16..@max_cursor_bytes do
    if Regex.match?(~r/\A[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\z/, value), do: :ok, else: :error
  end

  defp validate_cursor(_value), do: :error

  defp positive_decimal?(value) when is_binary(value),
    do: Regex.match?(@positive_decimal_regex, value)

  defp positive_decimal?(_value), do: false

  defp request_timestamp(clock) do
    timestamp = clock.()

    if is_integer(timestamp) and timestamp >= 0 do
      {:ok, Integer.to_string(timestamp)}
    else
      :error
    end
  rescue
    _error -> :error
  end

  defp rfc3986_encode(value), do: URI.encode(to_string(value), &URI.char_unreserved?/1)

  defp canonical_query_value(value) when is_binary(value), do: value
  defp canonical_query_value(value) when is_integer(value), do: Integer.to_string(value)
  defp canonical_query_value(value) when is_float(value), do: Float.to_string(value)
  defp canonical_query_value(value) when is_boolean(value), do: to_string(value)
  defp canonical_query_value(nil), do: ""
  defp canonical_query_value(value), do: Jason.encode!(value)

  defp sha256_hex(value), do: Base.encode16(:crypto.hash(:sha256, value), case: :lower)

  defp hmac_hex(value, secret),
    do: Base.encode16(:crypto.mac(:hmac, :sha256, secret, value), case: :lower)

  defp status_reason(:get, 400), do: :invalid_request
  defp status_reason(:post, 400), do: :invalid_request
  defp status_reason(_method, 401), do: :unauthorized
  defp status_reason(_method, 403), do: :unauthorized
  defp status_reason(_method, 409), do: :busy
  defp status_reason(_method, 410), do: :manifest_expired
  defp status_reason(:get, 404), do: :manifest_not_found
  defp status_reason(:post, 404), do: :manifest_unavailable
  defp status_reason(:post, status) when status in 500..599, do: :ambiguous_create
  defp status_reason(_method, status) when status in 500..599, do: :server_error
  defp status_reason(_method, _status), do: :server_error

  defp status_reason_from_body(method, status, body) when status == 503 do
    case Jason.decode(body) do
      {:ok, %{"error" => error}} when is_binary(error) ->
        case Enum.find(@known_503_reasons, &(Atom.to_string(&1) == error)) do
          nil -> status_reason(method, status)
          reason -> reason
        end

      _error ->
        status_reason(method, status)
    end
  end

  defp status_reason_from_body(method, status, _body), do: status_reason(method, status)

  defp emit_stop(operation, status, duration) do
    Telemetry.emit(Telemetry.rest_request_stop(), %{count: 1, duration: duration}, %{
      operation: operation,
      source: :woo_order_index,
      status: status
    })
  end

  defp failure_from_status(operation, method, status, body) do
    reason =
      if method == :post and status not in [400, 401, 403, 404, 409, 410] and
           status not in 500..599 do
        :ambiguous_create
      else
        status_reason_from_body(method, status, body)
      end

    emit_exception(operation, reason, status)
  end

  defp emit_exception(operation, reason, status \\ nil) do
    metadata = %{operation: operation, source: :woo_order_index, reason: reason}
    metadata = if is_integer(status), do: Map.put(metadata, :status, status), else: metadata
    Telemetry.emit(Telemetry.rest_request_exception(), %{count: 1}, metadata)
    {:error, WooOrderIndexError.exception(reason: reason, status: status)}
  end
end
