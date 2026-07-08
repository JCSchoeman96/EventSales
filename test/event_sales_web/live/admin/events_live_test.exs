defmodule EventSalesWeb.Live.Admin.EventsLiveTest do
  use EventSalesWeb.ConnCase, async: false

  require Ash.Query

  import Phoenix.LiveViewTest

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics.{DashboardCache, HotStateAggregator}
  alias EventSales.TestSupport.SalesHelpers

  setup do
    EventSales.DataCase.setup_sandbox(%{async: false})
    HotStateAggregator.reset_for_test!()

    on_exit(fn -> HotStateAggregator.reset_for_test!() end)

    :ok
  end

  test "rejects unauthenticated access", %{conn: conn} do
    conn = get(conn, "/admin/events")
    assert html_response(conn, 401) =~ "Admin access required"
    assert conn.status == 401
  end

  test "rejects non-admin access", %{conn: conn} do
    staff = create_user!("events-staff@example.com")
    create_global_role!(staff, :staff)

    conn =
      conn
      |> sign_in_as(staff)
      |> get("/admin/events")

    assert html_response(conn, 403) =~ "Admin role required"
    assert conn.status == 403
  end

  test "admin sees event list with hot summary metrics and disabled placeholders", %{conn: conn} do
    admin = create_user!("events-admin@example.com")
    create_global_role!(admin, :admin)

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        name: "List Visible Event",
        slug: unique_slug("list-visible"),
        capacity: 20
      })

    DashboardCache.put_event_summary(event.id, %{
      total_sold: 7,
      total_revenue: Decimal.new("700.00"),
      currency: "ZAR",
      refreshed_at: ~U[2026-05-18 08:00:00Z]
    })

    {:ok, _view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/events")

    assert html =~ "Events"
    assert html =~ "List Visible Event"
    assert html =~ "7"
    assert html =~ "13"
    assert html =~ "700.00"
    assert html =~ ~s(disabled)
    assert html =~ "Export CSV"
    assert html =~ "Import CSV"
    refute html =~ "phx-click=\"export"
    refute html =~ "phx-click=\"import"
  end

  test "admin can switch between current and past events with venue display", %{conn: conn} do
    admin = create_user!("events-lifecycle@example.com")
    create_global_role!(admin, :admin)

    source = SalesHelpers.create_source_system!()

    current =
      SalesHelpers.create_event!(source, %{
        name: "Current Visible Event",
        slug: unique_slug("current-visible"),
        starts_at: DateTime.add(DateTime.utc_now(), -1, :hour),
        ends_at: DateTime.add(DateTime.utc_now(), 1, :hour),
        venue_name: "Main Hall"
      })

    past =
      SalesHelpers.create_event!(source, %{
        name: "Past Hidden Event",
        slug: unique_slug("past-hidden"),
        starts_at: ~U[2026-01-01 10:00:00Z],
        ends_at: ~U[2026-01-01 12:00:00Z],
        venue_name: "Old Hall"
      })

    unknown =
      SalesHelpers.create_event!(source, %{
        name: "Unknown Date Event",
        slug: unique_slug("unknown-date")
      })

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/events")

    assert html =~ "Current"
    assert html =~ "Past"
    assert html =~ current.name
    assert html =~ "Main Hall"
    assert html =~ unknown.name
    refute html =~ past.name

    html = render_patch(view, "/admin/events?lifecycle=past")

    assert html =~ past.name
    assert html =~ "Old Hall"
    refute html =~ current.name
    refute html =~ unknown.name
  end

  test "event list pagination does not render all events", %{conn: conn} do
    admin = create_user!("events-pagination@example.com")
    create_global_role!(admin, :admin)

    source = SalesHelpers.create_source_system!()

    for index <- 1..30 do
      SalesHelpers.create_event!(source, %{
        name: "Paged Event #{String.pad_leading(to_string(index), 2, "0")}",
        slug: unique_slug("paged-#{index}")
      })
    end

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/events")

    assert html =~ "Paged Event 01"
    assert html =~ "Paged Event 25"
    refute html =~ "Paged Event 26"

    html = render_click(view, "next_page")
    assert html =~ "Paged Event 26"
    refute html =~ "Paged Event 01"
  end

  test "EventsLive source stays inside approved boundaries" do
    source = File.read!("lib/event_sales_web/live/admin/events_live.ex")

    for forbidden <- [
          "OrderItem",
          "Repo",
          "sales_order_items",
          "WooCommerce",
          "EventAggregator",
          "SnapshotRefresh",
          "Redix"
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
    role =
      Role
      |> Ash.Query.filter(name == ^role_name)
      |> Ash.read_one!(domain: Accounts)
      |> case do
        nil -> Ash.create!(Role, %{name: role_name}, action: :create, domain: Accounts)
        role -> role
      end

    Ash.create!(
      UserRole,
      %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
