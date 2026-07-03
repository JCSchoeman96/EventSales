defmodule EventSales.Catalog.TickeraCatalog.PlannerApplierTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  require Ash.Query

  alias EventSales.Analytics.DashboardCache
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, ProductMapping, TicketType}
  alias EventSales.Catalog.TickeraCatalog.{Applier, DiscoveryResult, Plan, Planner}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Ingestion.Workers.MissingCatalogResolutionWorker
  alias EventSales.TestSupport.{SalesHelpers, TickeraCatalogFixtures}

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
               source_updated_at: ~U[2026-06-01 10:00:00Z]
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
        %{
          "tickera_event_id" => 500_001,
          "event_title" => "Source Managed Event",
          "event_slug" => "source-managed-event",
          "event_status" => "publish"
        }
      ],
      catalog_rows: [row]
    }

    assert {:ok, plan} = Planner.plan(source.id, result)

    event_id = event.id
    ticket_id = ticket.id

    assert [%{action: :reuse, event_id: ^event_id}] = plan.event_changes
    assert [%{action: :reuse, ticket_type_id: ^ticket_id}] = plan.ticket_type_changes
    assert [%{action: :create, woo_product_id: 500_740}] = plan.product_mapping_changes
  end

  test "applier rejects stale hash and missing plan snapshot", %{source: source} do
    assert {:ok, plan} = Planner.plan(source.id, discovery_result())
    run = create_run!(source.id, plan)
    missing_snapshot = create_run!(source.id, %{plan | plan_snapshot: nil})

    assert {:error, :stale_dry_run_hash} = Applier.apply(run.id, "wrong", actor: nil)

    assert {:error, :missing_plan_snapshot} =
             Applier.apply(missing_snapshot.id, plan.dry_run_hash, actor: nil)
  end

  test "applier rejects runs that are not dry_run_ready", %{source: source} do
    assert {:ok, plan} = Planner.plan(source.id, discovery_result())

    queued_run =
      Ash.create!(
        TickeraCatalogSyncRun,
        %{
          source_system_id: source.id,
          scope: %{"kind" => "woo_product", "woo_product_id" => 109_740},
          status: :queued,
          dry_run_hash: plan.dry_run_hash,
          summary: plan.summary,
          plan_snapshot: plan.plan_snapshot
        },
        action: :create_dry_run,
        domain: Ingestion
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

  defp create_run!(source_system_id, plan) do
    Ash.create!(
      TickeraCatalogSyncRun,
      %{
        source_system_id: source_system_id,
        scope: %{"kind" => "woo_product", "woo_product_id" => 109_740},
        status: :dry_run_ready,
        dry_run_hash: plan.dry_run_hash,
        summary: plan.summary,
        plan_snapshot: plan.plan_snapshot
      },
      action: :create_dry_run,
      domain: Ingestion
    )
  end
end
