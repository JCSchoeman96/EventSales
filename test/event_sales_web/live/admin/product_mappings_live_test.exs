defmodule EventSalesWeb.Live.Admin.ProductMappingsLiveTest do
  use EventSalesWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.TestSupport.SalesHelpers

  setup do
    EventSales.DataCase.setup_sandbox(%{async: false})

    admin = create_user!("product-mappings-admin@example.com")
    staff = create_user!("product-mappings-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)

    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Mappings Live Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    mapping =
      create_mapping!(source, event, ticket, %{
        woo_product_id: 42_001,
        woo_variation_id: nil,
        current_label: "GA Ticket"
      })

    {:ok, admin: admin, staff: staff, event: event, mapping: mapping}
  end

  test "rejects unauthenticated access", %{conn: conn} do
    conn = get(conn, "/admin/mappings")
    assert html_response(conn, 401) =~ "Admin access required"
    assert conn.status == 401
  end

  test "rejects non-admin access", %{conn: conn, staff: staff} do
    conn =
      conn
      |> sign_in_as(staff)
      |> get("/admin/mappings")

    assert html_response(conn, 403) =~ "Admin role required"
    assert conn.status == 403
  end

  test "admin can view read-only product mappings without PII fields", %{
    conn: conn,
    admin: admin,
    mapping: mapping
  } do
    {:ok, _view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/mappings")

    assert html =~ "Product Mappings"
    assert html =~ "Mappings Live Event"
    assert html =~ "GA"
    assert html =~ Integer.to_string(mapping.woo_product_id)
    assert html =~ "GA Ticket"
    assert html =~ "true"

    refute html =~ "customer_email"
    refute html =~ "customer_name"
    refute html =~ "payment_gateway_transaction_id"
    refute html =~ "raw_payload"
    refute html =~ "private@example.test"
  end

  test "admin can filter mappings by event and product id", %{
    conn: conn,
    admin: admin,
    event: event,
    mapping: mapping
  } do
    {:ok, view, _html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/mappings")

    html =
      render_change(view, "filter", %{
        "filters" => %{"event_id" => event.id, "woo_product_id" => ""}
      })

    assert html =~ Integer.to_string(mapping.woo_product_id)

    html =
      render_change(view, "filter", %{
        "filters" => %{"event_id" => "", "woo_product_id" => "999999"}
      })

    assert html =~ "No product mappings match the current filters."
    refute html =~ Integer.to_string(mapping.woo_product_id)
  end

  test "ProductMappingsLive source stays inside approved boundaries" do
    source = File.read!("lib/event_sales_web/live/admin/product_mappings_live.ex")

    for forbidden <- [
          "MappingResolver",
          "WooCommerceClient",
          "OrderUpserter",
          "Repo",
          "Req",
          "Finch",
          "Tesla",
          "Ash.create",
          "Ash.update",
          "Ash.destroy"
        ] do
      refute source =~ forbidden
    end
  end

  defp sign_in_as(conn, user) do
    Plug.Test.init_test_session(conn, %{current_user_id: user.id})
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

  defp create_mapping!(source, event, ticket, attrs) do
    defaults = %{
      source_system_id: source.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_product_id: 1,
      woo_variation_id: nil,
      original_label: "Ticket",
      current_label: "Ticket",
      active: true
    }

    Ash.create!(ProductMapping, Map.merge(defaults, attrs), action: :create, domain: Catalog)
  end
end
