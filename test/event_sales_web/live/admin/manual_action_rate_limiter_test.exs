defmodule EventSalesWeb.Live.Admin.ManualActionRateLimiterTest do
  use ExUnit.Case, async: false

  alias EventSalesWeb.Live.Admin.ManualActionRateLimiter

  setup do
    ManualActionRateLimiter.reset_for_test!()
    on_exit(fn -> ManualActionRateLimiter.reset_for_test!() end)
    :ok
  end

  test "allows one action per user and action within the configured window" do
    assert :ok = ManualActionRateLimiter.allow?("user-1", :dashboard_refresh, now_ms: 1_000)

    assert {:error, :rate_limited} =
             ManualActionRateLimiter.allow?("user-1", :dashboard_refresh, now_ms: 1_500)

    assert :ok = ManualActionRateLimiter.allow?("user-1", :dashboard_refresh, now_ms: 31_001)
  end

  test "rate limit is keyed by user id" do
    assert :ok = ManualActionRateLimiter.allow?("user-1", :dashboard_refresh, now_ms: 1_000)
    assert :ok = ManualActionRateLimiter.allow?("user-2", :dashboard_refresh, now_ms: 1_500)
  end
end
