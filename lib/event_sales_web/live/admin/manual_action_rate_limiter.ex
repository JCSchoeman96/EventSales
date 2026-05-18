defmodule EventSalesWeb.Live.Admin.ManualActionRateLimiter do
  @moduledoc """
  Small ETS-backed rate limiter for admin LiveView manual actions.
  """

  @table __MODULE__.Table
  @default_window_ms 30_000

  @doc "Allows one action per user/action key inside the configured window."
  @spec allow?(String.t(), atom(), keyword()) :: :ok | {:error, :rate_limited}
  def allow?(user_id, action, opts \\ []) when is_binary(user_id) and is_atom(action) do
    ensure_table!()

    key = {user_id, action}
    now_ms = Keyword.get_lazy(opts, :now_ms, &monotonic_ms/0)
    window_ms = Keyword.get(opts, :window_ms, @default_window_ms)

    case :ets.lookup(@table, key) do
      [{^key, last_seen_ms}] when now_ms - last_seen_ms < window_ms ->
        {:error, :rate_limited}

      _other ->
        :ets.insert(@table, {key, now_ms})
        :ok
    end
  end

  @doc false
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

  defp monotonic_ms, do: System.monotonic_time(:millisecond)
end
