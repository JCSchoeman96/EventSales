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
  alias EventSales.Catalog.TickeraCatalog.{Applier, DiscoveryResult, Plan, Planner}
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

    mp_ticket_a = SalesHelpers.create_ticket_type!(mp_event, %{name: "MP Ticket A"})
    mp_ticket_b = SalesHelpers.create_ticket_type!(mp_event, %{name: "MP Ticket B"})

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
