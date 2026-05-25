defmodule EventSalesWeb.Controllers.AdminSessionControllerTest do
  use EventSalesWeb.ConnCase, async: false

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.User
  alias EventSales.TestSupport.AuthHelpers

  @valid_password "Test-Admin-Password-123!"
  @other_password "Other-Test-Password-123!"
  @generic_error "Invalid email, password, or access"

  setup do
    EventSales.DataCase.setup_sandbox(%{async: false})
    :ok
  end

  test "GET /admin/login renders admin login form", %{conn: conn} do
    conn = get(conn, ~p"/admin/login")
    html = html_response(conn, 200)

    assert html =~ "Admin sign in"
    assert html =~ ~s(name="admin_session[email]")
    assert html =~ ~s(name="admin_session[password]")
    assert html =~ "Sign in"
    assert html =~ ~s(href="/")
    assert html =~ ~s(href="/health")
  end

  test "GET /admin/login redirects an existing admin session to dashboard", %{conn: conn} do
    admin = create_user!("admin-login-redirect@example.test", @valid_password)
    AuthHelpers.create_global_role!(admin, :admin)

    conn =
      conn
      |> AuthHelpers.sign_in_as(admin)
      |> get(~p"/admin/login")

    assert redirected_to(conn) == ~p"/admin/dashboard"
  end

  test "POST /admin/login signs in active admins and renews session", %{conn: conn} do
    admin = create_user!("admin-login-success@example.test", @valid_password)
    AuthHelpers.create_global_role!(admin, :admin)

    conn =
      post(conn, ~p"/admin/login", %{
        "admin_session" => %{
          "email" => "admin-login-success@example.test",
          "password" => @valid_password
        }
      })

    assert redirected_to(conn) == ~p"/admin/dashboard"
    assert get_session(conn, :current_user_id) == admin.id
  end

  test "POST /admin/login rejects wrong password with generic message", %{conn: conn} do
    admin = create_user!("admin-login-wrong-password@example.test", @valid_password)
    AuthHelpers.create_global_role!(admin, :admin)

    conn =
      post(conn, ~p"/admin/login", %{
        "admin_session" => %{
          "email" => "admin-login-wrong-password@example.test",
          "password" => @other_password
        }
      })

    assert conn.status == 401
    html = html_response(conn, 401)
    assert html =~ @generic_error
    refute html =~ @other_password
    refute html =~ "wrong password"
    refute html =~ "does not exist"
  end

  test "POST /admin/login rejects unknown email with same generic message", %{conn: conn} do
    conn =
      post(conn, ~p"/admin/login", %{
        "admin_session" => %{
          "email" => "missing-login@example.test",
          "password" => @valid_password
        }
      })

    assert conn.status == 401
    html = html_response(conn, 401)
    assert html =~ @generic_error
    refute html =~ "missing-login@example.test"
    refute html =~ "does not exist"
  end

  test "POST /admin/login rejects valid non-admin users with generic message", %{conn: conn} do
    staff = create_user!("admin-login-staff@example.test", @valid_password)
    AuthHelpers.create_global_role!(staff, :staff)

    conn =
      post(conn, ~p"/admin/login", %{
        "admin_session" => %{
          "email" => "admin-login-staff@example.test",
          "password" => @valid_password
        }
      })

    assert conn.status == 401
    html = html_response(conn, 401)
    assert html =~ @generic_error
    refute html =~ "not admin"
    refute html =~ "staff"
  end

  test "POST /admin/login rejects inactive admins with generic message", %{conn: conn} do
    admin = create_user!("admin-login-inactive@example.test", @valid_password)
    AuthHelpers.create_global_role!(admin, :admin)
    Ash.update!(admin, %{active: false}, action: :update, domain: Accounts)

    conn =
      post(conn, ~p"/admin/login", %{
        "admin_session" => %{
          "email" => "admin-login-inactive@example.test",
          "password" => @valid_password
        }
      })

    assert conn.status == 401
    html = html_response(conn, 401)
    assert html =~ @generic_error
    refute html =~ "inactive"
  end

  test "DELETE /admin/logout clears session and redirects home", %{conn: conn} do
    admin = create_user!("admin-logout@example.test", @valid_password)
    AuthHelpers.create_global_role!(admin, :admin)

    conn =
      conn
      |> AuthHelpers.sign_in_as(admin)
      |> delete(~p"/admin/logout")

    assert redirected_to(conn) == ~p"/"
    refute get_session(conn, :current_user_id)
  end

  defp create_user!(email, password) do
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
end
