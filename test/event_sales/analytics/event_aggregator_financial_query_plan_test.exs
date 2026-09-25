defmodule EventSales.Analytics.EventAggregatorFinancialQueryPlanTest do
  @moduledoc false
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.Aggregators.EventAggregator
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem, Refund, RefundLine}
  alias EventSales.TestSupport.SalesHelpers

  @fact_tables ~w[sales_order_items sales_orders sales_refund_lines sales_refunds]

  setup do
    source = SalesHelpers.create_source_system!()
    event = SalesHelpers.create_event!(source, %{name: "Query Plan Event", slug: "qp-event"})
    ticket = SalesHelpers.create_ticket_type!(event, %{name: "QP Ticket"})

    order =
      create_order!(source, :completed,
        woo_order_id: 93_001,
        completed_at: ~U[2026-05-17 08:00:00.000000Z]
      )

    item =
      create_item!(order, event, ticket,
        woo_line_item_id: 70,
        quantity: 2,
        line_total: Decimal.new("80.00"),
        line_total_tax: Decimal.new("12.00")
      )

    refund = create_refund!(source, order, 903)
    create_refund_line!(refund, item, qty: 1, total: "40.00", tax: "6.00")

    %{event: event}
  end

  test "financial_summaries_for_event issues event-bounded SQL on financial fact tables", %{
    event: event
  } do
    {summaries, queries} =
      capture_sql(fn ->
        EventAggregator.financial_summaries_for_event(event.id)
      end)

    assert {:ok, %{"ZAR" => _}} = summaries

    fact_queries =
      queries
      |> Enum.uniq()
      |> Enum.filter(fn {sql, _params} ->
        Enum.any?(@fact_tables, &String.contains?(sql, &1))
      end)

    assert length(fact_queries) >= 4

    for {sql, params} <- fact_queries do
      assert event_bounded_sql?(sql, params, event.id),
             "expected event-bounded predicate in: #{sql}"

      plan = explain_plan_json(sql, params)
      assert is_list(plan), "expected EXPLAIN JSON for: #{sql}"

      refute unbounded_fact_seq_scan?(plan),
             "unbounded seq scan on fact table in plan: #{inspect(plan)}"
    end
  end

  defp capture_sql(fun) do
    handler_id = {__MODULE__, self(), make_ref()}
    parent = self()

    :ok =
      :telemetry.attach(
        handler_id,
        Repo.config()[:telemetry_prefix] ++ [:query],
        fn _event, _measurements, metadata, {test_pid, id} ->
          send(test_pid, {id, metadata.query, metadata.params})
        end,
        {parent, handler_id}
      )

    try do
      result = fun.()
      queries = collect_sql(handler_id, [])
      {result, queries}
    after
      :telemetry.detach(handler_id)
    end
  end

  defp collect_sql(handler_id, acc) do
    receive do
      {^handler_id, sql, params} -> collect_sql(handler_id, [{sql, params} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp event_bounded_sql?(sql, params, event_id) do
    dumped = Ecto.UUID.dump!(event_id)

    String.contains?(sql, "event_id") or
      dumped in params or
      event_id in params
  end

  defp explain_plan_json(sql, params) do
    case Repo.query("EXPLAIN (FORMAT JSON) #{sql}", params) do
      {:ok, %{rows: [[plan_json]]}} when is_binary(plan_json) -> Jason.decode!(plan_json)
      {:ok, %{rows: [[plan]]}} when is_list(plan) -> plan
      other -> flunk("EXPLAIN failed for #{sql}: #{inspect(other)}")
    end
  end

  defp unbounded_fact_seq_scan?(plan) do
    plan
    |> plan_nodes()
    |> Enum.any?(fn node ->
      node["Node Type"] == "Seq Scan" and
        node["Relation Name"] in @fact_tables and
        not event_id_filtered?(node)
    end)
  end

  defp plan_nodes(plan) when is_list(plan) do
    Enum.flat_map(plan, &plan_nodes/1)
  end

  defp plan_nodes(%{"Plans" => nested} = node) do
    [node | Enum.flat_map(nested, &plan_nodes/1)]
  end

  defp plan_nodes(node) when is_map(node), do: [node]

  defp event_id_filtered?(node) do
    filter = Map.get(node, "Filter") || Map.get(node, "Index Cond") || ""
    String.contains?(filter, "event_id")
  end

  defp create_order!(source, status, attrs) do
    defaults = %{
      source_system_id: source.id,
      woo_order_id: System.unique_integer([:positive]),
      order_number: "QP-#{System.unique_integer([:positive])}",
      status: status,
      currency: "ZAR",
      completed_at: ~U[2026-05-17 08:00:00.000000Z],
      created_at_source: ~U[2026-05-17 07:00:00.000000Z],
      updated_at_source: ~U[2026-05-17 08:00:00.000000Z],
      raw_total: Decimal.new("0"),
      raw_discount_total: Decimal.new("0"),
      raw_tax_total: Decimal.new("0")
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
      name: "QP Ticket",
      quantity: 1,
      line_subtotal: Decimal.new("80.00"),
      line_total: Decimal.new("80.00"),
      discount_total: Decimal.new("0"),
      item_kind: :ticket,
      mapping_status: :mapped
    }

    Ash.create!(OrderItem, Map.merge(defaults, Map.new(attrs)),
      action: :create_normalized,
      domain: Sales
    )
  end

  defp create_refund!(source, order, woo_refund_id) do
    Ash.create!(
      Refund,
      %{
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
      },
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
end
