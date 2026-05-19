defmodule EventSales.Ingestion.Clients.TickeraAttendeeClient do
  @moduledoc """
  Worker-safe Tickera attendee API client boundary.

  Tickera authenticates by API key in the path. This module never logs or emits
  that key, raw attendee payloads, attendee PII, or transaction IDs.
  """

  alias EventSales.Ingestion.Clients.{HttpcTransport, TickeraError}
  alias EventSales.Telemetry

  @default_site_url "https://voelgoed.co.za"
  @default_timeout_ms 30_000
  @default_connect_timeout_ms 5_000
  @default_receive_timeout_ms 30_000
  @default_per_page 50
  @default_page_delay_ms 100
  @user_agent "EventSales/1.0 (+https://voelgoed.co.za)"
  @known_atom_keys %{
    "allowed_checkins" => :allowed_checkins,
    "buyer_email" => :buyer_email,
    "buyer_first" => :buyer_first,
    "buyer_last" => :buyer_last,
    "checked_in" => :checked_in,
    "checked_in_count" => :checked_in_count,
    "checkin_limit" => :checkin_limit,
    "checkins" => :checkins,
    "checksum" => :checksum,
    "custom_fields" => :custom_fields,
    "email" => :email,
    "first_name" => :first_name,
    "last_name" => :last_name,
    "order_status" => :order_status,
    "payment_date" => :payment_date,
    "payment_status" => :payment_status,
    "purchaser_email" => :purchaser_email,
    "purchaser_first" => :purchaser_first,
    "purchaser_last" => :purchaser_last,
    "remaining_checkins" => :remaining_checkins,
    "ticket_code" => :ticket_code,
    "ticket_type" => :ticket_type,
    "ticket_type_id" => :ticket_type_id,
    "transaction_id" => :transaction_id,
    "used_checkins" => :used_checkins,
    "wc_order_status" => :wc_order_status,
    "woocommerce_order_status" => :woocommerce_order_status
  }

  @type page_result :: %{
          attendees: [map()],
          page: pos_integer(),
          per_page: pos_integer(),
          count: non_neg_integer(),
          additional: map()
        }

  @doc """
  Fetches one Tickera `tickets_info` page and normalizes supported response shapes.
  """
  @spec fetch_attendees_page(String.t(), String.t(), pos_integer(), pos_integer(), keyword()) ::
          {:ok, page_result()} | {:error, TickeraError.t()}
  def fetch_attendees_page(site_url, api_key, page, per_page, opts \\ []) do
    operation = :fetch_attendees_page

    with {:ok, config} <- config(opts),
         {:ok, page} <- normalize_positive_integer(page, :page, operation),
         {:ok, per_page} <- normalize_positive_integer(per_page, :per_page, operation),
         {:ok, request_url} <- build_url(site_url, api_key, "tickets_info/#{per_page}/#{page}/"),
         :ok <- validate_site_url(request_url, operation) do
      execute_request(operation, request_url, page, per_page, config)
    end
  end

  @doc false
  @spec safe_log_url(String.t()) :: String.t()
  def safe_log_url(url) when is_binary(url) do
    Regex.replace(~r{/tc-api/[^/]+/}, url, "/tc-api/[REDACTED]/")
  end

  def safe_log_url(value), do: inspect(value)

  defp execute_request(operation, request_url, page, per_page, config) do
    started_at = System.monotonic_time()
    headers = request_headers()
    opts = request_opts(config)

    case transport_request(config.transport, request_url, headers, opts) do
      {:ok, status, _headers, body} ->
        duration = System.monotonic_time() - started_at

        if status in 200..299 do
          decode_success(body, page, per_page, operation, status, duration)
        else
          reason = status_reason(status)
          emit_exception(operation, page, per_page, reason, status)
          {:error, tickera_error(reason, operation, status)}
        end

      {:error, :timeout} ->
        emit_exception(operation, page, per_page, :timeout, nil)
        {:error, tickera_error(:timeout, operation)}

      {:error, _reason} ->
        emit_exception(operation, page, per_page, :transport_error, nil)
        {:error, tickera_error(:transport_error, operation)}
    end
  end

  defp transport_request(transport, request_url, headers, opts) do
    transport.request(:get, request_url, headers, nil, opts)
  rescue
    _error -> {:error, :transport_failure}
  catch
    :exit, _reason -> {:error, :transport_failure}
    :throw, _value -> {:error, :transport_failure}
  end

  defp decode_success(body, page, per_page, operation, status, duration) when is_binary(body) do
    if String.trim(body) == "" do
      emit_exception(operation, page, per_page, :invalid_json, nil)
      {:error, tickera_error(:invalid_json, operation)}
    else
      case Jason.decode(body) do
        {:ok, decoded} ->
          result = normalize_response(decoded, page, per_page)
          emit_stop(operation, page, per_page, status, duration)
          {:ok, result}

        {:error, _error} ->
          emit_exception(operation, page, per_page, :invalid_json, nil)
          {:error, tickera_error(:invalid_json, operation)}
      end
    end
  end

  defp normalize_response(decoded, page, per_page) do
    {raw_attendees, additional} = raw_attendees_and_additional(decoded)

    attendees =
      raw_attendees
      |> Enum.filter(&parseable_attendee?/1)
      |> Enum.map(&normalize_attendee/1)

    %{
      attendees: attendees,
      page: page,
      per_page: per_page,
      count: length(attendees),
      additional: additional
    }
  end

  defp raw_attendees_and_additional(%{"data" => data, "additional" => additional})
       when is_list(data) and is_map(additional),
       do: {data, additional}

  defp raw_attendees_and_additional(%{"data" => data}) when is_list(data), do: {data, %{}}

  defp raw_attendees_and_additional(list) when is_list(list) do
    additional =
      list
      |> Enum.find_value(%{}, fn
        %{"additional" => additional} when is_map(additional) -> additional
        %{additional: additional} when is_map(additional) -> additional
        _other -> nil
      end)

    attendees =
      Enum.flat_map(list, fn
        %{"data" => data} when is_map(data) -> [data]
        %{data: data} when is_map(data) -> [data]
        %{"additional" => _additional} -> []
        %{additional: _additional} -> []
        item when is_map(item) -> [item]
        _other -> []
      end)

    {attendees, additional}
  end

  defp raw_attendees_and_additional(_decoded), do: {[], %{}}

  defp parseable_attendee?(attendee) when is_map(attendee) do
    attendee
    |> Map.drop(["additional", :additional])
    |> map_has_any_value?()
  end

  defp parseable_attendee?(_attendee), do: false

  defp map_has_any_value?(map) do
    Enum.any?(map, fn
      {_key, value} when is_binary(value) -> String.trim(value) != ""
      {_key, nil} -> false
      {_key, value} when is_map(value) -> map_has_any_value?(value)
      {_key, value} when is_list(value) -> value != []
      {_key, _value} -> true
    end)
  end

  defp normalize_attendee(attendee) do
    custom_fields = normalize_custom_fields(value(attendee, "custom_fields"))

    allowed_checkins =
      non_negative_integer(first_value(attendee, ["allowed_checkins", "checkin_limit"]))

    used_checkins =
      non_negative_integer(
        first_value(attendee, ["checkins", "used_checkins", "checked_in", "checked_in_count"])
      )

    payment_date = string_value(first_value(attendee, ["payment_date"]))
    buyer_first = buyer_value(attendee, custom_fields, :first_name)
    buyer_last = buyer_value(attendee, custom_fields, :last_name)
    buyer_email = buyer_value(attendee, custom_fields, :email)

    %{
      ticket_code: ticket_code(attendee),
      checksum: string_value(first_value(attendee, ["checksum"])),
      ticket_type_id: positive_integer(first_value(attendee, ["ticket_type_id"])),
      ticket_type:
        string_value(custom_field(custom_fields, ["ticket type", "attendee ticket"])) ||
          string_value(first_value(attendee, ["ticket_type"])),
      first_name: attendee_identity(attendee, custom_fields, :first_name, buyer_first),
      last_name: attendee_identity(attendee, custom_fields, :last_name, buyer_last),
      email: attendee_identity(attendee, custom_fields, :email, buyer_email),
      buyer_first: buyer_first,
      buyer_last: buyer_last,
      buyer_email: buyer_email,
      allowed_checkins: allowed_checkins,
      used_checkins: used_checkins,
      remaining_checkins:
        remaining_checkins(
          first_value(attendee, ["remaining_checkins"]),
          allowed_checkins,
          used_checkins
        ),
      checked_in?: boolean_value(first_value(attendee, ["checked-in", "checked_in"])),
      payment_status: payment_status(attendee, custom_fields, payment_date),
      payment_date: payment_date,
      transaction_id: string_value(first_value(attendee, ["transaction_id"])),
      custom_fields: custom_fields
    }
  end

  defp ticket_code(attendee) do
    string_value(first_value(attendee, ["ticket_code", "checksum"]))
  end

  defp attendee_identity(attendee, custom_fields, field, buyer_fallback) do
    direct_keys =
      case field do
        :first_name -> ["first_name", "attendee_first_name", "ticket_holder_first_name"]
        :last_name -> ["last_name", "attendee_last_name", "ticket_holder_last_name"]
        :email -> ["email", "attendee_email", "ticket_holder_email"]
      end

    custom_keys =
      case field do
        :first_name -> ["attendee first name", "ticket holder first name", "first name"]
        :last_name -> ["attendee last name", "ticket holder last name", "last name"]
        :email -> ["attendee email", "ticket holder email", "email"]
      end

    string_value(first_value(attendee, direct_keys)) ||
      string_value(custom_field(custom_fields, custom_keys)) ||
      buyer_fallback
  end

  defp buyer_value(attendee, custom_fields, field) do
    direct_keys =
      case field do
        :first_name -> ["buyer_first", "purchaser_first"]
        :last_name -> ["buyer_last", "purchaser_last"]
        :email -> ["buyer_email", "purchaser_email"]
      end

    custom_keys =
      case field do
        :first_name -> ["buyer first", "purchaser first"]
        :last_name -> ["buyer last", "purchaser last"]
        :email -> ["buyer email", "buyer e mail", "purchaser email", "purchaser e mail"]
      end

    string_value(first_value(attendee, direct_keys)) ||
      string_value(custom_field(custom_fields, custom_keys))
  end

  defp payment_status(attendee, custom_fields, payment_date) do
    status =
      first_value(attendee, [
        "order_status",
        "payment_status",
        "wc_order_status",
        "woocommerce_order_status"
      ]) ||
        custom_field(custom_fields, [
          "order status",
          "payment status",
          "wc order status",
          "woocommerce order status"
        ])

    case normalize_status(status) do
      nil ->
        if is_binary(payment_date) and payment_date != "", do: "completed"

      normalized ->
        normalized
    end
  end

  defp normalize_status(status) do
    case status |> string_value() |> downcase_trim() do
      value when value in ["wc-completed", "completed", "complete"] -> "completed"
      value when value in ["refunded", "refund"] -> "refunded"
      value when value in ["cancelled", "canceled"] -> "cancelled"
      "failed" -> "failed"
      value when value in ["pending", "on-hold"] -> "pending"
      "processing" -> "processing"
      "paid" -> "paid"
      _other -> nil
    end
  end

  defp downcase_trim(nil), do: nil
  defp downcase_trim(value), do: value |> String.trim() |> String.downcase()

  defp remaining_checkins(value, allowed_checkins, used_checkins) do
    non_negative_integer(value) ||
      if is_integer(allowed_checkins) and is_integer(used_checkins) do
        max(allowed_checkins - used_checkins, 0)
      end
  end

  defp normalize_custom_fields(nil), do: %{}
  defp normalize_custom_fields(value) when value in ["", []], do: %{}

  defp normalize_custom_fields(fields) when is_map(fields) do
    fields
    |> Enum.reduce(%{}, fn {key, value}, acc -> put_custom_field(acc, key, value) end)
  end

  defp normalize_custom_fields(fields) when is_list(fields) do
    fields
    |> Enum.reduce(%{}, fn
      %{"name" => key, "value" => value}, acc -> put_custom_field(acc, key, value)
      %{name: key, value: value}, acc -> put_custom_field(acc, key, value)
      [key, value], acc -> put_custom_field(acc, key, value)
      {key, value}, acc -> put_custom_field(acc, key, value)
      _other, acc -> acc
    end)
  end

  defp normalize_custom_fields(_fields), do: %{}

  defp put_custom_field(acc, key, value) do
    with key when is_binary(key) <- string_value(key),
         value when is_binary(value) <- string_value(value) do
      Map.put(acc, key, value)
    else
      _other -> acc
    end
  end

  defp custom_field(custom_fields, keys) do
    Enum.find_value(keys, &custom_field_value(custom_fields, &1))
  end

  defp custom_field_value(custom_fields, wanted) do
    Enum.find_value(custom_fields, fn {key, value} ->
      if normalize_custom_field_key(key) == wanted, do: value
    end)
  end

  defp normalize_custom_field_key(key) do
    key
    |> String.downcase()
    |> String.replace("_", " ")
    |> String.replace("-", " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  defp first_value(map, keys) do
    Enum.find_value(keys, &value(map, &1))
  end

  defp value(map, key) when is_map(map) and is_binary(key) do
    Map.get(map, key) || atom_key_value(map, key)
  end

  defp atom_key_value(map, key) do
    case Map.fetch(@known_atom_keys, key) do
      {:ok, atom_key} -> Map.get(map, atom_key)
      :error -> nil
    end
  end

  defp positive_integer(value) do
    case integer_value(value) do
      value when is_integer(value) and value > 0 -> value
      _other -> nil
    end
  end

  defp non_negative_integer(value) do
    case integer_value(value) do
      value when is_integer(value) and value >= 0 -> value
      _other -> nil
    end
  end

  defp integer_value(value) when is_integer(value), do: value

  defp integer_value(value) when is_binary(value) do
    value = String.trim(value)

    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _other -> nil
    end
  end

  defp integer_value(_value), do: nil

  defp boolean_value(value) when is_boolean(value), do: value

  defp boolean_value(value) when is_integer(value) and value in [0, 1], do: value == 1

  defp boolean_value(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      value when value in ["yes", "true", "1"] -> true
      value when value in ["no", "false", "0"] -> false
      _other -> nil
    end
  end

  defp boolean_value(_value), do: nil

  defp string_value(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: nil, else: value
  end

  defp string_value(value) when is_integer(value), do: Integer.to_string(value)
  defp string_value(value) when is_float(value), do: Float.to_string(value)
  defp string_value(_value), do: nil

  defp build_url(site_url, api_key, endpoint) do
    with {:ok, site_url} <- normalize_site_url(site_url),
         {:ok, api_key} <- normalize_api_key(api_key) do
      endpoint = endpoint |> String.trim() |> String.trim_leading("/")
      {:ok, "#{site_url}/tc-api/#{api_key}/#{endpoint}"}
    end
  end

  defp normalize_site_url(site_url) when is_binary(site_url) do
    site_url = String.trim(site_url)

    cond do
      site_url == "" ->
        {:error, tickera_error(:misconfigured, :fetch_attendees_page)}

      String.starts_with?(site_url, ["http://", "https://"]) ->
        {:ok, String.trim_trailing(site_url, "/")}

      true ->
        {:ok, "https://" <> String.trim_trailing(site_url, "/")}
    end
  end

  defp normalize_site_url(_site_url),
    do: {:error, tickera_error(:misconfigured, :fetch_attendees_page)}

  defp normalize_api_key(api_key) when is_binary(api_key) do
    api_key = String.trim(api_key)

    if api_key == "" do
      {:error, tickera_error(:invalid_request, :fetch_attendees_page)}
    else
      {:ok, api_key}
    end
  end

  defp normalize_api_key(_api_key),
    do: {:error, tickera_error(:invalid_request, :fetch_attendees_page)}

  defp validate_site_url(request_url, operation) do
    uri = URI.parse(request_url)

    cond do
      uri.scheme not in ["http", "https"] or not is_binary(uri.host) ->
        {:error, tickera_error(:misconfigured, operation)}

      app_env() == :prod and uri.scheme != "https" ->
        {:error, tickera_error(:misconfigured, operation)}

      true ->
        :ok
    end
  end

  defp normalize_positive_integer(value, _field, _operation) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp normalize_positive_integer(value, _field, operation) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _other -> {:error, tickera_error(:invalid_request, operation)}
    end
  end

  defp normalize_positive_integer(_value, _field, operation),
    do: {:error, tickera_error(:invalid_request, operation)}

  defp status_reason(401), do: :unauthorized
  defp status_reason(403), do: :forbidden
  defp status_reason(404), do: :not_found
  defp status_reason(429), do: :rate_limited
  defp status_reason(status) when status in 400..499, do: :client_error
  defp status_reason(status) when status in 500..599, do: :server_error
  defp status_reason(_status), do: :transport_error

  defp config(opts) do
    app_config =
      :event_sales
      |> Application.get_env(:tickera_api, [])
      |> defaults()
      |> Keyword.merge(opts)

    {:ok,
     %{
       default_site_url: Keyword.fetch!(app_config, :default_site_url),
       timeout_ms: Keyword.fetch!(app_config, :timeout_ms),
       connect_timeout_ms: Keyword.fetch!(app_config, :connect_timeout_ms),
       receive_timeout_ms: Keyword.fetch!(app_config, :receive_timeout_ms),
       per_page: Keyword.fetch!(app_config, :per_page),
       page_delay_ms: Keyword.fetch!(app_config, :page_delay_ms),
       transport: Keyword.fetch!(app_config, :transport)
     }}
  end

  defp defaults(app_config) do
    [
      default_site_url: @default_site_url,
      timeout_ms: @default_timeout_ms,
      connect_timeout_ms: @default_connect_timeout_ms,
      receive_timeout_ms: @default_receive_timeout_ms,
      per_page: @default_per_page,
      page_delay_ms: @default_page_delay_ms,
      transport: HttpcTransport
    ]
    |> Keyword.merge(app_config)
  end

  defp request_headers do
    [
      {"accept", "application/json"},
      {"user-agent", @user_agent},
      {"accept-language", "en-US,en;q=0.9"},
      {"accept-encoding", "identity"},
      {"cache-control", "no-cache"},
      {"pragma", "no-cache"}
    ]
  end

  defp request_opts(config) do
    [
      timeout_ms: config.timeout_ms,
      connect_timeout_ms: config.connect_timeout_ms,
      receive_timeout_ms: config.receive_timeout_ms
    ]
  end

  defp tickera_error(reason, operation, status \\ nil) do
    TickeraError.exception(reason: reason, operation: operation, status: status)
  end

  defp emit_stop(operation, page, per_page, status, duration) do
    Telemetry.emit(Telemetry.tickera_request_stop(), %{count: 1, duration: duration}, %{
      operation: operation,
      endpoint: :tickets_info,
      page: page,
      per_page: per_page,
      status: status,
      source: :tickera
    })
  end

  defp emit_exception(operation, page, per_page, reason, status) do
    error = tickera_error(reason, operation, status)

    metadata =
      %{
        operation: operation,
        endpoint: :tickets_info,
        page: page,
        per_page: per_page,
        reason: reason,
        retryable?: error.retryable?,
        source: :tickera
      }
      |> maybe_put_status(status)

    Telemetry.emit(Telemetry.tickera_request_exception(), %{count: 1}, metadata)
  end

  defp maybe_put_status(metadata, nil), do: metadata
  defp maybe_put_status(metadata, status), do: Map.put(metadata, :status, status)

  defp app_env do
    Application.get_env(:event_sales, :env, :dev)
  end
end
