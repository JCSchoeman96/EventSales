defmodule EventSales.Ingestion.Workers.CatalogChangeDispatchWorkerTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.CatalogChangePendingTarget
  alias EventSales.Ingestion.Workers.CatalogChangeDispatchWorker
  alias EventSales.TestSupport.SalesHelpers

  test "queues exactly one product target and snoozes for reconciliation" do
    old = Application.get_env(:event_sales, :catalog_change_trigger)

    Application.put_env(:event_sales, :catalog_change_trigger,
      dispatcher_enabled: true,
      active_run_recheck_seconds: 60
    )

    on_exit(fn -> Application.put_env(:event_sales, :catalog_change_trigger, old) end)
    source = SalesHelpers.create_source_system!()
    now = DateTime.add(DateTime.utc_now(), -10, :second)

    {:ok, target} =
      Ash.create(
        CatalogChangePendingTarget,
        %{
          source_system_id: source.id,
          target_type: :product,
          target_id: 456,
          latest_source_updated_at: now,
          latest_reason: :saved,
          first_received_at: now,
          last_received_at: now,
          quiet_until: now
        },
        action: :create,
        domain: Ingestion
      )

    assert {:snooze, 60} =
             perform_job(CatalogChangeDispatchWorker, %{"source_system_id" => source.id})

    linked = Ash.get!(CatalogChangePendingTarget, target.id, domain: Ingestion)
    assert linked.state == :queued
    assert linked.dispatched_generation == linked.generation
    refute is_nil(linked.catalog_sync_run_id)
  end
end
