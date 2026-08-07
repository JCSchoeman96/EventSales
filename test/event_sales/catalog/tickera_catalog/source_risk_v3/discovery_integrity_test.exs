defmodule EventSales.Catalog.TickeraCatalog.SourceRiskV3.DiscoveryIntegrityTest do
  use ExUnit.Case, async: true

  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.DiscoveryIntegrity

  defp page(overrides) do
    Map.merge(
      %{
        schema_version: "2026-08-07.v3",
        canonical_contract_version: "source_risk.v3",
        producer_version: "2026-08-07.1",
        source_system_id: "wordpress_tickera:abc",
        discovery_snapshot_id: "snap-1",
        source_snapshot_at: ~U[2026-08-07 10:00:00Z],
        generated_at: ~U[2026-08-07 10:00:01Z],
        page: 1,
        per_page: 50,
        has_more: false,
        filters: %{"include_private" => false},
        catalog_rows: [],
        evidence: []
      },
      Map.new(overrides)
    )
  end

  test "accepts a stable complete single-page discovery" do
    assert {:ok, :complete} = DiscoveryIntegrity.validate_discovery_pages([page(%{})])
  end

  test "accepts stable multipage discovery with differing generated_at" do
    pages = [
      page(%{page: 1, has_more: true, generated_at: ~U[2026-08-07 10:00:01Z]}),
      page(%{page: 2, has_more: false, generated_at: ~U[2026-08-07 10:00:05Z]})
    ]

    assert {:ok, :complete} = DiscoveryIntegrity.validate_discovery_pages(pages)
  end

  test "rejects mixed schema versions" do
    pages = [
      page(%{page: 1, has_more: true}),
      page(%{page: 2, schema_version: "2026-07-22.v2", has_more: false})
    ]

    assert {:error, :mixed_or_unknown_schema} =
             DiscoveryIntegrity.validate_discovery_pages(pages)
  end

  test "rejects snapshot identity mismatches" do
    pages = [
      page(%{page: 1, has_more: true}),
      page(%{page: 2, discovery_snapshot_id: "other", has_more: false})
    ]

    assert {:error, :discovery_snapshot_id_mismatch} =
             DiscoveryIntegrity.validate_discovery_pages(pages)
  end

  test "rejects source_snapshot_at mismatches" do
    pages = [
      page(%{page: 1, has_more: true}),
      page(%{page: 2, source_snapshot_at: ~U[2026-08-07 11:00:00Z], has_more: false})
    ]

    assert {:error, :source_snapshot_at_mismatch} =
             DiscoveryIntegrity.validate_discovery_pages(pages)
  end

  test "rejects source_system_id mismatches" do
    pages = [
      page(%{page: 1, has_more: true}),
      page(%{page: 2, source_system_id: "wordpress_tickera:other", has_more: false})
    ]

    assert {:error, :source_system_id_mismatch} =
             DiscoveryIntegrity.validate_discovery_pages(pages)
  end

  test "rejects producer_version and filters mismatches" do
    assert {:error, :producer_version_mismatch} =
             DiscoveryIntegrity.validate_discovery_pages([
               page(%{page: 1, has_more: true}),
               page(%{page: 2, producer_version: "2026-08-07.2", has_more: false})
             ])

    assert {:error, :filters_mismatch} =
             DiscoveryIntegrity.validate_discovery_pages([
               page(%{page: 1, has_more: true}),
               page(%{page: 2, filters: %{"include_private" => true}, has_more: false})
             ])
  end

  test "rejects duplicate pages, gaps, out-of-order, and incomplete sequences" do
    assert {:error, :duplicate_page} =
             DiscoveryIntegrity.validate_discovery_pages([
               page(%{page: 1, has_more: true}),
               page(%{page: 1, has_more: false})
             ])

    assert {:error, :page_gap_or_incomplete_sequence} =
             DiscoveryIntegrity.validate_discovery_pages([
               page(%{page: 1, has_more: true}),
               page(%{page: 3, has_more: false})
             ])

    assert {:error, :out_of_order_page} =
             DiscoveryIntegrity.validate_discovery_pages([
               page(%{page: 2, has_more: false}),
               page(%{page: 1, has_more: true})
             ])

    assert {:ok, :complete} =
             DiscoveryIntegrity.validate_discovery_pages([
               page(%{page: 1, has_more: true}),
               page(%{page: 2, has_more: false})
             ])

    assert {:error, :incomplete_page_sequence} =
             DiscoveryIntegrity.validate_discovery_pages([page(%{has_more: true})])
  end

  test "rejects per_page mismatches across pages" do
    assert {:ok, :complete} =
             DiscoveryIntegrity.validate_discovery_pages([
               page(%{page: 1, per_page: 100, has_more: true}),
               page(%{page: 2, per_page: 100, has_more: false})
             ])

    assert {:error, :per_page_mismatch} =
             DiscoveryIntegrity.validate_discovery_pages([
               page(%{page: 1, per_page: 100, has_more: true}),
               page(%{page: 2, per_page: 50, has_more: false})
             ])
  end

  test "enforces native per-page bounds" do
    assert :ok = DiscoveryIntegrity.validate_page_bounds(page(%{per_page: 100}))

    assert {:error, :invalid_per_page} =
             DiscoveryIntegrity.validate_page_bounds(page(%{per_page: 101}))

    assert :ok =
             DiscoveryIntegrity.validate_page_bounds(page(%{evidence: List.duplicate(:e, 500)}))

    assert {:error, :evidence_page_limit_exceeded} =
             DiscoveryIntegrity.validate_page_bounds(page(%{evidence: List.duplicate(:e, 501)}))

    assert :ok =
             DiscoveryIntegrity.validate_page_bounds(
               page(%{catalog_rows: List.duplicate(%{}, 100)})
             )

    assert {:error, :catalog_rows_page_limit_exceeded} =
             DiscoveryIntegrity.validate_page_bounds(
               page(%{catalog_rows: List.duplicate(%{}, 101)})
             )
  end

  test "normalizes base URLs and derives deterministic source keys" do
    urls = [
      "HTTPS://Example.com/",
      "https://example.com",
      "https://example.com:443/"
    ]

    keys =
      Enum.map(urls, fn url ->
        assert {:ok, normalized} = DiscoveryIntegrity.normalize_base_url(url)
        assert normalized == "https://example.com"
        assert {:ok, key} = DiscoveryIntegrity.expected_source_system_id(url)
        key
      end)

    assert Enum.uniq(keys) == [hd(keys)]
    assert String.starts_with?(hd(keys), "wordpress_tickera:")

    assert {:ok, "http://example.com"} =
             DiscoveryIntegrity.normalize_base_url("http://example.com:80/")

    assert {:ok, "https://example.com:8443"} =
             DiscoveryIntegrity.normalize_base_url("https://example.com:8443/")

    assert {:ok, "https://example.com/Path"} =
             DiscoveryIntegrity.normalize_base_url("https://example.com/Path/?q=1#frag")

    assert {:ok, left} = DiscoveryIntegrity.expected_source_system_id("https://a.example/wp")
    assert {:ok, right} = DiscoveryIntegrity.expected_source_system_id("https://a.example/other")
    refute left == right

    assert :ok = DiscoveryIntegrity.verify_source_system_id("https://example.com", hd(keys))

    assert {:error, :source_system_id_mismatch} =
             DiscoveryIntegrity.verify_source_system_id(
               "https://example.com",
               "wordpress_tickera:deadbeef"
             )
  end

  test "does not accept source-key overrides" do
    refute function_exported?(DiscoveryIntegrity, :override_source_system_id, 1)
    refute function_exported?(DiscoveryIntegrity, :configure_source_key, 1)

    {:ok, expected} = DiscoveryIntegrity.expected_source_system_id("https://example.com")

    assert {:error, :source_system_id_mismatch} =
             DiscoveryIntegrity.verify_source_system_id(
               "https://example.com",
               "EVENTSALES_TICKERA_CATALOG_SOURCE_KEY"
             )

    assert expected == "wordpress_tickera:" <> expected_hash("https://example.com")
  end

  defp expected_hash(url) do
    {:ok, normalized} = DiscoveryIntegrity.normalize_base_url(url)

    :crypto.hash(:sha256, normalized)
    |> Base.encode16(case: :lower)
  end
end
