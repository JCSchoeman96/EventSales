defmodule EventSales.Catalog.TickeraCatalog.ManualRowsDiscoverySourceTest do
  use ExUnit.Case, async: true

  alias EventSales.Catalog.TickeraCatalog.{DiscoveryResult, ManualRowsDiscoverySource}
  alias EventSales.TestSupport.TickeraCatalogFixtures

  test "builds DiscoveryResult from sanitized manual rows and event summaries" do
    scope = %{
      "kind" => "manual_rows",
      "events" => [TickeraCatalogFixtures.zero_product_event()],
      "catalog_rows" => [TickeraCatalogFixtures.vwg_row()]
    }

    assert {:ok, %DiscoveryResult{} = result} =
             ManualRowsDiscoverySource.discover("source-id", scope)

    assert Enum.any?(result.events, &(&1["tickera_event_id"] == 300_001))
    assert Enum.any?(result.events, &(&1["tickera_event_id"] == 109_316))
    assert [%{"woo_product_id" => 109_740}] = result.catalog_rows
  end
end
