defmodule EventSales.Ingestion.RestCircuitBreakerTest do
  use ExUnit.Case, async: false

  alias EventSales.Ingestion.Clients.WooCommerceError
  alias EventSales.Ingestion.RestCircuitBreaker

  setup do
    original_config = Application.get_env(:event_sales, :rest_circuit_breaker)

    Application.put_env(:event_sales, :rest_circuit_breaker,
      failure_threshold: 3,
      cooldown_ms: 25
    )

    RestCircuitBreaker.reset_for_test!()

    on_exit(fn ->
      restore_env(:rest_circuit_breaker, original_config)
      RestCircuitBreaker.reset_for_test!()
    end)

    :ok
  end

  test "repeated retryable failures open the breaker" do
    for _ <- 1..3 do
      assert {:error, %WooCommerceError{reason: :server_error}} =
               RestCircuitBreaker.run(fn ->
                 {:error, %WooCommerceError{reason: :server_error}}
               end)
    end

    assert %{state: :open, failures: 3} = RestCircuitBreaker.snapshot()

    assert {:error, %WooCommerceError{reason: :circuit_open}} =
             RestCircuitBreaker.run(fn -> :unexpected end)
  end

  test "local queue timeout and misconfigured errors do not open the breaker" do
    for reason <- [:queue_timeout, :misconfigured, :invalid_request, :pagination_limit] do
      assert {:error, %WooCommerceError{reason: ^reason}} =
               RestCircuitBreaker.run(fn ->
                 {:error, %WooCommerceError{reason: reason}}
               end)
    end

    assert %{state: :closed, failures: 0} = RestCircuitBreaker.snapshot()
  end

  test "half-open allows exactly one probe after cooldown" do
    open_breaker()
    Process.sleep(30)

    parent = self()

    probe =
      Task.async(fn ->
        RestCircuitBreaker.run(fn ->
          send(parent, {:probe_started, self()})

          receive do
            :finish -> {:ok, :probe}
          after
            1_000 -> flunk("test did not finish probe")
          end
        end)
      end)

    assert_receive {:probe_started, probe_pid}

    assert {:error, %WooCommerceError{reason: :circuit_open}} =
             RestCircuitBreaker.run(fn -> {:ok, :second_probe} end)

    send(probe_pid, :finish)
    assert {:ok, :probe} = Task.await(probe)
    assert %{state: :closed, failures: 0} = RestCircuitBreaker.snapshot()
  end

  test "half-open probe failure reopens the breaker" do
    open_breaker()
    Process.sleep(30)

    assert {:error, %WooCommerceError{reason: :timeout}} =
             RestCircuitBreaker.run(fn ->
               {:error, %WooCommerceError{reason: :timeout}}
             end)

    assert %{state: :open} = RestCircuitBreaker.snapshot()
  end

  test "half-open local queue timeout does not close the breaker" do
    open_breaker()
    Process.sleep(30)

    assert {:error, %WooCommerceError{reason: :queue_timeout}} =
             RestCircuitBreaker.run(fn ->
               {:error, %WooCommerceError{reason: :queue_timeout}}
             end)

    assert %{state: :open} = RestCircuitBreaker.snapshot()
  end

  defp open_breaker do
    for _ <- 1..3 do
      RestCircuitBreaker.run(fn -> {:error, %WooCommerceError{reason: :timeout}} end)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)
end
