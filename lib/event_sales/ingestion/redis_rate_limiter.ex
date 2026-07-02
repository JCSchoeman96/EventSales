defmodule EventSales.Ingestion.RedisRateLimiter do
  @moduledoc """
  Shared Redis-backed sliding-window rate limiter for high-velocity boundaries.
  """

  alias EventSales.Ingestion.Security.LowCardinalityKey

  @redix_name :event_sales_rate_limit_redis

  @doc false
  @spec redix_name() :: atom()
  def redix_name, do: @redix_name

  @doc """
  Returns `:ok` when the request is within the configured window, otherwise
  `{:error, :rate_limited}` or `{:error, :unavailable}` when Redis is required
  but unreachable.
  """
  @spec allow?(String.t(), keyword()) :: :ok | {:error, :rate_limited | :unavailable | :disabled}
  def allow?(key, opts \\ []) when is_binary(key) do
    with :ok <- gate_enabled(),
         {:ok, limit_opts} <- limit_opts(opts) do
      adapter_module().allow?(key, limit_opts)
    end
  end

  @doc """
  Builds a low-cardinality limiter key from hashed remote IP and token presence.
  """
  @spec webhook_key(term(), :present | :missing, String.t()) :: String.t()
  def webhook_key(remote_ip, token_presence, scope) when is_binary(scope) do
    [
      scope,
      LowCardinalityKey.hash_remote_ip(remote_ip),
      token_presence
    ]
    |> Enum.join(":")
  end

  @doc false
  @spec reset_for_test!() :: :ok
  def reset_for_test! do
    adapter_module().reset_for_test!()
    :ok
  end

  @doc false
  @spec saturate_for_test!(String.t(), keyword()) :: :ok
  def saturate_for_test!(key, opts \\ []) when is_binary(key) do
    with {:ok, limit_opts} <- limit_opts(opts) do
      adapter_module().saturate_for_test!(key, limit_opts)
      :ok
    end
  end

  defp gate_enabled do
    if Keyword.get(config(), :enabled, true), do: :ok, else: {:error, :disabled}
  end

  defp limit_opts(overrides) do
    window_ms = Keyword.get(overrides, :window_ms, config_value(:window_ms, 60_000))
    max_requests = Keyword.get(overrides, :max_requests, config_value(:max_requests, 120))

    if window_ms > 0 and max_requests > 0 do
      {:ok,
       [
         window_ms: window_ms,
         max_requests: max_requests,
         key_prefix: config_value(:key_prefix, "eventsales:webhook_rate_limit:v1")
       ] ++ overrides}
    else
      {:error, :disabled}
    end
  end

  defp config, do: Application.get_env(:event_sales, :webhook_intake_rate_limit, [])

  defp config_value(key, default) do
    config() |> Keyword.get(key, default)
  end

  defp adapter_module do
    config() |> Keyword.get(:adapter, EventSales.Ingestion.RedisRateLimiter.RedixAdapter)
  end
end
