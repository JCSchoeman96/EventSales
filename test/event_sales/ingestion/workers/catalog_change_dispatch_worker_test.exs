defmodule EventSales.Ingestion.Workers.CatalogChangeDispatchWorkerTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  alias EventSales.Ingestion
  alias EventSales.Ingestion.CatalogChangeDispatch
  alias EventSales.Ingestion.Resources.{CatalogChangePendingTarget, TickeraCatalogSyncRun}
  alias EventSales.Ingestion.Workers.CatalogChangeDispatchWorker
  alias EventSales.TestSupport.SalesHelpers

  setup do
    old = Application.get_env(:event_sales, :catalog_change_trigger)
    on_exit(fn -> Application.put_env(:event_sales, :catalog_change_trigger, old) end)
    :ok
  end

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

  test "disabled dispatcher snoozes its durable job and resumes without a new signal" do
    source = SalesHelpers.create_source_system!()
    target = create_target!(source.id)
    configure_dispatcher(false)

    assert {:snooze, 60} =
             perform_job(CatalogChangeDispatchWorker, %{"source_system_id" => source.id})

    assert Ash.get!(CatalogChangePendingTarget, target.id, domain: Ingestion).state == :pending

    configure_dispatcher(true)

    assert {:snooze, 60} =
             perform_job(CatalogChangeDispatchWorker, %{"source_system_id" => source.id})

    assert Ash.get!(CatalogChangePendingTarget, target.id, domain: Ingestion).state == :queued
  end

  test "generation advancing before the transaction lock retries newest work" do
    source = SalesHelpers.create_source_system!()
    target = create_target!(source.id)
    configure_dispatcher(true)

    advance_generation = fn ->
      EventSales.Repo.query!(
        "UPDATE ingestion_catalog_change_pending_targets SET generation = generation + 1 WHERE id = $1",
        [Ecto.UUID.dump!(target.id)]
      )

      :ok
    end

    assert {:snooze, 1} =
             CatalogChangeDispatch.perform(source.id,
               queue_opts: [before_trigger_lock: advance_generation]
             )

    reloaded = Ash.get!(CatalogChangePendingTarget, target.id, domain: Ingestion)
    assert reloaded.generation == 2
    assert reloaded.state == :pending
  end

  test "transient queue failure reaches Oban retry without failing the target" do
    source = SalesHelpers.create_source_system!()
    target = create_target!(source.id)
    configure_dispatcher(true)

    assert {:error, _reason} =
             CatalogChangeDispatch.perform(source.id,
               queue_opts: [
                 before_discovery_job_insert: fn -> {:error, :database_unavailable} end
               ]
             )

    assert Ash.get!(CatalogChangePendingTarget, target.id, domain: Ingestion).state == :pending
  end

  test "transition failure reaches Oban retry handling" do
    source = SalesHelpers.create_source_system!()
    _target = create_target!(source.id)
    configure_dispatcher(true)

    Ash.create!(
      TickeraCatalogSyncRun,
      %{source_system_id: source.id, scope: %{"kind" => "wordpress_feed", "event_id" => 99}},
      action: :create_dry_run,
      domain: Ingestion
    )

    assert {:error, :transition_unavailable} =
             CatalogChangeDispatch.perform(source.id,
               transition_fun: fn _target, _attrs -> {:error, :transition_unavailable} end
             )
  end

  defp create_target!(source_id) do
    now = DateTime.add(DateTime.utc_now(), -10, :second)

    Ash.create!(
      CatalogChangePendingTarget,
      %{
        source_system_id: source_id,
        target_type: :product,
        target_id: System.unique_integer([:positive]),
        latest_source_updated_at: now,
        latest_reason: :saved,
        first_received_at: now,
        last_received_at: now,
        quiet_until: now
      },
      action: :create,
      domain: Ingestion
    )
  end

  defp configure_dispatcher(enabled) do
    current = Application.get_env(:event_sales, :catalog_change_trigger, [])

    Application.put_env(
      :event_sales,
      :catalog_change_trigger,
      Keyword.merge(current,
        receiver_enabled: true,
        dispatcher_enabled: enabled,
        active_run_recheck_seconds: 60
      )
    )
  end
end
