defmodule EventSales.Ingestion.Clients.WooCommerceClientTest do
  use ExUnit.Case, async: false

  alias EventSales.Ingestion.Clients.WooCommerceClient
  alias EventSales.Ingestion.Clients.WooCommerceError

  defmodule FakeTransport do
    @behaviour EventSales.Ingestion.Clients.WooCommerceTransport

    def child_spec(opts) do
      %{
        id: __MODULE__,
        start: {__MODULE__, :start_link, [opts]}
      }
    end

    def start_link(_opts),
      do: Agent.start_link(fn -> %{responses: [], requests: []} end, name: __MODULE__)

    def reset!(responses) do
      Agent.update(__MODULE__, fn _ -> %{responses: responses, requests: []} end)
    end

    def requests do
      Agent.get(__MODULE__, &Enum.reverse(&1.requests))
    end

    @impl true
    def request(method, url, headers, body, opts) do
      Agent.get_and_update(__MODULE__, fn %{responses: [response | rest], requests: requests} =
                                            state ->
        request = %{method: method, url: url, headers: headers, body: body, opts: opts}
        {response, %{state | responses: rest, requests: [request | requests]}}
      end)
    end
  end

  setup do
    start_supervised!(FakeTransport)
    original_config = Application.get_env(:event_sales, :woocommerce_rest)
    original_env = Application.get_env(:event_sales, :env)
    original_breaker = Application.get_env(:event_sales, :rest_circuit_breaker)

    Application.put_env(:event_sales, :env, :test)

    Application.put_env(:event_sales, :rest_circuit_breaker,
      failure_threshold: 3,
      cooldown_ms: 50
    )

    Application.put_env(:event_sales, :woocommerce_rest,
      base_url: "https://woo.example.test",
      consumer_key: "ck_test_secret",
      consumer_secret: "cs_test_secret",
      timeout_ms: 1_000,
      queue_timeout_ms: 1_000,
      per_page: 2,
      max_pages: 3,
      transport: FakeTransport
    )

    EventSales.Ingestion.RestRateLimiter.reset_for_test!(max_concurrency: 2)
    EventSales.Ingestion.RestCircuitBreaker.reset_for_test!()

    on_exit(fn ->
      restore_env(:woocommerce_rest, original_config)
      restore_env(:env, original_env)
      restore_env(:rest_circuit_breaker, original_breaker)
      EventSales.Ingestion.RestRateLimiter.reset_for_test!(max_concurrency: 2)
      EventSales.Ingestion.RestCircuitBreaker.reset_for_test!()
    end)

    :ok
  end

  test "fetch_order accepts positive integer ids and returns decoded order data" do
    FakeTransport.reset!([{:ok, 200, [], ~s({"id":123,"status":"completed"})}])

    assert {:ok, %{"id" => 123, "status" => "completed"}} = WooCommerceClient.fetch_order(123)

    assert [
             %{
               method: :get,
               url: "https://woo.example.test/wp-json/wc/v3/orders/123",
               headers: headers,
               body: nil
             }
           ] = FakeTransport.requests()

    assert {"authorization", "Basic " <> _encoded} = List.keyfind(headers, "authorization", 0)
  end

  test "fetch_product accepts positive numeric string ids and returns decoded product data" do
    FakeTransport.reset!([{:ok, 200, [], ~s({"id":456,"name":"VIP Ticket"})}])

    assert {:ok, %{"id" => 456, "name" => "VIP Ticket"}} = WooCommerceClient.fetch_product("456")

    assert [%{url: "https://woo.example.test/wp-json/wc/v3/products/456"}] =
             FakeTransport.requests()
  end

  test "fetch_order rejects invalid ids before transport" do
    FakeTransport.reset!([{:ok, 200, [], ~s({"id":1})}])

    for bad_id <- [0, -1, "0", "-1", "abc", "1/../../customers", nil] do
      assert {:error, %WooCommerceError{reason: :invalid_request}} =
               WooCommerceClient.fetch_order(bad_id)
    end

    assert [] = FakeTransport.requests()
  end

  test "list_orders paginates until a short page" do
    FakeTransport.reset!([
      {:ok, 200, [], Jason.encode!([%{id: 1}, %{id: 2}])},
      {:ok, 200, [], Jason.encode!([%{id: 3}])}
    ])

    assert {:ok, [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}]} =
             WooCommerceClient.list_orders(%{"status" => "completed"})

    assert [
             %{
               url:
                 "https://woo.example.test/wp-json/wc/v3/orders?page=1&per_page=2&status=completed"
             },
             %{
               url:
                 "https://woo.example.test/wp-json/wc/v3/orders?page=2&per_page=2&status=completed"
             }
           ] = FakeTransport.requests()
  end

  test "list_products stops at max_pages with a typed pagination error" do
    FakeTransport.reset!([
      {:ok, 200, [], Jason.encode!([%{id: 1}, %{id: 2}])},
      {:ok, 200, [], Jason.encode!([%{id: 3}, %{id: 4}])},
      {:ok, 200, [], Jason.encode!([%{id: 5}, %{id: 6}])}
    ])

    assert {:error, %WooCommerceError{reason: :pagination_limit}} =
             WooCommerceClient.list_products(%{})
  end

  test "maps HTTP statuses and transport failures to typed errors" do
    cases = [
      {{:ok, 401, [], "{}"}, :unauthorized},
      {{:ok, 403, [], "{}"}, :forbidden},
      {{:ok, 404, [], "{}"}, :not_found},
      {{:ok, 429, [], "{}"}, :rate_limited},
      {{:ok, 418, [], "{}"}, :client_error},
      {{:ok, 500, [], "{}"}, :server_error},
      {{:error, :timeout}, :timeout},
      {{:error, :econnrefused}, :transport_error},
      {{:ok, 200, [], "not json"}, :invalid_json}
    ]

    for {response, reason} <- cases do
      EventSales.Ingestion.RestCircuitBreaker.reset_for_test!()
      FakeTransport.reset!([response])

      assert {:error, %WooCommerceError{reason: ^reason}} = WooCommerceClient.fetch_order(123)
    end
  end

  test "missing and invalid production config return misconfigured before transport" do
    FakeTransport.reset!([{:ok, 200, [], ~s({"id":123})}])

    Application.put_env(:event_sales, :woocommerce_rest, [])

    assert {:error, %WooCommerceError{reason: :misconfigured}} =
             WooCommerceClient.fetch_order(123)

    Application.put_env(:event_sales, :env, :prod)

    Application.put_env(:event_sales, :woocommerce_rest,
      base_url: "http://woo.example.test",
      consumer_key: "ck_test_secret",
      consumer_secret: "cs_test_secret",
      transport: FakeTransport
    )

    assert {:error, %WooCommerceError{reason: :misconfigured}} =
             WooCommerceClient.fetch_order(123)

    assert [] = FakeTransport.requests()
  end

  test "telemetry omits credentials, ids, bodies, and full URLs" do
    FakeTransport.reset!([{:ok, 200, [], ~s({"id":123})}])
    test_pid = self()
    handler_id = "woo-client-telemetry-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      EventSales.Telemetry.rest_request_stop(),
      fn _event, measurements, metadata, _config ->
        send(test_pid, {:telemetry, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, %{"id" => 123}} = WooCommerceClient.fetch_order(123)
    assert_receive {:telemetry, %{count: 1, duration: duration}, metadata}
    assert is_integer(duration)
    assert metadata == %{operation: :fetch_order, status: 200, source: :woocommerce}

    refute inspect(metadata) =~ "ck_test_secret"
    refute inspect(metadata) =~ "cs_test_secret"
    refute inspect(metadata) =~ "authorization"
    refute inspect(metadata) =~ "123"
    refute inspect(metadata) =~ "woo.example.test"
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)
end
