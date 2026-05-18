defmodule EventSales.Ingestion.ManualSyncTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.User
  alias EventSales.Audit
  alias EventSales.Audit.Resources.AuditLog
  alias EventSales.Ingestion.ManualSync
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Ingestion.Workers.ReconcileOrdersWorker
  alias EventSales.TestSupport.SalesHelpers

  @off_peak ~U[2026-05-16 12:00:00.000000Z]

  setup do
    user = create_user!("admin-sync@example.com")
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Manual", slug: unique_slug("manual")})

    {:ok, user: user, source: source, event: event}
  end

  test "queue_manual_scoped creates run, audits success, and enqueues worker", %{
    user: user,
    source: source,
    event: event
  } do
    assert {:ok, %{sync_run: run, job: job}} =
             ManualSync.queue_manual_scoped(
               %{
                 source_system_id: source.id,
                 event_id: event.id,
                 date_from: ~U[2026-05-01 00:00:00Z],
                 date_to: ~U[2026-05-02 00:00:00Z],
                 sync_mode: :shallow
               },
               %{
                 actor_type: :user,
                 actor_user_id: user.id,
                 actor_role: :admin,
                 source: :admin
               },
               now: @off_peak
             )

    assert run.status == :queued
    assert run.requested_via == :manual
    assert run.sync_mode == :shallow

    assert_enqueued(worker: ReconcileOrdersWorker, args: %{"sync_run_id" => run.id})
    assert Map.get(job.args, "sync_run_id") == run.id

    assert {:ok, [audit]} =
             AuditLog
             |> Ash.Query.filter(subject_id == ^run.id and event_type == :manual_sync_requested)
             |> Ash.read(domain: Audit)

    assert audit.metadata["scope"] == "event"
    assert audit.metadata["event_id"] == event.id
    assert audit.metadata["sync_mode"] == "shallow"
    assert audit.metadata["requested_via"] == "manual"
    assert audit.metadata["result"] == "queued"
  end

  test "rejected scope does not audit or enqueue", %{source: source, user: user} do
    assert {:error, _} =
             ManualSync.queue_manual_scoped(
               %{
                 source_system_id: source.id,
                 event_id: nil,
                 date_from: ~U[2026-05-01 00:00:00Z],
                 date_to: ~U[2026-05-02 00:00:00Z],
                 sync_mode: :shallow
               },
               %{
                 actor_type: :user,
                 actor_user_id: user.id,
                 actor_role: :admin,
                 source: :admin
               },
               now: @off_peak
             )

    refute_enqueued(worker: ReconcileOrdersWorker)

    assert {:ok, []} =
             AuditLog
             |> Ash.Query.filter(event_type == :manual_sync_requested)
             |> Ash.read(domain: Audit)
  end

  test "deep sync is rejected during peak without audit", %{
    source: source,
    event: event,
    user: user
  } do
    peak_monday = ~U[2026-05-18 12:00:00.000000Z]
    runs_before = Ash.count!(SyncRun, domain: EventSales.Ingestion)

    assert {:error, _} =
             ManualSync.queue_manual_scoped(
               %{
                 source_system_id: source.id,
                 event_id: event.id,
                 date_from: ~U[2026-05-01 00:00:00Z],
                 date_to: ~U[2026-05-02 00:00:00Z],
                 sync_mode: :deep
               },
               %{
                 actor_type: :user,
                 actor_user_id: user.id,
                 actor_role: :admin,
                 source: :admin
               },
               now: peak_monday
             )

    refute_enqueued(worker: ReconcileOrdersWorker)
    assert Ash.count!(SyncRun, domain: EventSales.Ingestion) == runs_before
  end

  defp create_user!(email, password \\ "valid-pass-123") do
    Ash.create!(
      User,
      %{
        email: email,
        name: "Test User",
        password: password,
        password_confirmation: password
      },
      action: :register_with_password,
      domain: Accounts
    )
  end

  defp unique_slug(prefix) do
    "#{prefix}-#{System.unique_integer([:positive])}"
  end
end
