defmodule EventSales.Analytics.CacheKeys do
  @moduledoc """
  Namespaced cache keys for analytics hot and warm read models.
  """

  @doc "Returns the ETS key for an event summary."
  @spec event_summary(Ecto.UUID.t() | String.t()) :: tuple()
  def event_summary(event_id) when is_binary(event_id) do
    {:eventsales, :analytics, :hot_state, :v1, :event_summary, event_id}
  end

  @doc "Returns the Redis key for an event warm snapshot."
  @spec redis_event_snapshot(Ecto.UUID.t() | String.t()) :: String.t()
  def redis_event_snapshot(event_id) when is_binary(event_id) do
    "#{redis_event_snapshot_prefix()}#{event_id}:summary"
  end

  @doc false
  @spec redis_event_snapshot_prefix() :: String.t()
  def redis_event_snapshot_prefix do
    namespace = Application.get_env(:event_sales, :redis_namespace, "eventsales:unknown")
    "#{namespace}:analytics:hot_state:v1:event:"
  end
end
