defmodule EventSalesWeb.Live.Admin.MappingsLiveTest do
  use EventSalesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.TestSupport.FixtureHelpers
  alias EventSales.TestSupport.SalesHelpers

  setup do
    EventSales.DataCase.setup_sandbox(%{async: false})

    original_internal_tools = Application.get_env(:event_sales, :internal_tools, [])

    on_exit(fn ->
      Application.put_env(:event_sales, :internal_tools, original_internal_tools)
    end)

    Application.put_env(:event_sales, :internal_tools, ash_admin_enabled: true)

    :ok
  end

  test "rejects unauthenticated access after internal gate passes", %{conn: conn} do
    conn = get(loopback(conn), "/internal/mappings")

    assert html_response(conn, 401) =~ "Admin access required"
    assert conn.status == 401
  end

  test "rejects non-admin access", %{conn: conn} do
    staff = create_user!("mapping-staff@example.com")
    create_global_role!(staff, :staff)

    conn =
      conn
      |> sign_in_as(staff)
      |> loopback()
      |> get("/internal/mappings")

    assert html_response(conn, 403) =~ "Admin role required"
    assert conn.status == 403
  end

  test "blocks non-loopback access before authentication details matter", %{conn: conn} do
    admin = create_user!("mapping-non-loopback-admin@example.com")
    create_global_role!(admin, :admin)

    conn =
      conn
      |> sign_in_as(admin)
      |> Map.put(:remote_ip, {10, 0, 0, 10})
      |> get("/internal/mappings")

    assert response(conn, 404) == "Not Found"
  end

  test "admin can view pending queue rows", %{conn: conn} do
    admin = create_user!("mapping-admin@example.com")
    create_global_role!(admin, :admin)
    create_pending_queue_row!("Synthetic Queue Ticket", 90_101, 777, nil)

    {:ok, _view, html} =
      conn
      |> sign_in_as(admin)
      |> loopback()
      |> live("/internal/mappings")

    assert html =~ "Mapping Queue"
    assert html =~ "Synthetic Queue Ticket"
    assert html =~ "ES-10001"
    assert html =~ "777"
    assert html =~ "pending_mapping_resolution"
  end

  defp create_pending_queue_row!(name, line_item_id, product_id, variation_id) do
    source = SalesHelpers.create_source_system!()
    order = SalesHelpers.create_order_from_fixture!(:order_completed, source)

    line =
      :woocommerce
      |> FixtureHelpers.decode_json_fixture!(:order_completed)
      |> Map.fetch!("line_items")
      |> hd()

    SalesHelpers.create_order_item_from_line!(order, line, %{
      woo_line_item_id: line_item_id,
      woo_product_id: product_id,
      woo_variation_id: variation_id,
      name: name,
      mapping_status: :pending_mapping_resolution,
      item_kind: :unknown
    })
  end

  defp loopback(conn), do: Map.put(conn, :remote_ip, {127, 0, 0, 1})

  defp sign_in_as(conn, user) do
    Plug.Test.init_test_session(conn, %{current_user_id: user.id})
  end

  defp create_user!(email, password \\ "valid-pass-123") do
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
