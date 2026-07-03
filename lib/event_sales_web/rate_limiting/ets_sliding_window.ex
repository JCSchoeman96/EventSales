defmodule EventSalesWeb.RateLimiting.EtsSlidingWindow do
  @moduledoc """
  Small ETS-backed sliding window limiter for low-volume HTTP boundaries.
  """

  @table __MODULE__.Table

  @spec allow?(String.t(), keyword()) :: :ok | {:error, :rate_limited}
  def allow?(key, opts \\ []) when is_binary(key) do
    ensure_table!()

    window_ms = Keyword.get(opts, :window_ms, 30_000)
    max_requests = Keyword.get(opts, :max_requests, 10)
    now_ms = Keyword.get_lazy(opts, :now_ms, fn -> System.system_time(:millisecond) end)
    cutoff = now_ms - window_ms

    entries =
      case :ets.lookup(@table, key) do
        [{^key, timestamps}] -> Enum.filter(timestamps, &(&1 > cutoff))
        [] -> []
      end

    if length(entries) >= max_requests do
      {:error, :rate_limited}
    else
      :ets.insert(@table, {key, [now_ms | entries]})
      :ok
    end
  end

  @spec reset_for_test!() :: :ok
  def reset_for_test! do
    case :ets.whereis(@table) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end
  end

  defp ensure_table! do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
      _table -> @table
    end
  end
end
