defmodule EventSalesWeb.PageControllerTest do
  use EventSalesWeb.ConnCase, async: false

  alias EventSales.TestSupport.AuthHelpers

  @csp_header [
    "default-src 'self'; base-uri 'self'; frame-ancestors 'self'; form-action 'self'; " <>
      "img-src 'self' data:; object-src 'none'; script-src 'self'; style-src 'self'; " <>
      "connect-src 'self'"
  ]

  setup do
    EventSales.DataCase.setup_sandbox(%{async: false})
    :ok
  end

  test "GET / renders internal EventSales landing for unauthenticated users", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "EventSales"
    assert html =~ "Internal sales intelligence"
    assert html =~ ~s(href="/admin/login")
    assert html =~ ~s(href="/health")
    refute html =~ "Peace of mind from prototype to production"
    refute html =~ "Phoenix Framework"
    refute html =~ ~s(href="/admin/dashboard")

    assert get_resp_header(conn, "content-security-policy") == @csp_header
  end

  test "GET / shows dashboard entry when an admin session exists", %{conn: conn} do
    admin = AuthHelpers.create_user!("home-admin@example.com")
    AuthHelpers.create_global_role!(admin, :admin)

    conn =
      conn
      |> AuthHelpers.sign_in_as(admin)
      |> get(~p"/")

    html = html_response(conn, 200)

    assert html =~ "EventSales"
    assert html =~ ~s(href="/health")
    assert html =~ ~s(href="/admin/dashboard")
    assert html =~ ~s(href="/admin/logout")
    assert html =~ ~s(data-method="delete")
  end

  test "GET / does not show dashboard entry for non-admin sessions", %{conn: conn} do
    staff = AuthHelpers.create_user!("home-staff@example.com")
    AuthHelpers.create_global_role!(staff, :staff)

    conn =
      conn
      |> AuthHelpers.sign_in_as(staff)
      |> get(~p"/")

    html = html_response(conn, 200)

    assert html =~ "EventSales"
    assert html =~ "Admin role required"
    assert html =~ ~s(href="/admin/login")
    assert html =~ ~s(href="/health")
    refute html =~ ~s(href="/admin/dashboard")
  end
end
