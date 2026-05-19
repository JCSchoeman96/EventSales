defmodule EventSales.Ingestion.TickeraAttendeeSyncQueueTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  require Ash.Query

  import EventSales.TestSupport.TickeraSyncTestHelpers

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraAttendeeSyncRun
  alias EventSales.Ingestion.TickeraAttendeeSyncQueue
  alias EventSales.Ingestion.TickeraEventSources
  alias EventSales.Ingestion.Workers.SyncTickeraAttendeesWorker
  alias EventSales.TestSupport.Fakes.FakeTickeraAttendeeClient

  setup [:setup_fake_client, :setup_admin]

  test "admin queues run and job", %{source: source, admin: admin} do
    assert {:ok, %{sync_run: run, job: job}} =
             TickeraAttendeeSyncQueue.queue_manual(source, %{}, actor: admin)

    assert run.status == :queued
    assert %Oban.Job{} = job
    assert_enqueued(worker: SyncTickeraAttendeesWorker, args: %{"sync_run_id" => run.id})
    assert [] = FakeTickeraAttendeeClient.calls()
  end

  test "staff and nil actor forbidden", %{source: source} do
    staff_user = create_staff!()

    assert {:error, :forbidden} = TickeraAttendeeSyncQueue.queue_manual(source, %{}, actor: nil)

    assert {:error, :forbidden} =
             TickeraAttendeeSyncQueue.queue_manual(source, %{}, actor: staff_user)

    refute_enqueued(worker: SyncTickeraAttendeesWorker)
  end

  test "inactive source rejected without run or job", %{source: source, admin: admin} do
    {:ok, deactivated} = TickeraEventSources.deactivate_source(source, actor: admin)

    assert {:error, :inactive_source} =
             TickeraAttendeeSyncQueue.queue_manual(deactivated, %{}, actor: admin)

    refute_enqueued(worker: SyncTickeraAttendeesWorker)

    count =
      TickeraAttendeeSyncRun
      |> Ash.Query.filter(tickera_event_source_id == ^deactivated.id)
      |> Ash.count!(domain: Ingestion)

    assert count == 0
  end

  test "enqueue failure cancels created run", %{source: source, admin: admin} do
    assert {:error, :enqueue_failed} =
             TickeraAttendeeSyncQueue.queue_manual(source, %{},
               actor: admin,
               oban_insert: fn _changeset -> {:error, :boom} end
             )

    [run] =
      TickeraAttendeeSyncRun
      |> Ash.Query.filter(tickera_event_source_id == ^source.id)
      |> Ash.read!(domain: Ingestion)

    assert run.status == :cancelled
    refute_enqueued(worker: SyncTickeraAttendeesWorker)
  end

  defp create_staff! do
    user = create_user!("staff-#{System.unique_integer([:positive])}@example.com")
    create_global_role!(user, :staff)
    user
  end

  defp create_user!(email) do
    alias EventSales.Accounts
    alias EventSales.Accounts.Resources.User

    Ash.create!(
      User,
      %{
        email: email,
        name: "Test",
        password: "valid-pass-123",
        password_confirmation: "valid-pass-123"
      },
      action: :register_with_password,
      domain: Accounts
    )
  end

  defp create_global_role!(user, role_name) do
    alias EventSales.Accounts
    alias EventSales.Accounts.Resources.{Role, UserRole}

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
end
