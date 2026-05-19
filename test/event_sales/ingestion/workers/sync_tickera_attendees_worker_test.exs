defmodule EventSales.Ingestion.Workers.SyncTickeraAttendeesWorkerTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

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

  test "completed run discards", %{source: source, env_var: env_var} do
    put_env!(env_var, "key")
    {:ok, run} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, internal?: true)
    {:ok, started} = TickeraAttendeeSyncRuns.mark_started(run, internal?: true)
    {:ok, completed} = TickeraAttendeeSyncRuns.mark_completed(started, internal?: true)

    FakeTickeraAttendeeClient.reset!({:ok, page_result()})
    assert :discard = perform(%{"sync_run_id" => completed.id})
    assert [] = FakeTickeraAttendeeClient.calls()
  end

  test "queued run starts and fetches first page", %{source: source, env_var: env_var} do
    put_env!(env_var, "key")
    {:ok, run} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, internal?: true)

    FakeTickeraAttendeeClient.reset!(
      {:ok, page_result(%{attendees: [attendee()], count: 1, per_page: 1})}
    )

    assert :ok = perform(%{"sync_run_id" => run.id})
    assert [_call] = FakeTickeraAttendeeClient.calls()
    assert Ash.get!(TickeraAttendeeSyncRun, run.id, domain: Ingestion).status == :completed
  end

  test "full page returns snooze and advances current_page", %{source: source, env_var: env_var} do
    put_env!(env_var, "key")
    {:ok, run} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, internal?: true)

    attendees = [attendee(), attendee()]

    FakeTickeraAttendeeClient.reset!(
      {:ok, page_result(%{attendees: attendees, count: 2, per_page: 2, page: 1})}
    )

    assert {:snooze, 1} = perform(%{"sync_run_id" => run.id})
    reloaded = Ash.get!(TickeraAttendeeSyncRun, run.id, domain: Ingestion)
    assert reloaded.status == :running
    assert reloaded.current_page == 2
  end

  test "future paused run snoozes without Tickera call", %{source: source, env_var: env_var} do
    put_env!(env_var, "key")
    {:ok, run} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, internal?: true)
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

  test "elapsed paused run resumes and fetches", %{source: source, env_var: env_var} do
    put_env!(env_var, "key")
    {:ok, run} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, internal?: true)
    {:ok, started} = TickeraAttendeeSyncRuns.mark_started(run, internal?: true)
    paused_until = DateTime.add(DateTime.utc_now(), -5, :second)

    {:ok, paused} =
      TickeraAttendeeSyncRuns.mark_paused(
        started,
        %{paused_until: paused_until, pause_reason: :rate_limited, last_error: "429"},
        internal?: true
      )

    FakeTickeraAttendeeClient.reset!(
      {:ok, page_result(%{attendees: [attendee()], count: 1, per_page: 1})}
    )

    assert :ok = perform(%{"sync_run_id" => paused.id})
    assert [_call] = FakeTickeraAttendeeClient.calls()
  end

  test "retryable Tickera error pauses and snoozes", %{source: source, env_var: env_var} do
    put_env!(env_var, "key")
    {:ok, run} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, internal?: true)

    FakeTickeraAttendeeClient.reset!(
      {:error, %TickeraError{reason: :rate_limited, operation: :fetch_attendees_page}}
    )

    assert {:snooze, _seconds} = perform(%{"sync_run_id" => run.id})

    reloaded = Ash.get!(TickeraAttendeeSyncRun, run.id, domain: Ingestion)
    assert reloaded.status == :paused
    assert reloaded.pause_reason == :rate_limited
  end

  test "non-retryable Tickera error fails run", %{source: source, env_var: env_var} do
    put_env!(env_var, "key")
    {:ok, run} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, internal?: true)

    FakeTickeraAttendeeClient.reset!(
      {:error, %TickeraError{reason: :unauthorized, operation: :fetch_attendees_page}}
    )

    assert :ok = perform(%{"sync_run_id" => run.id})
    reloaded = Ash.get!(TickeraAttendeeSyncRun, run.id, domain: Ingestion)
    assert reloaded.status == :failed
    assert reloaded.last_error == "tickera_unauthorized"
  end

  test "missing api key env fails without client call", %{source: source} do
    System.delete_env(source.api_key_env_var)
    {:ok, run} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, internal?: true)

    FakeTickeraAttendeeClient.reset!({:ok, page_result()})
    assert :ok = perform(%{"sync_run_id" => run.id})
    assert [] = FakeTickeraAttendeeClient.calls()
    assert Ash.get!(TickeraAttendeeSyncRun, run.id, domain: Ingestion).status == :failed
  end

  test "duplicate full page pauses without advancing page", %{source: source, env_var: env_var} do
    put_env!(env_var, "key")
    {:ok, run} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, internal?: true)

    attendees = [attendee(%{ticket_code: "DUP-A"}), attendee(%{ticket_code: "DUP-B"})]
    per_page = 2

    signature =
      attendees
      |> Enum.map(& &1.ticket_code)
      |> Enum.join("|")
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

  test "does not enqueue reconcile worker", %{source: source, env_var: env_var} do
    put_env!(env_var, "key")
    {:ok, run} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, internal?: true)

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
