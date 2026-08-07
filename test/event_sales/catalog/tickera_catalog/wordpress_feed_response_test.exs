defmodule EventSales.Catalog.TickeraCatalog.WordPressFeedResponseTest do
  use ExUnit.Case, async: true

  alias EventSales.Catalog.TickeraCatalog.WordPressFeedResponse

  test "accepts the complete v2 risk proof and marks it automation-capable" do
    assert {:ok, page} = WordPressFeedResponse.parse_page(valid_v2_page())

    assert page.schema_version == "2026-07-22.v2"
    assert page.auto_apply_proof_complete?
    assert hd(page.events)["event_status_classification"] == "publish"
    assert hd(page.catalog_rows)["product_semantics"]["membership"] == "unknown"
    assert "unknown_product_semantics" in hd(page.catalog_rows)["risk_codes"]
  end

  test "rejects v2 pages with an incomplete explicit risk proof" do
    event_fields = ["event_status_classification", "target_observation", "risk_codes"]

    for field <- event_fields do
      invalid =
        update_in(valid_v2_page(), ["events"], fn [event] -> [Map.delete(event, field)] end)

      assert {:error, :invalid_feed_response} = WordPressFeedResponse.parse_page(invalid)
    end

    row_fields = [
      "product_status_classification",
      "variation_status_classification",
      "product_type",
      "ticket_template_present",
      "subscription_classification",
      "product_semantics",
      "target_observation",
      "risk_codes"
    ]

    for field <- row_fields do
      invalid =
        update_in(valid_v2_page(), ["catalog_rows"], fn [row] -> [Map.delete(row, field)] end)

      assert {:error, :invalid_feed_response} = WordPressFeedResponse.parse_page(invalid)
    end
  end

  test "rejects malformed v2 semantic classifications" do
    invalid =
      put_in(
        valid_v2_page(),
        ["catalog_rows", Access.at(0), "product_semantics", "bundle"],
        "probably"
      )

    assert {:error, :invalid_feed_response} = WordPressFeedResponse.parse_page(invalid)
  end

  test "validates a feed page envelope" do
    assert {:ok, page} = WordPressFeedResponse.parse_page(valid_page())

    assert page.schema_version == "2026-07-08.v1"
    refute page.auto_apply_proof_complete?
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

  test "temporarily accepts the previous feed schema without event metadata" do
    page =
      valid_page()
      |> Map.put("schema_version", "2026-07-05.v1")
      |> Map.put("events", [
        %{
          "tickera_event_id" => 109_316,
          "event_title" => "Legacy feed event"
        }
      ])

    assert {:ok, parsed} = WordPressFeedResponse.parse_page(page)
    assert [%{"tickera_event_id" => 109_316}] = parsed.events
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

  test "rejects aggregation across feed schema versions" do
    assert {:ok, legacy} = WordPressFeedResponse.parse_page(valid_page())
    assert {:ok, v2} = WordPressFeedResponse.parse_page(valid_v2_page())

    assert {:error, :invalid_feed_response} =
             WordPressFeedResponse.aggregate_pages([legacy, v2])
  end

  describe "native 2026-08-07.v3" do
    test "parses a valid v3 page with locked stamps" do
      assert {:ok, page} = WordPressFeedResponse.parse_page(valid_v3_page())

      assert page.schema_version == "2026-08-07.v3"
      assert page.canonical_contract_version == "source_risk.v3"
      assert page.producer_version == "2026-08-07.1"
      assert page.source_system_id == "wordpress_tickera:fixture"
      assert page.discovery_snapshot_id == "snap-v3-1"
      assert page.generated_at == ~U[2026-08-07 10:00:01Z]
      assert page.filters == %{"include_private" => false}
      assert length(page.evidence) == 1
      refute page.auto_apply_proof_complete?
    end

    test "rejects missing or extra envelope keys and unknown schemas" do
      missing = Map.delete(valid_v3_page(), "filters")
      extra = Map.put(valid_v3_page(), "extra_meta", %{})
      unknown = Map.put(valid_v3_page(), "schema_version", "2026-09-01.v9")

      for invalid <- [missing, extra, unknown] do
        assert {:error, :invalid_feed_response} = WordPressFeedResponse.parse_page(invalid)
      end
    end

    test "enforces per_page evidence and catalog_rows bounds" do
      assert {:ok, _} =
               valid_v3_page()
               |> Map.put("per_page", 100)
               |> WordPressFeedResponse.parse_page()

      assert {:error, :invalid_feed_response} =
               valid_v3_page()
               |> Map.put("per_page", 101)
               |> WordPressFeedResponse.parse_page()

      assert {:ok, _} =
               valid_v3_page()
               |> Map.put("evidence", evidence_items(500))
               |> WordPressFeedResponse.parse_page()

      assert {:error, :invalid_feed_response} =
               valid_v3_page()
               |> Map.put("evidence", evidence_items(501))
               |> WordPressFeedResponse.parse_page()

      assert {:ok, _} =
               valid_v3_page()
               |> Map.put("catalog_rows", catalog_rows(100))
               |> WordPressFeedResponse.parse_page()

      assert {:error, :invalid_feed_response} =
               valid_v3_page()
               |> Map.put("catalog_rows", catalog_rows(101))
               |> WordPressFeedResponse.parse_page()
    end

    test "rejects invalid evidence and datetime fields" do
      bad_evidence =
        put_in(valid_v3_page(), ["evidence"], [
          %{"dimension" => "lifecycle", "state" => "present"}
        ])

      assert {:error, :invalid_feed_response} = WordPressFeedResponse.parse_page(bad_evidence)

      assert {:error, :invalid_feed_response} =
               valid_v3_page()
               |> Map.put("source_snapshot_at", "not-a-date")
               |> WordPressFeedResponse.parse_page()

      assert {:error, :invalid_feed_response} =
               valid_v3_page()
               |> Map.put("generated_at", "nope")
               |> WordPressFeedResponse.parse_page()
    end

    test "aggregates stable multipage v3 and allows differing generated_at" do
      {:ok, first} =
        valid_v3_page()
        |> Map.put("has_more", true)
        |> Map.put("generated_at", "2026-08-07T10:00:01Z")
        |> WordPressFeedResponse.parse_page()

      {:ok, second} =
        valid_v3_page()
        |> Map.put("page", 2)
        |> Map.put("has_more", false)
        |> Map.put("generated_at", "2026-08-07T10:00:09Z")
        |> Map.put("events", [%{"tickera_event_id" => 2}])
        |> Map.put("catalog_rows", [%{"woo_product_id" => 3}])
        |> Map.put("evidence", evidence_items(1, start_id: 99))
        |> WordPressFeedResponse.parse_page()

      assert {:ok, aggregate} = WordPressFeedResponse.aggregate_pages([first, second])
      assert aggregate.discovery_snapshot_id == "snap-v3-1"
      assert aggregate.source_snapshot_at == ~U[2026-08-07 10:00:00Z]
      assert length(aggregate.events) == 2
      assert length(aggregate.catalog_rows) == 2
      assert length(aggregate.evidence) == 2
      assert aggregate.generated_at == ~U[2026-08-07 10:00:09Z]
    end

    test "rejects mixed v2/v3 and native disagreements" do
      {:ok, v2} = WordPressFeedResponse.parse_page(valid_v2_page())
      {:ok, v3} = WordPressFeedResponse.parse_page(valid_v3_page())

      assert {:error, :invalid_feed_response} =
               WordPressFeedResponse.aggregate_pages([v2, v3])

      {:ok, first} =
        valid_v3_page()
        |> Map.put("has_more", true)
        |> WordPressFeedResponse.parse_page()

      disagreements = [
        Map.put(valid_v3_page(), "page", 2)
        |> Map.put("source_snapshot_at", "2026-08-07T11:00:00Z"),
        Map.put(valid_v3_page(), "page", 2)
        |> Map.put("discovery_snapshot_id", "other"),
        Map.put(valid_v3_page(), "page", 2)
        |> Map.put("source_system_id", "wordpress_tickera:other"),
        Map.put(valid_v3_page(), "page", 2)
        |> Map.put("filters", %{"include_private" => true})
      ]

      for raw <- disagreements do
        {:ok, second} = WordPressFeedResponse.parse_page(raw)

        assert {:error, :invalid_feed_response} =
                 WordPressFeedResponse.aggregate_pages([first, second])
      end
    end

    test "rejects duplicate pages and page gaps" do
      {:ok, a} =
        valid_v3_page()
        |> Map.put("has_more", true)
        |> WordPressFeedResponse.parse_page()

      {:ok, dup} =
        valid_v3_page()
        |> Map.put("page", 1)
        |> Map.put("has_more", false)
        |> WordPressFeedResponse.parse_page()

      {:ok, gap} =
        valid_v3_page()
        |> Map.put("page", 3)
        |> Map.put("has_more", false)
        |> WordPressFeedResponse.parse_page()

      assert {:error, :invalid_feed_response} = WordPressFeedResponse.aggregate_pages([a, dup])
      assert {:error, :invalid_feed_response} = WordPressFeedResponse.aggregate_pages([a, gap])
    end

    test "preserves legacy aggregation semantics" do
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
      assert aggregate.source_snapshot_at == ~U[2026-07-05 10:05:00Z]
      assert aggregate.evidence == []
    end
  end

  defp valid_page do
    %{
      "schema_version" => "2026-07-08.v1",
      "source" => "wordpress_tickera",
      "source_snapshot_at" => "2026-07-05T10:00:00Z",
      "page" => 1,
      "per_page" => 100,
      "has_more" => false,
      "events" => [
        %{
          "tickera_event_id" => 109_316,
          "event_start_at" => "2026-08-01T16:00:00Z",
          "event_end_at" => "2026-08-01T18:00:00Z",
          "event_location" => "Pretoria",
          "booking_fee_type" => "fixed",
          "booking_fee_value" => "25.00"
        }
      ],
      "catalog_rows" => [%{"woo_product_id" => 109_740}]
    }
  end

  defp valid_v2_page do
    %{
      "schema_version" => "2026-07-22.v2",
      "source" => "wordpress_tickera",
      "source_snapshot_at" => "2026-07-22T10:00:00Z",
      "page" => 1,
      "per_page" => 100,
      "has_more" => false,
      "events" => [
        %{
          "tickera_event_id" => 109_316,
          "event_status_classification" => "publish",
          "target_observation" => "present",
          "risk_codes" => []
        }
      ],
      "catalog_rows" => [
        %{
          "woo_product_id" => 109_740,
          "woo_variation_id" => nil,
          "product_status_classification" => "publish",
          "variation_status_classification" => nil,
          "product_type" => "simple",
          "ticket_template_present" => true,
          "subscription_classification" => "not_subscription",
          "product_semantics" => %{
            "payment_plan" => "unknown",
            "membership" => "unknown",
            "bundle" => "unknown",
            "add_on" => "unknown"
          },
          "target_observation" => "present",
          "risk_codes" => ["unknown_product_semantics"]
        }
      ]
    }
  end

  defp valid_v3_page do
    %{
      "schema_version" => "2026-08-07.v3",
      "canonical_contract_version" => "source_risk.v3",
      "producer_version" => "2026-08-07.1",
      "source" => "wordpress_tickera",
      "source_system_id" => "wordpress_tickera:fixture",
      "discovery_snapshot_id" => "snap-v3-1",
      "source_snapshot_at" => "2026-08-07T10:00:00Z",
      "generated_at" => "2026-08-07T10:00:01Z",
      "page" => 1,
      "per_page" => 50,
      "has_more" => false,
      "filters" => %{"include_private" => false},
      "events" => [%{"tickera_event_id" => 1}],
      "catalog_rows" => [%{"woo_product_id" => 2}],
      "evidence" => evidence_items(1)
    }
  end

  defp evidence_items(count, opts \\ []) do
    start_id = Keyword.get(opts, :start_id, 1)

    for id <- start_id..(start_id + count - 1) do
      %{
        "dimension" => "lifecycle",
        "producer_scope" => "parent_product",
        "target" => %{"woo_product_id" => id},
        "state" => "present",
        "producer_source_key" => "wp_posts.post_status",
        "completeness" => "partial",
        "provenance" => %{"producer_version" => "2026-08-07.1"},
        "value" => "publish"
      }
    end
  end

  defp catalog_rows(count) do
    for id <- 1..count, do: %{"woo_product_id" => id}
  end
end
