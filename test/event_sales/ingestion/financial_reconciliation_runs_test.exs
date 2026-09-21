defmodule EventSales.Ingestion.FinancialReconciliationRunsTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.FinancialReconciliationRuns
  alias EventSales.Ingestion.Resources.FinancialReconciliationRun
  alias EventSales.TestSupport.{FinancialReconciliationHelpers, SalesHelpers}

  setup do
    admin = create_user!("fin-recon-admin@example.com")
    staff = create_user!("fin-recon-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)

    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Financial Reconciliation Runs"})
    _sync_run = FinancialReconciliationHelpers.certified_run!(event)

    {:ok, admin: admin, staff: staff, source: source, event: event}
  end

  test "queue_manual_for_event creates a queued run bound to current M3 certificate", %{
    admin: admin,
    event: event
  } do
    assert {:ok, %{financial_reconciliation_run: run, job: _job}} =
             FinancialReconciliationRuns.queue_manual_for_event(event.id,
               actor: admin,
               oban_insert: fn _ -> {:ok, %{id: 1}} end
             )

    assert run.status == :queued
    assert run.requested_via == :manual
    assert run.event_id == event.id
    assert %DateTime{} = run.coverage_start
    assert %DateTime{} = run.sales_covered_through
    assert %DateTime{} = run.refunds_covered_through
  end

  test "queue_manual requires admin actor", %{staff: staff, event: event} do
    assert {:error, :forbidden} =
             FinancialReconciliationRuns.queue_manual_for_event(event.id, actor: staff)
  end

  test "queue_system requires internal authorization", %{event: event} do
    assert {:error, :forbidden} =
             FinancialReconciliationRuns.queue_manual_for_event(event.id, actor: nil)
  end

  test "lifecycle transitions update durable state", %{event: event} do
    {:ok, %{financial_reconciliation_run: run}} =
      FinancialReconciliationRuns.queue_system_for_event(event.id,
        internal?: true,
        oban_insert: fn _ -> {:ok, %{}} end
      )

    assert {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)
    assert started.status == :running
    assert %DateTime{} = started.started_at

    assert {:ok, passed} =
             FinancialReconciliationRuns.finalize_evidence(
               started,
               %{
                 disposition: :matched,
                 comparisons: [],
                 metric_mismatches: [],
                 structural_findings: []
               },
               internal?: true
             )

    assert passed.status == :passed
    assert %DateTime{} = passed.finished_at
  end

  test "terminal states reject further transitions", %{event: event} do
    {:ok, %{financial_reconciliation_run: run}} =
      FinancialReconciliationRuns.queue_system_for_event(event.id,
        internal?: true,
        oban_insert: fn _ -> {:ok, %{}} end
      )

    {:ok, started} = FinancialReconciliationRuns.mark_started(run, internal?: true)

    {:ok, passed} =
      FinancialReconciliationRuns.finalize_evidence(
        started,
        %{disposition: :matched, comparisons: [], metric_mismatches: [], structural_findings: []},
        internal?: true
      )

    assert {:error, %Ash.Error.Invalid{}} =
             FinancialReconciliationRuns.mark_started(passed, internal?: true)
  end

  test "only one active run per event and certificate", %{event: event} do
    oban = fn _ -> {:ok, %{}} end

    assert {:ok, %{financial_reconciliation_run: first}} =
             FinancialReconciliationRuns.queue_system_for_event(event.id,
               internal?: true,
               oban_insert: oban
             )

    assert {:ok, %{financial_reconciliation_run: second}} =
             FinancialReconciliationRuns.queue_system_for_event(event.id,
               internal?: true,
               oban_insert: oban
             )

    assert first.id == second.id
    assert first.status in [:queued, :running]
  end

  test "stale certificate cannot queue a new run", %{event: event} do
    stale_sync_run = FinancialReconciliationHelpers.certified_run!(event)
    _current_sync_run = FinancialReconciliationHelpers.certified_run!(event)

    assert {:error, %Ash.Error.Invalid{}} =
             FinancialReconciliationRun
             |> Ash.Changeset.new()
             |> Ash.Changeset.set_context(%{
               financial_reconciliation_state_authorized?: true,
               financial_reconciliation_state_authorized: true
             })
             |> Ash.Changeset.for_create(:queue_system, %{
               historical_sync_run_id: stale_sync_run.id
             })
             |> Ash.create(domain: Ingestion)
  end

  test "direct Ash mutation without authorization context fails", %{event: event} do
    sync_run = FinancialReconciliationHelpers.certified_run!(event)

    assert {:error, %Ash.Error.Invalid{}} =
             FinancialReconciliationRun
             |> Ash.Changeset.for_create(:queue_system, %{historical_sync_run_id: sync_run.id})
             |> Ash.create(domain: Ingestion)
  end

  test "new run enqueue failure cancels the newly created run", %{event: event} do
    assert {:error, :enqueue_failed} =
             FinancialReconciliationRuns.queue_system_for_event(event.id,
               internal?: true,
               oban_insert: fn _ -> {:error, :oban_down} end
             )

    runs =
      FinancialReconciliationRun
      |> Ash.Query.filter(event_id == ^event.id)
      |> Ash.read!(domain: Ingestion)

    assert length(runs) == 1
    assert hd(runs).status == :cancelled
  end

  test "existing queued run enqueue failure leaves run queued", %{event: event} do
    oban_fail = fn _ -> {:error, :oban_down} end

    assert {:ok, %{financial_reconciliation_run: first}} =
             FinancialReconciliationRuns.queue_system_for_event(event.id,
               internal?: true,
               oban_insert: fn _ -> {:ok, %{}} end
             )

    assert {:error, :enqueue_failed} =
             FinancialReconciliationRuns.queue_system_for_event(event.id,
               internal?: true,
               oban_insert: oban_fail
             )

    reloaded = Ash.get!(FinancialReconciliationRun, first.id, domain: Ingestion)
    assert reloaded.status == :queued
  end

  test "existing running run enqueue failure leaves run running", %{event: event} do
    assert {:ok, %{financial_reconciliation_run: run}} =
             FinancialReconciliationRuns.queue_system_for_event(event.id,
               internal?: true,
               oban_insert: fn _ -> {:ok, %{}} end
             )

    {:ok, running} = FinancialReconciliationRuns.mark_started(run, internal?: true)

    assert {:error, :enqueue_failed} =
             FinancialReconciliationRuns.queue_system_for_event(event.id,
               internal?: true,
               oban_insert: fn _ -> {:error, :oban_down} end
             )

    reloaded = Ash.get!(FinancialReconciliationRun, running.id, domain: Ingestion)
    assert reloaded.status == :running
  end

  test "cancel sets finished_at", %{event: event} do
    {:ok, %{financial_reconciliation_run: run}} =
      FinancialReconciliationRuns.queue_system_for_event(event.id,
        internal?: true,
        oban_insert: fn _ -> {:ok, %{}} end
      )

    assert {:ok, cancelled} = FinancialReconciliationRuns.cancel(run, internal?: true)
    assert cancelled.status == :cancelled
    assert %DateTime{} = cancelled.finished_at
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
end
