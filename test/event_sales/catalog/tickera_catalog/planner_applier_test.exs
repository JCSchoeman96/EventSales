defmodule EventSales.Catalog.TickeraCatalog.PlannerApplierTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  require Ash.Query

  alias EventSales.Analytics.DashboardCache
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, ProductMapping, TicketType}
  alias EventSales.Catalog.TickeraCatalog.{Applier, DiscoveryResult, Planner}
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
    assert {:ok, _run} = Applier.apply(run.id, plan.dry_run_hash, actor: nil)

    updated_event = Ash.get!(Event, event.id, domain: Catalog)
    updated_ticket = Ash.get!(TicketType, ticket.id, domain: Catalog)

    assert updated_event.external_event_id == 109_316
    assert updated_event.external_event_kind == :tickera_event
    assert updated_event.name == "Manual VWG Pretoria"
    assert updated_ticket.external_ticket_type_id == 109_740
    assert updated_ticket.external_ticket_type_kind == :woo_product
    assert updated_ticket.name == "Manual Toegang"

    assert Ash.count!(Event, domain: Catalog) == 1
    assert Ash.count!(TicketType, domain: Catalog) == 1
    assert Ash.count!(ProductMapping, domain: Catalog) == 1
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

  test "applier rejects stale hash and missing plan snapshot", %{source: source} do
    assert {:ok, plan} = Planner.plan(source.id, discovery_result())
    run = create_run!(source.id, plan)
    missing_snapshot = create_run!(source.id, %{plan | plan_snapshot: nil})

    assert {:error, :stale_dry_run_hash} = Applier.apply(run.id, "wrong", actor: nil)

    assert {:error, :missing_plan_snapshot} =
             Applier.apply(missing_snapshot.id, plan.dry_run_hash, actor: nil)
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
