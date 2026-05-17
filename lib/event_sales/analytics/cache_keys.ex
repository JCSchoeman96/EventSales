defmodule EventSales.Analytics.CacheKeys do
  @moduledoc """
  Namespaced cache keys for analytics hot and warm read models.
  """

  @prefix "eventsales:analytics:hot_state:v1"

  @doc "Returns the ETS key for an event summary."
  @spec event_summary(Ecto.UUID.t() | String.t()) :: tuple()
  def event_summary(event_id) when is_binary(event_id) do
    {:eventsales, :analytics, :hot_state, :v1, :event_summary, event_id}
  end

  @doc "Returns the Redis key for an event warm snapshot."
  @spec redis_event_snapshot(Ecto.UUID.t() | String.t()) :: String.t()
  def redis_event_snapshot(event_id) when is_binary(event_id) do
    "#{@prefix}:event:#{event_id}:summary"
  end
end
