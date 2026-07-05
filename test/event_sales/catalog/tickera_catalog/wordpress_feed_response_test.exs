defmodule EventSales.Catalog.TickeraCatalog.WordPressFeedResponseTest do
  use ExUnit.Case, async: true

  alias EventSales.Catalog.TickeraCatalog.WordPressFeedResponse

  test "validates a feed page envelope" do
    assert {:ok, page} = WordPressFeedResponse.parse_page(valid_page())

    assert page.page == 1
    assert page.per_page == 100
    refute page.has_more
    assert [%{"tickera_event_id" => 109_316}] = page.events
    assert [%{"woo_product_id" => 109_740}] = page.catalog_rows
    assert %DateTime{} = page.source_snapshot_at
  end

  test "rejects malformed envelopes" do
    invalid_pages = [
      "not a map",
      Map.put(valid_page(), "schema_version", "wrong"),
      Map.put(valid_page(), "source", "wrong"),
      Map.put(valid_page(), "events", %{}),
      Map.put(valid_page(), "catalog_rows", %{}),
      Map.put(valid_page(), "page", 0),
      Map.put(valid_page(), "per_page", 0),
      Map.put(valid_page(), "has_more", "false"),
      Map.put(valid_page(), "source_snapshot_at", "not-a-date")
    ]

    for invalid <- invalid_pages do
      assert {:error, :invalid_feed_response} = WordPressFeedResponse.parse_page(invalid)
    end
  end

  test "aggregates pages by deduping events and keeping catalog row order" do
    {:ok, first} =
      valid_page()
      |> Map.put("has_more", true)
      |> Map.put("source_snapshot_at", "2026-07-05T10:00:00Z")
      |> WordPressFeedResponse.parse_page()

    {:ok, second} =
      valid_page()
      |> Map.put("page", 2)
      |> Map.put("source_snapshot_at", "2026-07-05T10:05:00Z")
      |> Map.put("events", [
        %{"tickera_event_id" => 109_316, "event_title" => "Duplicate"},
        %{"tickera_event_id" => 200_000, "event_title" => "Second"}
      ])
      |> Map.put("catalog_rows", [%{"woo_product_id" => 109_741}])
      |> WordPressFeedResponse.parse_page()

    assert {:ok, aggregate} = WordPressFeedResponse.aggregate_pages([first, second])

    assert Enum.map(aggregate.events, & &1["tickera_event_id"]) == [109_316, 200_000]
    assert Enum.map(aggregate.catalog_rows, & &1["woo_product_id"]) == [109_740, 109_741]
    assert aggregate.source_snapshot_at == ~U[2026-07-05 10:05:00Z]
  end

  defp valid_page do
    %{
      "schema_version" => "2026-07-05.v1",
      "source" => "wordpress_tickera",
      "source_snapshot_at" => "2026-07-05T10:00:00Z",
      "page" => 1,
      "per_page" => 100,
      "has_more" => false,
      "events" => [%{"tickera_event_id" => 109_316}],
      "catalog_rows" => [%{"woo_product_id" => 109_740}]
    }
  end
end
