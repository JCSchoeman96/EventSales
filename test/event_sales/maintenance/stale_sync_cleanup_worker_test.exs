defmodule EventSales.Maintenance.StaleSyncCleanupWorkerTest do
  use EventSales.DataCase, async: false

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Maintenance.StaleSyncCleanupWorker
  alias EventSales.Telemetry
  alias EventSales.TestSupport.SalesHelpers

  setup do
    original = Application.get_env(:event_sales, :maintenance)

    Application.put_env(:event_sales, :maintenance,
      running_sync_stale_after_minutes: 60,
      paused_sync_stale_after_hours: 24,
      stale_sync_cleanup_batch_size: 100
    )

    on_exit(fn ->
      case original do
        nil -> Application.delete_env(:event_sales, :maintenance)
        value -> Application.put_env(:event_sales, :maintenance, value)
      end
    end)

    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Sync Cleanup", slug: "sync-cleanup"})
    %{source: source, event: event}
  end

  test "uses maintenance queue and low attempts" do
    assert StaleSyncCleanupWorker.__opts__() |> Keyword.fetch!(:queue) == :maintenance
    assert StaleSyncCleanupWorker.__opts__() |> Keyword.fetch!(:max_attempts) == 2
  end

  test "fails stale running and paused runs while keeping fresh and queued runs", context do
    stale_running = create_run!(context) |> start_run!()
    stale_paused = create_run!(context) |> start_run!() |> pause_run!()
    fresh_running = create_run!(context) |> start_run!()
    queued = create_run!(context)

    set_timestamps!(stale_running.id, %{
      started_at: ~U[2026-05-01 08:00:00.000000Z],
      updated_at: ~U[2026-05-01 08:00:00.000000Z]
    })

    set_timestamps!(stale_paused.id, %{
      updated_at: ~U[2026-05-01 08:00:00.000000Z]
    })

    set_timestamps!(fresh_running.id, %{
      started_at: ~U[2026-05-03 12:00:00.000000Z],
      updated_at: ~U[2026-05-03 12:00:00.000000Z]
    })

    handler_id = "stale-sync-cleanup-test-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      Telemetry.maintenance_stale_sync_cleanup_stop(),
      fn event_name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, event_name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert :ok =
             StaleSyncCleanupWorker.perform(%Oban.Job{
               args: %{"now" => "2026-05-03T12:45:00Z"}
             })

    assert Ash.get!(SyncRun, stale_running.id, domain: Ingestion).status == :failed
    assert Ash.get!(SyncRun, stale_paused.id, domain: Ingestion).status == :failed
    assert Ash.get!(SyncRun, fresh_running.id, domain: Ingestion).status == :running
    assert Ash.get!(SyncRun, queued.id, domain: Ingestion).status == :queued

    assert_receive {:telemetry, [:event_sales, :maintenance, :stale_sync_cleanup, :stop],
                    %{count: 2, duration: duration},
                    %{
                      worker: :stale_sync_cleanup_worker,
                      affected_count: 2,
                      running_count: 1,
                      paused_count: 1
                    }},
                   500

    assert is_integer(duration)
  end

  defp create_run!(%{source: source, event: event}) do
    Ash.create!(
      SyncRun,
      %{
        source_system_id: source.id,
        event_id: event.id,
        date_from: ~U[2026-05-01 00:00:00.000000Z],
        date_to: ~U[2026-05-02 00:00:00.000000Z],
        sync_mode: :shallow,
        requested_via: :manual
      },
      action: :queue_manual_scoped,
      domain: Ingestion,
      context: %{scoped_manual_sync_now: ~U[2026-05-16 12:00:00.000000Z]}
    )
  end

  defp start_run!(run), do: Ash.update!(run, %{}, action: :start, domain: Ingestion)

  defp pause_run!(run) do
    Ash.update!(
      run,
      %{
        paused_until: ~U[2026-05-03 13:00:00.000000Z],
        pause_reason: :rate_limited,
        last_error: "rate limited"
      },
      action: :pause,
      domain: Ingestion
    )
  end

  defp set_timestamps!(id, attrs) do
    import Ecto.Query
    dumped_id = Ecto.UUID.dump!(id)

    EventSales.Repo.update_all(
      from(run in "ingestion_sync_runs", where: run.id == ^dumped_id),
      set: Map.to_list(attrs)
    )
  end
end
