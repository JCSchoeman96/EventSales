defmodule EventSalesWeb.Live.Admin.DashboardLiveTest do
  use EventSalesWeb.ConnCase, async: false
  use Oban.Testing, repo: EventSales.Repo

  require Ash.Query

  import Phoenix.LiveViewTest

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics.{AdminDashboard, DashboardCache, DashboardPubSub, HotStateAggregator}
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers
  alias EventSalesWeb.Live.Admin.ManualActionRateLimiter

  setup do
    EventSales.DataCase.setup_sandbox(%{async: false})
    ManualActionRateLimiter.reset_for_test!()
    HotStateAggregator.reset_for_test!()
    delete_rebuild_jobs!()

    on_exit(fn ->
      ManualActionRateLimiter.reset_for_test!()
      HotStateAggregator.reset_for_test!()
      delete_rebuild_jobs!()
    end)

    :ok
  end

  test "rejects unauthenticated access", %{conn: conn} do
    conn = get(conn, "/admin/dashboard")
    assert html_response(conn, 401) =~ "Admin access required"
    assert conn.status == 401
  end

  test "admin sees shell navigation, empty dashboard sections, and sales trend placeholder", %{
    conn: conn
  } do
    admin = create_user!("dashboard-empty@example.com")
    create_global_role!(admin, :admin)

    {:ok, _view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/dashboard")

    assert html =~ "EventSales"
    assert html =~ ~s(href="/admin/dashboard")
    assert html =~ ~s(href="/admin/events")
    assert html =~ ~s(href="/admin/imports")
    assert html =~ ~s(href="/admin/webhooks")
    assert html =~ ~s(href="/admin/sync")
    assert html =~ ~s(href="/admin/reconciliation")
    assert html =~ ~s(href="/admin/catalog-sync")
    assert html =~ ~s(href="/admin/mappings")
    assert html =~ ~s(href="/admin/oban")
    assert html =~ ~s(href="/health")
    assert html =~ "Operations"
    assert html =~ "CSV Imports"
    assert html =~ "Catalog Sync"
    refute html =~ ~s(href="/internal/mappings")
    refute html =~ ~s(href="/internal/ash-admin")
    assert html =~ "Tickets Sold"
    assert html =~ "Revenue"
    assert html =~ "Today Tickets"
    assert html =~ "Today Revenue"
    assert html =~ "0"
    assert html =~ "No sales trend data yet"
    assert html =~ "No statuses yet."
    assert html =~ "No events yet."
    assert html =~ "No completed mapped ticket rows yet."
    assert html =~ "No recent orders."
    assert html =~ "No unmapped rows need attention."
  end

  test "rejects non-admin access", %{conn: conn} do
    staff = create_user!("dashboard-staff@example.com")
    create_global_role!(staff, :staff)

    conn =
      conn
      |> sign_in_as(staff)
      |> get("/admin/dashboard")

    assert html_response(conn, 403) =~ "Admin role required"
    assert conn.status == 403
  end

  test "admin can view dashboard data without PII", %{conn: conn} do
    admin = create_user!("dashboard-admin@example.com")
    create_global_role!(admin, :admin)

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        name: "Admin Dashboard Event",
        slug: unique_slug("admin")
      })

    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    order = create_order!(source, :completed, order_number: "ES-DASH-1")

    create_item!(order, event, ticket,
      name: "GA Ticket",
      quantity: 2,
      line_total: Decimal.new("900.00"),
      woo_line_item_id: 10
    )

    unmapped_item =
      create_item!(order, event, ticket,
        name: "Unmapped Ticket",
        mapping_status: :pending_mapping_resolution,
        item_kind: :unknown,
        woo_product_id: 888,
        woo_line_item_id: 11
      )

    {:ok, _view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/dashboard")

    assert html =~ "Admin Dashboard"
    assert html =~ "Tickets Sold"
    assert html =~ "Revenue"
    assert html =~ "Today Tickets"
    assert html =~ "Today Revenue"
    assert html =~ "2"
    assert html =~ "900.00"
    assert html =~ "completed"
    assert html =~ "Admin Dashboard Event"
    assert html =~ "GA"
    assert html =~ "ES-DASH-1"
    assert html =~ "Unmapped Ticket"
    assert html =~ ~s(href="/admin/unmapped-alerts/#{unmapped_item.id}/resolve")
    assert html =~ "No sales trend data yet"
    refute html =~ "private@example.test"
    refute html =~ "Private Customer"
    refute html =~ "txn_private"

    assert {:ok, dashboard} = AdminDashboard.snapshot()
    dashboard_dump = inspect(dashboard)

    refute dashboard_dump =~ "private@example.test"
    refute dashboard_dump =~ "Private Customer"
    refute dashboard_dump =~ "txn_private"
    refute dashboard_dump =~ "customer_email"
    refute dashboard_dump =~ "customer_name"
    refute dashboard_dump =~ "payment_gateway_transaction_id"
  end

  test "dashboard by event table switches between current and past with venue display", %{
    conn: conn
  } do
    admin = create_user!("dashboard-lifecycle@example.com")
    create_global_role!(admin, :admin)

    source = SalesHelpers.create_source_system!()

    current =
      SalesHelpers.create_event!(source, %{
        name: "Dashboard Current Event",
        slug: unique_slug("dash-current"),
        starts_at: DateTime.add(DateTime.utc_now(), -1, :hour),
        ends_at: DateTime.add(DateTime.utc_now(), 1, :hour),
        venue_name: "Dashboard Hall"
      })

    past =
      SalesHelpers.create_event!(source, %{
        name: "Dashboard Past Event",
        slug: unique_slug("dash-past"),
        starts_at: ~U[2026-01-01 10:00:00Z],
        ends_at: ~U[2026-01-01 12:00:00Z],
        venue_name: "Past Hall"
      })

    DashboardCache.put_event_summary(current.id, summary(%{total_sold: 1}))
    DashboardCache.put_event_summary(past.id, summary(%{total_sold: 2}))

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/dashboard")

    assert html =~ "Current"
    assert html =~ "Past"
    assert html =~ current.name
    assert html =~ "Dashboard Hall"
    refute html =~ past.name

    html = render_patch(view, "/admin/dashboard?lifecycle=past")

    assert html =~ past.name
    assert html =~ "Past Hall"
    refute html =~ current.name
  end

  test "manual refresh requests hot-state rebuild and rate limits by user", %{conn: conn} do
    first_admin = create_user!("dashboard-refresh-1@example.com")
    second_admin = create_user!("dashboard-refresh-2@example.com")
    create_global_role!(first_admin, :admin)
    create_global_role!(second_admin, :admin)

    {:ok, view, _html} =
      conn
      |> sign_in_as(first_admin)
      |> live("/admin/dashboard")

    assert render_click(view, "manual_refresh") =~ "Refresh requested"
    assert rebuild_job_count() == 1
    assert refresh_snapshot_job_count() == 0

    assert render_click(view, "manual_refresh") =~ "Try again shortly"
    assert rebuild_job_count() == 1
    assert refresh_snapshot_job_count() == 0

    {:ok, second_view, _html} =
      Phoenix.ConnTest.build_conn()
      |> sign_in_as(second_admin)
      |> live("/admin/dashboard")

    assert render_click(second_view, "manual_refresh") =~ "Refresh requested"
  end

  test "dashboard receives hot-state PubSub and updates one event row without full reload", %{
    conn: conn
  } do
    admin = create_user!("dashboard-pubsub@example.com")
    create_global_role!(admin, :admin)

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{name: "PubSub Event", slug: unique_slug("pubsub")})

    other_event =
      SalesHelpers.create_event!(source, %{name: "Other PubSub", slug: unique_slug("other")})

    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "VIP"})

    older = create_order!(source, :completed, order_number: "VISIBLE-ORDER")
    create_item!(older, event, ticket, woo_line_item_id: 21)
    create_item!(older, other_event, other_ticket, woo_line_item_id: 22)

    DashboardCache.put_event_summary(
      event.id,
      summary(%{total_sold: 1, status_breakdown: %{"completed" => 1}})
    )

    DashboardCache.put_event_summary(
      other_event.id,
      summary(%{
        total_sold: 2,
        total_revenue: Decimal.new("900.00"),
        status_breakdown: %{"pending" => 2}
      })
    )

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/dashboard")

    assert html =~ "VISIBLE-ORDER"

    create_order!(source, :completed,
      order_number: "SHOULD-NOT-APPEAR",
      updated_at_source: ~U[2026-05-17 09:00:00Z]
    )

    DashboardCache.put_event_summary(
      event.id,
      summary(%{
        total_sold: 4,
        total_revenue: Decimal.new("1800.00"),
        status_breakdown: %{"completed" => 4}
      })
    )

    send(view.pid, {:hot_state_updated, event.id, DateTime.utc_now()})

    html = render(view)

    assert html =~ "1800.00"
    assert html =~ "6"
    assert html =~ "completed"
    assert html =~ "pending"
    assert html =~ "VISIBLE-ORDER"
    refute html =~ "SHOULD-NOT-APPEAR"
    assert Process.alive?(view.pid)
  end

  test "dashboard ignores unknown event updates safely", %{conn: conn} do
    admin = create_user!("dashboard-unknown-event@example.com")
    create_global_role!(admin, :admin)

    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Known Event", slug: unique_slug("known")})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    order = create_order!(source, :completed, order_number: "KNOWN-ORDER")
    create_item!(order, event, ticket, woo_line_item_id: 31)

    DashboardCache.put_event_summary(event.id, summary(%{total_sold: 1}))

    {:ok, view, _html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/dashboard")

    html_before = render(view)

    send(view.pid, {:hot_state_updated, Ecto.UUID.generate(), DateTime.utc_now()})

    assert render(view) == html_before
  end

  test "manual refresh subscribes to newly visible event topics", %{conn: conn} do
    admin = create_user!("dashboard-refresh-subscribe@example.com")
    create_global_role!(admin, :admin)

    source = SalesHelpers.create_source_system!()

    initial =
      SalesHelpers.create_event!(source, %{name: "Initial Event", slug: unique_slug("initial")})

    initial_ticket = SalesHelpers.create_ticket_type!(initial, %{name: "GA"})
    order = create_order!(source, :completed, order_number: "INITIAL-ORDER")
    create_item!(order, initial, initial_ticket, woo_line_item_id: 41)

    DashboardCache.put_event_summary(initial.id, summary(%{total_sold: 1}))

    {:ok, view, _html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/dashboard")

    new_event =
      SalesHelpers.create_event!(source, %{name: "Newly Visible Event", slug: unique_slug("new")})

    new_ticket = SalesHelpers.create_ticket_type!(new_event, %{name: "Balcony"})
    new_order = create_order!(source, :completed, order_number: "NEW-ORDER")
    create_item!(new_order, new_event, new_ticket, woo_line_item_id: 42)

    DashboardCache.put_event_summary(new_event.id, summary(%{total_sold: 0}))

    assert render_click(view, "manual_refresh") =~ "Newly Visible Event"

    DashboardCache.put_event_summary(
      new_event.id,
      summary(%{
        total_sold: 5,
        total_revenue: Decimal.new("2250.00"),
        status_breakdown: %{"completed" => 5}
      })
    )

    DashboardPubSub.broadcast_hot_state_updated(new_event.id, DateTime.utc_now())

    assert render(view) =~ "2250.00"
  end

  test "DashboardLive source stays inside approved boundaries" do
    source = File.read!("lib/event_sales_web/live/admin/dashboard_live.ex")

    for forbidden <- [
          "EventAggregator",
          "OrderItem",
          "Repo",
          "sales_order_items",
          "SnapshotRefresh",
          "WooCommerce",
          "Redix",
          "SnapshotStore"
        ] do
      refute source =~ forbidden
    end
  end

  test "manual refresh recomputes chart assigns after loading dashboard data" do
    source = File.read!("lib/event_sales_web/live/admin/dashboard_live.ex")

    assert source =~
             ~r/\|> put_refresh_flash\(result\)\s+\|> load_dashboard\(\)\s+\|> assign_chart_data\(\)\s+\|> maybe_subscribe_to_event_topics\(\)/
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

  defp create_order!(source, status, attrs) do
    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "DASH-#{System.unique_integer([:positive])}",
      status: status,
      currency: "ZAR",
      completed_at: ~U[2026-05-17 08:00:00.000000Z],
      created_at_source: ~U[2026-05-17 07:00:00.000000Z],
      updated_at_source: ~U[2026-05-17 08:00:00.000000Z],
      customer_name: "Private Customer",
      customer_email: "private@example.test",
      raw_total: Decimal.new("900.00"),
      raw_discount_total: Decimal.new("0"),
      raw_tax_total: Decimal.new("0"),
      payment_gateway_transaction_id: "txn_private"
    }

    Ash.create!(Order, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_item!(order, event, ticket, attrs) do
    defaults = %{
      order_id: order.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_line_item_id: System.unique_integer([:positive]),
      woo_product_id: System.unique_integer([:positive]),
      woo_variation_id: nil,
      name: "Dashboard Ticket",
      quantity: 1,
      line_subtotal: Decimal.new("450.00"),
      line_total: Decimal.new("450.00"),
      discount_total: Decimal.new("0"),
      item_kind: :ticket,
      mapping_status: :mapped
    }

    Ash.create!(OrderItem, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp delete_rebuild_jobs! do
    import Ecto.Query

    Oban.Job
    |> where(
      [job],
      job.worker in [
        "EventSales.Analytics.Workers.RebuildHotStateWorker",
        "EventSales.Analytics.Workers.RefreshSnapshotWorker"
      ]
    )
    |> Repo.delete_all()
  end

  defp rebuild_job_count do
    count_jobs("EventSales.Analytics.Workers.RebuildHotStateWorker")
  end

  defp refresh_snapshot_job_count do
    count_jobs("EventSales.Analytics.Workers.RefreshSnapshotWorker")
  end

  defp count_jobs(worker) do
    import Ecto.Query

    Repo.aggregate(from(job in Oban.Job, where: job.worker == ^worker), :count)
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp summary(overrides) do
    %{
      total_sold: 0,
      total_revenue: Decimal.new("450.00"),
      today_sold: 0,
      today_revenue: Decimal.new("0"),
      status_breakdown: %{},
      currency: "ZAR",
      updated_at: ~U[2026-05-17 10:00:00Z]
    }
    |> Map.merge(overrides)
  end
end
