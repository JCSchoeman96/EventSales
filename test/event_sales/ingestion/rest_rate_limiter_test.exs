defmodule EventSales.Ingestion.RestRateLimiterTest do
  use ExUnit.Case, async: false

  alias EventSales.Ingestion.Clients.WooCommerceError
  alias EventSales.Ingestion.RestRateLimiter

  setup do
    RestRateLimiter.reset_for_test!(max_concurrency: 2)

    on_exit(fn ->
      RestRateLimiter.reset_for_test!(max_concurrency: 2)
    end)

    :ok
  end

  test "checkout never allows more than two concurrent callers" do
    parent = self()

    tasks =
      for _ <- 1..5 do
        Task.async(fn ->
          RestRateLimiter.checkout(
            fn ->
              send(parent, {:entered, self(), RestRateLimiter.snapshot()})

              receive do
                :release -> :ok
              after
                1_000 -> flunk("test did not release limiter caller")
              end
            end,
            queue_timeout_ms: 1_000
          )
        end)
      end

    first = wait_for_entered(2)
    refute_receive {:entered, _pid, _snapshot}, 50

    for {pid, %{active: active}} <- first do
      assert active <= 2
      send(pid, :release)
    end

    next_two = wait_for_entered(2)
    refute_receive {:entered, _pid, _snapshot}, 50

    for {pid, %{active: active}} <- next_two do
      assert active <= 2
      send(pid, :release)
    end

    final = wait_for_entered(1)

    for {pid, %{active: active}} <- final do
      assert active <= 2
      send(pid, :release)
    end

    assert Enum.all?(Task.await_many(tasks), &(&1 == :ok))
  end

  test "queued callers time out with typed queue timeout errors" do
    parent = self()

    holders =
      for _ <- 1..2 do
        Task.async(fn ->
          RestRateLimiter.checkout(fn ->
            send(parent, {:holder_entered, self()})

            receive do
              :release -> :ok
            after
              1_000 -> flunk("test did not release holder")
            end
          end)
        end)
      end

    holder_pids =
      for _ <- 1..2 do
        assert_receive {:holder_entered, pid}
        pid
      end

    assert {:error, %WooCommerceError{reason: :queue_timeout}} =
             RestRateLimiter.checkout(fn -> :unexpected end, queue_timeout_ms: 10)

    for pid <- holder_pids, do: send(pid, :release)
    assert Enum.all?(Task.await_many(holders), &(&1 == :ok))
  end

  test "permits are released after success, typed error, raise, throw, and exit" do
    assert :ok = RestRateLimiter.checkout(fn -> :ok end)

    assert {:error, %WooCommerceError{reason: :timeout}} =
             RestRateLimiter.checkout(fn ->
               {:error, %WooCommerceError{reason: :timeout}}
             end)

    assert_raise RuntimeError, "boom", fn ->
      RestRateLimiter.checkout(fn -> raise "boom" end)
    end

    assert catch_throw(RestRateLimiter.checkout(fn -> throw(:thrown) end)) == :thrown
    assert catch_exit(RestRateLimiter.checkout(fn -> exit(:stopped) end)) == :stopped
    assert %{active: 0, queued: 0, max_concurrency: 2} = RestRateLimiter.snapshot()
  end

  defp wait_for_entered(count), do: wait_for_entered(count, [])

  defp wait_for_entered(0, acc), do: Enum.reverse(acc)

  defp wait_for_entered(count, acc) do
    receive do
      {:entered, pid, snapshot} -> wait_for_entered(count - 1, [{pid, snapshot} | acc])
    after
      1_000 -> flunk("expected #{count} more limiter callers to enter")
    end
  end
end
