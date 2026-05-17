defmodule EventSales.Catalog.ProductMetadataCacheTest do
  use ExUnit.Case, async: false

  alias EventSales.Catalog.ProductMetadataCache

  setup do
    ProductMetadataCache.reset_for_test!()
    on_exit(fn -> ProductMetadataCache.reset_for_test!() end)
    :ok
  end

  test "get returns miss before a metadata entry is written" do
    assert :miss = ProductMetadataCache.get("source-1", 501, nil)
  end

  test "put stores bounded metadata and is idempotent" do
    metadata = metadata(%{name: "VIP Ticket", raw_body: %{"do" => "not store"}})

    assert :ok = ProductMetadataCache.put(metadata)
    assert :ok = ProductMetadataCache.put(Map.put(metadata, :name, "VIP Ticket Updated"))

    assert {:ok, cached} = ProductMetadataCache.get("source-1", 501, 601)
    assert cached.name == "VIP Ticket Updated"
    assert cached.source_system_id == "source-1"
    assert cached.woo_product_id == 501
    assert cached.woo_variation_id == 601
    assert cached.product_type == "variation"
    assert cached.status == "publish"
    assert %DateTime{} = cached.fetched_at
    assert %DateTime{} = cached.expires_at
    refute Map.has_key?(cached, :raw_body)
    refute inspect(cached) =~ "authorization"
  end

  test "expired entries are treated as misses" do
    expired_at = DateTime.add(DateTime.utc_now(), -1, :second)

    assert :ok =
             ProductMetadataCache.put(
               metadata(%{expires_at: expired_at}),
               ttl_ms: 1
             )

    assert :miss = ProductMetadataCache.get("source-1", 501, 601)
  end

  test "invalidate removes only the requested key" do
    assert :ok = ProductMetadataCache.put(metadata(%{woo_variation_id: nil, name: "Product"}))
    assert :ok = ProductMetadataCache.put(metadata(%{woo_variation_id: 601, name: "Variation"}))

    assert :ok = ProductMetadataCache.invalidate("source-1", 501, nil)

    assert :miss = ProductMetadataCache.get("source-1", 501, nil)
    assert {:ok, %{name: "Variation"}} = ProductMetadataCache.get("source-1", 501, 601)
  end

  test "reset_for_test clears all entries" do
    assert :ok = ProductMetadataCache.put(metadata(%{}))

    assert {:ok, _cached} = ProductMetadataCache.get("source-1", 501, 601)
    assert :ok = ProductMetadataCache.reset_for_test!()
    assert :miss = ProductMetadataCache.get("source-1", 501, 601)
  end

  defp metadata(overrides) do
    now = DateTime.utc_now()

    %{
      source_system_id: "source-1",
      woo_product_id: 501,
      woo_variation_id: 601,
      name: "Ticket",
      product_type: "variation",
      status: "publish",
      fetched_at: now,
      expires_at: DateTime.add(now, 1_800, :second),
      authorization: "secret"
    }
    |> Map.merge(overrides)
  end
end
