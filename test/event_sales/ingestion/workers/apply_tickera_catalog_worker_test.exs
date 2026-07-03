defmodule EventSales.Ingestion.Workers.ApplyTickeraCatalogWorkerTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Catalog.TickeraCatalog.{DiscoveryResult, Planner, PubSub}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Ingestion.Workers.ApplyTickeraCatalogWorker
  alias EventSales.TestSupport.{SalesHelpers, TickeraCatalogFixtures}

  test "applies a durable plan and broadcasts applied" do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Manual VWG", slug: "manual-worker-vwg"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "Manual Ticket"})

    Ash.create!(
      ProductMapping,
      %{
        source_system_id: source.id,
        event_id: event.id,
        ticket_type_id: ticket.id,
        woo_product_id: 109_740,
        woo_variation_id: nil,
        original_label: "Manual Ticket",
        current_label: "Manual Ticket",
        active: true
      },
      action: :create,
      domain: Catalog
    )

    {:ok, plan} =
      Planner.plan(source.id, %DiscoveryResult{
        events: [TickeraCatalogFixtures.vwg_event()],
        catalog_rows: [TickeraCatalogFixtures.vwg_row()]
      })

    run =
      Ash.create!(
        TickeraCatalogSyncRun,
        %{
          source_system_id: source.id,
          scope: %{"kind" => "woo_product", "woo_product_id" => 109_740},
          status: :dry_run_ready,
          dry_run_hash: plan.dry_run_hash,
          summary: plan.summary,
          plan_snapshot: plan.plan_snapshot
        },
        action: :create_dry_run,
        domain: Ingestion
      )

    PubSub.subscribe(run.id)

    assert :ok =
             ApplyTickeraCatalogWorker.perform(%Oban.Job{
               args: %{"run_id" => run.id, "dry_run_hash" => plan.dry_run_hash}
             })

    assert Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion).status == :applied
    assert_receive {:catalog_sync_applied, %{run_id: run_id}}
    assert run_id == run.id
  end
end
