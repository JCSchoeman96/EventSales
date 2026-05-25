defmodule EventSalesWeb.Live.Admin.ReconciliationLiveTest do
  use EventSalesWeb.ConnCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  import Ecto.Query
  import Phoenix.LiveViewTest

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraReconciliationFinding
  alias EventSales.Ingestion.TickeraEventSources
  alias EventSales.Ingestion.TickeraReconciliationFindings
  alias EventSales.Ingestion.TickeraReconciliationRuns
  alias EventSales.Ingestion.Workers.ReconcileTickeraAttendeesWorker
  alias EventSales.Ingestion.Workers.SyncTickeraAttendeesWorker
  alias EventSales.Repo
  alias EventSales.TestSupport.SalesHelpers
  alias EventSalesWeb.Live.Admin.ManualActionRateLimiter

  setup do
    EventSales.DataCase.setup_sandbox(%{async: false})
    ManualActionRateLimiter.reset_for_test!()
    Repo.delete_all(from(j in Oban.Job))

    on_exit(fn ->
      ManualActionRateLimiter.reset_for_test!()
      Repo.delete_all(from(j in Oban.Job))
    end)

    admin = create_user!("recon-live-admin@example.com")
    create_global_role!(admin, :admin)

    source_system = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source_system, %{
        name: "Reconciliation Live Event",
        slug: unique_slug("recon-live")
      })

    {:ok, source} =
      TickeraEventSources.create_source(
        %{
          source_system_id: source_system.id,
          event_id: event.id,
          api_key_env_var: "TICKERA_API_KEY_RECON_LIVE"
        },
        actor: admin
      )

    {:ok, run} = TickeraReconciliationRuns.queue_manual(source, %{}, actor: admin)

    {:ok, finding} =
      run
      |> finding_attrs(source, event)
      |> TickeraReconciliationFindings.upsert_open(internal?: true)

    {:ok,
     admin: admin,
     source_system: source_system,
     event: event,
     source: source,
     run: run,
     finding: finding}
  end

  test "rejects unauthenticated access", %{conn: conn} do
    conn = get(conn, "/admin/reconciliation")
    assert html_response(conn, 401) =~ "Admin access required"
    assert conn.status == 401
  end

  test "rejects non-admin access", %{conn: conn} do
    staff = create_user!("recon-live-staff@example.com")
    create_global_role!(staff, :staff)

    conn =
      conn
      |> sign_in_as(staff)
      |> get("/admin/reconciliation")

    assert html_response(conn, 403) =~ "Admin role required"
    assert conn.status == 403
  end

  test "admin sees summary and findings", %{conn: conn, admin: admin, finding: finding} do
    {:ok, _view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/reconciliation")

    assert html =~ "Reconciliation"
    assert html =~ "Open findings"
    assert html =~ finding.finding_type |> Atom.to_string()
    assert html =~ "critical"
    assert html =~ "open"
  end

  test "filters by status", %{conn: conn, admin: admin, finding: finding} do
    {:ok, view, _html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/reconciliation?status=open")

    assert render(view) =~ Atom.to_string(finding.finding_type)

    {:ok, finding} =
      TickeraReconciliationFindings.resolve(
        finding,
        %{resolution_reason: "done"},
        internal?: true
      )

    {:ok, _view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/reconciliation?status=resolved")

    assert html =~ Atom.to_string(finding.finding_type)
  end

  test "mark resolved updates finding", %{conn: conn, admin: admin, finding: finding} do
    {:ok, view, _html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/reconciliation")

    render_click(view, "expand_finding", %{"id" => finding.id})

    render_change(view, "update_resolution_note", %{
      "resolution" => %{"note" => "Checked manually"}
    })

    html = render_click(view, "resolve_finding", %{"id" => finding.id})
    assert html =~ "marked resolved"

    finding = Ash.get!(TickeraReconciliationFinding, finding.id, domain: Ingestion)
    assert finding.status == :resolved
    assert finding.resolution_reason == "Checked manually"
  end

  test "queue reconciliation enqueues worker", %{conn: conn, admin: admin, event: event} do
    {:ok, view, _html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/reconciliation")

    render_change(view, "update_action_event", %{"action" => %{"event_id" => event.id}})
    render_click(view, "confirm_reconciliation")
    html = render_click(view, "queue_reconciliation")

    assert html =~ "Reconciliation queued"
    assert_enqueued(worker: ReconcileTickeraAttendeesWorker)
  end

  test "sync shows error when event has no active Tickera source", %{
    conn: conn,
    admin: admin,
    source_system: source_system
  } do
    event_without_source =
      SalesHelpers.create_event!(source_system, %{
        name: "No Tickera Source Live Event",
        slug: unique_slug("no-tickera-source-live")
      })

    {:ok, view, _html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/reconciliation")

    render_change(view, "update_action_event", %{
      "action" => %{"event_id" => event_without_source.id}
    })

    render_click(view, "confirm_attendee_sync")
    html = render_click(view, "queue_attendee_sync")

    assert html =~ "No active Tickera source for this event"
    refute_enqueued(worker: SyncTickeraAttendeesWorker)
  end

  test "queue attendee sync enqueues worker", %{conn: conn, admin: admin, event: event} do
    {:ok, view, _html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/reconciliation")

    render_change(view, "update_action_event", %{"action" => %{"event_id" => event.id}})
    render_click(view, "confirm_attendee_sync")
    html = render_click(view, "queue_attendee_sync")

    assert html =~ "sync queued"
    assert_enqueued(worker: SyncTickeraAttendeesWorker)
  end

  test "ReconciliationLive source stays inside approved boundaries" do
    source = File.read!("lib/event_sales_web/live/admin/reconciliation_live.ex")

    for forbidden <- [
          "WooCommerceClient",
          "WooCommerce",
          "TickeraReconciliation",
          "TickeraAttendeeSync",
          "ReconcileTickeraAttendeesWorker",
          "SyncTickeraAttendeesWorker",
          "Repo",
          "Req."
        ] do
      refute source =~ forbidden
    end
  end

  defp sign_in_as(conn, user) do
    Plug.Test.init_test_session(conn, %{current_user_id: user.id})
  end

  defp finding_attrs(run, source, event) do
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
      finding_type: :woo_paid_missing_tickera,
      severity: :critical,
      status: :open,
      details: %{},
      fingerprint:
        TickeraReconciliationFindings.fingerprint([
          "live-test",
          event.id,
          source_scope_key,
          :woo_paid_missing_tickera
        ]),
      first_seen_at: ~U[2026-05-19 10:00:00Z],
      last_seen_at: ~U[2026-05-19 10:00:00Z]
    }
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
