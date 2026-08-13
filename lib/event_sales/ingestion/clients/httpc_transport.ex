defmodule EventSales.Ingestion.Clients.HttpcTransport do
  @moduledoc """
  `:httpc` transport for WooCommerce REST requests.

  Production configuration requires HTTPS before this transport is called. This
  module does not disable TLS verification.
  """

  @behaviour EventSales.Ingestion.Clients.WooCommerceTransport

  @impl true
  def request(:get, url, headers, nil, opts) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    request = {String.to_charlist(url), charlist_headers(headers)}
    http_options = [timeout: timeout_ms, connect_timeout: timeout_ms]
    options = [body_format: :binary]

    case :httpc.request(:get, request, http_options, options) do
      {:ok, {{_version, status, _reason}, response_headers, body}} ->
        {:ok, status, normalize_headers(response_headers), body}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, {:failed_connect, _details}} ->
        {:error, :econnrefused}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def request(:post, url, headers, body, opts) when is_binary(body) do
    timeout_ms = Keyword.fetch!(opts, :timeout_ms)
    request = {String.to_charlist(url), charlist_headers(headers), ~c"application/json", body}
    http_options = [timeout: timeout_ms, connect_timeout: timeout_ms]
    options = [body_format: :binary]

    case :httpc.request(:post, request, http_options, options) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        {:ok, status, normalize_headers(response_headers), response_body}

      {:error, :timeout} ->
        {:error, :timeout}

      {:error, {:failed_connect, _details}} ->
        {:error, :econnrefused}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp charlist_headers(headers) do
    Enum.map(headers, fn {key, value} -> {String.to_charlist(key), String.to_charlist(value)} end)
  end

  defp normalize_headers(headers) do
    Enum.map(headers, fn {key, value} -> {to_string(key), to_string(value)} end)
  end
end
