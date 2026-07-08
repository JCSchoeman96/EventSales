defmodule EventSales.Catalog.EventLifecycleTest do
  use ExUnit.Case, async: true

  alias EventSales.Catalog.EventLifecycle

  @now ~U[2026-07-08 12:00:00Z]

  test "classifies future events" do
    event = %{starts_at: ~U[2026-07-09 12:00:00Z], ends_at: ~U[2026-07-09 14:00:00Z]}

    assert EventLifecycle.classify(event, @now) == :future
    assert EventLifecycle.current_bucket?(event, @now)
    refute EventLifecycle.past?(event, @now)
  end

  test "classifies current events" do
    event = %{starts_at: ~U[2026-07-08 10:00:00Z], ends_at: ~U[2026-07-08 14:00:00Z]}

    assert EventLifecycle.classify(event, @now) == :current
    assert EventLifecycle.current_bucket?(event, @now)
    refute EventLifecycle.past?(event, @now)
  end

  test "classifies past events" do
    event = %{starts_at: ~U[2026-07-07 10:00:00Z], ends_at: ~U[2026-07-07 14:00:00Z]}

    assert EventLifecycle.classify(event, @now) == :past
    refute EventLifecycle.current_bucket?(event, @now)
    assert EventLifecycle.past?(event, @now)
  end

  test "classifies missing start or end as unknown" do
    assert EventLifecycle.classify(%{starts_at: nil, ends_at: ~U[2026-07-08 14:00:00Z]}, @now) ==
             :unknown

    assert EventLifecycle.classify(%{starts_at: ~U[2026-07-08 10:00:00Z], ends_at: nil}, @now) ==
             :unknown

    assert EventLifecycle.current_bucket?(%{starts_at: nil, ends_at: nil}, @now)
  end
end
