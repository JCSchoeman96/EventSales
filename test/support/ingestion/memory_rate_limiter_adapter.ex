defmodule EventSales.TestSupport.Ingestion.MemoryRateLimiterAdapter do
  @moduledoc false

  @behaviour EventSales.Ingestion.RedisRateLimiter.Adapter

  @table __MODULE__

  @impl true
  def allow?(key, opts) when is_binary(key) do
    table = ensure_table!()
    window_ms = Keyword.fetch!(opts, :window_ms)
    max_requests = Keyword.fetch!(opts, :max_requests)
    storage_key = storage_key(key, opts)
    now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)
    cutoff = now_ms - window_ms

    entries =
      case :ets.lookup(table, storage_key) do
        [{^storage_key, timestamps}] -> Enum.filter(timestamps, &(&1 > cutoff))
        [] -> []
      end

    if length(entries) >= max_requests do
      {:error, :rate_limited}
    else
      :ets.insert(table, {storage_key, [now_ms | entries]})
      :ok
    end
  end

  @impl true
  def reset_for_test! do
    case :ets.whereis(@table) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end
  end

  @impl true
  def saturate_for_test!(key, opts) when is_binary(key) do
    table = ensure_table!()
    max_requests = Keyword.fetch!(opts, :max_requests)
    storage_key = storage_key(key, opts)
    now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)

    entries =
      for offset <- 0..(max_requests - 1) do
        now_ms - offset
      end

    :ets.insert(table, {storage_key, entries})
    :ok
  end

  defp storage_key(key, opts) do
    key_prefix = Keyword.fetch!(opts, :key_prefix)
    "#{key_prefix}:#{key}"
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
        rescue
          ArgumentError -> :ok
        end

        @table

      table ->
        table
    end
  end
end
