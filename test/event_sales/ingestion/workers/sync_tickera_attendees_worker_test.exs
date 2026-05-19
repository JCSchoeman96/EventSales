defmodule EventSales.Ingestion.Workers.SyncTickeraAttendeesWorkerTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  import ExUnit.Callbacks, only: [on_exit: 1]
  import EventSales.TestSupport.TickeraSyncTestHelpers

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Clients.TickeraError
  alias EventSales.Ingestion.Resources.TickeraAttendeeSyncRun
  alias EventSales.Ingestion.TickeraAttendeeSyncRuns
  alias EventSales.Ingestion.TickeraEventSources
  alias EventSales.Ingestion.Workers.{ReconcileOrdersWorker, SyncTickeraAttendeesWorker}
  alias EventSales.TestSupport.Fakes.FakeTickeraAttendeeClient

  setup [:setup_fake_client, :setup_admin]

  test "malformed args discard", %{} do
    assert :discard = perform(%{})
  end

  test "missing run discards", %{env_var: env_var} do
    put_env!(env_var, "key")
    assert :discard = perform(%{"sync_run_id" => Ecto.UUID.generate()})
  end

  test "completed run discards", %{admin: admin, source: source, env_var: env_var} do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)
    {:ok, started} = TickeraAttendeeSyncRuns.mark_started(run, internal?: true)
    {:ok, completed} = TickeraAttendeeSyncRuns.mark_completed(started, internal?: true)

    FakeTickeraAttendeeClient.reset!({:ok, page_result()})
    assert :discard = perform(%{"sync_run_id" => completed.id})
    assert [] = FakeTickeraAttendeeClient.calls()
  end

  test "completed run discard emits no sync telemetry", %{
    admin: admin,
    source: source,
    env_var: env_var
  } do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)
    {:ok, started} = TickeraAttendeeSyncRuns.mark_started(run, internal?: true)
    {:ok, completed} = TickeraAttendeeSyncRuns.mark_completed(started, internal?: true)

    handler_id = "tickera-worker-discard-#{System.unique_integer([:positive])}"
    test_pid = self()

    for event <- [:start, :stop, :exception] do
      :ok =
        :telemetry.attach(
          "#{handler_id}-#{event}",
          [:event_sales, :tickera, :sync, event],
          fn _event, _measurements, _metadata, _config ->
            send(test_pid, {:tickera_sync, event})
          end,
          nil
        )
    end

    on_exit(fn ->
      for event <- [:start, :stop, :exception] do
        :telemetry.detach("#{handler_id}-#{event}")
      end
    end)

    FakeTickeraAttendeeClient.reset!({:ok, page_result()})
    assert :discard = perform(%{"sync_run_id" => completed.id})

    refute_receive {:tickera_sync, _}, 100
  end

  test "inactive source fails without client call", %{
    source: source,
    env_var: env_var,
    admin: admin
  } do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)
    {:ok, _deactivated} = TickeraEventSources.deactivate_source(source, actor: admin)

    FakeTickeraAttendeeClient.reset!({:ok, page_result()})
    assert :ok = perform(%{"sync_run_id" => run.id})
    assert [] = FakeTickeraAttendeeClient.calls()

    reloaded = Ash.get!(TickeraAttendeeSyncRun, run.id, domain: Ingestion)
    assert reloaded.status == :failed
    assert reloaded.last_error == "tickera_source_inactive"
  end

  test "queued run starts and fetches first page", %{
    admin: admin,
    source: source,
    env_var: env_var
  } do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)

    FakeTickeraAttendeeClient.reset!(
      {:ok, page_result(%{attendees: [attendee()], count: 1, per_page: 1})}
    )

    assert {:snooze, 1} = perform(%{"sync_run_id" => run.id})
    assert [_call] = FakeTickeraAttendeeClient.calls()

    reloaded = Ash.get!(TickeraAttendeeSyncRun, run.id, domain: Ingestion)
    assert reloaded.status == :running
    assert reloaded.current_page == 2
  end

  test "full page returns snooze and advances current_page", %{
    admin: admin,
    source: source,
    env_var: env_var
  } do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)

    attendees = [attendee(), attendee()]

    FakeTickeraAttendeeClient.reset!(
      {:ok, page_result(%{attendees: attendees, count: 2, per_page: 2, page: 1})}
    )

    assert {:snooze, 1} = perform(%{"sync_run_id" => run.id})
    reloaded = Ash.get!(TickeraAttendeeSyncRun, run.id, domain: Ingestion)
    assert reloaded.status == :running
    assert reloaded.current_page == 2
  end

  test "future paused run snoozes without Tickera call", %{
    admin: admin,
    source: source,
    env_var: env_var
  } do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)
    {:ok, started} = TickeraAttendeeSyncRuns.mark_started(run, internal?: true)

    paused_until = DateTime.add(DateTime.utc_now(), 120, :second)

    {:ok, paused} =
      TickeraAttendeeSyncRuns.mark_paused(
        started,
        %{paused_until: paused_until, pause_reason: :rate_limited, last_error: "429"},
        internal?: true
      )

    FakeTickeraAttendeeClient.reset!({:ok, page_result()})
    assert {:snooze, seconds} = perform(%{"sync_run_id" => paused.id})
    assert seconds > 0
    assert [] = FakeTickeraAttendeeClient.calls()
  end

  test "elapsed paused run resumes and fetches", %{
    admin: admin,
    source: source,
    env_var: env_var
  } do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)
    {:ok, started} = TickeraAttendeeSyncRuns.mark_started(run, internal?: true)
    paused_until = DateTime.add(DateTime.utc_now(), -5, :second)

    {:ok, paused} =
      TickeraAttendeeSyncRuns.mark_paused(
        started,
        %{paused_until: paused_until, pause_reason: :rate_limited, last_error: "429"},
        internal?: true
      )

    FakeTickeraAttendeeClient.reset!(
      {:ok, page_result(%{attendees: [attendee()], count: 1, per_page: 50})}
    )

    assert :ok = perform(%{"sync_run_id" => paused.id})
    assert [_call] = FakeTickeraAttendeeClient.calls()

    reloaded = Ash.get!(TickeraAttendeeSyncRun, paused.id, domain: Ingestion)
    assert reloaded.status == :completed
  end

  test "retryable Tickera error pauses and snoozes", %{
    admin: admin,
    source: source,
    env_var: env_var
  } do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)

    FakeTickeraAttendeeClient.reset!(
      {:error, %TickeraError{reason: :rate_limited, operation: :fetch_attendees_page}}
    )

    assert {:snooze, _seconds} = perform(%{"sync_run_id" => run.id})

    reloaded = Ash.get!(TickeraAttendeeSyncRun, run.id, domain: Ingestion)
    assert reloaded.status == :paused
    assert reloaded.pause_reason == :rate_limited
  end

  test "non-retryable Tickera error fails run", %{admin: admin, source: source, env_var: env_var} do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)

    FakeTickeraAttendeeClient.reset!(
      {:error, %TickeraError{reason: :unauthorized, operation: :fetch_attendees_page}}
    )

    assert :ok = perform(%{"sync_run_id" => run.id})
    reloaded = Ash.get!(TickeraAttendeeSyncRun, run.id, domain: Ingestion)
    assert reloaded.status == :failed
    assert reloaded.last_error == "tickera_unauthorized"
  end

  test "missing api key env fails without client call", %{admin: admin, source: source} do
    System.delete_env(source.api_key_env_var)
    run = queue_sync_run!(source, admin)

    FakeTickeraAttendeeClient.reset!({:ok, page_result()})
    assert :ok = perform(%{"sync_run_id" => run.id})
    assert [] = FakeTickeraAttendeeClient.calls()
    assert Ash.get!(TickeraAttendeeSyncRun, run.id, domain: Ingestion).status == :failed
  end

  test "duplicate full page pauses without advancing page", %{
    admin: admin,
    source: source,
    env_var: env_var
  } do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)

    attendees = [attendee(%{ticket_code: "DUP-A"}), attendee(%{ticket_code: "DUP-B"})]
    per_page = 2

    signature =
      attendees
      |> Enum.map_join("|", & &1.ticket_code)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    {:ok, run} =
      TickeraAttendeeSyncRuns.record_page(
        run,
        %{
          current_page: 1,
          last_successful_page: 1,
          last_page_count: 2,
          last_page_signature: signature
        },
        internal?: true
      )

    FakeTickeraAttendeeClient.reset!(
      {:ok, page_result(%{attendees: attendees, count: 2, per_page: per_page, page: 1})}
    )

    assert {:snooze, 300} = perform(%{"sync_run_id" => run.id})

    reloaded = Ash.get!(TickeraAttendeeSyncRun, run.id, domain: Ingestion)
    assert reloaded.status == :paused
    assert reloaded.pause_reason == :duplicate_page
    assert reloaded.current_page == 1
  end

  test "does not enqueue reconcile worker", %{admin: admin, source: source, env_var: env_var} do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)

    FakeTickeraAttendeeClient.reset!(
      {:ok, page_result(%{attendees: [attendee()], count: 1, per_page: 1})}
    )

    perform(%{"sync_run_id" => run.id})
    refute_enqueued(worker: ReconcileOrdersWorker)
  end

  defp perform(args) do
    SyncTickeraAttendeesWorker.perform(%Oban.Job{args: args})
  end
end
