defmodule EventSales.Analytics.DashboardCache do
  @moduledoc """
  Facade for dashboard hot cache access.

  `EventSales.Analytics.HotStateAggregator` owns the ETS table lifecycle. This
  module only reads and writes the named table when it exists.
  """

  alias EventSales.Analytics.CacheKeys

  @table __MODULE__.Table

  @doc false
  @spec table_name() :: atom()
  def table_name, do: @table

  @doc false
  @spec ensure_table!() :: atom()
  def ensure_table! do
    case :ets.whereis(@table) do
      :undefined -> :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
      _table -> @table
    end

    @table
  end

  @doc false
  @spec delete_table_for_test!() :: :ok
  def delete_table_for_test! do
    case :ets.whereis(@table) do
      :undefined -> :ok
      _table -> :ets.delete(@table)
    end
  end

  @doc "Returns the current hot event summary."
  @spec get_event_summary(Ecto.UUID.t() | String.t()) :: {:ok, map()} | :miss
  def get_event_summary(event_id) when is_binary(event_id) do
    with table when table != :undefined <- :ets.whereis(@table),
         [{_key, summary}] <- :ets.lookup(table, CacheKeys.event_summary(event_id)) do
      {:ok, summary}
    else
      _ -> :miss
    end
  end

  @doc "Writes an event summary to the hot cache if the table exists."
  @spec put_event_summary(Ecto.UUID.t() | String.t(), map(), keyword()) ::
          :ok | {:error, :unavailable}
  def put_event_summary(event_id, summary, _opts \\ [])
      when is_binary(event_id) and is_map(summary) do
    case :ets.whereis(@table) do
      :undefined ->
        {:error, :unavailable}

      table ->
        :ets.insert(table, {CacheKeys.event_summary(event_id), summary})
        :ok
    end
  end

  @doc "Invalidates an event summary from the hot cache."
  @spec invalidate_event(Ecto.UUID.t() | String.t(), atom()) :: :ok
  def invalidate_event(event_id, _reason) when is_binary(event_id) do
    case :ets.whereis(@table) do
      :undefined ->
        :ok

      table ->
        :ets.delete(table, CacheKeys.event_summary(event_id))
        :ok
    end
  end
end
