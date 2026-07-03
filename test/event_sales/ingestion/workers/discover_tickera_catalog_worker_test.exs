defmodule EventSales.Ingestion.Workers.DiscoverTickeraCatalogWorkerTest do
  use EventSales.DataCase, async: false

  alias EventSales.Catalog.TickeraCatalog.PubSub
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{TickeraCatalogSyncFinding, TickeraCatalogSyncRun}
  alias EventSales.Ingestion.Workers.DiscoverTickeraCatalogWorker
  alias EventSales.TestSupport.{SalesHelpers, TickeraCatalogFixtures}

  test "discovers manual rows, persists plan snapshot/findings, and broadcasts ready" do
    source = SalesHelpers.create_source_system!()

    run =
      Ash.create!(
        TickeraCatalogSyncRun,
        %{
          source_system_id: source.id,
          scope: %{
            "kind" => "manual_rows",
            "events" => [TickeraCatalogFixtures.zero_product_event()],
            "catalog_rows" => [TickeraCatalogFixtures.vwg_row()]
          }
        },
        action: :create_dry_run,
        domain: Ingestion
      )

    PubSub.subscribe(run.id)

    assert :ok = DiscoverTickeraCatalogWorker.perform(%Oban.Job{args: %{"run_id" => run.id}})

    updated = Ash.get!(TickeraCatalogSyncRun, run.id, domain: Ingestion)
    findings = Ash.read!(TickeraCatalogSyncFinding, domain: Ingestion)

    assert updated.status == :dry_run_ready
    assert is_binary(updated.dry_run_hash)
    assert is_map(updated.plan_snapshot)
    assert Enum.any?(findings, &(&1.code == :published_event_without_ticket_products))

    assert_receive {:catalog_sync_started, %{run_id: run_id}}
    assert run_id == run.id
    assert_receive {:catalog_sync_preview_ready, %{run_id: run_id}}
    assert run_id == run.id
  end
end
