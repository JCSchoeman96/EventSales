defmodule EventSales.Ingestion.Clients.WooCommerceClient do
  @moduledoc """
  Worker-safe WooCommerce REST client boundary.

  This client is intentionally not wired into any reconciliation or dashboard
  workflow in Slice 7.5. Future workers may use it as the only WooCommerce REST
  boundary.
  """

  alias EventSales.Ingestion.Clients.HttpcTransport
  alias EventSales.Ingestion.Clients.WooCommerceError
  alias EventSales.Ingestion.RestCircuitBreaker
  alias EventSales.Ingestion.RestRateLimiter
  alias EventSales.Telemetry

  @default_timeout_ms 5_000
  @default_queue_timeout_ms 5_000
  @default_per_page 100
  @default_max_pages 50

  @type params :: %{optional(String.t() | atom()) => term()} | keyword()
  @type result :: {:ok, map() | [map()]} | {:error, WooCommerceError.t()}

  @doc "Fetches a WooCommerce order by positive order ID."
  @spec fetch_order(pos_integer() | String.t(), keyword()) ::
          {:ok, map()} | {:error, WooCommerceError.t()}
  def fetch_order(id, opts \\ []) do
    with {:ok, id} <- normalize_positive_id(id, :fetch_order),
         {:ok, config} <- config(:fetch_order, opts) do
      request_one(:fetch_order, config, "/orders/#{id}")
    end
  end

  @doc "Fetches a WooCommerce product by positive product ID."
  @spec fetch_product(pos_integer() | String.t(), keyword()) ::
          {:ok, map()} | {:error, WooCommerceError.t()}
  def fetch_product(id, opts \\ []) do
    with {:ok, id} <- normalize_positive_id(id, :fetch_product),
         {:ok, config} <- config(:fetch_product, opts) do
      request_one(:fetch_product, config, "/products/#{id}")
    end
  end

  @doc "Lists WooCommerce orders using bounded page iteration."
  @spec list_orders(params(), keyword()) :: {:ok, [map()]} | {:error, WooCommerceError.t()}
  def list_orders(params \\ %{}, opts \\ []) do
    with {:ok, config} <- config(:list_orders, opts) do
      request_pages(:list_orders, config, "/orders", params)
    end
  end

  @doc "Lists WooCommerce products using bounded page iteration."
  @spec list_products(params(), keyword()) :: {:ok, [map()]} | {:error, WooCommerceError.t()}
  def list_products(params \\ %{}, opts \\ []) do
    with {:ok, config} <- config(:list_products, opts) do
      request_pages(:list_products, config, "/products", params)
    end
  end

  defp request_one(operation, config, path) do
    guarded_request(operation, config, url(config, path, []))
  end

  defp request_pages(operation, config, path, params) do
    page_result =
      Enum.reduce_while(1..config.max_pages, {:continue, []}, fn page, {:continue, acc} ->
        query = page_query(params, page, config.per_page)

        case guarded_request(operation, config, url(config, path, query)) do
          {:ok, page_items} when is_list(page_items) ->
            acc = acc ++ page_items

            if length(page_items) < config.per_page do
              {:halt, {:done, acc}}
            else
              {:cont, {:continue, acc}}
            end

          {:ok, _not_a_list} ->
            {:halt, emit_exception(operation, :invalid_json)}

          {:error, %WooCommerceError{} = error} ->
            {:halt, {:error, error}}
        end
      end)

    case page_result do
      {:done, acc} -> {:ok, acc}
      {:continue, _acc} -> emit_exception(operation, :pagination_limit)
      other -> other
    end
  end

  defp guarded_request(operation, config, request_url) do
    RestCircuitBreaker.run(fn ->
      result =
        RestRateLimiter.checkout(
          fn -> execute_request(operation, config, request_url) end,
          queue_timeout_ms: config.queue_timeout_ms
        )

      case result do
        {:error, %WooCommerceError{reason: :queue_timeout}} ->
          emit_exception(operation, :queue_timeout)

        other ->
          other
      end
    end)
    |> case do
      {:error, %WooCommerceError{reason: :circuit_open}} ->
        emit_exception(operation, :circuit_open)

      other ->
        other
    end
  end

  defp execute_request(operation, config, request_url) do
    started_at = System.monotonic_time()
    headers = auth_headers(config)
    opts = [timeout_ms: config.timeout_ms]

    case config.transport.request(:get, request_url, headers, nil, opts) do
      {:ok, status, _headers, body} ->
        duration = System.monotonic_time() - started_at
        emit_stop(operation, status, duration)

        case decode_response(status, body) do
          {:error, %WooCommerceError{reason: :invalid_json}} ->
            emit_exception(operation, :invalid_json)

          other ->
            other
        end

      {:error, :timeout} ->
        emit_exception(operation, :timeout)

      {:error, _reason} ->
        emit_exception(operation, :transport_error)
    end
  end

  defp decode_response(status, body) when status in 200..299 do
    case Jason.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _error} -> {:error, WooCommerceError.exception(reason: :invalid_json)}
    end
  end

  defp decode_response(status, _body) do
    {:error, WooCommerceError.exception(reason: status_reason(status), status: status)}
  end

  defp status_reason(401), do: :unauthorized
  defp status_reason(403), do: :forbidden
  defp status_reason(404), do: :not_found
  defp status_reason(429), do: :rate_limited
  defp status_reason(status) when status in 400..499, do: :client_error
  defp status_reason(status) when status in 500..599, do: :server_error
  defp status_reason(_status), do: :transport_error

  defp normalize_positive_id(id, _operation) when is_integer(id) and id > 0, do: {:ok, id}

  defp normalize_positive_id(id, operation) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> emit_exception(operation, :invalid_request)
    end
  end

  defp normalize_positive_id(_id, operation), do: emit_exception(operation, :invalid_request)

  defp config(operation, opts) do
    app_config =
      :event_sales
      |> Application.get_env(:woocommerce_rest, [])
      |> Keyword.merge(opts)

    with {:ok, base_url} <- fetch_required(app_config, :base_url),
         {:ok, consumer_key} <- fetch_required(app_config, :consumer_key),
         {:ok, consumer_secret} <- fetch_required(app_config, :consumer_secret),
         :ok <- validate_base_url(base_url) do
      {:ok,
       %{
         base_url: trim_trailing_slash(base_url),
         consumer_key: consumer_key,
         consumer_secret: consumer_secret,
         timeout_ms: Keyword.get(app_config, :timeout_ms, @default_timeout_ms),
         queue_timeout_ms: Keyword.get(app_config, :queue_timeout_ms, @default_queue_timeout_ms),
         per_page: Keyword.get(app_config, :per_page, @default_per_page),
         max_pages: Keyword.get(app_config, :max_pages, @default_max_pages),
         transport: Keyword.get(app_config, :transport, HttpcTransport)
       }}
    else
      _error -> emit_exception(operation, :misconfigured)
    end
  end

  defp fetch_required(config, key) do
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

      app_env() == :prod and uri.scheme != "https" ->
        {:error, :invalid_prod_scheme}

      true ->
        :ok
    end
  end

  defp app_env do
    Application.get_env(:event_sales, :env, :dev)
  end

  defp url(config, path, []), do: config.base_url <> "/wp-json/wc/v3" <> path

  defp url(config, path, query) do
    config.base_url <> "/wp-json/wc/v3" <> path <> "?" <> URI.encode_query(query)
  end

  defp page_query(params, page, per_page) do
    [{"page", page}, {"per_page", per_page}] ++ normalize_query_params(params)
  end

  defp normalize_query_params(params) do
    params
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp auth_headers(config) do
    token = Base.encode64(config.consumer_key <> ":" <> config.consumer_secret)
    [{"authorization", "Basic " <> token}, {"accept", "application/json"}]
  end

  defp trim_trailing_slash(base_url), do: String.trim_trailing(base_url, "/")

  defp emit_stop(operation, status, duration) do
    Telemetry.emit(Telemetry.rest_request_stop(), %{count: 1, duration: duration}, %{
      operation: operation,
      status: status,
      source: :woocommerce
    })
  end

  defp emit_exception(operation, reason) do
    emit_exception(operation, reason, %{})
  end

  defp emit_exception(operation, reason, _extra) do
    Telemetry.emit(Telemetry.rest_request_exception(), %{count: 1}, %{
      operation: operation,
      reason: reason,
      source: :woocommerce
    })

    {:error, WooCommerceError.exception(reason: reason)}
  end
end
