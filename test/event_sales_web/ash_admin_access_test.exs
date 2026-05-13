defmodule EventSalesWeb.AshAdminAccessTest do
  use EventSalesWeb.ConnCase, async: true

  setup do
    original_internal_tools = Application.get_env(:event_sales, :internal_tools, [])

    on_exit(fn ->
      Application.put_env(:event_sales, :internal_tools, original_internal_tools)
    end)

    :ok
  end

  test "does not expose a public /ash-admin route" do
    assert :error ==
             Phoenix.Router.route_info(EventSalesWeb.Router, "GET", "/ash-admin", "localhost")
  end

  test "returns not found when the internal ash admin gate is disabled", %{conn: conn} do
    Application.put_env(:event_sales, :internal_tools, ash_admin_enabled: false)

    conn = get(%{conn | remote_ip: {127, 0, 0, 1}}, "/internal/ash-admin")

    assert response(conn, 404) == "Not Found"
  end

  test "allows the internal ash admin route when the gate is enabled", %{conn: conn} do
    Application.put_env(:event_sales, :internal_tools, ash_admin_enabled: true)

    conn = get(%{conn | remote_ip: {127, 0, 0, 1}}, "/internal/ash-admin")

    assert conn.status in [200, 302]
  end

  test "returns not found for non-loopback requests even when enabled", %{conn: conn} do
    Application.put_env(:event_sales, :internal_tools, ash_admin_enabled: true)

    conn = get(%{conn | remote_ip: {10, 0, 0, 10}}, "/internal/ash-admin")

    assert response(conn, 404) == "Not Found"
  end
end
