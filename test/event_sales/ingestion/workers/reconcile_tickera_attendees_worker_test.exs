defmodule EventSales.Ingestion.Workers.ReconcileTickeraAttendeesWorkerTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraReconciliationRun
  alias EventSales.Ingestion.{TickeraEventSources, TickeraReconciliationRuns}
  alias EventSales.Ingestion.Workers.ReconcileTickeraAttendeesWorker
  alias EventSales.TestSupport.SalesHelpers

  defmodule RaisingEngine do
    def run(_run), do: raise("forced reconciliation failure")
  end

  setup do
    original_engine = Application.get_env(:event_sales, :tickera_reconciliation_engine)
    original_raise = Application.get_env(:event_sales, :tickera_reconciliation_test_raise)

    on_exit(fn ->
      if original_engine do
        Application.put_env(:event_sales, :tickera_reconciliation_engine, original_engine)
      else
        Application.delete_env(:event_sales, :tickera_reconciliation_engine)
      end

      restore_test_raise!(original_raise)
    end)

    admin = create_user!("tickera-reconciliation-worker-admin@example.com")
    create_global_role!(admin, :admin)

    source_system = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source_system, %{
        name: "Tickera Reconciliation Worker",
        slug: unique_slug("tickera-reconciliation-worker")
      })

    {:ok, source} =
      TickeraEventSources.create_source(
        %{
          source_system_id: source_system.id,
          event_id: event.id,
          api_key_env_var: "TICKERA_API_KEY_RECONCILIATION_WORKER"
        },
        actor: admin
      )

    {:ok, admin: admin, source_system: source_system, event: event, source: source}
  end

  test "malformed args discard" do
    assert :discard = perform_job(ReconcileTickeraAttendeesWorker, %{})
  end

  test "missing run discards" do
    assert :discard =
             perform_job(ReconcileTickeraAttendeesWorker, %{
               "reconciliation_run_id" => Ecto.UUID.generate()
             })
  end

  test "terminal runs discard", %{admin: admin, source: source} do
    {:ok, completed} = completed_run(source, admin)

    assert :discard =
             perform_job(ReconcileTickeraAttendeesWorker, %{
               "reconciliation_run_id" => completed.id
             })

    {:ok, failed} = failed_run(source, admin)

    assert :discard =
             perform_job(ReconcileTickeraAttendeesWorker, %{"reconciliation_run_id" => failed.id})

    {:ok, cancelled} = cancelled_run(source, admin)

    assert :discard =
             perform_job(ReconcileTickeraAttendeesWorker, %{
               "reconciliation_run_id" => cancelled.id
             })
  end

  test "queued run is processed and completed", %{admin: admin, source: source} do
    {:ok, run} = TickeraReconciliationRuns.queue_manual(source, %{}, actor: admin)

    assert :ok =
             perform_job(ReconcileTickeraAttendeesWorker, %{"reconciliation_run_id" => run.id})

    reloaded = Ash.get!(TickeraReconciliationRun, run.id, domain: Ingestion)
    assert reloaded.status == :completed
  end

  test "unexpected engine raise marks run failed", %{admin: admin, source: source} do
    Application.put_env(:event_sales, :tickera_reconciliation_engine, RaisingEngine)
    {:ok, run} = TickeraReconciliationRuns.queue_manual(source, %{}, actor: admin)

    assert {:error, %RuntimeError{}} =
             perform_job(ReconcileTickeraAttendeesWorker, %{"reconciliation_run_id" => run.id})

    reloaded = Ash.get!(TickeraReconciliationRun, run.id, domain: Ingestion)
    assert reloaded.status == :failed
    assert reloaded.last_error =~ "forced reconciliation failure"
  end

  test "real engine exception marks run failed and returns error", %{admin: admin, source: source} do
    Application.put_env(
      :event_sales,
      :tickera_reconciliation_test_raise,
      "forced reconciliation failure"
    )

    {:ok, run} = TickeraReconciliationRuns.queue_manual(source, %{}, actor: admin)

    assert {:error, {:failed, _failed, :exception}} =
             perform_job(ReconcileTickeraAttendeesWorker, %{"reconciliation_run_id" => run.id})

    reloaded = Ash.get!(TickeraReconciliationRun, run.id, domain: Ingestion)
    assert reloaded.status == :failed
    assert reloaded.last_error =~ "forced reconciliation failure"
  end

  test "inactive source marks run failed and completes worker", %{
    admin: admin,
    source: source
  } do
    {:ok, run} = TickeraReconciliationRuns.queue_manual(source, %{}, actor: admin)
    {:ok, _deactivated} = TickeraEventSources.deactivate_source(source, actor: admin)

    assert :ok =
             perform_job(ReconcileTickeraAttendeesWorker, %{"reconciliation_run_id" => run.id})

    reloaded = Ash.get!(TickeraReconciliationRun, run.id, domain: Ingestion)
    assert reloaded.status == :failed
    assert reloaded.last_error == "tickera_source_inactive"
  end

  defp completed_run(source, admin) do
    {:ok, run} = TickeraReconciliationRuns.queue_manual(source, %{}, actor: admin)
    {:ok, started} = TickeraReconciliationRuns.mark_started(run, internal?: true)
    TickeraReconciliationRuns.mark_completed(started, %{}, internal?: true)
  end

  defp failed_run(source, admin) do
    {:ok, run} = TickeraReconciliationRuns.queue_manual(source, %{}, actor: admin)
    {:ok, started} = TickeraReconciliationRuns.mark_started(run, internal?: true)
    TickeraReconciliationRuns.mark_failed(started, %{last_error: "failed"}, internal?: true)
  end

  defp cancelled_run(source, admin) do
    {:ok, run} = TickeraReconciliationRuns.queue_manual(source, %{}, actor: admin)
    TickeraReconciliationRuns.cancel(run, internal?: true)
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

  defp restore_test_raise!(nil),
    do: Application.delete_env(:event_sales, :tickera_reconciliation_test_raise)

  defp restore_test_raise!(value),
    do: Application.put_env(:event_sales, :tickera_reconciliation_test_raise, value)
end
