defmodule EventSales.Analytics.EventDetailTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics
  alias EventSales.Analytics.{DashboardCache, EventDetail, HotStateAggregator}
  alias EventSales.Analytics.Resources.EventAggregateSnapshot
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers

  setup do
    HotStateAggregator.reset_for_test!()
    on_exit(fn -> HotStateAggregator.reset_for_test!() end)

    admin = create_user!("slice-12-admin@example.com")
    staff = create_user!("slice-12-staff@example.com")
    create_global_role!(admin, :admin)
    create_global_role!(staff, :staff)

    source = SalesHelpers.create_source_system!()

    event =
      SalesHelpers.create_event!(source, %{
        name: "Slice 12 Event",
        slug: unique_slug("slice-12"),
        capacity: 10
      })

    other_event =
      SalesHelpers.create_event!(source, %{
        name: "Other Slice 12 Event",
        slug: unique_slug("slice-12-other"),
        capacity: nil
      })

    ga = SalesHelpers.create_ticket_type!(event, %{name: "GA", capacity: 8})
    vip = SalesHelpers.create_ticket_type!(event, %{name: "VIP", capacity: nil})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other GA"})

    %{
      admin: admin,
      staff: staff,
      source: source,
      event: event,
      other_event: other_event,
      ga: ga,
      vip: vip,
      other_ticket: other_ticket
    }
  end

  test "list_events uses hot summary before snapshot and raw order rows", %{
    admin: admin,
    source: source,
    event: event,
    ga: ga
  } do
    completed = create_order!(source, :completed, woo_order_id: 101)
    create_item!(completed, event, ga, quantity: 9, line_total: Decimal.new("900.00"))
    create_snapshot!(event, %{total_sold: 4, total_revenue: Decimal.new("400.00")})

    DashboardCache.put_event_summary(event.id, %{
      total_sold: 2,
      total_revenue: Decimal.new("200.00"),
      status_breakdown: %{"completed" => 1},
      currency: "ZAR",
      refreshed_at: ~U[2026-05-18 08:00:00Z]
    })

    assert {:ok, %{rows: rows}} = EventDetail.list_events(actor: admin)

    row = Enum.find(rows, &(&1.event_id == event.id))
    assert row.sold == 2
    assert row.revenue == Decimal.new("200.00")
    assert row.remaining == 8
    assert row.refreshed_at == ~U[2026-05-18 08:00:00Z]
  end

  test "list_events falls back to snapshot summary and then zero summary", %{
    admin: admin,
    event: event,
    other_event: other_event
  } do
    create_snapshot!(event, %{total_sold: 5, total_revenue: Decimal.new("500.00")})

    assert {:ok, %{rows: rows}} = EventDetail.list_events(actor: admin)

    snapshot_row = Enum.find(rows, &(&1.event_id == event.id))
    zero_row = Enum.find(rows, &(&1.event_id == other_event.id))

    assert snapshot_row.sold == 5
    assert snapshot_row.revenue == Decimal.new("500.00")
    assert snapshot_row.remaining == 5

    assert zero_row.sold == 0
    assert zero_row.revenue == Decimal.new("0")
    assert zero_row.remaining == nil
  end

  test "facade rejects missing and non-admin actors", %{staff: staff, event: event} do
    assert {:error, :forbidden} = EventDetail.list_events(actor: nil)
    assert {:error, :forbidden} = EventDetail.list_events(actor: staff)
    assert {:error, :forbidden} = EventDetail.get_event_detail(event.id, actor: staff)
    assert {:error, :forbidden} = EventDetail.recent_orders(event.id, actor: staff)
    assert {:error, :forbidden} = EventDetail.unmapped_items(event.id, actor: staff)
  end

  test "get_event_detail computes nil capacity safely", %{
    admin: admin,
    source: source,
    other_event: event,
    other_ticket: ticket
  } do
    completed = create_order!(source, :completed, woo_order_id: 201)
    create_item!(completed, event, ticket, quantity: 3, line_total: Decimal.new("300.00"))

    assert {:ok, detail} = EventDetail.get_event_detail(event.id, actor: admin)

    assert detail.capacity == nil
    assert detail.sold == 3
    assert detail.remaining == nil
    assert detail.revenue == Decimal.new("300.00")
  end

  test "get_event_detail computes remaining with capacity", %{
    admin: admin,
    source: source,
    event: event,
    ga: ga
  } do
    completed = create_order!(source, :completed, woo_order_id: 301)
    create_item!(completed, event, ga, quantity: 4, line_total: Decimal.new("450.00"))

    assert {:ok, detail} = EventDetail.get_event_detail(event.id, actor: admin)

    assert detail.capacity == 10
    assert detail.sold == 4
    assert detail.remaining == 6
    assert detail.status_breakdown == %{"completed" => 4}
    ga_row = Enum.find(detail.ticket_types, &(&1.ticket_type_id == ga.id))
    assert %{sold: 4, remaining: 4} = ga_row
  end

  test "mixed-event orders are filtered by selected event line items", %{
    admin: admin,
    source: source,
    event: event,
    other_event: other_event,
    ga: ga,
    other_ticket: other_ticket
  } do
    order = create_order!(source, :completed, woo_order_id: 401, order_number: "MIXED-1")
    create_item!(order, event, ga, quantity: 2, line_total: Decimal.new("200.00"))
    create_item!(order, other_event, other_ticket, quantity: 7, line_total: Decimal.new("700.00"))

    assert {:ok, detail} = EventDetail.get_event_detail(event.id, actor: admin)
    assert detail.sold == 2
    assert detail.revenue == Decimal.new("200.00")

    assert {:ok, %{rows: [recent]}} = EventDetail.recent_orders(event.id, actor: admin)
    assert recent.order_number == "MIXED-1"
    refute Map.has_key?(recent, :customer_email)
    refute Map.has_key?(recent, :customer_name)
    refute Map.has_key?(recent, :payment_gateway_transaction_id)
  end

  test "unmapped items are visible for the selected event and capped", %{
    admin: admin,
    source: source,
    event: event,
    ga: ga
  } do
    order = create_order!(source, :completed, woo_order_id: 501, order_number: "UNMAPPED-1")

    for index <- 1..55 do
      create_item!(order, event, ga,
        name: "Needs Mapping #{index}",
        woo_line_item_id: 1_000 + index,
        woo_product_id: 2_000 + index,
        mapping_status: :pending_mapping_resolution,
        item_kind: :unknown
      )
    end

    assert {:ok, %{rows: rows, page: page}} =
             EventDetail.unmapped_items(event.id, actor: admin, per_page: 100)

    assert length(rows) == 50
    assert page.per_page == 50
    assert page.has_next? == true
    assert Enum.all?(rows, &(&1.order_number == "UNMAPPED-1"))
  end

  test "recent orders are capped at max 50", %{admin: admin, source: source, event: event, ga: ga} do
    for index <- 1..55 do
      order =
        create_order!(source, :completed,
          woo_order_id: 600 + index,
          order_number: "RECENT-#{index}",
          updated_at_source: DateTime.add(~U[2026-05-18 08:00:00Z], index, :second)
        )

      create_item!(order, event, ga, woo_line_item_id: 3_000 + index)
    end

    assert {:ok, %{rows: rows, page: page}} =
             EventDetail.recent_orders(event.id, actor: admin, per_page: 100)

    assert length(rows) == 50
    assert page.per_page == 50
    assert page.has_next? == true
    assert hd(rows).order_number == "RECENT-55"
  end

  test "unknown event returns not_found", %{admin: admin} do
    assert :not_found = EventDetail.get_event_detail(Ecto.UUID.generate(), actor: admin)
  end

  defp create_snapshot!(%Event{} = event, attrs) do
    defaults = %{
      event_id: event.id,
      total_sold: 0,
      total_revenue: Decimal.new("0"),
      today_sold: 0,
      today_revenue: Decimal.new("0"),
      status_breakdown: %{},
      currency: "ZAR",
      business_timezone: "Africa/Johannesburg",
      refreshed_at: ~U[2026-05-18 07:00:00.000000Z],
      source_row_count: 0,
      snapshot_version: 1
    }

    Ash.create!(EventAggregateSnapshot, Map.merge(defaults, Map.new(attrs)),
      action: :create_snapshot,
      domain: Analytics
    )
  end

  defp create_order!(source, status, attrs) do
    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "ED-#{System.unique_integer([:positive])}",
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
      name: "Slice 12 Ticket",
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
