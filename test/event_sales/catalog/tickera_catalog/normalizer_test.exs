defmodule EventSales.Catalog.TickeraCatalog.NormalizerTest do
  use ExUnit.Case, async: true

  alias EventSales.Catalog.TickeraCatalog.{DiscoveryResult, Normalizer}
  alias EventSales.TestSupport.TickeraCatalogFixtures

  test "normalizes VWG Pretoria as one product-level candidate" do
    result = %DiscoveryResult{
      events: [TickeraCatalogFixtures.vwg_event()],
      catalog_rows: [TickeraCatalogFixtures.vwg_row()]
    }

    assert {:ok, %{rows: [row], findings: findings}} = Normalizer.normalize(result)

    assert row.tickera_event_id == 109_316
    assert row.woo_product_id == 109_740
    assert row.woo_variation_id == nil
    assert row.ticket_type_name == "Toegang"
    assert row.ticket_type_kind == :woo_product
    assert findings == []
  end

  test "collapses duplicate meta rows without using price as identity" do
    row = TickeraCatalogFixtures.vwg_row()
    duplicate = Map.put(row, "price", "199.00")

    result = %DiscoveryResult{
      events: [TickeraCatalogFixtures.vwg_event()],
      catalog_rows: [row, duplicate]
    }

    assert {:ok, %{rows: rows, findings: findings}} = Normalizer.normalize(result)

    assert length(rows) == 1
    assert [%{code: :duplicate_meta_collapsed, severity: :info}] = findings
  end

  test "skips private Tickera events even when Woo product is published" do
    event = %{
      "tickera_event_id" => 200_001,
      "event_title" => "Private Retreat",
      "event_slug" => "private-retreat",
      "event_status" => "private"
    }

    result = %DiscoveryResult{
      events: [event],
      catalog_rows: [TickeraCatalogFixtures.private_event_row()]
    }

    assert {:ok, %{rows: [], findings: findings}} = Normalizer.normalize(result)
    assert [%{code: :private_event_skipped, severity: :info}] = findings
  end

  test "warns when a published Tickera event has no eligible ticket products" do
    result = %DiscoveryResult{
      events: [TickeraCatalogFixtures.zero_product_event()],
      catalog_rows: []
    }

    assert {:ok, %{rows: [], findings: findings}} = Normalizer.normalize(result)
    assert [%{code: :published_event_without_ticket_products, severity: :warning}] = findings
  end

  test "variation products emit variation-level candidates only and warning" do
    [first_variation | _rest] = variation_rows = TickeraCatalogFixtures.variation_rows()

    parent_row =
      first_variation
      |> Map.put("woo_variation_id", nil)
      |> Map.put("variation_title", nil)
      |> Map.put("variation_status", nil)
      |> Map.put("variation_source_updated_at", nil)

    result = %DiscoveryResult{
      events: [
        %{
          "tickera_event_id" => 400_001,
          "event_title" => "Variation Event",
          "event_slug" => "variation-event",
          "event_status" => "publish"
        }
      ],
      catalog_rows: [parent_row | variation_rows]
    }

    assert {:ok, %{rows: rows, findings: findings}} = Normalizer.normalize(result)

    assert Enum.map(rows, & &1.woo_variation_id) == [400_741, 400_742]
    assert Enum.all?(rows, &(&1.ticket_type_kind == :woo_variation))
    assert Enum.any?(findings, &(&1.code == :variation_mapping_required))
    refute Enum.any?(rows, &is_nil(&1.woo_variation_id))
  end
end
