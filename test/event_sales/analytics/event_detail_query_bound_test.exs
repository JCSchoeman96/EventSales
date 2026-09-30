defmodule EventSales.Analytics.EventDetailQueryBoundTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics
  alias EventSales.Analytics.EventDetail
  alias EventSales.Analytics.Resources.EventAggregateSnapshot
  alias EventSales.Analytics.SnapshotRefresh
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.SalesHelpers

  setup do
    test_pid = self()
    handler_id = "event-detail-sql-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:event_sales, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          query = IO.iodata_to_binary(metadata.query)
          send(test_pid, {:repo_sql, query})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
  end

  test "certified get_event_detail succeeds without legacy raw financial helpers in module" do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Query Bound Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    admin = create_admin!()

    order = create_order!(source)

    create_item!(order, event, ticket,
      woo_product_id: 501,
      woo_variation_id: 601,
      quantity: 2,
      line_total: Decimal.new("20.00"),
      line_total_tax: Decimal.new("2.00")
    )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)
    EventDetailCertificationHelpers.certify_analytics_ready!(event)

    assert {:ok, detail} = EventDetail.get_event_detail(event.id, actor: admin)
    assert detail.sold == 2
    assert detail.revenue == Decimal.new("22.00")
  end

  test "get_event_detail SQL capture excludes raw financial and ticket aggregates", %{} do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "SQL Capture Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    admin = create_admin!()

    order = create_order!(source)

    create_item!(order, event, ticket,
      woo_product_id: 501,
      woo_variation_id: 601,
      quantity: 2,
      line_total: Decimal.new("20.00"),
      line_total_tax: Decimal.new("2.00")
    )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)
    EventDetailCertificationHelpers.certify_analytics_ready!(event)

    drain_repo_sql()

    assert {:ok, _detail} = EventDetail.get_event_detail(event.id, actor: admin)

    queries = drain_repo_sql()
    assert queries != []

    sql = Enum.join(queries, "\n")
    lowered = String.downcase(sql)

    refute lowered =~ "sum(line_total)"
    refute lowered =~ "sum(oi.line_total)"
    refute String.match?(lowered, ~r/group by.*ticket_type_id/)

    assert Enum.count(queries, &operational_status_query?/1) == 1
  end

  test "projection rollback emits no operational status SQL after nested rollback", %{} do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Rollback SQL Event"})
    admin = create_admin!()

    EventDetailCertificationHelpers.certify_analytics_ready!(event)

    Ash.create!(
      EventAggregateSnapshot,
      %{
        event_id: event.id,
        currency: "ZAR",
        snapshot_version: 2,
        gross_ticket_quantity: 1,
        gross_ticket_value: Decimal.new("10.00"),
        refund_ticket_quantity: 0,
        refund_ticket_value: Decimal.new("0"),
        recognised_order_count: 1,
        total_sold: 0,
        total_revenue: Decimal.new("0"),
        today_sold: 0,
        today_revenue: Decimal.new("0"),
        status_breakdown: %{},
        business_timezone: "Africa/Johannesburg",
        refreshed_at: ~U[2026-05-18 07:00:00.000000Z],
        source_row_count: 1
      },
      action: :create_snapshot,
      domain: Analytics
    )

    drain_repo_sql()

    assert {:error, :snapshot_not_ready} =
             EventDetail.get_event_detail(event.id, actor: admin)

    queries = drain_repo_sql()
    refute Enum.any?(queries, &operational_status_query?/1)
  end

  test "event_detail module source excludes removed raw financial helpers" do
    source = File.read!("lib/event_sales/analytics/event_detail.ex")

    refute source =~ "scoped_summary"
    refute source =~ "ticket_type_aggregate_rows"
    refute source =~ "EventAggregator"
    refute source =~ "DimensionAggregator"
    assert source =~ "operational_status_breakdown_map"
    refute source =~ "defp status_breakdown"
  end

  defp drain_repo_sql do
    receive do
      {:repo_sql, query} -> [query | drain_repo_sql()]
    after
      0 -> []
    end
  end

  defp operational_status_query?(query) do
    lowered = String.downcase(query)

    String.contains?(lowered, "sales_order_items") and
      String.contains?(lowered, "group by") and
      String.contains?(lowered, "mapped") and
      not String.contains?(lowered, "line_total")
  end

  defp create_admin! do
    user =
      Ash.create!(
        User,
        %{
          email: "qb-#{System.unique_integer([:positive])}@example.com",
          name: "Admin",
          password: "valid-pass-123",
          password_confirmation: "valid-pass-123"
        },
        action: :register_with_password,
        domain: Accounts
      )

    role =
      Role
      |> Ash.Query.filter(name == :admin)
      |> Ash.read_one!(domain: Accounts)
      |> case do
        nil -> Ash.create!(Role, %{name: :admin}, action: :create, domain: Accounts)
        role -> role
      end

    Ash.create!(UserRole, %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )

    user
  end

  defp create_order!(source) do
    Ash.create!(
      Order,
      %{
        source_system_id: source.id,
        woo_order_id: System.unique_integer([:positive]),
        order_number: "QB-1",
        status: :completed,
        currency: "ZAR",
        completed_at: ~U[2026-05-18 08:00:00.000000Z],
        created_at_source: ~U[2026-05-18 07:00:00.000000Z],
        updated_at_source: ~U[2026-05-18 08:00:00.000000Z],
        customer_name: "Customer",
        customer_email: "c@example.test",
        raw_total: Decimal.new("100.00"),
        raw_discount_total: Decimal.new("0"),
        raw_tax_total: Decimal.new("0")
      },
      action: :create_normalized,
      domain: EventSales.Sales
    )
  end

  defp create_item!(order, %Event{} = event, %TicketType{} = ticket, attrs) do
    defaults = %{
      order_id: order.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_line_item_id: System.unique_integer([:positive]),
      woo_product_id: 500,
      woo_variation_id: 600,
      name: "Ticket",
      quantity: 1,
      line_subtotal: Decimal.new("10.00"),
      line_total: Decimal.new("10.00"),
      line_total_tax: Decimal.new("0"),
      discount_total: Decimal.new("0"),
      item_kind: :ticket,
      mapping_status: :mapped
    }

    Ash.create!(OrderItem, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: EventSales.Sales
    )
  end
end
