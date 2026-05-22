defmodule EventSalesWeb.Admin.EventExportControllerTest do
  use EventSalesWeb.ConnCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Audit
  alias EventSales.Audit.Resources.AuditLog
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers

  setup do
    EventSales.DataCase.setup_sandbox(%{async: false})

    admin = create_user!("event-export-admin@example.com")
    create_global_role!(admin, :admin)
    staff = create_user!("event-export-staff@example.com")
    create_global_role!(staff, :staff)

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        name: "Controller Export",
        slug: unique_slug("controller-export")
      })

    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA", capacity: 20})
    order = create_order!(source, :completed, order_number: "CTRL-1")
    create_item!(order, event, ticket, quantity: 2, line_total: Decimal.new("200.00"))

    %{admin: admin, staff: staff, source: source, event: event, ticket: ticket}
  end

  test "unauthenticated exports return 401", %{conn: conn, event: event} do
    conn = get(conn, "/admin/events/#{event.id}/exports/summary.csv")
    assert response(conn, 401) == "Unauthorized"
  end

  test "non-admin exports return 403", %{conn: conn, event: event, staff: staff} do
    conn =
      conn
      |> sign_in_as(staff)
      |> get("/admin/events/#{event.id}/exports/orders.csv")

    assert response(conn, 403) == "Forbidden"
  end

  test "admin exports summary csv and writes requested audit", %{
    conn: conn,
    event: event,
    admin: admin
  } do
    conn =
      conn
      |> sign_in_as(admin)
      |> get("/admin/events/#{event.id}/exports/summary.csv")

    assert response(conn, 200)
    assert get_resp_header(conn, "content-type") == ["text/csv; charset=utf-8"]
    assert get_resp_header(conn, "x-event-sales-export-truncated") == ["false"]
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~s(attachment; filename="event-summary-#{event.id}.csv")

    body = response(conn, 200)
    assert body =~ "row_type,event_id,event_name"
    assert body =~ "Controller Export"
    refute body =~ "Private Customer"
    refute body =~ "private@example.test"
    refute body =~ "txn_private"

    assert {:ok, [audit]} =
             AuditLog
             |> Ash.Query.filter(event_type == :event_sales_export_requested)
             |> Ash.read(domain: Audit)

    assert audit.actor_user_id == admin.id
    assert audit.actor_role == :admin
    assert audit.source == :admin
    assert audit.event_id == event.id
    assert audit.metadata["event_id"] == event.id
    assert audit.metadata["export_type"] == "summary"
    assert audit.metadata["actor_user_id"] == admin.id
    assert audit.metadata["actor_role"] == "admin"
    assert audit.metadata["source"] == "admin"
    assert audit.metadata["pii_policy"] == "no_pii"
    refute inspect(audit.metadata) =~ "private@example.test"
  end

  test "admin exports orders csv and writes requested audit", %{
    conn: conn,
    event: event,
    admin: admin
  } do
    conn =
      conn
      |> sign_in_as(admin)
      |> get("/admin/events/#{event.id}/exports/orders.csv")

    assert response(conn, 200)
    assert get_resp_header(conn, "x-event-sales-export-truncated") == ["false"]

    body = response(conn, 200)
    assert body =~ "event_id,event_name,order_id,order_number"
    assert body =~ "CTRL-1"
    refute body =~ "Private Customer"
    refute body =~ "private@example.test"
    refute body =~ "txn_private"
    refute body =~ "payment_gateway_transaction_id"

    assert {:ok, [audit]} =
             AuditLog
             |> Ash.Query.filter(event_type == :event_sales_export_requested)
             |> Ash.read(domain: Audit)

    assert audit.metadata["export_type"] == "orders"
  end

  test "orders export reports truncation header", %{
    conn: conn,
    admin: admin,
    source: source,
    event: event,
    ticket: ticket
  } do
    for index <- 1..3 do
      order =
        create_order!(source, :completed,
          woo_order_id: 4_000 + index,
          order_number: "LIMIT-#{index}",
          updated_at_source: DateTime.add(~U[2026-05-18 08:00:00.000000Z], index, :second)
        )

      create_item!(order, event, ticket, woo_line_item_id: 5_000 + index)
    end

    conn =
      conn
      |> sign_in_as(admin)
      |> get("/admin/events/#{event.id}/exports/orders.csv?max_rows=2")

    assert response(conn, 200)
    assert get_resp_header(conn, "x-event-sales-export-truncated") == ["true"]
    body = response(conn, 200)
    assert body =~ "LIMIT-3"
    assert body =~ "LIMIT-2"
    refute body =~ "LIMIT-1"
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

  defp create_order!(source, status, attrs) do
    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "CTRL-#{System.unique_integer([:positive])}",
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
      name: "Controller Ticket",
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
