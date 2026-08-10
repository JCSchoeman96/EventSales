defmodule EventSales.Catalog.TickeraCatalog.PlannerApplierTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics.DashboardCache
  alias EventSales.Catalog
  alias EventSales.Catalog.MappingConflictResolver
  alias EventSales.Catalog.Resources.{Event, ProductMapping, TicketType}

  alias EventSales.Catalog.TickeraCatalog.{
    Applier,
    DiscoveryResult,
    Plan,
    Planner,
    SnapshotCanonicalizer
  }

  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.{
    CanonicalFact,
    ContractRegistry,
    FindingPolicy
  }

  alias EventSales.Ingestion.Workers.MissingCatalogResolutionWorker
  alias EventSales.TestSupport.{CatalogSyncRunHelpers, SalesHelpers, TickeraCatalogFixtures}

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Manual VWG Pretoria", slug: "manual-vwg"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Manual Toegang"})

    mapping =
      Ash.create!(
        ProductMapping,
        %{
          source_system_id: source.id,
          event_id: event.id,
          ticket_type_id: ticket.id,
          woo_product_id: 109_740,
          woo_variation_id: nil,
          original_label: "Manual Toegang",
          current_label: "Manual Toegang",
          active: true
        },
        action: :create,
        domain: Catalog
      )

    {:ok, source: source, event: event, ticket: ticket, mapping: mapping}
  end

  test "planner adopts existing active product mapping before creating records", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    assert {:ok, plan} = Planner.plan(source.id, discovery_result())

    assert Enum.any?(plan.findings, &(&1.code == :existing_mapping_adopted))
    assert Enum.any?(plan.findings, &(&1.code == :vwg_pretoria_preserved))

    assert plan.event_changes == [
             %{
               action: :adopt_existing,
               event_id: event.id,
               external_event_id: 109_316,
               external_event_kind: :tickera_event,
               source_status: "publish",
               source_created_at: ~U[2026-05-01 08:00:00Z],
               source_updated_at: ~U[2026-06-01 10:00:00Z],
               starts_at: ~U[2026-08-01 16:00:00Z],
               ends_at: ~U[2026-08-01 18:00:00Z],
               venue_name: "Pretoria",
               booking_fee_type: :fixed,
               booking_fee_value: Decimal.new("25.00")
             }
           ]

    assert plan.ticket_type_changes == [
             %{
               action: :adopt_existing,
               ticket_type_id: ticket.id,
               event_id: event.id,
               external_ticket_type_id: 109_740,
               external_ticket_type_kind: :woo_product,
               external_product_id: 109_740,
               external_variation_id: nil,
               source_status: "publish",
               source_updated_at: ~U[2026-06-01 10:05:00Z]
             }
           ]

    assert plan.product_mapping_changes == []
  end

  test "new Event action carries authoritative source creation evidence", %{source: source} do
    discovery =
      discovery_result()
      |> Map.update!(:events, fn events ->
        Enum.map(events, &Map.put(&1, "tickera_event_id", 71_001))
      end)
      |> Map.update!(:catalog_rows, fn rows ->
        Enum.map(rows, fn row ->
          row
          |> Map.put("tickera_event_id", 71_001)
          |> Map.put("woo_product_id", 71_002)
        end)
      end)

    assert {:ok, plan} = Planner.plan(source.id, discovery)

    assert [%{action: :create, source_created_at: ~U[2026-05-01 08:00:00Z]}] =
             Enum.filter(plan.event_changes, &(&1.action == :create))
  end

  test "an existing Event without source creation evidence gets an update action", %{
    source: source
  } do
    event =
      SalesHelpers.create_event!(source, %{
        external_event_kind: :tickera_event,
        external_event_id: 71_003,
        source_updated_at: ~U[2026-06-01 10:00:00Z],
        starts_at: ~U[2026-08-01 16:00:00Z],
        ends_at: ~U[2026-08-01 18:00:00Z],
        venue_name: "Pretoria",
        booking_fee_type: :fixed,
        booking_fee_value: Decimal.new("25.00"),
        source_status: "publish"
      })

    discovery =
      discovery_result()
      |> Map.update!(:events, fn events ->
        Enum.map(events, &Map.put(&1, "tickera_event_id", 71_003))
      end)
      |> Map.update!(:catalog_rows, fn rows ->
        Enum.map(rows, fn row ->
          row
          |> Map.put("tickera_event_id", 71_003)
          |> Map.put("woo_product_id", 71_004)
        end)
      end)

    assert {:ok, plan} = Planner.plan(source.id, discovery)

    assert [%{action: :update_metadata, event_id: event_id, source_created_at: timestamp}] =
             Enum.filter(plan.event_changes, &(&1.action == :update_metadata))

    assert event_id == event.id
    assert timestamp == ~U[2026-05-01 08:00:00Z]
  end

  test "matching source creation evidence does not create a source-created delta", %{
    source: source
  } do
    event =
      SalesHelpers.create_event!(source, %{
        external_event_kind: :tickera_event,
        external_event_id: 71_005,
        source_updated_at: ~U[2026-06-01 10:00:00Z],
        starts_at: ~U[2026-08-01 16:00:00Z],
        ends_at: ~U[2026-08-01 18:00:00Z],
        venue_name: "Pretoria",
        booking_fee_type: :fixed,
        booking_fee_value: Decimal.new("25.00"),
        source_status: "publish"
      })

    assert {:ok, event} =
             Ash.update(
               event,
               %{source_created_at: ~U[2026-05-01 08:00:00Z]},
               action: :capture_source_created_at,
               domain: Catalog
             )

    discovery =
      discovery_result()
      |> Map.update!(:events, fn events ->
        Enum.map(events, &Map.put(&1, "tickera_event_id", 71_005))
      end)
      |> Map.update!(:catalog_rows, fn rows ->
        Enum.map(rows, fn row ->
          row
          |> Map.put("tickera_event_id", 71_005)
          |> Map.put("woo_product_id", 71_006)
        end)
      end)

    assert {:ok, plan} = Planner.plan(source.id, discovery)

    assert [%{action: :reuse, event_id: event_id}] = plan.event_changes
    assert event_id == event.id
  end

  test "different source creation evidence is represented as a metadata difference", %{
    source: source
  } do
    event =
      SalesHelpers.create_event!(source, %{
        external_event_kind: :tickera_event,
        external_event_id: 71_007,
        source_updated_at: ~U[2026-06-01 10:00:00Z],
        starts_at: ~U[2026-08-01 16:00:00Z],
        ends_at: ~U[2026-08-01 18:00:00Z],
        venue_name: "Pretoria",
        booking_fee_type: :fixed,
        booking_fee_value: Decimal.new("25.00"),
        source_status: "publish"
      })

    assert {:ok, event} =
             Ash.update(
               event,
               %{source_created_at: ~U[2026-04-30 08:00:00Z]},
               action: :capture_source_created_at,
               domain: Catalog
             )

    discovery =
      discovery_result()
      |> Map.update!(:events, fn events ->
        Enum.map(events, &Map.put(&1, "tickera_event_id", 71_007))
      end)
      |> Map.update!(:catalog_rows, fn rows ->
        Enum.map(rows, fn row ->
          row
          |> Map.put("tickera_event_id", 71_007)
          |> Map.put("woo_product_id", 71_008)
        end)
      end)

    assert {:ok, plan} = Planner.plan(source.id, discovery)

    assert [%{action: :update_metadata, event_id: event_id, source_created_at: timestamp}] =
             Enum.filter(plan.event_changes, &(&1.action == :update_metadata))

    assert event_id == event.id
    assert timestamp == ~U[2026-05-01 08:00:00Z]
  end

  test "v2 planner stores an exact eleven-key snapshot with an external hash", %{source: source} do
    discovery =
      discovery_result()
      |> Map.put(:schema_version, "2026-07-22.v2")
      |> Map.put(:auto_apply_proof_complete?, true)
      |> Map.put(:origin, :targeted_catalog_change)
      |> Map.update!(:events, fn events ->
        Enum.map(events, &Map.put(&1, "risk_codes", []))
      end)
      |> Map.update!(:catalog_rows, fn rows ->
        Enum.map(rows, &Map.put(&1, "risk_codes", ["unknown_product_semantics"]))
      end)

    assert {:ok, plan} = Planner.plan(source.id, discovery)

    assert Map.keys(plan.plan_snapshot) |> Enum.sort() ==
             ~w(
               event_actions findings historical_impact identity_membership_proof origin
               product_mapping_actions snapshot_schema_version source_risks source_system_id
               ticket_type_actions touched_identifiers
             )

    refute Map.has_key?(plan.plan_snapshot, "dry_run_hash")
    assert plan.plan_snapshot["snapshot_schema_version"] == "tickera_catalog_plan.v2"

    assert {:ok, _bytes, recomputed_hash} =
             EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizer.canonicalize(
               plan.plan_snapshot
             )

    assert recomputed_hash == plan.dry_run_hash
  end

  test "native v3 discovery plans a review-only plan.v3 snapshot with an external hash", %{
    source: source
  } do
    assert {:ok, plan} = Planner.plan(source.id, native_v3_discovery())

    assert Map.keys(plan.plan_snapshot) |> Enum.sort() ==
             ~w(
               canonical_source_risk_facts canonical_source_risk_findings event_actions findings
               historical_impact identity_membership_proof origin product_mapping_actions
               snapshot_schema_version source source_system_id ticket_type_actions
               touched_identifiers
             )

    assert plan.plan_snapshot["snapshot_schema_version"] == "tickera_catalog_plan.v3"
    refute Map.has_key?(plan.plan_snapshot, "dry_run_hash")
    refute Map.has_key?(plan.plan_snapshot, "source_risks")

    assert plan.plan_snapshot["source"] == %{
             "schema_version" => "2026-08-07.v3",
             "canonical_contract_version" => "source_risk.v3",
             "producer_version" => "2026-08-07.1",
             "source_system_id" => native_source_system_id(),
             "discovery_snapshot_id" => "native-snapshot-1",
             "source_snapshot_at" => "2026-08-07T09:00:00Z",
             "evidence_origin" => "native"
           }

    assert {:ok, _bytes, recomputed_hash} =
             SnapshotCanonicalizer.canonicalize(plan.plan_snapshot)

    assert recomputed_hash == plan.dry_run_hash
  end

  test "native v3 source-risk findings project as string codes without dynamic atoms", %{
    source: source
  } do
    assert {:ok, plan} = Planner.plan(source.id, native_v3_discovery())

    projected =
      Enum.filter(plan.findings, &(&1.code == "source_risk.lifecycle_draft"))

    assert [finding] = projected
    assert is_binary(finding.code)
    assert finding.severity == :blocking

    assert finding.message ==
             "Native source-risk finding: source_risk.lifecycle_draft (explicit_risk)"

    assert finding.metadata == %{"disposition" => "explicit_risk", "dimension_local_only" => true}
    assert is_nil(finding.tickera_event_id)
    assert is_nil(finding.woo_product_id)
    assert is_nil(finding.woo_variation_id)

    assert Enum.any?(plan.findings, &(&1.code == "contract.evidence_conflict"))
    assert Enum.any?(plan.findings, &(&1.code == :existing_mapping_adopted))

    assert_raise ArgumentError, fn -> String.to_existing_atom("source_risk.lifecycle_draft") end

    snapshot_codes = Enum.map(plan.plan_snapshot["findings"], & &1["code"])
    assert "source_risk.lifecycle_draft" in snapshot_codes
    assert "existing_mapping_adopted" in snapshot_codes
  end

  test "native v3 plan serializes canonical facts with multi-record provenance lists", %{
    source: source
  } do
    assert {:ok, plan} = Planner.plan(source.id, native_v3_discovery())

    facts = plan.plan_snapshot["canonical_source_risk_facts"]

    assert Enum.map(facts, & &1["dimension"]) == ~w(lifecycle subscription)
    assert Enum.all?(facts, &is_list(&1["provenance"]))
    assert Enum.all?(facts, &(&1["target"] == %{"woo_product_id" => 109_740}))

    lifecycle_fact = Enum.find(facts, &(&1["dimension"] == "lifecycle"))
    assert length(lifecycle_fact["provenance"]) == 2
    assert lifecycle_fact["value"] == "draft"

    subscription_fact = Enum.find(facts, &(&1["dimension"] == "subscription"))
    assert is_nil(subscription_fact["value"])

    assert Enum.map(
             plan.plan_snapshot["canonical_source_risk_findings"],
             & &1["implies_apply_eligible"]
           ) == [false, false]
  end

  test "native v3 discovery with an inconsistent contract combination fails closed", %{
    source: source
  } do
    for override <- [
          %{schema_version: "2026-07-22.v2"},
          %{canonical_contract_version: "compat.v2_to_source_risk_v3.v1"},
          %{producer_version: "2026-08-07.2"},
          %{evidence_origin: nil}
        ] do
      discovery = struct!(native_v3_discovery(), override)

      assert {:error, :inconsistent_native_v3_discovery} = Planner.plan(source.id, discovery)
    end
  end

  test "native v3 discovery requires exact producer_version 2026-08-07.1", %{source: source} do
    assert {:ok, plan} = Planner.plan(source.id, native_v3_discovery())
    assert plan.plan_snapshot["source"]["producer_version"] == "2026-08-07.1"

    assert {:error, :inconsistent_native_v3_discovery} =
             Planner.plan(
               source.id,
               struct!(native_v3_discovery(), producer_version: "2026-08-07.2")
             )
  end

  test "applier denies a plan.v3 snapshot before any catalogue write", %{source: source} do
    assert {:ok, plan} = Planner.plan(source.id, native_v3_discovery())
    run = create_run!(source.id, plan)

    counts = %{
      events: Ash.count!(Event, domain: Catalog),
      ticket_types: Ash.count!(TicketType, domain: Catalog),
      mappings: Ash.count!(ProductMapping, domain: Catalog)
    }

    assert {:error, :unsupported_snapshot_version} =
             Applier.apply(run.id, plan.dry_run_hash, actor: nil)

    assert Ash.count!(Event, domain: Catalog) == counts.events
    assert Ash.count!(TicketType, domain: Catalog) == counts.ticket_types
    assert Ash.count!(ProductMapping, domain: Catalog) == counts.mappings

    assert Ash.get!(
             EventSales.Ingestion.Resources.TickeraCatalogSyncRun,
             run.id,
             domain: EventSales.Ingestion
           ).status == :dry_run_ready
  end

  test "applier adopts existing records idempotently from durable plan snapshot", %{
    source: source,
    event: event,
    ticket: ticket
  } do
    DashboardCache.ensure_table!()
    DashboardCache.put_event_summary(event.id, %{total_sold: 5})

    assert {:ok, plan} = Planner.plan(source.id, discovery_result())
    run = create_run!(source.id, plan)

    assert {:ok, _run} = Applier.apply(run.id, plan.dry_run_hash, actor: nil)
    assert {:error, :run_not_ready} = Applier.apply(run.id, plan.dry_run_hash, actor: nil)

    updated_event = Ash.get!(Event, event.id, domain: Catalog)
    updated_ticket = Ash.get!(TicketType, ticket.id, domain: Catalog)

    assert updated_event.external_event_id == 109_316
    assert updated_event.external_event_kind == :tickera_event
    assert updated_event.name == "Manual VWG Pretoria"
    assert updated_event.starts_at == ~U[2026-08-01 16:00:00.000000Z]
    assert updated_event.ends_at == ~U[2026-08-01 18:00:00.000000Z]
    assert updated_event.venue_name == "Pretoria"
    assert updated_event.booking_fee_type == :fixed
    assert updated_event.booking_fee_value == Decimal.new("25.00")
    assert updated_ticket.external_ticket_type_id == 109_740
    assert updated_ticket.external_ticket_type_kind == :woo_product
    assert updated_ticket.name == "Manual Toegang"

    assert event_count(source.id) == 1
    assert ticket_type_count(event.id) == 1
    assert mapping_count(source.id) == 1
    assert DashboardCache.get_event_summary(event.id) == :miss

    assert_enqueued(
      worker: MissingCatalogResolutionWorker,
      queue: :webhooks,
      args: %{
        "source_system_id" => source.id,
        "woo_product_id" => 109_740,
        "woo_variation_id" => nil
      }
    )
  end

  test "planner reuses source-managed event and ticket type before creating a missing mapping", %{
    source: source
  } do
    event =
      SalesHelpers.create_event!(source, %{
        name: "Source Managed Event",
        slug: "source-managed-event",
        external_event_id: 500_001,
        external_event_kind: :tickera_event,
        source_status: "publish"
      })

    ticket =
      SalesHelpers.create_ticket_type!(event, %{
        name: "Source Managed Ticket",
        external_ticket_type_id: 500_740,
        external_ticket_type_kind: :woo_product,
        external_product_id: 500_740,
        source_status: "publish"
      })

    row =
      TickeraCatalogFixtures.vwg_row()
      |> Map.merge(%{
        "tickera_event_id" => 500_001,
        "event_title" => "Source Managed Event",
        "event_slug" => "source-managed-event",
        "woo_product_id" => 500_740,
        "product_title" => "Source Managed Product",
        "product_slug" => "source-managed-product"
      })

    result = %DiscoveryResult{
      events: [
        TickeraCatalogFixtures.vwg_event()
        |> Map.merge(%{
          "tickera_event_id" => 500_001,
          "event_title" => "Source Managed Event",
          "event_slug" => "source-managed-event",
          "event_status" => "publish"
        })
      ],
      catalog_rows: [row]
    }

    assert {:ok, plan} = Planner.plan(source.id, result)

    event_id = event.id
    ticket_id = ticket.id

    assert [%{action: :update_metadata, event_id: ^event_id} = event_change] = plan.event_changes
    assert event_change.starts_at == ~U[2026-08-01 16:00:00Z]
    assert event_change.venue_name == "Pretoria"
    assert [%{action: :reuse, ticket_type_id: ^ticket_id}] = plan.ticket_type_changes
    assert [%{action: :create, woo_product_id: 500_740}] = plan.product_mapping_changes
  end

  test "applier updates reused source-managed event metadata without changing mappings", %{
    source: source
  } do
    event =
      SalesHelpers.create_event!(source, %{
        name: "Source Managed Event",
        slug: "source-managed-event-metadata",
        external_event_id: 600_001,
        external_event_kind: :tickera_event,
        source_status: "publish"
      })

    ticket =
      SalesHelpers.create_ticket_type!(event, %{
        name: "Source Managed Ticket",
        external_ticket_type_id: 600_740,
        external_ticket_type_kind: :woo_product,
        external_product_id: 600_740,
        source_status: "publish"
      })

    row =
      TickeraCatalogFixtures.vwg_row()
      |> Map.merge(%{
        "tickera_event_id" => 600_001,
        "event_title" => "Source Managed Event",
        "event_slug" => "source-managed-event-metadata",
        "woo_product_id" => 600_740,
        "product_title" => "Source Managed Product",
        "product_slug" => "source-managed-product"
      })

    result = %DiscoveryResult{
      events: [
        TickeraCatalogFixtures.vwg_event()
        |> Map.merge(%{
          "tickera_event_id" => 600_001,
          "event_title" => "Source Managed Event",
          "event_slug" => "source-managed-event-metadata"
        })
      ],
      catalog_rows: [row]
    }

    assert {:ok, plan} = Planner.plan(source.id, result)
    run = create_run!(source.id, plan)

    assert {:ok, _run} = Applier.apply(run.id, plan.dry_run_hash, actor: nil)

    updated_event = Ash.get!(Event, event.id, domain: Catalog)
    assert updated_event.starts_at == ~U[2026-08-01 16:00:00.000000Z]
    assert updated_event.venue_name == "Pretoria"
    assert updated_event.booking_fee_type == :fixed
    assert mapping_count(source.id) == 2
    assert ticket_type_count(event.id) == 1
    assert ticket.id == Ash.get!(TicketType, ticket.id, domain: Catalog).id
  end

  test "applier rejects stale hash and missing plan snapshot", %{source: source} do
    assert {:ok, plan} = Planner.plan(source.id, discovery_result())
    run = create_run!(source.id, plan)

    missing_snapshot =
      create_run!(
        SalesHelpers.create_source_system!(%{name: "Planner Applier Missing Snapshot Fixture"}).id,
        %{plan | plan_snapshot: nil}
      )

    assert {:error, :stale_dry_run_hash} = Applier.apply(run.id, "wrong", actor: nil)

    assert {:error, :missing_plan_snapshot} =
             Applier.apply(missing_snapshot.id, plan.dry_run_hash, actor: nil)
  end

  test "applier rejects runs that are not dry_run_ready", %{source: source} do
    assert {:ok, plan} = Planner.plan(source.id, discovery_result())

    queued_run =
      CatalogSyncRunHelpers.create_queued_catalog_sync_run!(
        source.id,
        %{"kind" => "woo_product", "woo_product_id" => 109_740}
      )

    assert {:error, :run_not_ready} = Applier.apply(queued_run.id, plan.dry_run_hash, actor: nil)
  end

  test "applier rolls back catalog writes when a later apply step fails", %{source: source} do
    snapshot = %{
      "source_system_id" => source.id,
      "event_changes" => [
        %{
          "action" => "create",
          "ref" => "tickera_event:777001",
          "source_system_id" => source.id,
          "name" => "Rollback Event",
          "slug" => "rollback-event",
          "external_event_id" => 777_001,
          "external_event_kind" => "tickera_event",
          "source_status" => "publish"
        }
      ],
      "ticket_type_changes" => [],
      "product_mapping_changes" => [
        %{
          "action" => "create",
          "event_ref" => "tickera_event:777001",
          "ticket_type_ref" => "missing-ticket",
          "source_system_id" => source.id,
          "woo_product_id" => 777_740,
          "woo_variation_id" => nil,
          "original_label" => "Rollback Ticket",
          "current_label" => "Rollback Ticket"
        }
      ],
      "findings" => [],
      "touched_event_ids" => [],
      "touched_product_keys" => [[777_740, nil]]
    }

    run =
      create_run!(source.id, %Plan{
        dry_run_hash: "rollback-hash",
        summary: %{},
        plan_snapshot: snapshot
      })

    assert {:error, %KeyError{}} = Applier.apply(run.id, "rollback-hash", actor: nil)
    assert event_count(source.id) == 1
  end

  test "planner creates normal WR plan after stale MP mappings are deactivated", %{source: source} do
    admin = create_admin!("vs-26i-4-planner-admin@example.com")

    mp_event =
      SalesHelpers.create_event!(source, %{
        name: "Lynette Beer LIVE - MP",
        slug: "lynette-beer-live-mp",
        external_event_id: 108_658,
        external_event_kind: :tickera_event
      })

    mp_ticket_a =
      SalesHelpers.create_ticket_type!(mp_event, %{
        name: "MP Ticket A",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 109_165,
        external_product_id: 109_132,
        external_variation_id: 109_165
      })

    mp_ticket_b =
      SalesHelpers.create_ticket_type!(mp_event, %{
        name: "MP Ticket B",
        external_ticket_type_kind: :woo_variation,
        external_ticket_type_id: 109_167,
        external_product_id: 109_132,
        external_variation_id: 109_167
      })

    stale_a =
      create_mapping!(source, mp_event, mp_ticket_a, %{
        woo_product_id: 109_132,
        woo_variation_id: 109_165,
        original_label: "MP Ticket A",
        current_label: "MP Ticket A"
      })

    stale_b =
      create_mapping!(source, mp_event, mp_ticket_b, %{
        woo_product_id: 109_132,
        woo_variation_id: 109_167,
        original_label: "MP Ticket B",
        current_label: "MP Ticket B"
      })

    discovery = lynette_wr_discovery()

    assert {:ok, blocked_plan} = Planner.plan(source.id, discovery)

    assert Enum.count(
             blocked_plan.findings,
             &(&1.code == :existing_mapping_conflict and &1.woo_product_id == 109_132)
           ) == 2

    run = create_run!(source.id, blocked_plan)

    assert {:ok, %{mapping: %{id: stale_a_id}}} =
             MappingConflictResolver.deactivate_stale_mapping(
               run.id,
               blocked_plan.dry_run_hash,
               109_132,
               109_165,
               actor: admin
             )

    assert {:ok, %{mapping: %{id: stale_b_id}}} =
             MappingConflictResolver.deactivate_stale_mapping(
               run.id,
               blocked_plan.dry_run_hash,
               109_132,
               109_167,
               actor: admin
             )

    assert stale_a_id == stale_a.id
    assert stale_b_id == stale_b.id

    assert {:ok, resolved_plan} = Planner.plan(source.id, discovery)

    refute Enum.any?(
             resolved_plan.findings,
             &(&1.code == :existing_mapping_conflict and &1.woo_product_id == 109_132)
           )

    assert [%{action: :create, external_event_id: 109_120}] = resolved_plan.event_changes

    assert Enum.sort(Enum.map(resolved_plan.ticket_type_changes, & &1.external_ticket_type_id)) ==
             [109_165, 109_167]

    assert Enum.all?(resolved_plan.ticket_type_changes, &(&1.action == :create))

    assert Enum.sort(Enum.map(resolved_plan.product_mapping_changes, & &1.woo_variation_id)) ==
             [109_165, 109_167]

    assert Enum.all?(resolved_plan.product_mapping_changes, &(&1.action == :create))
  end

  defp event_count(source_system_id) do
    Event
    |> Ash.Query.filter(source_system_id == ^source_system_id)
    |> Ash.count!(domain: Catalog)
  end

  defp ticket_type_count(event_id) do
    TicketType
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.count!(domain: Catalog)
  end

  defp mapping_count(source_system_id) do
    ProductMapping
    |> Ash.Query.filter(source_system_id == ^source_system_id)
    |> Ash.count!(domain: Catalog)
  end

  defp discovery_result do
    %DiscoveryResult{
      events: [TickeraCatalogFixtures.vwg_event()],
      catalog_rows: [TickeraCatalogFixtures.vwg_row()]
    }
  end

  defp native_v3_discovery do
    lifecycle = native_fact("lifecycle", "present", "draft", "slot.lifecycle.wp_post_status")

    lifecycle = %{
      lifecycle
      | provenance:
          lifecycle.provenance ++
            [%{"discovery_snapshot_id" => "native-snapshot-1", "raw_producer_code" => "draft"}]
    }

    conflicting = %{
      lifecycle
      | value: "private",
        provenance: List.first(lifecycle.provenance) |> List.wrap()
    }

    subscription =
      native_fact("subscription", "unknown", nil, "slot.subscription.detection")

    %DiscoveryResult{
      schema_version: "2026-08-07.v3",
      auto_apply_proof_complete?: false,
      origin: :human_admin,
      events: [TickeraCatalogFixtures.vwg_event()],
      catalog_rows: [TickeraCatalogFixtures.vwg_row()],
      source_snapshot_at: ~U[2026-08-07 09:00:00Z],
      canonical_contract_version: "source_risk.v3",
      producer_version: "2026-08-07.1",
      source_system_id: native_source_system_id(),
      discovery_snapshot_id: "native-snapshot-1",
      normalization_mode: :native_v3_review,
      evidence_origin: :native,
      canonical_source_risk_facts: CanonicalFact.sort_facts([lifecycle, subscription]),
      canonical_source_risk_findings: [
        FindingPolicy.evaluate(lifecycle),
        FindingPolicy.evaluate_conflict(lifecycle, conflicting)
      ]
    }
  end

  defp native_fact(dimension, state, value, authority_slot) do
    {:ok, authority} = ContractRegistry.authority_for_slot(authority_slot)
    {:ok, producer_source_key} = ContractRegistry.producer_source_key_for_authority(authority)

    %CanonicalFact{
      run_id: "native-snapshot-1",
      dimension: dimension,
      semantic_scope: "parent_product",
      target: %{woo_product_id: 109_740},
      authority_slot: authority_slot,
      authority: authority,
      state: state,
      completeness: "exhaustive",
      origin: "native",
      value: value,
      provenance: [
        %{
          "discovery_snapshot_id" => "native-snapshot-1",
          "producer_version" => "2026-08-07.1",
          "producer_source_key" => producer_source_key,
          "woo_product_id" => 109_740
        }
      ]
    }
  end

  defp native_source_system_id, do: "wordpress_tickera:" <> String.duplicate("a", 64)

  defp lynette_wr_discovery do
    %DiscoveryResult{
      events: [TickeraCatalogFixtures.lynette_wr_event()],
      catalog_rows: TickeraCatalogFixtures.lynette_wr_variation_rows()
    }
  end

  defp create_mapping!(source, event, ticket, attrs) do
    defaults = %{
      source_system_id: source.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_product_id: 1,
      woo_variation_id: nil,
      original_label: "Ticket",
      current_label: "Ticket",
      active: true
    }

    Ash.create!(ProductMapping, Map.merge(defaults, attrs), action: :create, domain: Catalog)
  end

  defp create_admin!(email) do
    user =
      Ash.create!(
        User,
        %{
          email: email,
          name: "Admin",
          password: "valid-pass-123",
          password_confirmation: "valid-pass-123"
        },
        action: :register_with_password,
        domain: Accounts
      )

    role =
      Role
      |> Ash.Query.filter(name == :admin)
      |> Ash.read_one!(domain: Accounts)
      |> case do
        nil -> Ash.create!(Role, %{name: :admin}, action: :create, domain: Accounts)
        role -> role
      end

    Ash.create!(UserRole, %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )

    user
  end

  defp create_run!(source_system_id, plan) do
    CatalogSyncRunHelpers.create_ready_catalog_sync_run!(
      source_system_id,
      %{"kind" => "woo_product", "woo_product_id" => 109_740},
      %{
        dry_run_hash: plan.dry_run_hash,
        summary: plan.summary,
        plan_snapshot: plan.plan_snapshot
      }
    )
  end
end
