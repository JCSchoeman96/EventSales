defmodule EventSalesWeb.Auth.AdminAccessTest do
  use EventSalesWeb.ConnCase, async: false

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.Role
  alias EventSales.Accounts.Resources.User
  alias EventSales.Accounts.Resources.UserRole

  setup do
    EventSales.DataCase.setup_sandbox(%{async: false})

    original_internal_tools = Application.get_env(:event_sales, :internal_tools, [])

    on_exit(fn ->
      Application.put_env(:event_sales, :internal_tools, original_internal_tools)
    end)

    Application.put_env(:event_sales, :internal_tools, ash_admin_enabled: true)

    :ok
  end

  test "keeps /ash-admin nonexistent", %{conn: conn} do
    assert :error ==
             Phoenix.Router.route_info(EventSalesWeb.Router, "GET", "/ash-admin", "localhost")

    assert html_response(get(conn, "/ash-admin"), 404)
  end

  test "rejects unauthenticated access to internal AshAdmin after the internal gate passes", %{
    conn: conn
  } do
    conn = get(%{conn | remote_ip: {127, 0, 0, 1}}, "/internal/ash-admin")

    assert html_response(conn, 401) =~ "Admin access required"
    assert conn.status == 401
  end

  test "rejects staff access to internal AshAdmin", %{conn: conn} do
    staff = create_user!("staff-admin-access@example.com")
    create_global_role!(staff, :staff)

    conn =
      conn
      |> sign_in_as(staff)
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> get("/internal/ash-admin")

    assert html_response(conn, 403) =~ "Admin role required"
    assert conn.status == 403
  end

  test "renders styled 401 page for unauthenticated admin dashboard access", %{conn: conn} do
    conn = get(conn, "/admin/dashboard")
    html = html_response(conn, 401)

    assert conn.status == 401
    assert html =~ "Admin access required"
    assert html =~ "EventSales"
    assert html =~ ~s(href="/admin/login")
    assert html =~ ~s(href="/")
    assert html =~ ~s(href="/health")
  end

  test "renders styled 403 page for authenticated non-admin dashboard access", %{conn: conn} do
    staff = create_user!("dashboard-forbidden@example.com")
    create_global_role!(staff, :staff)

    conn =
      conn
      |> sign_in_as(staff)
      |> get("/admin/dashboard")

    html = html_response(conn, 403)

    assert conn.status == 403
    assert html =~ "Admin role required"
    assert html =~ "EventSales"
    refute html =~ ~s(href="/admin/login")
    assert html =~ ~s(href="/")
    assert html =~ ~s(href="/health")
  end

  test "allows admin access to internal AshAdmin when the internal gate passes", %{conn: conn} do
    admin = create_user!("admin-access@example.com")
    create_global_role!(admin, :admin)

    conn =
      conn
      |> sign_in_as(admin)
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> get("/internal/ash-admin")

    assert conn.status in [200, 302]
  end

  test "does not trust roles stored in the session", %{conn: conn} do
    user = create_user!("session-role-fake@example.com")

    conn =
      conn
      |> Plug.Test.init_test_session(%{current_user_id: user.id, roles: [:admin]})
      |> Map.put(:remote_ip, {127, 0, 0, 1})
      |> get("/internal/ash-admin")

    assert html_response(conn, 403) =~ "Admin role required"
    assert conn.status == 403
  end

  test "keeps existing InternalOnly not-found behavior for non-loopback requests", %{conn: conn} do
    admin = create_user!("non-loopback-admin@example.com")
    create_global_role!(admin, :admin)

    conn =
      conn
      |> sign_in_as(admin)
      |> Map.put(:remote_ip, {10, 0, 0, 10})
      |> get("/internal/ash-admin")

    assert response(conn, 404) == "Not Found"
  end

  defp sign_in_as(conn, user) do
    Plug.Test.init_test_session(conn, %{current_user_id: user.id})
  end

  defp create_user!(email) do
    Ash.create!(
      User,
      %{
        email: email,
        name: "Test User",
        password: "valid-pass-123",
        password_confirmation: "valid-pass-123"
      },
      action: :register_with_password,
      domain: Accounts
    )
  end

  defp create_global_role!(user, role_name) do
    role = Ash.create!(Role, %{name: role_name}, action: :create, domain: Accounts)

    Ash.create!(
      UserRole,
      %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )
  end
end
