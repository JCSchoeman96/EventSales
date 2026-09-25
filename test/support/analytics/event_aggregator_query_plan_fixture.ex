defmodule EventSales.TestSupport.Analytics.EventAggregatorQueryPlanFixture do
  @moduledoc false

  alias EventSales.Repo
  alias EventSales.TestSupport.SalesHelpers

  @noise_line_count 800

  @doc """
  Seeds a selective financial fixture: one target event row plus many noise
  order lines (and matching refund facts) on a different event for query-plan
  certification.
  """
  @spec seed!(keyword()) :: %{
          source: term(),
          target_event: term(),
          target_ticket: term(),
          noise_event_id: Ecto.UUID.t(),
          noise_line_count: pos_integer(),
          noise_refund_count: pos_integer(),
          target_order_id: Ecto.UUID.t(),
          target_item_id: Ecto.UUID.t()
        }
  def seed!(opts \\ []) do
    noise_count = Keyword.get(opts, :noise_line_count, @noise_line_count)

    source = SalesHelpers.create_source_system!()

    target_event =
      SalesHelpers.create_event!(source, %{name: "Query Plan Target", slug: "qp-target-event"})

    target_ticket = SalesHelpers.create_ticket_type!(target_event, %{name: "Target Ticket"})

    noise_event =
      SalesHelpers.create_event!(source, %{name: "Query Plan Noise", slug: "qp-noise-event"})

    noise_ticket = SalesHelpers.create_ticket_type!(noise_event, %{name: "Noise Ticket"})

    {noise_line_count, noise_refund_count} =
      bulk_insert_completed_lines!(source.id, noise_event.id, noise_ticket.id, noise_count)

    {target_order_id, target_item_id} =
      insert_target_financial_row!(source.id, target_event.id, target_ticket.id)

    analyze_financial_tables!()

    %{
      source: source,
      target_event: target_event,
      target_ticket: target_ticket,
      noise_event_id: noise_event.id,
      noise_line_count: noise_line_count,
      noise_refund_count: noise_refund_count,
      target_order_id: target_order_id,
      target_item_id: target_item_id
    }
  end

  defp analyze_financial_tables! do
    for table <- ~w(sales_orders sales_order_items sales_refunds sales_refund_lines) do
      {:ok, _} = Repo.query("ANALYZE #{table}")
    end
  end

  defp bulk_insert_completed_lines!(source_id, event_id, ticket_type_id, count)
       when is_integer(count) and count > 0 do
    ts = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    zero = Decimal.new("0")
    line_total = Decimal.new("10.00")
    line_tax = Decimal.new("1.50")
    refund_total = Decimal.new("5.00")
    refund_tax = Decimal.new("0.75")

    source_id = Ecto.UUID.dump!(source_id)
    event_id = Ecto.UUID.dump!(event_id)
    ticket_type_id = Ecto.UUID.dump!(ticket_type_id)

    order_rows =
      for i <- 1..count do
        %{
          id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
          source_system_id: source_id,
          woo_order_id: 900_000 + i,
          order_number: "qp-noise-#{i}",
          status: "completed",
          currency: "ZAR",
          completed_at: ts,
          created_at_source: ts,
          updated_at_source: ts,
          raw_total: zero,
          raw_discount_total: zero,
          raw_tax_total: zero,
          inserted_at: ts,
          updated_at: ts
        }
      end

    Repo.insert_all("sales_orders", order_rows)

    item_rows =
      Enum.map(order_rows, fn order ->
        woo_line = :erlang.phash2(order.id, 1_000_000_000)

        %{
          id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
          order_id: order.id,
          event_id: event_id,
          ticket_type_id: ticket_type_id,
          woo_line_item_id: woo_line,
          woo_product_id: woo_line + 1,
          name: "Noise ticket",
          quantity: 1,
          line_subtotal: line_total,
          line_total: line_total,
          line_total_tax: line_tax,
          discount_total: zero,
          item_kind: "ticket",
          mapping_status: "mapped",
          inserted_at: ts,
          updated_at: ts
        }
      end)

    Repo.insert_all("sales_order_items", item_rows)

    refund_rows =
      Enum.map(order_rows, fn order ->
        %{
          id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
          source_system_id: source_id,
          order_id: order.id,
          woo_order_id: order.woo_order_id,
          woo_refund_id: order.woo_order_id + 10_000_000,
          currency: "ZAR",
          source_state: "active",
          detail_status: "complete",
          summary_total_amount: refund_total,
          header_amount: zero,
          shipping_refund_amount: zero,
          shipping_refund_tax: zero,
          fee_refund_amount: zero,
          fee_refund_tax: zero,
          unallocated_header_amount: zero,
          source_created_at: ts,
          inserted_at: ts,
          updated_at: ts
        }
      end)

    Repo.insert_all("sales_refunds", refund_rows)

    refund_line_rows =
      Enum.zip(refund_rows, item_rows)
      |> Enum.map(fn {refund, item} ->
        %{
          id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
          refund_id: refund.id,
          order_item_id: item.id,
          woo_refund_line_item_id: 1,
          woo_refunded_item_id: item.woo_line_item_id,
          woo_product_id: item.woo_product_id,
          refunded_quantity: 1,
          refund_subtotal_amount: refund_total,
          refund_total_amount: refund_total,
          refund_total_tax: refund_tax,
          inserted_at: ts,
          updated_at: ts
        }
      end)

    Repo.insert_all("sales_refund_lines", refund_line_rows)

    {count, count}
  end

  defp insert_target_financial_row!(source_id, event_id, ticket_type_id) do
    ts = DateTime.utc_now() |> DateTime.truncate(:microsecond)
    zero = Decimal.new("0")
    order_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    item_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    refund_id = Ecto.UUID.generate() |> Ecto.UUID.dump!()
    source_id = Ecto.UUID.dump!(source_id)
    event_id = Ecto.UUID.dump!(event_id)
    ticket_type_id = Ecto.UUID.dump!(ticket_type_id)

    Repo.insert_all("sales_orders", [
      %{
        id: order_id,
        source_system_id: source_id,
        woo_order_id: 93_001,
        order_number: "qp-target-1",
        status: "completed",
        currency: "ZAR",
        completed_at: ts,
        created_at_source: ts,
        updated_at_source: ts,
        raw_total: zero,
        raw_discount_total: zero,
        raw_tax_total: zero,
        inserted_at: ts,
        updated_at: ts
      }
    ])

    Repo.insert_all("sales_order_items", [
      %{
        id: item_id,
        order_id: order_id,
        event_id: event_id,
        ticket_type_id: ticket_type_id,
        woo_line_item_id: 70,
        woo_product_id: 71,
        name: "Target ticket",
        quantity: 2,
        line_subtotal: Decimal.new("80.00"),
        line_total: Decimal.new("80.00"),
        line_total_tax: Decimal.new("12.00"),
        discount_total: zero,
        item_kind: "ticket",
        mapping_status: "mapped",
        inserted_at: ts,
        updated_at: ts
      }
    ])

    Repo.insert_all("sales_refunds", [
      %{
        id: refund_id,
        source_system_id: source_id,
        order_id: order_id,
        woo_order_id: 93_001,
        woo_refund_id: 903,
        currency: "ZAR",
        source_state: "active",
        detail_status: "complete",
        summary_total_amount: Decimal.new("46.00"),
        header_amount: zero,
        shipping_refund_amount: zero,
        shipping_refund_tax: zero,
        fee_refund_amount: zero,
        fee_refund_tax: zero,
        unallocated_header_amount: zero,
        source_created_at: ts,
        inserted_at: ts,
        updated_at: ts
      }
    ])

    Repo.insert_all("sales_refund_lines", [
      %{
        id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
        refund_id: refund_id,
        order_item_id: item_id,
        woo_refund_line_item_id: 1,
        woo_refunded_item_id: 70,
        woo_product_id: 71,
        refunded_quantity: 1,
        refund_subtotal_amount: Decimal.new("40.00"),
        refund_total_amount: Decimal.new("40.00"),
        refund_total_tax: Decimal.new("6.00"),
        inserted_at: ts,
        updated_at: ts
      }
    ])

    {Ecto.UUID.cast!(order_id), Ecto.UUID.cast!(item_id)}
  end
end
