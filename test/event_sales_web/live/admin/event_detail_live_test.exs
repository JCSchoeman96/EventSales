defmodule EventSalesWeb.Live.Admin.EventDetailLiveTest do
  use EventSalesWeb.ConnCase, async: false

  require Ash.Query

  import Phoenix.LiveViewTest

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics.HotStateAggregator
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers

  setup do
    EventSales.DataCase.setup_sandbox(%{async: false})
    HotStateAggregator.reset_for_test!()

    on_exit(fn -> HotStateAggregator.reset_for_test!() end)

    :ok
  end

  test "rejects unauthenticated access", %{conn: conn} do
    conn = get(conn, "/admin/events/#{Ecto.UUID.generate()}")
    assert response(conn, 401) == "Unauthorized"
  end

  test "rejects non-admin access", %{conn: conn} do
    staff = create_user!("event-detail-staff@example.com")
    create_global_role!(staff, :staff)

    conn =
      conn
      |> sign_in_as(staff)
      |> get("/admin/events/#{Ecto.UUID.generate()}")

    assert response(conn, 403) == "Forbidden"
  end

  test "admin sees selected event detail with capacity, breakdowns, recent orders, and unmapped rows",
       %{conn: conn} do
    admin = create_user!("event-detail-admin@example.com")
    create_global_role!(admin, :admin)

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        name: "Detail Event",
        slug: unique_slug("detail"),
        capacity: 10
      })

    other_event =
      SalesHelpers.create_event!(source, %{
        name: "Other Detail Event",
        slug: unique_slug("other-detail")
      })

    ga = SalesHelpers.create_ticket_type!(event, %{name: "GA", capacity: 8})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other GA"})

    mixed_order = create_order!(source, :completed, order_number: "MIXED-DETAIL")
    create_item!(mixed_order, event, ga, quantity: 3, line_total: Decimal.new("300.00"))

    create_item!(mixed_order, other_event, other_ticket,
      quantity: 6,
      line_total: Decimal.new("600.00")
    )

    create_item!(mixed_order, event, ga,
      name: "Detail Unmapped",
      woo_line_item_id: 901,
      woo_product_id: 9901,
      mapping_status: :pending_mapping_resolution,
      item_kind: :unknown
    )

    {:ok, _view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/events/#{event.id}")

    assert html =~ "Detail Event"
    assert html =~ "Capacity"
    assert html =~ "10"
    assert html =~ "Sold"
    assert html =~ "3"
    assert html =~ "Remaining"
    assert html =~ "7"
    assert html =~ "GA"
    assert html =~ "completed"
    assert html =~ "MIXED-DETAIL"
    assert html =~ "Detail Unmapped"
    refute html =~ "Other Detail Event"
    refute html =~ "Private Customer"
    refute html =~ "private@example.test"
    refute html =~ "txn_private"
  end

  test "nil capacity renders safely", %{conn: conn} do
    admin = create_user!("event-detail-nil-capacity@example.com")
    create_global_role!(admin, :admin)

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{name: "Uncapped Event", slug: unique_slug("uncapped")})

    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    order = create_order!(source, :completed)
    create_item!(order, event, ticket, quantity: 2)

    {:ok, _view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/events/#{event.id}")

    assert html =~ "Uncapped Event"
    assert html =~ "Uncapped"
  end

  test "recent orders and unmapped streams use bounded pages", %{conn: conn} do
    admin = create_user!("event-detail-bounded@example.com")
    create_global_role!(admin, :admin)

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{name: "Bounded Event", slug: unique_slug("bounded")})

    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    for index <- 1..30 do
      order =
        create_order!(source, :completed,
          woo_order_id: 1_200 + index,
          order_number: "BOUND-#{index}",
          updated_at_source: DateTime.add(~U[2026-05-18 08:00:00Z], index, :second)
        )

      create_item!(order, event, ticket, woo_line_item_id: 2_200 + index)

      create_item!(order, event, ticket,
        name: "Unmapped #{index}",
        woo_line_item_id: 3_200 + index,
        woo_product_id: 4_200 + index,
        mapping_status: :pending_mapping_resolution,
        item_kind: :unknown
      )
    end

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/events/#{event.id}")

    assert html =~ "BOUND-30"
    refute html =~ "BOUND-5"
    assert html =~ "Unmapped 30"
    refute html =~ "Unmapped 5"

    render_click(view, "next_recent_orders_page")
    html = render(view)
    assert html =~ "BOUND-5"

    render_click(view, "next_unmapped_items_page")
    html = render(view)
    assert html =~ "Unmapped 5"
  end

  test "PubSub refresh updates summaries but does not reload streams", %{conn: conn} do
    admin = create_user!("event-detail-pubsub@example.com")
    create_global_role!(admin, :admin)

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{name: "PubSub Detail", slug: unique_slug("pubsub")})

    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})

    order = create_order!(source, :completed, order_number: "ORIGINAL-ORDER")
    create_item!(order, event, ticket, quantity: 1, woo_line_item_id: 10)

    create_item!(order, event, ticket,
      name: "Original Unmapped",
      woo_line_item_id: 11,
      woo_product_id: 111,
      mapping_status: :pending_mapping_resolution,
      item_kind: :unknown
    )

    {:ok, view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/events/#{event.id}")

    assert html =~ "ORIGINAL-ORDER"
    assert html =~ "Original Unmapped"

    new_order =
      create_order!(source, :completed,
        order_number: "NEW-AFTER-MOUNT",
        updated_at_source: ~U[2026-05-18 09:00:00Z]
      )

    create_item!(new_order, event, ticket, quantity: 4, woo_line_item_id: 12)

    create_item!(new_order, event, ticket,
      name: "New Unmapped After Mount",
      woo_line_item_id: 13,
      woo_product_id: 113,
      mapping_status: :pending_mapping_resolution,
      item_kind: :unknown
    )

    send(view.pid, {:hot_state_updated, event.id, DateTime.utc_now()})

    html = render(view)
    assert html =~ "5"
    assert html =~ "ORIGINAL-ORDER"
    assert html =~ "Original Unmapped"
    refute html =~ "NEW-AFTER-MOUNT"
    refute html =~ "New Unmapped After Mount"
  end

  test "unknown event id renders a safe not-found state", %{conn: conn} do
    admin = create_user!("event-detail-not-found@example.com")
    create_global_role!(admin, :admin)

    {:ok, _view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/events/#{Ecto.UUID.generate()}")

    assert html =~ "Event not found"
  end

  test "event detail renders event-scoped export links", %{conn: conn} do
    admin = create_user!("event-detail-placeholders@example.com")
    create_global_role!(admin, :admin)

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        name: "Placeholder Event",
        slug: unique_slug("placeholder")
      })

    {:ok, _view, html} =
      conn
      |> sign_in_as(admin)
      |> live("/admin/events/#{event.id}")

    assert html =~ "Summary CSV"
    assert html =~ "Orders CSV"
    assert html =~ "Import CSV"
    assert html =~ ~s(/admin/events/#{event.id}/exports/summary.csv)
    assert html =~ ~s(/admin/events/#{event.id}/exports/orders.csv)
    refute html =~ "Export CSV"
    refute html =~ "phx-click=\"import"
  end

  test "EventDetailLive source stays inside approved boundaries" do
    source = File.read!("lib/event_sales_web/live/admin/event_detail_live.ex")

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

  defp create_order!(source, status, attrs \\ []) do
    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "DETAIL-#{System.unique_integer([:positive])}",
      status: status,
      currency: "ZAR",
      completed_at: ~U[2026-05-18 08:00:00.000000Z],
      created_at_source: ~U[2026-05-18 07:00:00.000000Z],
      updated_at_source: ~U[2026-05-18 08:00:00.000000Z],
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

  defp create_item!(order, %Event{} = event, %TicketType{} = ticket, attrs) do
    defaults = %{
      order_id: order.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_line_item_id: System.unique_integer([:positive]),
      woo_product_id: System.unique_integer([:positive]),
      woo_variation_id: nil,
      name: "Detail Ticket",
      quantity: 1,
      line_subtotal: Decimal.new("100.00"),
      line_total: Decimal.new("100.00"),
      discount_total: Decimal.new("0"),
      item_kind: :ticket,
      mapping_status: :mapped
    }

    Ash.create!(OrderItem, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
