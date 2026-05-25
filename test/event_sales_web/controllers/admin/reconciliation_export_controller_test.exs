defmodule EventSalesWeb.Admin.ReconciliationExportControllerTest do
  use EventSalesWeb.ConnCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Ingestion.TickeraEventSources
  alias EventSales.Ingestion.TickeraReconciliationFindings
  alias EventSales.Ingestion.TickeraReconciliationRuns
  alias EventSales.TestSupport.SalesHelpers

  setup do
    EventSales.DataCase.setup_sandbox(%{async: false})
    original_staff_visibility = Application.get_env(:event_sales, :staff_customer_pii_visibility)

    on_exit(fn ->
      case original_staff_visibility do
        nil -> Application.delete_env(:event_sales, :staff_customer_pii_visibility)
        value -> Application.put_env(:event_sales, :staff_customer_pii_visibility, value)
      end
    end)

    admin = create_user!("recon-export-admin@example.com")
    create_global_role!(admin, :admin)

    source_system = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source_system, %{
        name: "Reconciliation Export Event",
        slug: unique_slug("recon-export")
      })

    {:ok, source} =
      TickeraEventSources.create_source(
        %{
          source_system_id: source_system.id,
          event_id: event.id,
          api_key_env_var: "TICKERA_API_KEY_RECON_EXPORT"
        },
        actor: admin
      )

    {:ok, run} = TickeraReconciliationRuns.queue_manual(source, %{}, actor: admin)

    {:ok, _finding} =
      run
      |> finding_attrs(source, event)
      |> TickeraReconciliationFindings.upsert_open(internal?: true)

    {:ok, admin: admin, event: event}
  end

  test "unauthenticated export returns 401", %{conn: conn} do
    conn = get(conn, "/admin/reconciliation/export.csv")
    assert html_response(conn, 401) =~ "Admin access required"
    assert conn.status == 401
  end

  test "non-admin export returns 403", %{conn: conn} do
    staff = create_user!("recon-export-staff@example.com")
    create_global_role!(staff, :staff)

    conn =
      conn
      |> sign_in_as(staff)
      |> get("/admin/reconciliation/export.csv")

    assert html_response(conn, 403) =~ "Admin role required"
    assert conn.status == 403
  end

  test "admin export returns csv with headers and truncation header", %{conn: conn, admin: admin} do
    Application.put_env(:event_sales, :staff_customer_pii_visibility, :full)

    conn =
      conn
      |> sign_in_as(admin)
      |> get("/admin/reconciliation/export.csv")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]

    assert get_resp_header(conn, "x-event-sales-export-truncated") in [
             ["true"],
             ["false"]
           ]

    body = response(conn, 200)

    assert body =~ "event,source,run_id,finding_type,severity,status"
    refute body =~ "attendee_email"
    refute body =~ "buyer_email"
    refute body =~ "api_key"
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
          "export-test",
          event.id,
          source_scope_key
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
