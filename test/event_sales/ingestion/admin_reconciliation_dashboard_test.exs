defmodule EventSales.Ingestion.AdminReconciliationDashboardTest do
  use EventSales.DataCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  import Ecto.Query

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Audit
  alias EventSales.Audit.Resources.AuditLog
  alias EventSales.Ingestion.AdminReconciliationDashboard
  alias EventSales.Ingestion.TickeraEventSources
  alias EventSales.Ingestion.TickeraReconciliationFindings
  alias EventSales.Ingestion.TickeraReconciliationRuns
  alias EventSales.Ingestion.Workers.ReconcileTickeraAttendeesWorker
  alias EventSales.Ingestion.Workers.SyncTickeraAttendeesWorker
  alias EventSales.Repo
  alias EventSales.TestSupport.SalesHelpers

  setup do
    Repo.delete_all(from(j in Oban.Job))

    admin = create_user!("admin-recon-dashboard@example.com")
    create_global_role!(admin, :admin)
    staff = create_user!("staff-recon-dashboard@example.com")
    create_global_role!(staff, :staff)

    source_system = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source_system, %{
        name: "Reconciliation Dashboard Event",
        slug: unique_slug("recon-dashboard")
      })

    {:ok, source} =
      TickeraEventSources.create_source(
        %{
          source_system_id: source_system.id,
          event_id: event.id,
          api_key_env_var: "TICKERA_API_KEY_RECON_DASHBOARD"
        },
        actor: admin
      )

    {:ok, run} = TickeraReconciliationRuns.queue_manual(source, %{}, actor: admin)

    {:ok, finding} =
      run
      |> finding_attrs(source, event, :woo_paid_missing_tickera, :critical)
      |> TickeraReconciliationFindings.upsert_open(internal?: true)

    %{
      admin: admin,
      staff: staff,
      event: event,
      source: source,
      run: run,
      finding: finding
    }
  end

  test "snapshot and list_findings require admin", %{admin: admin, staff: staff, finding: finding} do
    assert {:ok, snapshot} = AdminReconciliationDashboard.snapshot(actor: admin)
    assert snapshot.open_count >= 1
    assert snapshot.critical_count >= 1

    assert {:ok, %{rows: rows}} = AdminReconciliationDashboard.list_findings(actor: admin)
    assert Enum.any?(rows, &(&1.id == finding.id))

    assert {:error, :forbidden} = AdminReconciliationDashboard.snapshot(actor: staff)
    assert {:error, :forbidden} = AdminReconciliationDashboard.list_findings(actor: staff)
  end

  test "list_findings filters by status", %{admin: admin, finding: finding} do
    assert {:ok, %{rows: open_rows}} =
             AdminReconciliationDashboard.list_findings(status: "open", actor: admin)

    assert Enum.any?(open_rows, &(&1.id == finding.id))

    assert {:ok, finding} =
             TickeraReconciliationFindings.resolve(
               finding,
               %{resolution_reason: "done"},
               internal?: true
             )

    assert finding.status == :resolved

    assert {:ok, %{rows: resolved_rows}} =
             AdminReconciliationDashboard.list_findings(status: "resolved", actor: admin)

    assert Enum.any?(resolved_rows, &(&1.id == finding.id))
  end

  test "get_finding returns sanitized row without forbidden fields", %{
    admin: admin,
    finding: finding
  } do
    assert {:ok, row} = AdminReconciliationDashboard.get_finding(finding.id, actor: admin)
    assert row.id == finding.id
    assert is_binary(row.recommended_action)
    refute Map.has_key?(row, :api_key_env_var)
    refute Map.has_key?(row.details, "email")
  end

  test "resolve ignore and reopen delegate through dashboard", %{admin: admin, finding: finding} do
    assert {:ok, resolved} =
             AdminReconciliationDashboard.resolve_finding(
               finding.id,
               %{resolution_reason: "checked"},
               actor: admin
             )

    assert resolved.status == :resolved

    assert {:ok, reopened} =
             AdminReconciliationDashboard.reopen_finding(finding.id, actor: admin)

    assert reopened.status == :open

    assert {:ok, ignored} =
             AdminReconciliationDashboard.ignore_finding(
               finding.id,
               %{resolution_reason: "noise"},
               actor: admin
             )

    assert ignored.status == :ignored
  end

  test "queue_reconciliation enqueues worker and audits", %{admin: admin, event: event} do
    assert {:ok, %{reconciliation_run: run}} =
             AdminReconciliationDashboard.queue_reconciliation(event.id,
               actor: admin,
               audit_attrs: audit_attrs(admin)
             )

    assert_enqueued(
      worker: ReconcileTickeraAttendeesWorker,
      args: %{"reconciliation_run_id" => run.id}
    )

    assert {:ok, [audit]} =
             AuditLog
             |> Ash.Query.filter(event_type == :tickera_reconciliation_run_requested)
             |> Ash.read(domain: Audit)

    assert audit.metadata["event_id"] == event.id
    assert audit.metadata["result"] == "queued"
  end

  test "queue_attendee_sync enqueues worker and audits", %{admin: admin, event: event} do
    assert {:ok, %{sync_run: run}} =
             AdminReconciliationDashboard.queue_attendee_sync(event.id,
               actor: admin,
               audit_attrs: audit_attrs(admin)
             )

    assert_enqueued(worker: SyncTickeraAttendeesWorker, args: %{"sync_run_id" => run.id})

    assert {:ok, [audit]} =
             AuditLog
             |> Ash.Query.filter(event_type == :tickera_attendee_sync_requested)
             |> Ash.read(domain: Audit)

    assert audit.metadata["event_id"] == event.id
    assert audit.metadata["result"] == "queued"
  end

  test "stream_findings_for_export is bounded", %{
    admin: admin,
    event: event,
    run: run,
    source: source
  } do
    for index <- 1..3 do
      run
      |> finding_attrs(source, event, :quantity_mismatch, :warning, "fp-#{index}")
      |> TickeraReconciliationFindings.upsert_open(internal?: true)
    end

    assert {:ok, stream, truncated?} =
             AdminReconciliationDashboard.stream_findings_for_export(
               event_id: event.id,
               limit: 2,
               actor: admin
             )

    rows = Enum.to_list(stream)
    assert length(rows) == 2
    assert truncated? == true
  end

  defp finding_attrs(run, source, event, type, severity, fingerprint_suffix \\ "default") do
    source_scope_key =
      TickeraReconciliationFindings.source_scope_key(%{
        event_id: event.id,
        tickera_event_source_id: source.id
      })

    %{
      tickera_reconciliation_run_id: run.id,
      tickera_event_source_id: source.id,
      source_scope_key: source_scope_key,
      source_system_id: run.source_system_id,
      event_id: event.id,
      finding_type: type,
      severity: severity,
      status: :open,
      details: %{},
      fingerprint:
        TickeraReconciliationFindings.fingerprint([
          "test",
          event.id,
          source_scope_key,
          type,
          fingerprint_suffix
        ]),
      first_seen_at: ~U[2026-05-19 10:00:00Z],
      last_seen_at: ~U[2026-05-19 10:00:00Z]
    }
  end

  defp audit_attrs(admin) do
    %{actor_type: :user, actor_user_id: admin.id, actor_role: :admin, source: :admin}
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
