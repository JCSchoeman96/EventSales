defmodule EventSales.Catalog.TickeraCatalog.WordPressFeedDiscoverySourceTest do
  use ExUnit.Case, async: false

  alias EventSales.Catalog.TickeraCatalog.{
    ConfiguredDiscoverySource,
    DiscoveryResult,
    WordPressFeedDiscoverySource
  }

  alias EventSales.Catalog.TickeraCatalog.WordPressFeedClientTest.FakeTransport

  setup do
    start_supervised!(FakeTransport)
    original_feed = Application.get_env(:event_sales, :tickera_catalog_feed)
    original_adapter = Application.get_env(:event_sales, :tickera_catalog_discovery_source)

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
      restore_env(:tickera_catalog_discovery_source, original_adapter)
    end)

    :ok
  end

  test "discovers full feed as a DiscoveryResult" do
    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(page_response())}])

    assert {:ok, %DiscoveryResult{} = result} =
             WordPressFeedDiscoverySource.discover("source-id", %{
               "kind" => "wordpress_feed",
               "mode" => "full"
             })

    assert [%{"tickera_event_id" => 109_316}] = result.events
    assert [%{"woo_product_id" => 109_740}] = result.catalog_rows
    assert result.source_snapshot_at == ~U[2026-07-05 10:00:00Z]
  end

  test "maps targeted scopes to feed query params" do
    scopes = [
      {%{"kind" => "wordpress_feed", "product_id" => 109_740}, "product_id=109740"},
      {%{"kind" => "wordpress_feed", "variation_id" => 109_741}, "variation_id=109741"},
      {%{"kind" => "wordpress_feed", "event_id" => 109_316}, "event_id=109316"},
      {%{"kind" => "wordpress_feed", "updated_since" => "2026-07-05T10:00:00Z"},
       "updated_since=2026-07-05T10%3A00%3A00Z"}
    ]

    for {scope, query_fragment} <- scopes do
      FakeTransport.reset!([{:ok, 200, [], Jason.encode!(page_response())}])

      assert {:ok, %DiscoveryResult{}} = WordPressFeedDiscoverySource.discover("source-id", scope)
      assert [%{url: url}] = FakeTransport.requests()
      assert url =~ query_fragment
    end
  end

  test "rejects invalid and mixed feed scopes" do
    invalid_scopes = [
      %{},
      %{"kind" => "manual_rows"},
      %{"kind" => "wordpress_feed", "mode" => "unsupported"},
      %{"kind" => "wordpress_feed", "product_id" => 0},
      %{"kind" => "wordpress_feed", "variation_id" => -1},
      %{"kind" => "wordpress_feed", "event_id" => "abc"},
      %{"kind" => "wordpress_feed", "updated_since" => "yesterday"},
      %{"kind" => "wordpress_feed", "product_id" => 109_740, "event_id" => 109_316}
    ]

    for scope <- invalid_scopes do
      assert {:error, :invalid_scope} = WordPressFeedDiscoverySource.discover("source-id", scope)
    end
  end

  test "configured source preserves manual rows even when feed adapter is configured" do
    Application.put_env(
      :event_sales,
      :tickera_catalog_discovery_source,
      WordPressFeedDiscoverySource
    )

    scope = %{
      "kind" => "manual_rows",
      "events" => [],
      "catalog_rows" => [%{"woo_product_id" => 109_740}]
    }

    assert {:ok, %DiscoveryResult{catalog_rows: [%{"woo_product_id" => 109_740}]}} =
             ConfiguredDiscoverySource.discover("source-id", scope)

    assert [] = FakeTransport.requests()
  end

  test "configured source sends wordpress_feed scopes to adapter" do
    Application.put_env(
      :event_sales,
      :tickera_catalog_discovery_source,
      WordPressFeedDiscoverySource
    )

    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(page_response())}])

    assert {:ok, %DiscoveryResult{}} =
             ConfiguredDiscoverySource.discover("source-id", %{
               "kind" => "wordpress_feed",
               "mode" => "full"
             })

    assert [_request] = FakeTransport.requests()
  end

  test "manual fallback still works without configured adapter and unsupported scope is not configured" do
    Application.delete_env(:event_sales, :tickera_catalog_discovery_source)

    assert {:ok, %DiscoveryResult{}} =
             ConfiguredDiscoverySource.discover("source-id", %{
               "kind" => "manual_rows",
               "events" => [],
               "catalog_rows" => []
             })

    assert {:error, :not_configured} =
             ConfiguredDiscoverySource.discover("source-id", %{"kind" => "unknown"})
  end

  defp page_response do
    %{
      "schema_version" => "2026-07-05.v1",
      "source" => "wordpress_tickera",
      "source_snapshot_at" => "2026-07-05T10:00:00Z",
      "page" => 1,
      "per_page" => 2,
      "has_more" => false,
      "events" => [%{"tickera_event_id" => 109_316}],
      "catalog_rows" => [%{"woo_product_id" => 109_740}]
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)
end
