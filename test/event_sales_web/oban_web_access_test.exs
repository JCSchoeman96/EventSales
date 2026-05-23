defmodule EventSalesWeb.ObanWebAccessTest do
  use EventSalesWeb.ConnCase, async: false

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}

  setup do
    EventSales.DataCase.setup_sandbox(%{async: false})
    :ok
  end

  test "does not expose a public /oban route", %{conn: conn} do
    assert :error == Phoenix.Router.route_info(EventSalesWeb.Router, "GET", "/oban", "localhost")
    assert html_response(get(conn, "/oban"), 404)
  end

  test "rejects unauthenticated access to admin Oban Web", %{conn: conn} do
    conn = get(conn, "/admin/oban")

    assert response(conn, 401) == "Unauthorized"
  end

  test "rejects staff access to admin Oban Web", %{conn: conn} do
    staff = create_user!("oban-web-staff@example.com")
    create_global_role!(staff, :staff)

    conn =
      conn
      |> sign_in_as(staff)
      |> get("/admin/oban")

    assert response(conn, 403) == "Forbidden"
  end

  test "allows admin access to admin Oban Web", %{conn: conn} do
    with_oban_web_runtime(fn ->
      admin = create_user!("oban-web-admin@example.com")
      create_global_role!(admin, :admin)

      conn =
        conn
        |> sign_in_as(admin)
        |> get("/admin/oban")

      assert conn.status in [200, 302]
    end)
  end

  test "resolver grants admins read-only access and never all access" do
    admin = create_user!("oban-web-read-only@example.com")
    create_global_role!(admin, :admin)

    assert EventSalesWeb.ObanWebResolver.resolve_access(admin) == :read_only
    refute EventSalesWeb.ObanWebResolver.resolve_access(admin) == :all
  end

  test "resolver denies staff and unauthenticated users" do
    staff = create_user!("oban-web-resolver-staff@example.com")
    create_global_role!(staff, :staff)

    assert EventSalesWeb.ObanWebResolver.resolve_access(staff) == {:forbidden, "/"}
    assert EventSalesWeb.ObanWebResolver.resolve_access(nil) == {:forbidden, "/"}
  end

  test "resolver does not grant a mutation allowlist" do
    admin = create_user!("oban-web-no-actions@example.com")
    create_global_role!(admin, :admin)

    access = EventSalesWeb.ObanWebResolver.resolve_access(admin)

    refute is_list(access)
    assert access == :read_only
  end

  defp sign_in_as(conn, user) do
    Plug.Test.init_test_session(conn, %{current_user_id: user.id})
  end

  defp with_oban_web_runtime(fun) do
    original_config = Application.fetch_env!(:event_sales, Oban)

    web_config =
      original_config
      |> Keyword.put(:testing, :disabled)
      |> Keyword.put(:queues, false)
      |> Keyword.put(:plugins, [])

    try do
      restart_oban!(web_config)
      fun.()
    after
      restart_oban!(original_config)
    end
  end

  defp restart_oban!(config) do
    Application.put_env(:event_sales, Oban, config)

    case Supervisor.terminate_child(EventSales.Supervisor, Oban) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    case Supervisor.delete_child(EventSales.Supervisor, Oban) do
      :ok -> :ok
      {:error, :not_found} -> :ok
    end

    {:ok, _pid} = Supervisor.start_child(EventSales.Supervisor, {Oban, config})
    :ok
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
