defmodule EventSales.Catalog.TickeraCatalog.WordPressFeedClientTest do
  use ExUnit.Case, async: false

  alias EventSales.Catalog.TickeraCatalog.WordPressFeedClient
  alias EventSales.Ingestion.Clients.WooCommerceTransport

  defmodule FakeTransport do
    @behaviour WooCommerceTransport

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

    def requests, do: Agent.get(__MODULE__, &Enum.reverse(&1.requests))

    @impl true
    def request(method, url, headers, body, opts) do
      Agent.get_and_update(__MODULE__, fn %{responses: [response | rest], requests: requests} =
                                            state ->
        request = %{method: method, url: url, headers: headers, body: body, opts: opts}
        {response, %{state | responses: rest, requests: [request | requests]}}
      end)
      |> case do
        {:raise, message} -> raise message
        response -> response
      end
    end
  end

  setup do
    start_supervised!(FakeTransport)
    original_feed = Application.get_env(:event_sales, :tickera_catalog_feed)
    original_env = Application.get_env(:event_sales, :env)

    Application.put_env(:event_sales, :env, :test)

    Application.put_env(:event_sales, :tickera_catalog_feed,
      base_url: "https://wordpress.example.test",
      secret: "test-feed-secret",
      timeout_ms: 1_000,
      per_page: 2,
      max_pages: 3,
      path: "/wp-json/eventsales/v1/tickera-catalog",
      transport: FakeTransport
    )

    on_exit(fn ->
      restore_env(:tickera_catalog_feed, original_feed)
      restore_env(:env, original_env)
    end)

    :ok
  end

  test "fetch_page signs and sends a bounded GET request" do
    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(page_response(page: 1, has_more: false))}])

    assert {:ok, page} = WordPressFeedClient.fetch_page(%{"product_id" => 109_740}, 1)
    assert page.page == 1

    assert [
             %{
               method: :get,
               url:
                 "https://wordpress.example.test/wp-json/eventsales/v1/tickera-catalog?page=1&per_page=2&product_id=109740",
               headers: headers,
               body: nil,
               opts: [timeout_ms: 1_000]
             }
           ] = FakeTransport.requests()

    assert {"x-eventsales-timestamp", timestamp} =
             List.keyfind(headers, "x-eventsales-timestamp", 0)

    assert String.match?(timestamp, ~r/^\d+$/)

    assert {"x-eventsales-signature", "v1=" <> signature} =
             List.keyfind(headers, "x-eventsales-signature", 0)

    assert byte_size(signature) == 64
  end

  test "fetch aggregates pages until has_more is false" do
    FakeTransport.reset!([
      {:ok, 200, [], Jason.encode!(page_response(page: 1, has_more: true))},
      {:ok, 200, [], Jason.encode!(page_response(page: 2, product_id: 109_741))}
    ])

    assert {:ok, aggregate} = WordPressFeedClient.fetch(%{"mode" => "full"})
    assert Enum.map(aggregate.catalog_rows, & &1["woo_product_id"]) == [109_740, 109_741]
    assert length(FakeTransport.requests()) == 2
  end

  test "fetch stops at max_pages" do
    FakeTransport.reset!([
      {:ok, 200, [], Jason.encode!(page_response(page: 1, has_more: true))},
      {:ok, 200, [], Jason.encode!(page_response(page: 2, has_more: true))},
      {:ok, 200, [], Jason.encode!(page_response(page: 3, has_more: true))}
    ])

    assert {:error, :pagination_limit} = WordPressFeedClient.fetch(%{"mode" => "full"})
  end

  test "maps status, transport, and decode errors to safe atoms" do
    cases = [
      {{:ok, 400, [], "{}"}, :invalid_request},
      {{:ok, 401, [], "{}"}, :unauthorized},
      {{:ok, 403, [], "{}"}, :forbidden},
      {{:ok, 404, [], "{}"}, :not_found},
      {{:ok, 429, [], "{}"}, :rate_limited},
      {{:ok, 500, [], "{}"}, :server_error},
      {{:error, :timeout}, :timeout},
      {{:error, :econnrefused}, :transport_error},
      {{:ok, 200, [], "not json"}, :invalid_json},
      {{:ok, 200, [], Jason.encode!(%{"schema_version" => "wrong"})}, :invalid_feed_response}
    ]

    for {response, reason} <- cases do
      FakeTransport.reset!([response])
      assert {:error, ^reason} = WordPressFeedClient.fetch_page(%{}, 1)
    end
  end

  test "telemetry metadata does not expose secret, signature, headers, raw body, or query params" do
    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(page_response(page: 1))}])
    test_pid = self()
    handler_id = "tickera-feed-client-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      EventSales.Telemetry.rest_request_stop(),
      fn _event, _measurements, metadata, _config ->
        send(test_pid, {:telemetry, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, _page} = WordPressFeedClient.fetch_page(%{"product_id" => 109_740}, 1)
    assert_receive {:telemetry, metadata}

    inspected = inspect(metadata)
    refute inspected =~ "test-feed-secret"
    refute inspected =~ "x-eventsales-signature"
    refute inspected =~ "109740"
    refute inspected =~ "wordpress.example.test"
    assert metadata.source == :tickera_catalog_feed
  end

  test "invalid or missing config returns misconfigured before transport" do
    Application.put_env(:event_sales, :tickera_catalog_feed, [])
    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(page_response(page: 1))}])

    assert {:error, :misconfigured} = WordPressFeedClient.fetch_page(%{}, 1)
    assert [] = FakeTransport.requests()
  end

  defp page_response(opts) do
    page = Keyword.get(opts, :page, 1)
    product_id = Keyword.get(opts, :product_id, 109_740)
    has_more = Keyword.get(opts, :has_more, false)

    %{
      "schema_version" => "2026-07-05.v1",
      "source" => "wordpress_tickera",
      "source_snapshot_at" => "2026-07-05T10:00:00Z",
      "page" => page,
      "per_page" => 2,
      "has_more" => has_more,
      "events" => [%{"tickera_event_id" => 109_316}],
      "catalog_rows" => [%{"woo_product_id" => product_id}]
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)
end
