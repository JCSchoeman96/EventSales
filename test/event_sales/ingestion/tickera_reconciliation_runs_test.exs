defmodule EventSales.Ingestion.TickeraReconciliationRunsTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraReconciliationRun
  alias EventSales.Ingestion.{TickeraEventSources, TickeraReconciliationRuns}
  alias EventSales.TestSupport.SalesHelpers

  setup do
    admin = create_user!("tickera-reconciliation-run-admin@example.com")
    staff = create_user!("tickera-reconciliation-run-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)

    source_system = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source_system, %{
        name: "Tickera Reconciliation Run",
        slug: unique_slug("tickera-reconciliation-run")
      })

    {:ok, source} =
      TickeraEventSources.create_source(
        %{
          source_system_id: source_system.id,
          event_id: event.id,
          api_key_env_var: "TICKERA_API_KEY_RECONCILIATION_RUN"
        },
        actor: admin
      )

    {:ok, admin: admin, staff: staff, source_system: source_system, event: event, source: source}
  end

  test "queue_manual creates a queued run for a Tickera source", %{admin: admin, source: source} do
    assert {:ok, run} = TickeraReconciliationRuns.queue_manual(source, %{}, actor: admin)

    assert run.status == :queued
    assert run.requested_via == :manual
    assert run.tickera_event_source_id == source.id
    assert run.source_system_id == source.source_system_id
    assert run.event_id == source.event_id
  end

  test "queue_manual_for_event creates a source-backed run when an active source exists", %{
    admin: admin,
    event: event,
    source: source
  } do
    assert {:ok, %{reconciliation_run: run, job: _job}} =
             TickeraReconciliationRuns.queue_manual_for_event(event.id, actor: admin)

    assert run.status == :queued
    assert run.tickera_event_source_id == source.id
  end

  test "queue_manual requires admin actor", %{staff: staff, source: source} do
    assert {:error, :forbidden} = TickeraReconciliationRuns.queue_manual(source, %{}, actor: nil)

    assert {:error, :forbidden} =
             TickeraReconciliationRuns.queue_manual(source, %{}, actor: staff)
  end

  test "lifecycle transitions update durable state", %{admin: admin, source: source} do
    {:ok, run} = TickeraReconciliationRuns.queue_manual(source, %{}, actor: admin)

    assert {:ok, started} = TickeraReconciliationRuns.mark_started(run, internal?: true)
    assert started.status == :running
    assert %DateTime{} = started.started_at

    assert {:ok, counted} =
             TickeraReconciliationRuns.record_counts(
               started,
               %{
                 woo_orders_scanned_count: 2,
                 woo_items_scanned_count: 3,
                 tickera_snapshots_scanned_count: 4,
                 findings_created_count: 1,
                 findings_open_count: 1,
                 critical_count: 1
               },
               internal?: true
             )

    assert counted.woo_orders_scanned_count == 2
    assert counted.findings_open_count == 1

    assert {:ok, completed} =
             TickeraReconciliationRuns.mark_completed(counted, %{}, internal?: true)

    assert completed.status == :completed
    assert %DateTime{} = completed.finished_at
  end

  test "fail and cancel transitions set finished_at", %{admin: admin, source: source} do
    {:ok, run} = TickeraReconciliationRuns.queue_manual(source, %{}, actor: admin)
    {:ok, started} = TickeraReconciliationRuns.mark_started(run, internal?: true)

    assert {:ok, failed} =
             TickeraReconciliationRuns.mark_failed(started, %{last_error: "unexpected"},
               internal?: true
             )

    assert failed.status == :failed
    assert failed.last_error == "unexpected"
    assert %DateTime{} = failed.finished_at

    {:ok, cancellable} = TickeraReconciliationRuns.queue_manual(source, %{}, actor: admin)
    assert {:ok, cancelled} = TickeraReconciliationRuns.cancel(cancellable, internal?: true)
    assert cancelled.status == :cancelled
    assert %DateTime{} = cancelled.finished_at
  end

  test "invalid transitions fail through AshStateMachine", %{admin: admin, source: source} do
    {:ok, run} = TickeraReconciliationRuns.queue_manual(source, %{}, actor: admin)

    assert {:error, %Ash.Error.Invalid{}} =
             TickeraReconciliationRuns.mark_completed(run, %{}, internal?: true)
  end

  test "direct Ash mutation without authorization context fails", %{source: source} do
    assert {:error, %Ash.Error.Invalid{}} =
             TickeraReconciliationRun
             |> Ash.Changeset.for_create(:queue_manual, %{
               tickera_event_source_id: source.id,
               source_system_id: source.source_system_id,
               event_id: source.event_id
             })
             |> Ash.create(domain: Ingestion)
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
