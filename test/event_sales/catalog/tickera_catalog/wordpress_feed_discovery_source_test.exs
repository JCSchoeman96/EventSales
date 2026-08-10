defmodule EventSales.Catalog.TickeraCatalog.WordPressFeedDiscoverySourceTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog.TickeraCatalog.{
    ConfiguredDiscoverySource,
    DiscoveryResult,
    WordPressFeedDiscoverySource
  }

  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.CanonicalFact
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.DiscoveryIntegrity
  alias EventSales.Ingestion.Clients.WooCommerceTransport
  alias EventSales.TestSupport.SalesHelpers

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
    assert result.normalization_mode == :legacy_v2_operational
    assert result.evidence_origin == nil
    assert result.canonical_source_risk_facts == []
    assert result.canonical_source_risk_findings == []
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

  test "v2 remains legacy_v2_operational without V2Adapter and without native facts" do
    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(valid_v2_page())}])

    assert {:ok, %DiscoveryResult{} = result} =
             WordPressFeedDiscoverySource.discover("source-id", %{
               "kind" => "wordpress_feed",
               "mode" => "full"
             })

    assert result.schema_version == "2026-07-22.v2"
    assert result.normalization_mode == :legacy_v2_operational
    assert result.evidence_origin == nil
    assert result.canonical_source_risk_facts == []
    assert result.canonical_source_risk_findings == []
    assert result.auto_apply_proof_complete?
  end

  test "native v3 discovers review-only facts bound to configured SourceSystem base_url" do
    source =
      SalesHelpers.create_source_system!(%{
        base_url: "https://wordpress.example.test/"
      })

    assert {:ok, expected_key} =
             DiscoveryIntegrity.expected_source_system_id(source.base_url)

    FakeTransport.reset!([
      {:ok, 200, [], Jason.encode!(valid_v3_page(expected_key, "snap-native-1"))}
    ])

    assert {:ok, %DiscoveryResult{} = result} =
             WordPressFeedDiscoverySource.discover(source.id, %{
               "kind" => "wordpress_feed",
               "mode" => "full"
             })

    assert result.normalization_mode == :native_v3_review
    assert result.evidence_origin == :native
    assert result.schema_version == "2026-08-07.v3"
    assert result.canonical_contract_version == "source_risk.v3"
    assert result.producer_version == "2026-08-07.1"
    assert result.source_system_id == expected_key
    refute result.source_system_id == source.id
    assert result.discovery_snapshot_id == "snap-native-1"
    refute result.auto_apply_proof_complete?

    assert [
             %{
               "tickera_event_id" => 1,
               "event_source_created_at" => "2026-05-01T08:00:00Z",
               "event_source_updated_at" => "2026-06-01T10:00:00Z"
             }
           ] = result.events

    assert [%CanonicalFact{} = fact] = result.canonical_source_risk_facts
    assert fact.run_id == result.discovery_snapshot_id
    assert fact.origin == "native"
    assert fact.completeness in ["partial", "exhaustive", "unknown"]

    assert [%{qualified_finding_id: "source_risk.lifecycle_draft", severity: :blocking}] =
             result.canonical_source_risk_findings
  end

  test "native source_system_id mismatch fails closed" do
    source =
      SalesHelpers.create_source_system!(%{
        base_url: "https://wordpress.example.test/"
      })

    FakeTransport.reset!([
      {:ok, 200, [], Jason.encode!(valid_v3_page("wordpress_tickera:wrong", "snap-x"))}
    ])

    assert {:error, :invalid_feed_response} =
             WordPressFeedDiscoverySource.discover(source.id, %{
               "kind" => "wordpress_feed",
               "mode" => "full"
             })
  end

  test "exhaustive evidence is accepted only after completed native discovery" do
    source =
      SalesHelpers.create_source_system!(%{
        base_url: "https://wordpress.example.test"
      })

    assert {:ok, expected_key} =
             DiscoveryIntegrity.expected_source_system_id(source.base_url)

    page =
      valid_v3_page(expected_key, "snap-exh")
      |> put_in(["evidence"], [
        %{
          "dimension" => "lifecycle",
          "producer_scope" => "parent_product",
          "target" => %{"woo_product_id" => 42},
          "state" => "present",
          "producer_source_key" => "wp_posts.post_status",
          "completeness" => "exhaustive",
          "provenance" => %{"producer_version" => "2026-08-07.1"},
          "value" => "publish"
        }
      ])

    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(page)}])

    assert {:ok, %DiscoveryResult{} = result} =
             WordPressFeedDiscoverySource.discover(source.id, %{
               "kind" => "wordpress_feed",
               "mode" => "full"
             })

    assert [%CanonicalFact{completeness: "exhaustive", origin: "native"}] =
             result.canonical_source_risk_facts

    assert result.canonical_source_risk_findings == []
  end

  test "duplicate identical provenance collapses to one fact and one provenance record" do
    source =
      SalesHelpers.create_source_system!(%{base_url: "https://wordpress.example.test"})

    assert {:ok, expected_key} =
             DiscoveryIntegrity.expected_source_system_id(source.base_url)

    evidence_item = %{
      "dimension" => "lifecycle",
      "producer_scope" => "parent_product",
      "target" => %{"woo_product_id" => 42},
      "state" => "present",
      "producer_source_key" => "wp_posts.post_status",
      "completeness" => "partial",
      "provenance" => %{"producer_version" => "2026-08-07.1"},
      "value" => "publish"
    }

    page =
      valid_v3_page(expected_key, "snap-dup-same")
      |> Map.put("evidence", [evidence_item, evidence_item])

    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(page)}])

    assert {:ok, %DiscoveryResult{} = result} =
             WordPressFeedDiscoverySource.discover(source.id, %{
               "kind" => "wordpress_feed",
               "mode" => "full"
             })

    assert length(result.canonical_source_risk_facts) == 1
    assert length(hd(result.canonical_source_risk_facts).provenance) == 1
    assert result.canonical_source_risk_findings == []
  end

  test "duplicate distinct provenance collapses while retaining both records" do
    source =
      SalesHelpers.create_source_system!(%{base_url: "https://wordpress.example.test"})

    assert {:ok, expected_key} =
             DiscoveryIntegrity.expected_source_system_id(source.base_url)

    left = %{
      "dimension" => "lifecycle",
      "producer_scope" => "parent_product",
      "target" => %{"woo_product_id" => 42},
      "state" => "present",
      "producer_source_key" => "wp_posts.post_status",
      "completeness" => "partial",
      "provenance" => %{"producer_version" => "2026-08-07.1"},
      "value" => "publish"
    }

    right =
      put_in(left, ["provenance", "raw_producer_code"], "private_product")

    page =
      valid_v3_page(expected_key, "snap-dup-distinct")
      |> Map.put("evidence", [left, right])

    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(page)}])

    assert {:ok, %DiscoveryResult{} = result} =
             WordPressFeedDiscoverySource.discover(source.id, %{
               "kind" => "wordpress_feed",
               "mode" => "full"
             })

    assert [fact] = result.canonical_source_risk_facts
    assert length(fact.provenance) == 2
    assert result.canonical_source_risk_findings == []
  end

  test "safe-positive publish has fact but no actual finding; draft and conflicts do" do
    source =
      SalesHelpers.create_source_system!(%{base_url: "https://wordpress.example.test"})

    assert {:ok, expected_key} =
             DiscoveryIntegrity.expected_source_system_id(source.base_url)

    publish_page =
      valid_v3_page(expected_key, "snap-safe")
      |> Map.put("evidence", [
        %{
          "dimension" => "lifecycle",
          "producer_scope" => "parent_product",
          "target" => %{"woo_product_id" => 7},
          "state" => "present",
          "producer_source_key" => "wp_posts.post_status",
          "completeness" => "partial",
          "provenance" => %{"producer_version" => "2026-08-07.1"},
          "value" => "publish"
        }
      ])

    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(publish_page)}])

    assert {:ok, safe} =
             WordPressFeedDiscoverySource.discover(source.id, %{
               "kind" => "wordpress_feed",
               "mode" => "full"
             })

    assert length(safe.canonical_source_risk_facts) == 1
    assert safe.canonical_source_risk_findings == []

    draft_page =
      valid_v3_page(expected_key, "snap-draft")
      |> Map.put("evidence", [
        %{
          "dimension" => "lifecycle",
          "producer_scope" => "parent_product",
          "target" => %{"woo_product_id" => 8},
          "state" => "present",
          "producer_source_key" => "wp_posts.post_status",
          "completeness" => "partial",
          "provenance" => %{"producer_version" => "2026-08-07.1"},
          "value" => "draft"
        }
      ])

    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(draft_page)}])

    assert {:ok, risky} =
             WordPressFeedDiscoverySource.discover(source.id, %{
               "kind" => "wordpress_feed",
               "mode" => "full"
             })

    assert length(risky.canonical_source_risk_facts) == 1

    assert Enum.any?(risky.canonical_source_risk_findings, fn finding ->
             finding.qualified_finding_id == "source_risk.lifecycle_draft"
           end)

    conflict_page =
      valid_v3_page(expected_key, "snap-conflict")
      |> Map.put("evidence", [
        %{
          "dimension" => "lifecycle",
          "producer_scope" => "parent_product",
          "target" => %{"woo_product_id" => 9},
          "state" => "present",
          "producer_source_key" => "wp_posts.post_status",
          "completeness" => "partial",
          "provenance" => %{"producer_version" => "2026-08-07.1"},
          "value" => "draft"
        },
        %{
          "dimension" => "lifecycle",
          "producer_scope" => "parent_product",
          "target" => %{"woo_product_id" => 9},
          "state" => "present",
          "producer_source_key" => "wp_posts.post_status",
          "completeness" => "partial",
          "provenance" => %{"producer_version" => "2026-08-07.1"},
          "value" => "private"
        }
      ])

    FakeTransport.reset!([{:ok, 200, [], Jason.encode!(conflict_page)}])

    assert {:ok, conflict} =
             WordPressFeedDiscoverySource.discover(source.id, %{
               "kind" => "wordpress_feed",
               "mode" => "full"
             })

    assert length(conflict.canonical_source_risk_facts) == 2

    assert Enum.any?(conflict.canonical_source_risk_findings, fn finding ->
             finding.qualified_finding_id == "contract.evidence_conflict"
           end)
  end

  defp page_response do
    %{
      "schema_version" => "2026-07-08.v1",
      "source" => "wordpress_tickera",
      "source_snapshot_at" => "2026-07-05T10:00:00Z",
      "page" => 1,
      "per_page" => 2,
      "has_more" => false,
      "events" => [%{"tickera_event_id" => 109_316}],
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

  defp valid_v3_page(source_system_id, snapshot_id) do
    %{
      "schema_version" => "2026-08-07.v3",
      "canonical_contract_version" => "source_risk.v3",
      "producer_version" => "2026-08-07.1",
      "source" => "wordpress_tickera",
      "source_system_id" => source_system_id,
      "discovery_snapshot_id" => snapshot_id,
      "source_snapshot_at" => "2026-08-07T10:00:00Z",
      "generated_at" => "2026-08-07T10:00:01Z",
      "page" => 1,
      "per_page" => 50,
      "has_more" => false,
      "filters" => %{"include_private" => false},
      "events" => [
        %{
          "tickera_event_id" => 1,
          "event_source_created_at" => "2026-05-01T08:00:00Z",
          "event_source_updated_at" => "2026-06-01T10:00:00Z"
        }
      ],
      "catalog_rows" => [%{"woo_product_id" => 2}],
      "evidence" => [
        %{
          "dimension" => "lifecycle",
          "producer_scope" => "parent_product",
          "target" => %{"woo_product_id" => 2},
          "state" => "present",
          "producer_source_key" => "wp_posts.post_status",
          "completeness" => "partial",
          "provenance" => %{"producer_version" => "2026-08-07.1"},
          "value" => "draft"
        }
      ]
    }
  end

  defp restore_env(key, nil), do: Application.delete_env(:event_sales, key)
  defp restore_env(key, value), do: Application.put_env(:event_sales, key, value)
end
