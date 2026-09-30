defmodule EventSales.Analytics.M502DimensionReconciliationTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics
  alias EventSales.Analytics.DimensionSnapshotReader
  alias EventSales.Analytics.Resources.EventAggregateSnapshot
  alias EventSales.Analytics.SnapshotRefresh
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.SalesHelpers

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "M5-02 Reconciliation Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    admin = create_admin!()

    %{source: source, event: event, ticket: ticket, admin: admin}
  end

  test "integrated refresh reconciles event, ticket, and product per currency", %{
    source: source,
    event: event,
    ticket: ticket,
    admin: admin
  } do
    order = create_order!(source, :completed)

    create_item!(order, event, ticket,
      woo_product_id: 901,
      woo_variation_id: 1001,
      quantity: 2,
      line_total: Decimal.new("20.00"),
      line_total_tax: Decimal.new("2.00")
    )

    create_item!(order, event, ticket,
      woo_product_id: 902,
      woo_variation_id: nil,
      quantity: 1,
      line_total: Decimal.new("15.00"),
      line_total_tax: Decimal.new("0.00")
    )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)
    EventDetailCertificationHelpers.certify_analytics_ready!(event)

    event_row = event_v2_snapshot!(event.id, "ZAR")
    assert {:ok, dimension} = DimensionSnapshotReader.list_for_event(event.id, actor: admin)

    zar = Enum.find(dimension.currencies, &(&1.currency == "ZAR"))
    tickets = zar.dimensions.ticket_type
    products = zar.dimensions.source_product
    variations = zar.dimensions.source_variation

    ticket_qty = Enum.sum(Enum.map(tickets, & &1.gross_ticket_quantity))
    ticket_value = sum_values(tickets)

    product_qty = Enum.sum(Enum.map(products, & &1.gross_ticket_quantity))
    product_value = sum_values(products)

    variation_qty = Enum.sum(Enum.map(variations, & &1.gross_ticket_quantity))
    variation_value = sum_values(variations)

    assert ticket_qty == event_row.gross_ticket_quantity
    assert product_qty == event_row.gross_ticket_quantity
    assert Decimal.equal?(ticket_value, event_row.gross_ticket_value)
    assert Decimal.equal?(product_value, event_row.gross_ticket_value)

    assert variation_qty == 2
    assert Decimal.equal?(variation_value, Decimal.new("22.00"))
    assert variation_qty < event_row.gross_ticket_quantity
    assert Decimal.compare(variation_value, event_row.gross_ticket_value) == :lt

    families_qty = ticket_qty + product_qty + variation_qty
    refute families_qty == event_row.gross_ticket_quantity
  end

  test "multi-currency reconciles independently", %{
    source: source,
    event: event,
    ticket: ticket,
    admin: admin
  } do
    second_ticket = SalesHelpers.create_ticket_type!(event, %{name: "USD GA"})

    zar_order = create_order!(source, :completed, woo_order_id: 1)

    create_item!(zar_order, event, ticket,
      woo_product_id: 911,
      woo_variation_id: 1011,
      quantity: 1,
      line_total: Decimal.new("10.00"),
      line_total_tax: Decimal.new("0.00")
    )

    usd_order =
      create_order!(source, :completed,
        currency: "USD",
        woo_order_id: 2
      )

    create_item!(usd_order, event, second_ticket,
      woo_product_id: 912,
      woo_variation_id: 1012,
      quantity: 2,
      line_total: Decimal.new("8.00"),
      line_total_tax: Decimal.new("0.00")
    )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)

    reconcile_currency!(event.id, "ZAR", admin)
    reconcile_currency!(event.id, "USD", admin)
  end

  defp reconcile_currency!(event_id, currency, admin) do
    event_row = event_v2_snapshot!(event_id, currency)
    assert {:ok, dimension} = DimensionSnapshotReader.list_for_event(event_id, actor: admin)
    bucket = Enum.find(dimension.currencies, &(&1.currency == currency))

    tickets = bucket.dimensions.ticket_type
    products = bucket.dimensions.source_product

    assert Enum.sum(Enum.map(tickets, & &1.gross_ticket_quantity)) ==
             event_row.gross_ticket_quantity

    assert Enum.sum(Enum.map(products, & &1.gross_ticket_quantity)) ==
             event_row.gross_ticket_quantity

    assert Decimal.equal?(sum_values(tickets), event_row.gross_ticket_value)
    assert Decimal.equal?(sum_values(products), event_row.gross_ticket_value)
  end

  defp sum_values(rows) do
    Enum.reduce(rows, Decimal.new("0"), fn row, acc ->
      Decimal.add(acc, row.gross_ticket_value || Decimal.new("0"))
    end)
  end

  defp event_v2_snapshot!(event_id, currency) do
    EventAggregateSnapshot
    |> Ash.Query.filter(event_id == ^event_id and snapshot_version == 2 and currency == ^currency)
    |> Ash.read_one!(domain: Analytics)
  end

  defp create_order!(source, status, attrs \\ []) do
    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "REC-#{System.unique_integer([:positive])}",
      status: status,
      currency: "ZAR",
      completed_at: ~U[2026-05-18 08:00:00.000000Z],
      created_at_source: ~U[2026-05-18 07:00:00.000000Z],
      updated_at_source: ~U[2026-05-18 08:00:00.000000Z],
      customer_name: "Customer",
      customer_email: "c@example.test",
      raw_total: Decimal.new("100.00"),
      raw_discount_total: Decimal.new("0"),
      raw_tax_total: Decimal.new("0")
    }

    Ash.create!(Order, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_item!(order, %Event{} = event, ticket, attrs) do
    defaults = %{
      order_id: order.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_line_item_id: System.unique_integer([:positive]),
      woo_product_id: System.unique_integer([:positive]),
      woo_variation_id: nil,
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
      domain: Sales
    )
  end

  defp create_admin! do
    user =
      Ash.create!(
        User,
        %{
          email: "m5-02-recon-#{System.unique_integer([:positive])}@example.com",
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

    Ash.create!(
      EventSales.Accounts.Resources.UserRole,
      %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )

    user
  end
end
