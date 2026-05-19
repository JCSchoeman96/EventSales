defmodule EventSales.Ingestion.TickeraAttendeeSyncTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  import EventSales.TestSupport.TickeraSyncTestHelpers

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraAttendeeSnapshot
  alias EventSales.Ingestion.TickeraAttendeeSnapshotHash
  alias EventSales.Ingestion.TickeraAttendeeSync
  alias EventSales.Ingestion.TickeraAttendeeSyncRuns
  alias EventSales.Ingestion.TickeraEventSources
  alias EventSales.TestSupport.Fakes.FakeTickeraAttendeeClient

  setup [:setup_fake_client, :setup_admin]

  test "resolves api key from env and never leaks secret", %{admin: admin, source: source, env_var: env_var} do
    secret = "tickera-secret-#{System.unique_integer([:positive])}"
    put_env!(env_var, secret)

    run = queue_sync_run!(source, admin)

    FakeTickeraAttendeeClient.reset!(
      {:ok, page_result(%{attendees: [attendee()], count: 1, per_page: 1})}
    )

    assert {:complete, completed} =
             TickeraAttendeeSync.run_step(run,
               per_page: 1,
               tickera_client: FakeTickeraAttendeeClient
             )

    refute_secret_leaks!(completed, secret)
    refute_secret_leaks!(FakeTickeraAttendeeClient.calls(), secret)
  end

  test "uses source tickera_site_url and run current_page", %{admin: admin, source: source} do
    put_env!(source.api_key_env_var, "key")

    run = queue_sync_run!(source, admin)
    {:ok, run} = TickeraAttendeeSyncRuns.record_page(run, %{current_page: 2}, internal?: true)

    FakeTickeraAttendeeClient.reset!(
      {:ok, page_result(%{page: 2, per_page: 1, count: 1, attendees: [attendee()]})}
    )

    assert {:complete, _} = TickeraAttendeeSync.run_step(run, per_page: 1)

    assert [%{site_url: site_url, page: 2}] = FakeTickeraAttendeeClient.calls()
    assert site_url == source.tickera_site_url
  end

  test "full page continues and advances current_page", %{admin: admin, source: source, env_var: env_var} do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)

    attendees = [attendee(), attendee()]
    per_page = 2

    FakeTickeraAttendeeClient.reset!(
      {:ok, page_result(%{attendees: attendees, count: 2, per_page: per_page, page: 1})}
    )

    assert {:continue, continued} = TickeraAttendeeSync.run_step(run, per_page: per_page)
    assert continued.current_page == 2
    assert continued.attendees_seen_count == 2
    assert continued.attendees_upserted_count == 2
  end

  test "short page completes", %{admin: admin, source: source, env_var: env_var} do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)

    FakeTickeraAttendeeClient.reset!(
      {:ok, page_result(%{attendees: [attendee()], count: 1, per_page: 50, page: 1})}
    )

    assert {:complete, completed} = TickeraAttendeeSync.run_step(run, per_page: 50)
    assert completed.status == :completed
  end

  test "snapshot attrs omit forbidden fields and hash ignores transaction_id", %{
    admin: admin,
    source: source,
    env_var: env_var
  } do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)

    base = attendee(%{transaction_id: "txn-a"})
    changed_txn = Map.put(base, :transaction_id, "txn-b")

    assert raw_hash(base) == raw_hash(changed_txn)

    FakeTickeraAttendeeClient.reset!(
      {:ok, page_result(%{attendees: [base], count: 1, per_page: 1})}
    )

    assert {:complete, _} = TickeraAttendeeSync.run_step(run, per_page: 1)

    snapshot =
      TickeraAttendeeSnapshot
      |> Ash.Query.filter(tickera_event_source_id == ^source.id)
      |> Ash.read_one!(domain: Ingestion)

    assert snapshot.event_id == source.event_id
    assert snapshot.source_system_id == source.source_system_id
    refute Map.has_key?(snapshot, :transaction_id)
  end

  test "duplicate page pauses without advancing current_page", %{admin: admin, source: source, env_var: env_var} do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)
    {:ok, run} = TickeraAttendeeSyncRuns.mark_started(run, internal?: true)

    attendees = [attendee(%{ticket_code: "DUP-1"}), attendee(%{ticket_code: "DUP-2"})]
    per_page = 2
    signature = duplicate_signature(attendees)

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

    assert {:pause, paused, :duplicate_page, 300} =
             TickeraAttendeeSync.run_step(run, per_page: per_page)

    assert paused.status == :paused
    assert paused.current_page == 1
    assert paused.duplicate_page_count == 1
  end

  test "inactive source fails without client call", %{
    source: source,
    env_var: env_var,
    admin: admin
  } do
    put_env!(env_var, "key")
    {:ok, deactivated} = TickeraEventSources.deactivate_source(source, actor: admin)
    run = queue_sync_run!(deactivated, admin)

    FakeTickeraAttendeeClient.reset!({:ok, page_result()})

    assert {:error, {:failed, failed, :inactive_source}} =
             TickeraAttendeeSync.run_step(run)

    assert failed.last_error == "tickera_source_inactive"
    assert [] = FakeTickeraAttendeeClient.calls()
  end

  test "run source mismatch fails without client call", %{admin: admin, source: source, env_var: env_var} do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)

    mismatched = %{run | event_id: Ecto.UUID.generate()}

    FakeTickeraAttendeeClient.reset!({:ok, page_result()})

    assert {:error, {:failed, failed, :source_mismatch}} =
             TickeraAttendeeSync.run_step(mismatched)

    assert failed.last_error == "tickera_source_mismatch"
    assert [] = FakeTickeraAttendeeClient.calls()
  end

  test "missing api key env fails without client call", %{admin: admin, source: source} do
    System.delete_env(source.api_key_env_var)
    run = queue_sync_run!(source, admin)

    FakeTickeraAttendeeClient.reset!({:ok, page_result()})

    assert {:error, {:failed, failed, :missing_api_key}} = TickeraAttendeeSync.run_step(run)
    assert failed.last_error == "tickera_api_key_missing"
    assert [] = FakeTickeraAttendeeClient.calls()
  end

  test "missing source fails without client call", %{admin: admin, source: source, env_var: env_var} do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)
    missing_source_run = %{run | tickera_event_source_id: Ecto.UUID.generate()}

    FakeTickeraAttendeeClient.reset!({:ok, page_result()})

    assert {:error, {:failed, failed, :source_missing}} =
             TickeraAttendeeSync.run_step(missing_source_run)

    assert failed.last_error == "tickera_source_missing"
    assert [] = FakeTickeraAttendeeClient.calls()
  end

  test "one bad attendee does not fail the whole page", %{admin: admin, source: source, env_var: env_var} do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)

    attendees = [attendee(%{ticket_code: "", checksum: ""}), attendee()]

    FakeTickeraAttendeeClient.reset!(
      {:ok, page_result(%{attendees: attendees, count: 2, per_page: 2})}
    )

    assert {:continue, continued} = TickeraAttendeeSync.run_step(run, per_page: 2)
    assert continued.attendees_seen_count == 2
    assert continued.attendees_upserted_count == 1
    assert continued.attendees_failed_count == 1
    assert continued.errors_count == 1
  end

  test "emits exactly one start and one stop per run_step", %{admin: admin, source: source, env_var: env_var} do
    put_env!(env_var, "key")
    run = queue_sync_run!(source, admin)

    FakeTickeraAttendeeClient.reset!(
      {:ok, page_result(%{attendees: [attendee()], count: 1, per_page: 1})}
    )

    handler_id = "tickera-sync-test-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:event_sales, :tickera, :sync, :stop],
        fn _event, _measurements, _metadata, pid ->
          send(pid, :stop)
        end,
        nil
      )

    parent = self()

    start_handler = fn _event, _measurements, _metadata ->
      send(parent, :start)
    end

    :ok =
      :telemetry.attach(
        "#{handler_id}-start",
        [:event_sales, :tickera, :sync, :start],
        start_handler,
        nil
      )

    assert {:complete, _} = TickeraAttendeeSync.run_step(run, per_page: 1)

    assert_receive :start, 500
    assert_receive :stop, 500

    :telemetry.detach(handler_id)
    :telemetry.detach("#{handler_id}-start")
  end

  defp raw_hash(attendee) do
    attendee
    |> Map.drop([
      :transaction_id,
      "transaction_id",
      :api_key,
      "api_key",
      :tickera_api_key,
      "tickera_api_key"
    ])
    |> TickeraAttendeeSnapshotHash.hash()
  end

  defp duplicate_signature(attendees) do
    attendees
    |> Enum.map_join("|", fn a -> a.ticket_code || a.checksum || "" end)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
