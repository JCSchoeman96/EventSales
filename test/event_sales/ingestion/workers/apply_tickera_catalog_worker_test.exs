defmodule EventSales.Ingestion.Workers.ApplyTickeraCatalogWorkerTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, ProductMapping, TicketType}
  alias EventSales.Catalog.TickeraCatalog.{DiscoveryResult, Planner, PubSub}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Ingestion.TickeraCatalogSync
  alias EventSales.Ingestion.Workers.ApplyTickeraCatalogWorker
  alias EventSales.TestSupport.{AuthHelpers, SalesHelpers, TickeraCatalogFixtures}

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

  test "stale hash fails without leaving run in applying status" do
    source = SalesHelpers.create_source_system!()

    run =
      Ash.create!(
        TickeraCatalogSyncRun,
        %{
          source_system_id: source.id,
          scope: %{"kind" => "manual_rows"},
          status: :dry_run_ready,
          dry_run_hash: "current-hash",
          summary: %{},
          plan_snapshot: %{
            "dry_run_hash" => "current-hash",
            "event_changes" => [],
            "ticket_type_changes" => [],
            "product_mapping_changes" => [],
            "findings" => [],
            "touched_event_ids" => [],
            "touched_product_keys" => []
          }
        },
        action: :create_dry_run,
        domain: Ingestion
      )

    assert {:error, :stale_dry_run_hash} =
             ApplyTickeraCatalogWorker.perform(%Oban.Job{
               args: %{"run_id" => run.id, "dry_run_hash" => "stale-hash"}
             })

    updated = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)
    assert updated.status == :failed
    assert updated.last_error == "stale_dry_run_hash"
  end

  test "queued Apply job discards when revocation wins and preserves its audit" do
    admin = AuthHelpers.create_user!("revoked-apply-worker@example.com")
    AuthHelpers.create_global_role!(admin, :admin)
    source = SalesHelpers.create_source_system!()

    run =
      Ash.create!(
        TickeraCatalogSyncRun,
        %{
          source_system_id: source.id,
          scope: %{"kind" => "wordpress_feed", "mode" => "full"},
          status: :dry_run_ready,
          dry_run_hash: "revoked-worker-hash",
          summary: %{},
          plan_snapshot: %{
            "dry_run_hash" => "revoked-worker-hash",
            "event_changes" => [],
            "ticket_type_changes" => [],
            "product_mapping_changes" => [],
            "findings" => [],
            "touched_event_ids" => [],
            "touched_product_keys" => []
          }
        },
        action: :create_dry_run,
        domain: Ingestion
      )

    assert {:ok, revoked} =
             TickeraCatalogSync.revoke_ready_dry_run(
               run.id,
               %{
                 cancellation_reason_code: :source_changed,
                 cancellation_reason_details: "Source changed before execution"
               },
               actor: admin
             )

    catalog_counts = %{
      events: Ash.count!(Event, domain: Catalog),
      ticket_types: Ash.count!(TicketType, domain: Catalog),
      mappings: Ash.count!(ProductMapping, domain: Catalog)
    }

    assert :discard =
             ApplyTickeraCatalogWorker.perform(%Oban.Job{
               args: %{"run_id" => run.id, "dry_run_hash" => run.dry_run_hash}
             })

    reloaded = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)
    assert reloaded.status == :cancelled
    assert reloaded.cancelled_at == revoked.cancelled_at
    assert reloaded.cancelled_by_user_id == admin.id
    assert reloaded.cancellation_reason_code == :source_changed
    assert reloaded.cancellation_reason_details == "Source changed before execution"
    assert is_nil(reloaded.last_error)
    assert Ash.count!(Event, domain: Catalog) == catalog_counts.events
    assert Ash.count!(TicketType, domain: Catalog) == catalog_counts.ticket_types
    assert Ash.count!(ProductMapping, domain: Catalog) == catalog_counts.mappings
  end
end
