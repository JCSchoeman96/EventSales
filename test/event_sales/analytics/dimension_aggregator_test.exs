defmodule EventSales.Analytics.DimensionAggregatorTest do
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.Aggregators.DimensionAggregator
  alias EventSales.Analytics.Aggregators.EventAggregator
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem, Refund, RefundLine}
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

  test "rejects nonpositive source product identities" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    create_item!(order, event, ticket, woo_product_id: 0)
    create_item!(order, event, ticket, woo_product_id: -1)

    assert DimensionAggregator.gross_rows_for_event(event.id) ==
             {:error, :invalid_dimension_identity}
  end

  test "rejects nonpositive source variation identities" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    create_item!(order, event, ticket, woo_product_id: 1201, woo_variation_id: 0)
    create_item!(order, event, ticket, woo_product_id: 1202, woo_variation_id: -1)

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

  defp financial_row!(rows, dimension_kind, identity) do
    row!(rows, dimension_kind, identity)
  end

  test "financial_rows_for_event merges gross and refund grains with refund-only product rows" do
    %{source: source, event: event, ticket: ticket, second_ticket: second_ticket} = fixture!()
    order = create_order!(source, :completed)

    _item_a =
      create_item!(order, event, ticket,
        woo_product_id: 2001,
        woo_variation_id: 2002,
        quantity: 2,
        line_total: Decimal.new("80.00"),
        line_total_tax: Decimal.new("12.00")
      )

    item_b =
      create_item!(order, event, second_ticket,
        woo_product_id: 2101,
        woo_variation_id: nil,
        quantity: 1,
        line_total: Decimal.new("10.00"),
        line_total_tax: Decimal.new("1.00")
      )

    refund = create_refund!(source, order, 920_001)
    create_refund_line!(refund, item_b, qty: 1, total: "10.00", tax: "1.00")

    assert {:ok, rows} = DimensionAggregator.financial_rows_for_event(event.id)

    ticket_a = financial_row!(rows, :ticket_type, ticket_type_id: ticket.id)
    ticket_b = financial_row!(rows, :ticket_type, ticket_type_id: second_ticket.id)

    assert ticket_a.gross_ticket_quantity == 2
    assert ticket_a.refund_ticket_quantity == 0
    assert Decimal.equal?(ticket_a.refund_ticket_value, Decimal.new("0"))
    assert ticket_b.gross_ticket_quantity == 1
    assert ticket_b.refund_ticket_quantity == 1
    assert Decimal.equal?(ticket_b.refund_ticket_value, Decimal.new("11.00"))

    product_b =
      financial_row!(rows, :source_product,
        source_system_id: source.id,
        woo_product_id: 2101
      )

    assert product_b.gross_ticket_quantity == 1
    assert product_b.refund_ticket_quantity == 1

    refute Enum.any?(
             rows,
             &(&1.dimension_kind == :source_variation and &1.woo_product_id == 2101)
           )
  end

  test "counts value-only refunds without quantity" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    item =
      create_item!(order, event, ticket,
        woo_product_id: 2201,
        woo_variation_id: 2202,
        quantity: 1,
        line_total: Decimal.new("50.00"),
        line_total_tax: Decimal.new("7.50")
      )

    refund = create_refund!(source, order, 920_002)
    create_refund_line!(refund, item, qty: 0, total: "30.00", tax: "4.50")

    assert {:ok, rows} = DimensionAggregator.financial_rows_for_event(event.id)

    ticket_row = financial_row!(rows, :ticket_type, ticket_type_id: ticket.id)

    product_row =
      financial_row!(rows, :source_product,
        source_system_id: source.id,
        woo_product_id: 2201
      )

    variation_row =
      financial_row!(rows, :source_variation,
        source_system_id: source.id,
        woo_product_id: 2201,
        woo_variation_id: 2202
      )

    assert ticket_row.refund_ticket_quantity == 0
    assert Decimal.equal?(ticket_row.refund_ticket_value, Decimal.new("34.50"))
    assert product_row.refund_ticket_quantity == 0
    assert Decimal.equal?(product_row.refund_ticket_value, Decimal.new("34.50"))
    assert variation_row.refund_ticket_quantity == 0
    assert Decimal.equal?(variation_row.refund_ticket_value, Decimal.new("34.50"))
  end

  test "requires exact two-part parent binder for dimensional refunds" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    item_a =
      create_item!(order, event, ticket,
        woo_line_item_id: 31_001,
        woo_product_id: 2301,
        quantity: 1,
        line_total: Decimal.new("10.00"),
        line_total_tax: Decimal.new("1.00")
      )

    item_b =
      create_item!(order, event, ticket,
        woo_line_item_id: 31_002,
        woo_product_id: 2302,
        quantity: 1,
        line_total: Decimal.new("20.00"),
        line_total_tax: Decimal.new("2.00")
      )

    refund = create_refund!(source, order, 920_003)

    insert_mismatched_refund_line!(refund, item_a, item_b,
      qty: 1,
      total: "99.00",
      tax: "9.00"
    )

    assert {:ok, rows} = DimensionAggregator.financial_rows_for_event(event.id)

    ticket_row = financial_row!(rows, :ticket_type, ticket_type_id: ticket.id)
    assert ticket_row.refund_ticket_quantity == 0
    assert Decimal.equal?(ticket_row.refund_ticket_value, Decimal.new("0"))
  end

  test "sums multiple qualifying refund lines without multiplying gross" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    item =
      create_item!(order, event, ticket,
        woo_product_id: 2401,
        quantity: 3,
        line_total: Decimal.new("90.00"),
        line_total_tax: Decimal.new("9.00")
      )

    refund = create_refund!(source, order, 920_004)
    create_refund_line!(refund, item, line_id: 1, qty: 1, total: "20.00", tax: "2.00")
    create_refund_line!(refund, item, line_id: 2, qty: 2, total: "10.00", tax: "1.00")

    assert {:ok, rows} = DimensionAggregator.financial_rows_for_event(event.id)
    ticket_row = financial_row!(rows, :ticket_type, ticket_type_id: ticket.id)

    assert ticket_row.gross_ticket_quantity == 3
    assert Decimal.equal?(ticket_row.gross_ticket_value, Decimal.new("99.00"))
    assert ticket_row.refund_ticket_quantity == 3
    assert Decimal.equal?(ticket_row.refund_ticket_value, Decimal.new("33.00"))
  end

  test "uses parent line identity for refunds when refund line product evidence differs" do
    %{source: source, event: event, ticket: ticket} = fixture!()
    order = create_order!(source, :completed)

    item =
      create_item!(order, event, ticket,
        woo_product_id: 2501,
        woo_variation_id: 2502,
        quantity: 1,
        line_total: Decimal.new("40.00"),
        line_total_tax: Decimal.new("4.00")
      )

    refund = create_refund!(source, order, 920_005)

    insert_refund_line_with_product_evidence!(refund, item,
      woo_product_id: 9999,
      woo_variation_id: 8888,
      qty: 1,
      total: "10.00",
      tax: "1.00"
    )

    assert {:ok, rows} = DimensionAggregator.financial_rows_for_event(event.id)

    product_row =
      financial_row!(rows, :source_product,
        source_system_id: source.id,
        woo_product_id: 2501
      )

    variation_row =
      financial_row!(rows, :source_variation,
        source_system_id: source.id,
        woo_product_id: 2501,
        woo_variation_id: 2502
      )

    assert product_row.refund_ticket_quantity == 1
    refute Enum.any?(rows, &(&1.woo_product_id == 9999))
    refute Enum.any?(rows, &(&1.woo_variation_id == 8888))
    assert variation_row.refund_ticket_quantity == 1
  end

  test "applies qualifying refunds after historical completion when order status later changes" do
    %{source: source, event: event, ticket: ticket} = fixture!()

    refunded =
      create_order!(source, :refunded, completed_at: ~U[2026-05-17 08:00:00Z])

    cancelled =
      create_order!(source, :cancelled, completed_at: ~U[2026-05-17 08:00:00Z])

    item_refunded =
      create_item!(refunded, event, ticket,
        woo_product_id: 2601,
        quantity: 2,
        line_total: Decimal.new("20.00"),
        line_total_tax: Decimal.new("2.00")
      )

    item_cancelled =
      create_item!(cancelled, event, ticket,
        woo_product_id: 2602,
        quantity: 1,
        line_total: Decimal.new("10.00"),
        line_total_tax: Decimal.new("1.00")
      )

    refund_a = create_refund!(source, refunded, 920_006)
    create_refund_line!(refund_a, item_refunded, qty: 1, total: "5.00", tax: "0.50")

    refund_b = create_refund!(source, cancelled, 920_007)
    create_refund_line!(refund_b, item_cancelled, qty: 1, total: "4.00", tax: "0.40")

    assert {:ok, rows} = DimensionAggregator.financial_rows_for_event(event.id)
    ticket_row = financial_row!(rows, :ticket_type, ticket_type_id: ticket.id)

    assert ticket_row.gross_ticket_quantity == 3
    assert ticket_row.refund_ticket_quantity == 2
    assert Decimal.equal?(ticket_row.refund_ticket_value, Decimal.new("9.90"))
  end

  test "excludes non-qualifying refunds from dimensional aggregation" do
    %{
      source: source,
      event: event,
      other_event: other_event,
      ticket: ticket,
      other_ticket: other_ticket
    } = fixture!()

    completed = create_order!(source, :completed)
    pending = create_order!(source, :pending, completed_at: nil)

    base_item =
      create_item!(completed, event, ticket,
        woo_product_id: 2701,
        quantity: 5,
        line_total: Decimal.new("50.00"),
        line_total_tax: Decimal.new("5.00")
      )

    qualifying_refund = create_refund!(source, completed, 920_010)
    create_refund_line!(qualifying_refund, base_item, qty: 1, total: "5.00", tax: "0.50")

    voided_refund = create_refund!(source, completed, 920_011, source_state: :voided)
    create_refund_line!(voided_refund, base_item, qty: 1, total: "9.00", tax: "0.90")

    unresolved_refund =
      create_refund!(source, completed, 920_012, detail_status: :unresolved)

    create_refund_line!(unresolved_refund, base_item, qty: 1, total: "9.00", tax: "0.90")

    reference_refund =
      create_refund!(source, completed, 920_013, detail_status: :reference_only)

    create_refund_line!(reference_refund, base_item, qty: 1, total: "9.00", tax: "0.90")

    binding_refund = create_refund!(source, completed, 920_014)
    insert_refund_line_with_binding_reason!(binding_refund, base_item)

    validation_refund = create_refund!(source, completed, 920_015)
    insert_refund_line_with_validation_reason!(validation_refund, base_item)

    nil_amount_refund = create_refund!(source, completed, 920_016)
    insert_refund_line_nil_amount!(nil_amount_refund, base_item)

    currency_refund = create_refund!(source, completed, 920_017, currency: "EUR")
    create_refund_line!(currency_refund, base_item, qty: 1, total: "9.00", tax: "0.90")

    unmapped_item =
      create_item!(completed, event, ticket,
        woo_product_id: 2709,
        mapping_status: :unmapped
      )

    unmapped_refund = create_refund!(source, completed, 920_018)
    create_refund_line!(unmapped_refund, unmapped_item, qty: 1, total: "9.00", tax: "0.90")

    non_ticket_item =
      create_item!(completed, event, ticket,
        woo_product_id: 2710,
        item_kind: :non_ticket,
        mapping_status: :non_ticket
      )

    non_ticket_refund = create_refund!(source, completed, 920_019)
    create_refund_line!(non_ticket_refund, non_ticket_item, qty: 1, total: "9.00", tax: "0.90")

    other_event_order = create_order!(source, :completed)

    other_event_item =
      create_item!(other_event_order, other_event, other_ticket, woo_product_id: 2711)

    other_event_refund = create_refund!(source, other_event_order, 920_020)
    create_refund_line!(other_event_refund, other_event_item, qty: 1, total: "9.00", tax: "0.90")

    unrecognised_item =
      create_item!(pending, event, ticket,
        woo_product_id: 2712,
        quantity: 1,
        line_total: Decimal.new("10.00"),
        line_total_tax: Decimal.new("1.00")
      )

    unrecognised_refund = create_refund!(source, pending, 920_021)

    create_refund_line!(unrecognised_refund, unrecognised_item,
      qty: 1,
      total: "9.00",
      tax: "0.90"
    )

    assert {:ok, rows} = DimensionAggregator.financial_rows_for_event(event.id)
    ticket_row = financial_row!(rows, :ticket_type, ticket_type_id: ticket.id)

    assert ticket_row.gross_ticket_quantity == 5
    assert ticket_row.refund_ticket_quantity == 1
    assert Decimal.equal?(ticket_row.refund_ticket_value, Decimal.new("5.50"))
  end

  test "ignores ProductMapping changes for dimensional refund identity" do
    %{source: source, event: event, other_event: other_event} = fixture!()
    product_id = 2801
    variation_id = 2802

    variation_ticket =
      SalesHelpers.create_variation_ticket_type!(event, product_id, variation_id)

    other_ticket =
      SalesHelpers.create_variation_ticket_type!(other_event, product_id, variation_id)

    order = create_order!(source, :completed)

    item =
      create_item!(order, event, variation_ticket,
        woo_product_id: product_id,
        woo_variation_id: variation_id,
        quantity: 2,
        line_total: Decimal.new("20.00"),
        line_total_tax: Decimal.new("2.00")
      )

    refund = create_refund!(source, order, 920_030)
    create_refund_line!(refund, item, qty: 1, total: "5.00", tax: "0.50")

    assert {:ok, before} = DimensionAggregator.financial_rows_for_event(event.id)

    mapping =
      Ash.create!(
        ProductMapping,
        %{
          source_system_id: source.id,
          event_id: other_event.id,
          ticket_type_id: other_ticket.id,
          woo_product_id: product_id,
          woo_variation_id: variation_id,
          original_label: "Old",
          current_label: "Old",
          active: true
        },
        action: :create,
        domain: Catalog
      )

    assert {:ok, after_create} = DimensionAggregator.financial_rows_for_event(event.id)
    assert after_create == before

    Ash.update!(
      mapping,
      %{event_id: event.id, ticket_type_id: variation_ticket.id},
      action: :remap,
      domain: Catalog
    )

    assert {:ok, after_remap} = DimensionAggregator.financial_rows_for_event(event.id)
    assert after_remap == before
  end

  defp create_refund!(source, order, woo_refund_id, attrs \\ []) do
    defaults = %{
      source_system_id: source.id,
      order_id: order.id,
      woo_order_id: order.woo_order_id,
      woo_refund_id: woo_refund_id,
      currency: order.currency,
      source_state: :active,
      detail_status: :complete,
      summary_total_amount: Decimal.new("10"),
      header_amount: Decimal.new("0"),
      shipping_refund_amount: Decimal.new("0"),
      shipping_refund_tax: Decimal.new("0"),
      fee_refund_amount: Decimal.new("0"),
      fee_refund_tax: Decimal.new("0"),
      unallocated_header_amount: Decimal.new("0"),
      source_created_at: ~U[2026-05-17 09:00:00.000000Z]
    }

    Ash.create!(Refund, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_refund_line!(refund, item, opts) do
    Ash.create!(
      RefundLine,
      %{
        refund_id: refund.id,
        order_item_id: item.id,
        woo_refund_line_item_id: Keyword.get(opts, :line_id, 1),
        woo_refunded_item_id: item.woo_line_item_id,
        woo_product_id: item.woo_product_id,
        woo_variation_id: item.woo_variation_id,
        refunded_quantity: Keyword.get(opts, :qty, 1),
        refund_subtotal_amount: Decimal.new(Keyword.get(opts, :total, "10.00")),
        refund_total_amount: Decimal.new(Keyword.get(opts, :total, "10.00")),
        refund_total_tax: Decimal.new(Keyword.get(opts, :tax, "0.00"))
      },
      action: :create_normalized,
      domain: Sales
    )
  end

  defp insert_mismatched_refund_line!(refund, item_a, item_b, opts) do
    ts = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all("sales_refund_lines", [
      %{
        id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
        refund_id: Ecto.UUID.dump!(refund.id),
        order_item_id: Ecto.UUID.dump!(item_a.id),
        woo_refund_line_item_id: 99,
        woo_refunded_item_id: item_b.woo_line_item_id,
        woo_product_id: item_a.woo_product_id,
        refunded_quantity: Keyword.get(opts, :qty, 1),
        refund_subtotal_amount: Decimal.new(Keyword.get(opts, :total, "10.00")),
        refund_total_amount: Decimal.new(Keyword.get(opts, :total, "10.00")),
        refund_total_tax: Decimal.new(Keyword.get(opts, :tax, "0.00")),
        inserted_at: ts,
        updated_at: ts
      }
    ])
  end

  defp insert_refund_line_with_product_evidence!(refund, item, opts) do
    ts = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all("sales_refund_lines", [
      %{
        id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
        refund_id: Ecto.UUID.dump!(refund.id),
        order_item_id: Ecto.UUID.dump!(item.id),
        woo_refund_line_item_id: 1,
        woo_refunded_item_id: item.woo_line_item_id,
        woo_product_id: Keyword.fetch!(opts, :woo_product_id),
        woo_variation_id: Keyword.fetch!(opts, :woo_variation_id),
        refunded_quantity: Keyword.get(opts, :qty, 1),
        refund_subtotal_amount: Decimal.new(Keyword.get(opts, :total, "10.00")),
        refund_total_amount: Decimal.new(Keyword.get(opts, :total, "10.00")),
        refund_total_tax: Decimal.new(Keyword.get(opts, :tax, "0.00")),
        inserted_at: ts,
        updated_at: ts
      }
    ])
  end

  defp insert_refund_line_with_binding_reason!(refund, item) do
    ts = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all("sales_refund_lines", [
      %{
        id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
        refund_id: Ecto.UUID.dump!(refund.id),
        order_item_id: Ecto.UUID.dump!(item.id),
        woo_refund_line_item_id: 1,
        woo_refunded_item_id: item.woo_line_item_id,
        woo_product_id: item.woo_product_id,
        refunded_quantity: 1,
        refund_subtotal_amount: Decimal.new("9.00"),
        refund_total_amount: Decimal.new("9.00"),
        refund_total_tax: Decimal.new("0.90"),
        binding_reason: "order_item_not_found",
        inserted_at: ts,
        updated_at: ts
      }
    ])
  end

  defp insert_refund_line_with_validation_reason!(refund, item) do
    ts = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all("sales_refund_lines", [
      %{
        id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
        refund_id: Ecto.UUID.dump!(refund.id),
        order_item_id: Ecto.UUID.dump!(item.id),
        woo_refund_line_item_id: 1,
        woo_refunded_item_id: item.woo_line_item_id,
        woo_product_id: item.woo_product_id,
        refunded_quantity: 1,
        refund_subtotal_amount: Decimal.new("9.00"),
        refund_total_amount: Decimal.new("9.00"),
        refund_total_tax: Decimal.new("0.90"),
        validation_reason: "source_detail_conflict",
        inserted_at: ts,
        updated_at: ts
      }
    ])
  end

  defp insert_refund_line_nil_amount!(refund, item) do
    ts = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    Repo.insert_all("sales_refund_lines", [
      %{
        id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
        refund_id: Ecto.UUID.dump!(refund.id),
        order_item_id: Ecto.UUID.dump!(item.id),
        woo_refund_line_item_id: 1,
        woo_refunded_item_id: item.woo_line_item_id,
        woo_product_id: item.woo_product_id,
        refunded_quantity: 1,
        refund_subtotal_amount: nil,
        refund_total_amount: nil,
        refund_total_tax: Decimal.new("0.90"),
        inserted_at: ts,
        updated_at: ts
      }
    ])
  end
end
