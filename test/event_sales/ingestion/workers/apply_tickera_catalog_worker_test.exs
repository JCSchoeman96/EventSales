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

  alias EventSales.TestSupport.{
    AuthHelpers,
    CatalogSyncRunHelpers,
    SalesHelpers,
    TickeraCatalogFixtures
  }

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
      CatalogSyncRunHelpers.create_ready_catalog_sync_run!(
        source.id,
        %{"kind" => "woo_product", "woo_product_id" => 109_740},
        %{
          dry_run_hash: plan.dry_run_hash,
          summary: plan.summary,
          plan_snapshot: plan.plan_snapshot
        }
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

  test "stale hash leaves the unclaimed review-ready run unchanged" do
    source = SalesHelpers.create_source_system!()

    run =
      CatalogSyncRunHelpers.create_ready_catalog_sync_run!(
        source.id,
        %{"kind" => "manual_rows"},
        %{
          dry_run_hash: "current-hash",
          summary: %{},
          plan_snapshot: empty_snapshot("current-hash")
        }
      )

    assert {:error, :stale_dry_run_hash} =
             ApplyTickeraCatalogWorker.perform(%Oban.Job{
               args: %{"run_id" => run.id, "dry_run_hash" => "stale-hash"}
             })

    updated = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)
    assert updated.status == :dry_run_ready
    assert is_nil(updated.last_error)
  end

  test "queued Apply job discards when revocation wins and preserves its audit" do
    admin = AuthHelpers.create_user!("revoked-apply-worker@example.com")
    AuthHelpers.create_global_role!(admin, :admin)
    source = SalesHelpers.create_source_system!()

    run =
      CatalogSyncRunHelpers.create_ready_catalog_sync_run!(
        source.id,
        %{"kind" => "wordpress_feed", "mode" => "full"},
        %{
          dry_run_hash: "revoked-worker-hash",
          summary: %{},
          plan_snapshot: empty_snapshot("revoked-worker-hash")
        }
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

  test "failure transition loses to a concurrent revocation without false failure" do
    parent = self()
    admin = AuthHelpers.create_user!("failure-race-admin@example.com")
    AuthHelpers.create_global_role!(admin, :admin)
    source = SalesHelpers.create_source_system!()

    run =
      CatalogSyncRunHelpers.create_ready_catalog_sync_run!(
        source.id,
        %{"kind" => "wordpress_feed", "mode" => "full"},
        %{
          dry_run_hash: "failure-race-hash",
          summary: %{},
          plan_snapshot: %{}
        }
      )

    PubSub.subscribe(run.id)

    failure_task =
      Task.async(fn ->
        ApplyTickeraCatalogWorker.fail_run(run.id, :stale_dry_run_hash,
          before_update: fn ->
            send(parent, :before_failure_update)

            receive do
              :continue_failure_update -> :ok
            end
          end
        )
      end)

    assert_receive :before_failure_update

    assert {:ok, _revoked} =
             TickeraCatalogSync.revoke_ready_dry_run(
               run.id,
               %{cancellation_reason_code: :source_changed},
               actor: admin
             )

    send(failure_task.pid, :continue_failure_update)
    assert :discard = Task.await(failure_task)
    refute_receive {:catalog_sync_failed, _}

    reloaded = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)
    assert reloaded.status == :cancelled
    assert is_nil(reloaded.last_error)
    assert reloaded.cancelled_by_user_id == admin.id
  end

  test "stale plan.v3 Apply job discards without writing or marking the run applied" do
    source = SalesHelpers.create_source_system!()

    run =
      CatalogSyncRunHelpers.create_ready_catalog_sync_run!(
        source.id,
        %{"kind" => "wordpress_feed", "mode" => "full"},
        %{
          dry_run_hash: "native-v3-hash",
          summary: %{},
          plan_snapshot: review_only_snapshot()
        }
      )

    PubSub.subscribe(run.id)

    counts = %{
      events: Ash.count!(Event, domain: Catalog),
      ticket_types: Ash.count!(TicketType, domain: Catalog),
      mappings: Ash.count!(ProductMapping, domain: Catalog)
    }

    assert :discard =
             ApplyTickeraCatalogWorker.perform(%Oban.Job{
               args: %{"run_id" => run.id, "dry_run_hash" => "native-v3-hash"}
             })

    reloaded = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)

    assert reloaded.status == :dry_run_ready
    assert is_nil(reloaded.last_error)
    assert Ash.count!(Event, domain: Catalog) == counts.events
    assert Ash.count!(TicketType, domain: Catalog) == counts.ticket_types
    assert Ash.count!(ProductMapping, domain: Catalog) == counts.mappings
    refute_receive {:catalog_sync_applied, _payload}
    refute_receive {:catalog_sync_failed, _payload}
  end

  test "wrong-hash plan.v3 Apply job discards before Applier hash validation" do
    source = SalesHelpers.create_source_system!()

    run =
      CatalogSyncRunHelpers.create_ready_catalog_sync_run!(
        source.id,
        %{"kind" => "wordpress_feed", "mode" => "full"},
        %{
          dry_run_hash: "native-v3-hash",
          summary: %{},
          plan_snapshot: review_only_snapshot()
        }
      )

    PubSub.subscribe(run.id)

    counts = %{
      events: Ash.count!(Event, domain: Catalog),
      ticket_types: Ash.count!(TicketType, domain: Catalog),
      mappings: Ash.count!(ProductMapping, domain: Catalog)
    }

    # A wrong job hash would hit Applier's stale-hash check before version denial
    # if the worker deferred to Applier. Worker-level v3 gate must discard first.
    assert :discard =
             ApplyTickeraCatalogWorker.perform(%Oban.Job{
               args: %{"run_id" => run.id, "dry_run_hash" => "deliberately-wrong-hash"}
             })

    reloaded = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)

    assert reloaded.status == :dry_run_ready
    assert is_nil(reloaded.last_error)
    assert Ash.count!(Event, domain: Catalog) == counts.events
    assert Ash.count!(TicketType, domain: Catalog) == counts.ticket_types
    assert Ash.count!(ProductMapping, domain: Catalog) == counts.mappings
    refute_receive {:catalog_sync_applied, _payload}
    refute_receive {:catalog_sync_failed, _payload}
  end

  defp review_only_snapshot do
    %{
      "snapshot_schema_version" => "tickera_catalog_plan.v3",
      "event_actions" => [],
      "ticket_type_actions" => [],
      "product_mapping_actions" => [],
      "findings" => [],
      "canonical_source_risk_facts" => [],
      "canonical_source_risk_findings" => [],
      "touched_identifiers" => %{
        "event_ids" => [],
        "ticket_type_ids" => [],
        "mapping_ids" => [],
        "product_keys" => []
      }
    }
  end

  defp empty_snapshot(hash) do
    %{
      "dry_run_hash" => hash,
      "event_changes" => [],
      "ticket_type_changes" => [],
      "product_mapping_changes" => [],
      "findings" => [],
      "touched_event_ids" => [],
      "touched_product_keys" => []
    }
  end
end
