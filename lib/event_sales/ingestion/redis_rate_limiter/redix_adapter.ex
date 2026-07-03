defmodule EventSales.Ingestion.RedisRateLimiter.RedixAdapter do
  @moduledoc false

  @behaviour EventSales.Ingestion.RedisRateLimiter.Adapter

  @impl true
  def allow?(key, opts) when is_binary(key) do
    window_ms = Keyword.fetch!(opts, :window_ms)
    max_requests = Keyword.fetch!(opts, :max_requests)
    key_prefix = Keyword.fetch!(opts, :key_prefix)
    redis_key = "#{key_prefix}:#{key}"
    now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)
    window_start = now_ms - window_ms
    member = "#{now_ms}:#{:erlang.unique_integer([:positive])}"

    case Redix.transaction_pipeline(redix_name(), [
           ["ZREMRANGEBYSCORE", redis_key, "-inf", window_start],
           ["ZADD", redis_key, now_ms, member],
           ["ZCARD", redis_key],
           ["PEXPIRE", redis_key, window_ms]
         ]) do
      {:ok, [_removed, _added, count, _expire]} when is_integer(count) ->
        if count > max_requests do
          _ = Redix.command(redix_name(), ["ZREM", redis_key, member])
          {:error, :rate_limited}
        else
          :ok
        end

      {:error, _reason} ->
        {:error, :unavailable}
    end
  end

  @impl true
  def reset_for_test!, do: :ok

  @impl true
  def saturate_for_test!(_key, _opts), do: :ok

  defp redix_name, do: EventSales.Ingestion.RedisRateLimiter.redix_name()
end
