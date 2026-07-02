defmodule EventSales.Ingestion.RedisRateLimiterTest do
  use ExUnit.Case, async: true

  alias EventSales.Ingestion.RedisRateLimiter
  alias EventSales.TestSupport.Ingestion.MemoryRateLimiterAdapter

  setup do
    MemoryRateLimiterAdapter.reset_for_test!()
    on_exit(fn -> MemoryRateLimiterAdapter.reset_for_test!() end)
    :ok
  end

  test "allows requests within the configured window" do
    key = "router:test-ip:present"

    assert :ok = RedisRateLimiter.allow?(key, max_requests: 2, window_ms: 60_000, now_ms: 1_000)
    assert :ok = RedisRateLimiter.allow?(key, max_requests: 2, window_ms: 60_000, now_ms: 2_000)
  end

  test "blocks requests above the configured window" do
    key = "router:test-ip:present"

    assert :ok = RedisRateLimiter.allow?(key, max_requests: 1, window_ms: 60_000, now_ms: 1_000)

    assert {:error, :rate_limited} =
             RedisRateLimiter.allow?(key, max_requests: 1, window_ms: 60_000, now_ms: 2_000)
  end

  test "resets after the window elapses" do
    key = "router:test-ip:present"

    assert :ok = RedisRateLimiter.allow?(key, max_requests: 1, window_ms: 1_000, now_ms: 1_000)

    assert {:error, :rate_limited} =
             RedisRateLimiter.allow?(key, max_requests: 1, window_ms: 1_000, now_ms: 1_500)

    assert :ok = RedisRateLimiter.allow?(key, max_requests: 1, window_ms: 1_000, now_ms: 2_001)
  end

  test "webhook_key never includes raw token values" do
    key =
      RedisRateLimiter.webhook_key(
        {127, 0, 0, 1},
        :present,
        "router"
      )

    refute key =~ "secret-token"
    assert key =~ "router:"
    assert key =~ "present"
  end
end
