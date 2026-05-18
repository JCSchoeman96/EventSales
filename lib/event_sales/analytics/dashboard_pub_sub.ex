defmodule EventSales.Analytics.DashboardPubSub do
  @moduledoc """
  Event-scoped PubSub helpers for dashboard hot-state updates.

  This module only wraps topic naming and PubSub calls. It intentionally does
  not introduce a global dashboard topic.
  """

  @doc "Returns the event-scoped dashboard topic."
  @spec event_topic(Ecto.UUID.t() | String.t()) :: String.t()
  def event_topic(event_id) when is_binary(event_id), do: "analytics:event:#{event_id}"

  @doc "Subscribes the caller to the event-scoped dashboard topic."
  @spec subscribe_event(Ecto.UUID.t() | String.t()) :: :ok | {:error, term()}
  def subscribe_event(event_id) when is_binary(event_id) do
    Phoenix.PubSub.subscribe(EventSales.PubSub, event_topic(event_id))
  end

  @doc "Broadcasts a hot-state update on the event-scoped dashboard topic."
  @spec broadcast_hot_state_updated(Ecto.UUID.t() | String.t(), DateTime.t()) :: :ok
  def broadcast_hot_state_updated(event_id, %DateTime{} = updated_at) when is_binary(event_id) do
    Phoenix.PubSub.broadcast(
      EventSales.PubSub,
      event_topic(event_id),
      {:hot_state_updated, event_id, updated_at}
    )
  end
end
