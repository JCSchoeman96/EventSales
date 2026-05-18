defmodule EventSales.Analytics.DashboardPubSubTest do
  use ExUnit.Case, async: false

  alias EventSales.Analytics.DashboardPubSub

  @event_id "0a701836-b78d-4fe4-9b30-3f2618093e20"

  test "event topic includes the event scope" do
    assert DashboardPubSub.event_topic(@event_id) == "analytics:event:#{@event_id}"
  end

  test "subscribe_event subscribes the caller to the event topic" do
    assert :ok = DashboardPubSub.subscribe_event(@event_id)

    updated_at = DateTime.utc_now()

    Phoenix.PubSub.broadcast(
      EventSales.PubSub,
      DashboardPubSub.event_topic(@event_id),
      {:hot_state_updated, @event_id, updated_at}
    )

    assert_receive {:hot_state_updated, @event_id, ^updated_at}, 500
  end
end
