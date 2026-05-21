defmodule EventSalesWeb.Live.Admin.ImportsLiveTest do
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

    admin = create_user!("imports-live-admin@example.com")
    staff = create_user!("imports-live-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)

    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Imports Live Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    create_mapping!(source, event, ticket, %{woo_product_id: 501, woo_variation_id: 601})

    {:ok, admin: admin, staff: staff, event: event}
  end

  test "rejects unauthenticated access", %{conn: conn} do
    conn = get(conn, "/admin/imports")
    assert response(conn, 401) == "Unauthorized"
  end

  test "rejects non-admin access", %{conn: conn, staff: staff} do
    conn =
      conn
      |> sign_in_as(staff)
      |> get("/admin/imports")

    assert response(conn, 403) == "Forbidden"
  end

  test "admin can upload a CSV for a selected event and sees dry-run rows", %{
    conn: conn,
    admin: admin,
    event: event
  } do
    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/imports?event_id=#{event.id}")

    assert html =~ "CSV Imports"
    assert html =~ "Imports Live Event"
    refute html =~ "Apply import"

    upload =
      file_input(view, "#csv-import-form", :csv, [
        %{
          name: "import_valid.csv",
          content: File.read!(fixture_path("import_valid.csv")),
          type: "text/csv"
        }
      ])

    assert render_upload(upload, "import_valid.csv") =~ "100%"
    html = render_submit(view, "dry_run", %{"import" => %{"event_id" => event.id}})

    assert html =~ "Dry-run passed"
    assert html =~ "ES-10001"
    assert html =~ "70001"
    refute html =~ "Apply import"
  end

  test "invalid CSV displays row errors", %{conn: conn, admin: admin, event: event} do
    {:ok, view, _html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/imports?event_id=#{event.id}")

    upload =
      file_input(view, "#csv-import-form", :csv, [
        %{
          name: "import_invalid.csv",
          content: File.read!(fixture_path("import_invalid.csv")),
          type: "text/csv"
        }
      ])

    render_upload(upload, "import_invalid.csv")
    html = render_submit(view, "dry_run", %{"import" => %{"event_id" => event.id}})

    assert html =~ "Dry-run found errors"
    assert html =~ "quantity must be a positive integer"
    assert html =~ "line_total must be a non-negative money value"
  end

  test "ImportsLive source stays inside approved boundaries" do
    source = File.read!("lib/event_sales_web/live/admin/imports_live.ex")

    for forbidden <- [
          "Repo",
          "MappingResolver",
          "WooCommerceClient",
          "ProcessCsvImportWorker",
          "Sales.OrderUpserter",
          "Req",
          "Finch",
          "Tesla"
        ] do
      refute source =~ forbidden
    end
  end

  defp fixture_path(name), do: Path.join(["test", "fixtures", "csv", name])

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
