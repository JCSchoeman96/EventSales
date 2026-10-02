defmodule EventSales.Analytics.M503RevenueRefundDimensionReconciliationTest do
  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics
  alias EventSales.Analytics.DimensionSnapshotReader
  alias EventSales.Analytics.MetricRules
  alias EventSales.Analytics.Resources.EventAggregateSnapshot
  alias EventSales.Analytics.SnapshotRefresh
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Sales
  alias EventSales.Sales.RefundUpserter
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers

  @zero Decimal.new("0")

  test "reconciles refund, net, variation, currency, and ATV projections" do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "M5-03F Reconciliation Event"})
    ga = SalesHelpers.create_ticket_type!(event, %{name: "GA"})
    vip = SalesHelpers.create_ticket_type!(event, %{name: "VIP"})
    admin = create_admin!()

    zar_order = create_order!(source, :completed, currency: "ZAR", woo_order_id: 50_301)

    variation_item =
      create_item!(zar_order, event, ga,
        woo_line_item_id: 50_311,
        woo_product_id: 9_011,
        woo_variation_id: 10_011,
        quantity: 3,
        line_total: Decimal.new("30.00"),
        line_total_tax: Decimal.new("3.00")
      )

    product_only_item =
      create_item!(zar_order, event, vip,
        woo_line_item_id: 50_312,
        woo_product_id: 9_012,
        woo_variation_id: nil,
        quantity: 1,
        line_total: Decimal.new("15.00"),
        line_total_tax: Decimal.new("1.00")
      )

    assert {:ok, _normal_refund} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               zar_order.woo_order_id,
               normalized_refund(50_321, [
                 normalized_refund_line(50_331, variation_item,
                   refunded_quantity: 1,
                   refund_subtotal_amount: Decimal.new("5.00"),
                   refund_total_amount: Decimal.new("5.00"),
                   refund_total_tax: Decimal.new("1.00")
                 )
               ])
             )

    assert {:ok, _value_only_refund} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               zar_order.woo_order_id,
               normalized_refund(
                 50_322,
                 [
                   normalized_refund_line(50_332, product_only_item,
                     refunded_quantity: 0,
                     refund_subtotal_amount: Decimal.new("4.00"),
                     refund_total_amount: Decimal.new("4.00"),
                     refund_total_tax: Decimal.new("0.50")
                   )
                 ],
                 header_amount: Decimal.new("4.50")
               )
             )

    assert {:ok, _header_only_refund} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               zar_order.woo_order_id,
               normalized_refund(
                 50_323,
                 [],
                 header_amount: Decimal.new("20.00"),
                 unallocated_header_amount: Decimal.new("20.00")
               )
             )

    usd_order = create_order!(source, :completed, currency: "USD", woo_order_id: 50_302)

    usd_variation_item =
      create_item!(usd_order, event, ga,
        woo_line_item_id: 50_313,
        woo_product_id: 9_013,
        woo_variation_id: 10_013,
        quantity: 2,
        line_total: Decimal.new("20.00"),
        line_total_tax: Decimal.new("2.00")
      )

    assert {:ok, _usd_refund} =
             RefundUpserter.upsert_normalized_refund(
               source.id,
               usd_order.woo_order_id,
               normalized_refund(
                 50_324,
                 [
                   normalized_refund_line(50_334, usd_variation_item,
                     refunded_quantity: 1,
                     refund_subtotal_amount: Decimal.new("3.00"),
                     refund_total_amount: Decimal.new("3.00"),
                     refund_total_tax: Decimal.new("0.50")
                   )
                 ],
                 header_amount: Decimal.new("3.50")
               )
             )

    assert {:ok, _} = SnapshotRefresh.refresh_event(event.id)
    assert {:ok, result} = DimensionSnapshotReader.list_for_event(event.id, actor: admin)
    assert Enum.map(result.currencies, & &1.currency) == ["USD", "ZAR"]
    assert result.pii_visibility == :none

    zar = currency_bucket!(result, "ZAR")
    usd = currency_bucket!(result, "USD")
    zar_event = event_snapshot!(event.id, "ZAR")
    usd_event = event_snapshot!(event.id, "USD")

    assert_currency_reconciliation!(zar_event, zar)
    assert_currency_reconciliation!(usd_event, usd)

    assert zar_event.gross_ticket_quantity == 4
    assert Decimal.equal?(zar_event.gross_ticket_value, Decimal.new("49.00"))
    assert zar_event.refund_ticket_quantity == 1
    assert Decimal.equal?(zar_event.refund_ticket_value, Decimal.new("10.50"))

    assert usd_event.gross_ticket_quantity == 2
    assert Decimal.equal?(usd_event.gross_ticket_value, Decimal.new("22.00"))
    assert usd_event.refund_ticket_quantity == 1
    assert Decimal.equal?(usd_event.refund_ticket_value, Decimal.new("3.50"))

    zar_variation = zar.dimensions.source_variation

    assert [
             %{woo_product_id: 9_011, woo_variation_id: 10_011},
             %{woo_product_id: 9_013, woo_variation_id: 10_013}
           ] =
             Enum.map(zar_variation ++ usd.dimensions.source_variation, fn row ->
               Map.take(row, [:woo_product_id, :woo_variation_id])
             end)
             |> Enum.sort_by(&{&1.woo_product_id, &1.woo_variation_id})

    zar_variation_row = hd(zar_variation)
    assert zar_variation_row.gross_ticket_quantity == 3
    assert zar_variation_row.refund_ticket_quantity == 1
    assert zar_variation_row.net_ticket_quantity == 2
    assert Decimal.equal?(zar_variation_row.gross_ticket_value, Decimal.new("33.00"))
    assert Decimal.equal?(zar_variation_row.refund_ticket_value, Decimal.new("6.00"))
    assert Decimal.equal?(zar_variation_row.net_ticket_value, Decimal.new("27.00"))

    usd_variation_row = hd(usd.dimensions.source_variation)
    assert usd_variation_row.gross_ticket_quantity == 2
    assert usd_variation_row.refund_ticket_quantity == 1
    assert usd_variation_row.net_ticket_quantity == 1
    assert Decimal.equal?(usd_variation_row.gross_ticket_value, Decimal.new("22.00"))
    assert Decimal.equal?(usd_variation_row.refund_ticket_value, Decimal.new("3.50"))
    assert Decimal.equal?(usd_variation_row.net_ticket_value, Decimal.new("18.50"))

    assert zar_variation_row.gross_ticket_quantity < zar_event.gross_ticket_quantity

    assert Decimal.compare(zar_variation_row.gross_ticket_value, zar_event.gross_ticket_value) ==
             :lt

    refute Enum.any?(zar_variation, &(&1.woo_product_id == 9_012))

    zar_product_only =
      Enum.find(zar.dimensions.source_product, &(&1.woo_product_id == 9_012))

    assert zar_product_only.gross_ticket_quantity == 1
    assert zar_product_only.refund_ticket_quantity == 0
    assert zar_product_only.net_ticket_quantity == 1
    assert Decimal.equal?(zar_product_only.refund_ticket_value, Decimal.new("4.50"))
    assert Decimal.equal?(zar_product_only.net_ticket_value, Decimal.new("11.50"))
    assert Decimal.equal?(zar_product_only.average_ticket_value, Decimal.new("11.50"))

    assert_decimal_not_equal_to_row_sums!(zar.dimensions.ticket_type)
    assert_decimal_not_equal_to_row_sums!(zar.dimensions.source_product)

    ticket_qty = sum(zar.dimensions.ticket_type, :gross_ticket_quantity)
    product_qty = sum(zar.dimensions.source_product, :gross_ticket_quantity)
    variation_qty = sum(zar.dimensions.source_variation, :gross_ticket_quantity)

    refute ticket_qty + product_qty + variation_qty == zar_event.gross_ticket_quantity

    assert Decimal.equal?(
             sum_values(zar.dimensions.source_variation, :gross_ticket_value),
             Decimal.new("33.00")
           )

    assert Decimal.equal?(
             sum_values(usd.dimensions.source_variation, :gross_ticket_value),
             usd_event.gross_ticket_value
           )
  end

  defp assert_currency_reconciliation!(event_row, bucket) do
    event_metrics =
      derive_metrics!(%{
        gross_ticket_quantity: Decimal.new(event_row.gross_ticket_quantity),
        refund_ticket_quantity: Decimal.new(event_row.refund_ticket_quantity),
        gross_ticket_value: event_row.gross_ticket_value,
        refund_ticket_value: event_row.refund_ticket_value
      })

    for rows <- [bucket.dimensions.ticket_type, bucket.dimensions.source_product] do
      assert sum(rows, :gross_ticket_quantity) == event_row.gross_ticket_quantity
      assert sum(rows, :refund_ticket_quantity) == event_row.refund_ticket_quantity
      assert Decimal.equal?(sum_values(rows, :gross_ticket_value), event_row.gross_ticket_value)
      assert Decimal.equal?(sum_values(rows, :refund_ticket_value), event_row.refund_ticket_value)

      assert sum(rows, :net_ticket_quantity) ==
               Decimal.to_integer(event_metrics.net_ticket_quantity)

      assert Decimal.equal?(sum_values(rows, :net_ticket_value), event_metrics.net_ticket_value)

      family_metrics =
        derive_metrics!(%{
          gross_ticket_quantity: Decimal.new(sum(rows, :gross_ticket_quantity)),
          refund_ticket_quantity: Decimal.new(sum(rows, :refund_ticket_quantity)),
          gross_ticket_value: sum_values(rows, :gross_ticket_value),
          refund_ticket_value: sum_values(rows, :refund_ticket_value)
        })

      assert family_metrics.net_ticket_quantity == event_metrics.net_ticket_quantity
      assert Decimal.equal?(family_metrics.net_ticket_value, event_metrics.net_ticket_value)

      assert Decimal.equal?(
               family_metrics.average_ticket_value,
               event_metrics.average_ticket_value
             )
    end
  end

  defp assert_decimal_not_equal_to_row_sums!(rows) do
    row_atvs = Enum.map(rows, & &1.average_ticket_value)
    assert length(row_atvs) >= 2
    refute Enum.uniq(row_atvs) |> length() == 1

    rolled =
      derive_metrics!(%{
        gross_ticket_quantity: Decimal.new(sum(rows, :gross_ticket_quantity)),
        refund_ticket_quantity: Decimal.new(sum(rows, :refund_ticket_quantity)),
        gross_ticket_value: sum_values(rows, :gross_ticket_value),
        refund_ticket_value: sum_values(rows, :refund_ticket_value)
      })

    sum_atv = Enum.reduce(row_atvs, @zero, &Decimal.add/2)
    average_atv = Decimal.div(sum_atv, Decimal.new(length(row_atvs)))

    refute Decimal.equal?(rolled.average_ticket_value, sum_atv)
    refute Decimal.equal?(rolled.average_ticket_value, average_atv)
  end

  defp derive_metrics!(primitives) do
    assert {:ok, metrics} = MetricRules.derive_financial_metrics(primitives)
    metrics
  end

  defp currency_bucket!(result, currency) do
    Enum.find(result.currencies, &(&1.currency == currency)) || flunk("missing #{currency}")
  end

  defp event_snapshot!(event_id, currency) do
    EventAggregateSnapshot
    |> Ash.Query.filter(event_id == ^event_id and snapshot_version == 2 and currency == ^currency)
    |> Ash.read_one!(domain: Analytics)
  end

  defp sum(rows, key), do: Enum.reduce(rows, 0, &(Map.fetch!(&1, key) + &2))

  defp sum_values(rows, key) do
    Enum.reduce(rows, @zero, fn row, acc -> Decimal.add(acc, Map.fetch!(row, key) || @zero) end)
  end

  defp create_order!(source, status, attrs) do
    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "m5-03f-#{System.unique_integer([:positive])}",
      status: status,
      currency: "ZAR",
      completed_at: ~U[2026-05-18 08:00:00.000000Z],
      created_at_source: ~U[2026-05-18 07:00:00.000000Z],
      updated_at_source: ~U[2026-05-18 08:00:00.000000Z],
      customer_name: "Customer",
      customer_email: "customer@example.test",
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

  defp normalized_refund(refund_id, line_items, attrs \\ []) do
    defaults = %{
      woo_refund_id: refund_id,
      header_amount: Decimal.new("6.00"),
      reason: "customer request",
      source_created_at: ~U[2026-05-18 10:00:00.000000Z],
      line_items: line_items,
      shipping_refund_amount: nil,
      shipping_refund_tax: nil,
      fee_refund_amount: nil,
      fee_refund_tax: nil,
      unallocated_header_amount: Decimal.new("0.00")
    }

    Map.merge(defaults, Map.new(attrs))
  end

  defp normalized_refund_line(line_id, item, attrs) do
    defaults = %{
      woo_refund_line_item_id: line_id,
      woo_refunded_item_id: item.woo_line_item_id,
      woo_product_id: item.woo_product_id,
      woo_variation_id: item.woo_variation_id,
      refunded_quantity: 1,
      refund_subtotal_amount: Decimal.new("5.00"),
      refund_total_amount: Decimal.new("5.00"),
      refund_total_tax: Decimal.new("1.00"),
      binding_reason: nil,
      validation_reason: nil
    }

    Map.merge(defaults, Map.new(attrs))
  end

  defp create_admin! do
    user =
      Ash.create!(
        User,
        %{
          email: "m5-03f-recon-#{System.unique_integer([:positive])}@example.com",
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
      UserRole,
      %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )

    user
  end
end
