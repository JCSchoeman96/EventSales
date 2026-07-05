defmodule EventSales.Catalog.TickeraCatalog.WordPressFeedClient do
  @moduledoc """
  Signed HTTP client for the VS-26C WordPress Tickera catalog feed.
  """

  alias EventSales.Catalog.TickeraCatalog.{WordPressFeedResponse, WordPressFeedSignature}
  alias EventSales.Ingestion.Clients.HttpcTransport
  alias EventSales.Telemetry

  @default_timeout_ms 5_000
  @default_per_page 100
  @default_max_pages 50
  @default_path "/wp-json/eventsales/v1/tickera-catalog"

  @type query :: %{optional(String.t() | atom()) => term()} | keyword()

  @spec fetch(query(), keyword()) ::
          {:ok, WordPressFeedResponse.t()} | {:error, atom()}
  def fetch(query, opts \\ []) do
    with {:ok, config} <- config(opts) do
      fetch_pages(query, config, 1, [])
    end
  end

  @spec fetch_page(query(), pos_integer(), keyword()) ::
          {:ok, WordPressFeedResponse.t()} | {:error, atom()}
  def fetch_page(query, page, opts \\ [])

  def fetch_page(query, page, opts) when is_integer(page) and page > 0 do
    with {:ok, config} <- config(opts) do
      fetch_page_request(query, page, config)
    end
  end

  def fetch_page(_query, _page, _opts), do: {:error, :invalid_request}

  defp fetch_pages(query, config, page, acc) when page <= config.max_pages do
    case fetch_page_request(query, page, config) do
      {:ok, %WordPressFeedResponse{has_more: true} = response} ->
        fetch_pages(query, config, page + 1, acc ++ [response])

      {:ok, %WordPressFeedResponse{} = response} ->
        WordPressFeedResponse.aggregate_pages(acc ++ [response])

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_pages(_query, _config, _page, _acc), do: {:error, :pagination_limit}

  defp fetch_page_request(query, page, config) do
    query = page_query(query, page, config.per_page)

    with {:ok, canonical_query} <- WordPressFeedSignature.canonical_query(query),
         {:ok, headers} <- WordPressFeedSignature.headers(:get, config.path, query, config.secret) do
      url = config.base_url <> config.path <> "?" <> canonical_query
      started_at = System.monotonic_time()

      case transport_request(config.transport, url, headers, timeout_ms: config.timeout_ms) do
        {:ok, status, _headers, body} ->
          duration = System.monotonic_time() - started_at
          decode_response(status, body, page, duration)

        {:error, :timeout} ->
          emit_exception(:timeout, page)
          {:error, :timeout}

        {:error, _reason} ->
          emit_exception(:transport_error, page)
          {:error, :transport_error}
      end
    else
      {:error, :invalid_request} -> {:error, :invalid_request}
    end
  end

  defp decode_response(status, body, page, duration) when status in 200..299 do
    with {:ok, decoded} <- Jason.decode(body),
         {:ok, response} <- WordPressFeedResponse.parse_page(decoded) do
      emit_stop(status, duration, page, response.has_more)
      {:ok, response}
    else
      {:error, %Jason.DecodeError{}} ->
        emit_exception(:invalid_json, page)
        {:error, :invalid_json}

      {:error, :invalid_feed_response} ->
        emit_exception(:invalid_feed_response, page)
        {:error, :invalid_feed_response}
    end
  end

  defp decode_response(status, _body, page, _duration) do
    reason = status_reason(status)
    emit_exception(reason, page)
    {:error, reason}
  end

  defp status_reason(400), do: :invalid_request
  defp status_reason(401), do: :unauthorized
  defp status_reason(403), do: :forbidden
  defp status_reason(404), do: :not_found
  defp status_reason(429), do: :rate_limited
  defp status_reason(status) when status in 500..599, do: :server_error
  defp status_reason(_status), do: :transport_error

  defp transport_request(transport, url, headers, opts) do
    transport.request(:get, url, headers, nil, opts)
  rescue
    _error -> {:error, :transport_failure}
  catch
    :exit, _reason -> {:error, :transport_failure}
    :throw, _value -> {:error, :transport_failure}
  end

  defp config(opts) do
    app_config =
      :event_sales
      |> Application.get_env(:tickera_catalog_feed, [])
      |> Keyword.merge(opts)

    with {:ok, base_url} <- required(app_config, :base_url),
         {:ok, secret} <- required(app_config, :secret),
         :ok <- validate_base_url(base_url) do
      {:ok,
       %{
         base_url: String.trim_trailing(base_url, "/"),
         secret: secret,
         timeout_ms: Keyword.get(app_config, :timeout_ms, @default_timeout_ms),
         per_page: Keyword.get(app_config, :per_page, @default_per_page),
         max_pages: Keyword.get(app_config, :max_pages, @default_max_pages),
         path: Keyword.get(app_config, :path, @default_path),
         transport: Keyword.get(app_config, :transport, HttpcTransport)
       }}
    else
      _error -> {:error, :misconfigured}
    end
  end

  defp required(config, key) do
    case Keyword.get(config, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing}
    end
  end

  defp validate_base_url(base_url) do
    uri = URI.parse(base_url)

    cond do
      uri.scheme not in ["http", "https"] or not is_binary(uri.host) ->
        {:error, :invalid_base_url}

      Application.get_env(:event_sales, :env, :dev) == :prod and uri.scheme != "https" ->
        {:error, :invalid_prod_scheme}

      true ->
        :ok
    end
  end

  defp page_query(query, page, per_page) do
    query
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.reject(fn {key, value} -> is_nil(value) or key == "mode" end)
    |> Kernel.++([{"page", page}, {"per_page", per_page}])
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp emit_stop(status, duration, page, has_more) do
    Telemetry.emit(Telemetry.rest_request_stop(), %{count: 1, duration: duration}, %{
      operation: :tickera_catalog_feed_fetch_page,
      source: :tickera_catalog_feed,
      status: status,
      page: page,
      has_more: has_more
    })
  end

  defp emit_exception(reason, page) do
    Telemetry.emit(Telemetry.rest_request_exception(), %{count: 1}, %{
      operation: :tickera_catalog_feed_fetch_page,
      source: :tickera_catalog_feed,
      reason: reason,
      page: page
    })
  end
end
