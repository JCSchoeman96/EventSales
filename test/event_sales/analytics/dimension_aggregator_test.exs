defmodule EventSales.Analytics.DimensionAggregatorTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.Aggregators.DimensionAggregator
  alias EventSales.Analytics.Aggregators.EventAggregator
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.TestSupport.SalesHelpers

  test "groups ticket, product, and variation rows and combines matching grains" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    create_item!(order, event, ticket,
      woo_product_id: 501,
      woo_variation_id: 601,
      quantity: 1,
      line_total: Decimal.new("10.00"),
      line_total_tax: Decimal.new("1.00")
    )

    create_item!(order, event, ticket,
      woo_product_id: 501,
      woo_variation_id: 601,
      quantity: 3,
      line_total: Decimal.new("40.00"),
      line_total_tax: Decimal.new("4.00")
    )

    create_item!(order, event, ticket,
      woo_product_id: 501,
      woo_variation_id: 602,
      quantity: 2,
      line_total: Decimal.new("20.00"),
      line_total_tax: Decimal.new("2.00")
    )

    create_item!(order, event, ticket,
      woo_product_id: 501,
      woo_variation_id: nil,
      quantity: 1,
      line_total: Decimal.new("30.00"),
      line_total_tax: Decimal.new("3.00")
    )

    assert {:ok, rows} = DimensionAggregator.gross_rows_for_event(event.id)

    ticket_row = row!(rows, :ticket_type, ticket_type_id: ticket.id)

    product_row =
      row!(rows, :source_product,
        source_system_id: source.id,
        woo_product_id: 501
      )

    variation_601 =
      row!(rows, :source_variation,
        source_system_id: source.id,
        woo_product_id: 501,
        woo_variation_id: 601
      )

    variation_602 =
      row!(rows, :source_variation,
        source_system_id: source.id,
        woo_product_id: 501,
        woo_variation_id: 602
      )

    assert ticket_row.gross_ticket_quantity == 7
    assert Decimal.equal?(ticket_row.gross_ticket_value, Decimal.new("110.00"))
    assert product_row.gross_ticket_quantity == 7
    assert Decimal.equal?(product_row.gross_ticket_value, Decimal.new("110.00"))
    assert variation_601.gross_ticket_quantity == 4
    assert Decimal.equal?(variation_601.gross_ticket_value, Decimal.new("55.00"))
    assert variation_602.gross_ticket_quantity == 2
    assert Decimal.equal?(variation_602.gross_ticket_value, Decimal.new("22.00"))

    assert Enum.map(rows, & &1.dimension_kind) == [
             :ticket_type,
             :source_product,
             :source_variation,
             :source_variation
           ]

    assert Enum.map(
             Enum.filter(rows, &(&1.dimension_kind == :source_variation)),
             & &1.woo_variation_id
           ) ==
             [601, 602]

    assert Map.keys(ticket_row) |> MapSet.new() ==
             MapSet.new([
               :event_id,
               :currency,
               :dimension_kind,
               :ticket_type_id,
               :source_system_id,
               :woo_product_id,
               :woo_variation_id,
               :gross_ticket_quantity,
               :gross_ticket_value
             ])

    refute Enum.any?(
             rows,
             &(&1.dimension_kind == :source_variation and &1.woo_variation_id == nil)
           )
  end

  test "keeps TicketTypes and currencies separate and reconciles ticket and product totals" do
    %{source: source, event: event, ticket: ticket, second_ticket: second_ticket} = fixture!()

    zar_order = create_order!(source, :completed, currency: "ZAR")
    usd_order = create_order!(source, :completed, currency: "USD")

    create_item!(zar_order, event, ticket,
      woo_product_id: 701,
      woo_variation_id: nil,
      quantity: 2,
      line_total: Decimal.new("100.00"),
      line_total_tax: Decimal.new("15.00")
    )

    create_item!(zar_order, event, second_ticket,
      woo_product_id: 702,
      woo_variation_id: nil,
      quantity: 1,
      line_total: Decimal.new("20.00"),
      line_total_tax: Decimal.new("2.00")
    )

    create_item!(usd_order, event, ticket,
      woo_product_id: 701,
      woo_variation_id: 801,
      quantity: 3,
      line_total: Decimal.new("30.00"),
      line_total_tax: Decimal.new("3.00")
    )

    assert {:ok, rows} = DimensionAggregator.gross_rows_for_event(event.id)
    assert {:ok, event_summaries} = EventAggregator.financial_summaries_for_event(event.id)

    assert Enum.any?(rows, &(&1.currency == "ZAR"))
    assert Enum.any?(rows, &(&1.currency == "USD"))

    assert length(
             Enum.filter(rows, &(&1.dimension_kind == :ticket_type and &1.currency == "ZAR"))
           ) == 2

    for {currency, summary} <- event_summaries do
      for dimension_kind <- [:ticket_type, :source_product] do
        family =
          Enum.filter(rows, &(&1.currency == currency and &1.dimension_kind == dimension_kind))

        quantity =
          Enum.reduce(family, Decimal.new("0"), fn row, total ->
            Decimal.add(total, Decimal.new(row.gross_ticket_quantity))
          end)

        value =
          Enum.reduce(family, Decimal.new("0"), fn row, total ->
            Decimal.add(total, row.gross_ticket_value)
          end)

        assert Decimal.equal?(quantity, summary.gross_ticket_quantity)
        assert Decimal.equal?(value, summary.gross_ticket_value)
      end
    end

    zar_variation_rows =
      Enum.filter(rows, &(&1.currency == "ZAR" and &1.dimension_kind == :source_variation))

    zar_product_rows =
      Enum.filter(rows, &(&1.currency == "ZAR" and &1.dimension_kind == :source_product))

    assert Enum.reduce(zar_variation_rows, 0, &(&1.gross_ticket_quantity + &2)) == 0
    assert Enum.reduce(zar_product_rows, 0, &(&1.gross_ticket_quantity + &2)) == 3
  end

  test "recognises historical completion and excludes unrecognised, unmapped, non-ticket, and other-event lines" do
    %{
      source: source,
      event: event,
      other_event: other_event,
      ticket: ticket,
      other_ticket: other_ticket
    } =
      fixture!()

    completed = create_order!(source, :completed, completed_at: nil)
    refunded = create_order!(source, :refunded, completed_at: ~U[2026-05-17 08:00:00Z])
    cancelled = create_order!(source, :cancelled, completed_at: ~U[2026-05-17 08:00:00Z])
    pending = create_order!(source, :pending, completed_at: nil)
    uncompleted_refund = create_order!(source, :refunded, completed_at: nil)

    create_item!(completed, event, ticket,
      woo_product_id: 901,
      quantity: 1,
      line_total: Decimal.new("10")
    )

    create_item!(refunded, event, ticket,
      woo_product_id: 902,
      quantity: 2,
      line_total: Decimal.new("20")
    )

    create_item!(cancelled, event, ticket,
      woo_product_id: 903,
      quantity: 3,
      line_total: Decimal.new("30")
    )

    create_item!(pending, event, ticket,
      woo_product_id: 904,
      quantity: 4,
      line_total: Decimal.new("40")
    )

    create_item!(uncompleted_refund, event, ticket,
      woo_product_id: 905,
      quantity: 5,
      line_total: Decimal.new("50")
    )

    create_item!(completed, event, ticket,
      woo_product_id: 906,
      quantity: 6,
      line_total: Decimal.new("60"),
      mapping_status: :unmapped
    )

    create_item!(completed, event, ticket,
      woo_product_id: 907,
      quantity: 7,
      line_total: Decimal.new("70"),
      item_kind: :non_ticket,
      mapping_status: :non_ticket
    )

    create_item!(completed, other_event, other_ticket,
      woo_product_id: 908,
      quantity: 8,
      line_total: Decimal.new("80")
    )

    assert {:ok, rows} = DimensionAggregator.gross_rows_for_event(event.id)
    ticket_row = row!(rows, :ticket_type, ticket_type_id: ticket.id)

    assert ticket_row.gross_ticket_quantity == 6
    assert Decimal.equal?(ticket_row.gross_ticket_value, Decimal.new("60"))
    refute Enum.any?(rows, &(&1.woo_product_id in [904, 905, 906, 907, 908]))
  end

  test "rejects incomplete line_total and line_total_tax primitives" do
    Repo.query!("ALTER TABLE sales_order_items ALTER COLUMN line_total DROP NOT NULL")

    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    insert_item_with_null_line_total!(order, event, ticket)

    assert DimensionAggregator.gross_rows_for_event(event.id) ==
             {:error, :incomplete_financial_primitives}

    Repo.query!("DELETE FROM sales_order_items")

    tax_order = create_order!(source, :completed)

    create_item!(tax_order, event, ticket,
      woo_product_id: 1002,
      line_total: Decimal.new("10"),
      line_total_tax: nil
    )

    assert DimensionAggregator.gross_rows_for_event(event.id) ==
             {:error, :incomplete_financial_primitives}
  end

  test "rejects a recognised ticket line with a missing ticket type identity" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)
    item = create_item!(order, event, ticket, woo_product_id: 1101)

    Repo.query!("UPDATE sales_order_items SET ticket_type_id = NULL WHERE id = $1", [
      Ecto.UUID.dump!(item.id)
    ])

    assert DimensionAggregator.gross_rows_for_event(event.id) ==
             {:error, :invalid_dimension_identity}
  end

  test "returns an empty list for no recognised sales and rejects invalid event ids" do
    assert DimensionAggregator.gross_rows_for_event("not-a-uuid") == {:error, :invalid_event_id}
    assert DimensionAggregator.gross_rows_for_event(Ecto.UUID.generate()) == {:ok, []}
  end

  test "ignores ProductMapping creation and changes when grouping historical line identity" do
    %{source: source, event: event, other_event: other_event} = fixture!()
    product_id = 1201
    variation_id = 1202

    ticket = SalesHelpers.create_variation_ticket_type!(event, product_id, variation_id)

    other_ticket =
      SalesHelpers.create_variation_ticket_type!(other_event, product_id, variation_id)

    order = create_order!(source, :completed)

    create_item!(order, event, ticket,
      woo_product_id: product_id,
      woo_variation_id: variation_id,
      quantity: 2,
      line_total: Decimal.new("20.00"),
      line_total_tax: Decimal.new("2.00")
    )

    assert {:ok, before_mapping} = DimensionAggregator.gross_rows_for_event(event.id)

    mapping =
      Ash.create!(
        ProductMapping,
        %{
          source_system_id: source.id,
          event_id: other_event.id,
          ticket_type_id: other_ticket.id,
          woo_product_id: product_id,
          woo_variation_id: variation_id,
          original_label: "Old label",
          current_label: "Old label",
          active: true
        },
        action: :create,
        domain: Catalog
      )

    assert {:ok, after_mapping_create} = DimensionAggregator.gross_rows_for_event(event.id)
    assert after_mapping_create == before_mapping

    Ash.update!(
      mapping,
      %{event_id: event.id, ticket_type_id: ticket.id},
      action: :remap,
      domain: Catalog
    )

    assert {:ok, after_mapping_change} = DimensionAggregator.gross_rows_for_event(event.id)
    assert after_mapping_change == before_mapping
  end

  defp fixture! do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Dimension Event"})
    other_event = SalesHelpers.create_event!(source, %{name: "Other Dimension Event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "General Admission"})
    second_ticket = SalesHelpers.create_ticket_type!(event, %{name: "VIP"})
    other_ticket = SalesHelpers.create_ticket_type!(other_event, %{name: "Other Ticket"})

    %{
      source: source,
      event: event,
      other_event: other_event,
      ticket: ticket,
      second_ticket: second_ticket,
      other_ticket: other_ticket
    }
  end

  defp create_order!(source, status, opts \\ []) do
    timestamp = ~U[2026-05-17 08:00:00Z]

    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "dimension-#{System.unique_integer([:positive])}",
      status: status,
      currency: "ZAR",
      completed_at: timestamp,
      created_at_source: ~U[2026-05-17 07:00:00Z],
      updated_at_source: timestamp,
      raw_total: Decimal.new("0"),
      raw_discount_total: Decimal.new("0"),
      raw_tax_total: Decimal.new("0")
    }

    Ash.create!(Order, Map.merge(defaults, Map.new(opts)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_item!(order, event, ticket, opts) do
    defaults = %{
      order_id: order.id,
      event_id: event.id,
      ticket_type_id: ticket.id,
      woo_line_item_id: System.unique_integer([:positive]),
      woo_product_id: System.unique_integer([:positive]),
      woo_variation_id: nil,
      name: "Dimension Ticket",
      quantity: 1,
      line_subtotal: Decimal.new("10.00"),
      line_total: Decimal.new("10.00"),
      line_total_tax: Decimal.new("0.00"),
      discount_total: Decimal.new("0.00"),
      item_kind: :ticket,
      mapping_status: :mapped
    }

    Ash.create!(OrderItem, Map.merge(defaults, Map.new(opts)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp insert_item_with_null_line_total!(order, event, ticket) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all("sales_order_items", [
      %{
        id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
        order_id: Ecto.UUID.dump!(order.id),
        event_id: Ecto.UUID.dump!(event.id),
        ticket_type_id: Ecto.UUID.dump!(ticket.id),
        woo_line_item_id: 1001,
        woo_product_id: 1001,
        woo_variation_id: nil,
        name: "Incomplete ticket",
        quantity: 1,
        line_subtotal: Decimal.new("10"),
        line_total: nil,
        line_total_tax: Decimal.new("1"),
        discount_total: Decimal.new("0"),
        item_kind: "ticket",
        mapping_status: "mapped",
        inserted_at: timestamp,
        updated_at: timestamp
      }
    ])
  end

  defp row!(rows, dimension_kind, identity) do
    Enum.find(rows, fn row ->
      row.dimension_kind == dimension_kind and
        Enum.all?(identity, fn {key, value} -> Map.get(row, key) == value end)
    end) || flunk("missing #{dimension_kind} row for #{inspect(identity)} in #{inspect(rows)}")
  end
end
