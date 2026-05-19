defmodule EventSales.Ingestion.TickeraAttendeeSyncRunsTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraAttendeeSyncRun
  alias EventSales.Ingestion.{TickeraAttendeeSyncRuns, TickeraEventSources}
  alias EventSales.Ingestion.Workers.ReconcileOrdersWorker
  alias EventSales.TestSupport.SalesHelpers

  setup do
    admin = create_user!("tickera-run-admin@example.com")
    staff = create_user!("tickera-run-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)

    source_system = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source_system, %{
        name: "Tickera Run",
        slug: unique_slug("tickera-run")
      })

    {:ok, source} = create_tickera_source(source_system, event, admin)

    {:ok, admin: admin, staff: staff, source_system: source_system, event: event, source: source}
  end

  test "queue_manual creates queued run without enqueueing a worker", %{
    admin: admin,
    source: source
  } do
    assert {:ok, run} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, actor: admin)

    assert run.status == :queued
    assert run.requested_via == :manual
    assert run.sync_mode == :full
    assert run.tickera_event_source_id == source.id
    assert run.source_system_id == source.source_system_id
    assert run.event_id == source.event_id
    refute_enqueued(worker: ReconcileOrdersWorker)
  end

  test "queue_manual requires admin actor", %{staff: staff, source: source} do
    assert {:error, :forbidden} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, actor: nil)
    assert {:error, :forbidden} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, actor: staff)
  end

  test "lifecycle transitions update durable state", %{admin: admin, source: source} do
    {:ok, run} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, actor: admin)

    assert {:ok, started} = TickeraAttendeeSyncRuns.mark_started(run, internal?: true)
    assert started.status == :running
    assert %DateTime{} = started.started_at

    paused_until = DateTime.add(DateTime.utc_now(), 120, :second)

    assert {:ok, paused} =
             TickeraAttendeeSyncRuns.mark_paused(
               started,
               %{paused_until: paused_until, pause_reason: :server_error, last_error: "500"},
               internal?: true
             )

    assert paused.status == :paused
    assert paused.pause_reason == :server_error
    assert paused.last_error == "500"

    assert {:ok, resumed} = TickeraAttendeeSyncRuns.mark_resumed(paused, internal?: true)
    assert resumed.status == :running
    assert is_nil(resumed.paused_until)
    assert is_nil(resumed.pause_reason)

    assert {:ok, completed} = TickeraAttendeeSyncRuns.mark_completed(resumed, internal?: true)
    assert completed.status == :completed
    assert %DateTime{} = completed.finished_at
  end

  test "fail and cancel transitions set finished_at", %{admin: admin, source: source} do
    {:ok, queued} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, actor: admin)

    assert {:ok, failed} =
             TickeraAttendeeSyncRuns.mark_failed(queued, %{last_error: "bad config"},
               internal?: true
             )

    assert failed.status == :failed
    assert failed.last_error == "bad config"
    assert %DateTime{} = failed.finished_at

    {:ok, cancellable} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, actor: admin)
    assert {:ok, cancelled} = TickeraAttendeeSyncRuns.cancel(cancellable, internal?: true)
    assert cancelled.status == :cancelled
    assert %DateTime{} = cancelled.finished_at
  end

  test "invalid transition is rejected", %{admin: admin, source: source} do
    {:ok, run} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, actor: admin)

    assert {:error, %Ash.Error.Invalid{}} =
             TickeraAttendeeSyncRuns.mark_completed(run, internal?: true)
  end

  test "record_page and record_counts update state and reject negative counts", %{
    admin: admin,
    source: source
  } do
    {:ok, run} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, actor: admin)

    assert {:ok, paged} =
             TickeraAttendeeSyncRuns.record_page(
               run,
               %{
                 current_page: 3,
                 last_successful_page: 2,
                 last_page_count: 50,
                 last_page_signature: "sha-page"
               },
               internal?: true
             )

    assert paged.current_page == 3
    assert paged.last_successful_page == 2
    assert paged.last_page_count == 50
    assert paged.last_page_signature == "sha-page"

    assert {:ok, counted} =
             TickeraAttendeeSyncRuns.record_counts(
               paged,
               %{attendees_seen_count: 50, attendees_upserted_count: 49, errors_count: 1},
               internal?: true
             )

    assert counted.attendees_seen_count == 50
    assert counted.attendees_upserted_count == 49
    assert counted.errors_count == 1

    assert {:error, %Ash.Error.Invalid{}} =
             TickeraAttendeeSyncRuns.record_counts(counted, %{errors_count: -1}, internal?: true)
  end

  test "direct Ash mutation without authorization context fails", %{source: source} do
    assert {:error, %Ash.Error.Invalid{}} =
             TickeraAttendeeSyncRun
             |> Ash.Changeset.for_create(:queue_manual, %{
               tickera_event_source_id: source.id,
               source_system_id: source.source_system_id,
               event_id: source.event_id
             })
             |> Ash.create(domain: Ingestion)
  end

  test "bounded list ordering is deterministic", %{admin: admin, source: source} do
    {:ok, first} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, actor: admin)
    {:ok, second} = TickeraAttendeeSyncRuns.queue_manual(source, %{}, actor: admin)

    assert {:ok, [listed_second, listed_first]} =
             TickeraAttendeeSyncRuns.list_runs(actor: admin, limit: 2)

    assert listed_second.id == second.id
    assert listed_first.id == first.id
  end

  defp create_tickera_source(source_system, event, admin) do
    TickeraEventSources.create_source(
      %{
        source_system_id: source_system.id,
        event_id: event.id,
        api_key_env_var: "TICKERA_API_KEY_#{System.unique_integer([:positive])}"
      },
      actor: admin
    )
  end

  defp create_user!(email, password \\ "valid-pass-123") do
    Ash.create!(
      User,
      %{email: email, name: "Test User", password: password, password_confirmation: password},
      action: :register_with_password,
      domain: Accounts
    )
  end

  defp create_global_role!(user, role_name) do
    role =
      Role
      |> Ash.Query.filter(name == ^role_name)
      |> Ash.read_one!(domain: Accounts)
      |> case do
        nil -> Ash.create!(Role, %{name: role_name}, action: :create, domain: Accounts)
        role -> role
      end

    Ash.create!(UserRole, %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
