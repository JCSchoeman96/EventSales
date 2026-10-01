defmodule EventSales.Analytics.DimensionAggregatorQueryPlanTest do
  @moduledoc false
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.Aggregators.DimensionAggregator
  alias EventSales.Repo
  alias EventSales.TestSupport.Analytics.EventAggregatorQueryPlanFixture

  @event_first_order_item_indexes [
    "sales_order_items_event_id_idx",
    "sales_order_items_event_mapping_status_idx"
  ]

  @index_node_types ["Index Scan", "Bitmap Index Scan", "Index Only Scan"]

  @refund_index_access_types ["Index Scan", "Bitmap Index Scan", "Index Only Scan"]

  @allowed_refund_header_indexes [
    "sales_refunds_order_id_idx",
    "sales_refunds_pkey",
    "sales_refunds_unique_source_order_refund_index"
  ]

  @refund_line_index_keys %{
    "sales_refund_lines_order_item_id_idx" => "order_item_id",
    "sales_refund_lines_unique_refund_line_index" => "refund_id"
  }

  test "financial_rows_for_event uses six bounded dimensional aggregates under selective data" do
    for iteration <- 1..3 do
      fixture = EventAggregatorQueryPlanFixture.seed!()
      certify_financial_iteration!(fixture, iteration)
    end
  end

  test "all three dimensional aggregates use event-first indexed plans under selective data" do
    for iteration <- 1..3 do
      fixture = EventAggregatorQueryPlanFixture.seed!()
      certify_iteration!(fixture, iteration)
    end
  end

  defp certify_financial_iteration!(fixture, iteration) do
    event_id = fixture.target_event.id

    {result, captured_queries} =
      capture_sql(fn -> DimensionAggregator.financial_rows_for_event(event_id) end)

    assert {:ok, rows} = result
    assert length(rows) == 3

    dimensional_queries = select_queries(captured_queries)
    assert length(dimensional_queries) == 6

    classified =
      Enum.group_by(dimensional_queries, fn {sql, _params} ->
        classify_financial_query!(sql)
      end)

    assert Map.keys(classified) |> Enum.sort() ==
             [
               {:gross, :source_product},
               {:gross, :source_variation},
               {:gross, :ticket_type},
               {:refund, :source_product},
               {:refund, :source_variation},
               {:refund, :ticket_type}
             ]

    for {{side, path}, queries} <- classified do
      assert length(queries) == 1
      {sql, params} = hd(queries)
      plan = explain_plan_json(sql, params)

      case side do
        :gross ->
          assert_event_scope!(sql, params, event_id, path, iteration)
          assert_item_access!(plan, path, iteration)
          assert_no_seq_scan!(plan, "sales_order_items", path, iteration)
          assert_order_access!(plan, path, iteration)
          assert_no_seq_scan!(plan, "sales_orders", path, iteration)

        :refund ->
          assert_event_scope!(sql, params, event_id, path, iteration)
          assert_refund_path_index_use!(plan, path, iteration)
      end
    end

    ticket_row = Enum.find(rows, &(&1.dimension_kind == :ticket_type))
    assert ticket_row.gross_ticket_quantity == 2
    assert ticket_row.refund_ticket_quantity == 1
    assert Decimal.equal?(ticket_row.gross_ticket_value, Decimal.new("92.00"))
    assert Decimal.equal?(ticket_row.refund_ticket_value, Decimal.new("46.00"))

    assert fixture.noise_line_count >= 800
    assert fixture.noise_refund_count >= 800
  end

  defp classify_financial_query!(sql) do
    side = if String.contains?(sql, "sales_refund_lines"), do: :refund, else: :gross
    group_by = group_by_clause!(sql)

    family =
      cond do
        source_variation_group?(group_by) -> :source_variation
        source_product_group?(group_by) -> :source_product
        ticket_type_group?(group_by) -> :ticket_type
        true -> flunk("unclassified dimensional GROUP BY: #{group_by}")
      end

    {side, family}
  end

  defp assert_refund_path_index_use!(plan, path, iteration) do
    assert_no_seq_scan!(plan, "sales_refund_lines", path, iteration)
    assert_no_seq_scan!(plan, "sales_refunds", path, iteration)

    refund_line_nodes = relation_nodes(plan, "sales_refund_lines")

    assert refund_line_nodes != [],
           "#{path} iteration #{iteration}: expected sales_refund_lines in refund dimensional plan"

    assert Enum.any?(refund_line_nodes, &refund_line_index_access?/1),
           "#{path} iteration #{iteration}: expected bounded sales_refund_lines index access"

    refund_nodes = relation_nodes(plan, "sales_refunds")

    assert refund_nodes != [],
           "#{path} iteration #{iteration}: expected sales_refunds in refund dimensional plan"

    assert Enum.any?(refund_nodes, &refund_header_index_access?/1),
           "#{path} iteration #{iteration}: expected bounded sales_refunds index access"

    item_nodes = relation_nodes(plan, "sales_order_items")

    assert Enum.any?(item_nodes, fn node ->
             node["Node Type"] in @index_node_types and
               node["Index Name"] in @event_first_order_item_indexes
           end),
           "#{path} iteration #{iteration}: expected event-first sales_order_items access in refund dimensional plan"
  end

  defp refund_line_index_access?(node) do
    index_key = Map.get(@refund_line_index_keys, node["Index Name"])
    index_condition = String.downcase(Map.get(node, "Index Cond", ""))

    node["Node Type"] in @refund_index_access_types and is_binary(index_key) and
      String.contains?(index_condition, index_key)
  end

  defp refund_header_index_access?(node) do
    node["Node Type"] in @refund_index_access_types and
      node["Index Name"] in @allowed_refund_header_indexes
  end

  defp certify_iteration!(fixture, iteration) do
    event_id = fixture.target_event.id

    {result, captured_queries} =
      capture_sql(fn -> DimensionAggregator.gross_rows_for_event(event_id) end)

    assert {:ok, rows} = result
    assert length(rows) == 3

    assert MapSet.new(Enum.map(rows, & &1.dimension_kind)) ==
             MapSet.new([:ticket_type, :source_product, :source_variation])

    ticket_row = Enum.find(rows, &(&1.dimension_kind == :ticket_type))
    product_row = Enum.find(rows, &(&1.dimension_kind == :source_product))
    variation_row = Enum.find(rows, &(&1.dimension_kind == :source_variation))

    assert ticket_row.event_id == event_id
    assert ticket_row.ticket_type_id == fixture.target_ticket.id
    assert ticket_row.gross_ticket_quantity == 2
    assert Decimal.equal?(ticket_row.gross_ticket_value, Decimal.new("92.00"))
    assert product_row.source_system_id == fixture.source.id
    assert product_row.woo_product_id == 71
    assert variation_row.source_system_id == fixture.source.id
    assert variation_row.woo_product_id == 71
    assert variation_row.woo_variation_id == 72

    dimensional_queries = select_queries(captured_queries)
    assert length(dimensional_queries) == 3

    classified = Enum.group_by(dimensional_queries, fn {sql, _params} -> classify_query!(sql) end)

    assert Map.keys(classified) |> Enum.sort() ==
             [:source_product, :source_variation, :ticket_type]

    for {path, [{sql, params}]} <- classified do
      assert_event_scope!(sql, params, event_id, path, iteration)
      plan = explain_plan_json(sql, params)
      assert_item_access!(plan, path, iteration)
      assert_no_seq_scan!(plan, "sales_order_items", path, iteration)
      assert_order_access!(plan, path, iteration)
      assert_no_seq_scan!(plan, "sales_orders", path, iteration)
    end

    assert fixture.noise_line_count >= 800
  end

  defp classify_query!(sql) do
    group_by = group_by_clause!(sql)

    cond do
      source_variation_group?(group_by) -> :source_variation
      source_product_group?(group_by) -> :source_product
      ticket_type_group?(group_by) -> :ticket_type
      true -> flunk("unclassified dimensional GROUP BY: #{group_by}")
    end
  end

  defp group_by_clause!(sql) do
    sql
    |> String.downcase()
    |> String.split("group by", parts: 2)
    |> case do
      [_before, rest] -> rest
      _ -> flunk("expected grouped dimensional SQL, got: #{sql}")
    end
    |> String.split(~r/\b(order by|limit|having)\b/, parts: 2)
    |> hd()
  end

  defp source_variation_group?(group_by) do
    has_all_columns?(group_by, ["source_system_id", "woo_product_id", "woo_variation_id"])
  end

  defp source_product_group?(group_by) do
    has_all_columns?(group_by, ["source_system_id", "woo_product_id"]) and
      not String.contains?(group_by, "woo_variation_id")
  end

  defp ticket_type_group?(group_by) do
    String.contains?(group_by, "ticket_type_id") and
      not String.contains?(group_by, "source_system_id") and
      not String.contains?(group_by, "woo_product_id")
  end

  defp has_all_columns?(group_by, columns) do
    Enum.all?(columns, &String.contains?(group_by, &1))
  end

  defp assert_event_scope!(sql, params, event_id, path, iteration) do
    dumped_event_id = Ecto.UUID.dump!(event_id)

    assert String.match?(sql, ~r/event_id[\"]?\s*=\s*\$\d+/i),
           "#{path} iteration #{iteration}: SQL has no bound event_id predicate: #{sql}"

    assert dumped_event_id in params,
           "#{path} iteration #{iteration}: requested Event UUID is not bound: #{inspect(params)}"
  end

  defp assert_item_access!(plan, path, iteration) do
    nodes = relation_nodes(plan, "sales_order_items")

    assert nodes != [],
           "#{path} iteration #{iteration}: no sales_order_items plan nodes: #{inspect(plan_nodes(plan))}"

    Enum.each(nodes, fn node ->
      assert node["Node Type"] in @index_node_types,
             "#{path} iteration #{iteration}: expected indexed sales_order_items access: #{inspect(node)}"

      assert node["Index Name"] in @event_first_order_item_indexes,
             "#{path} iteration #{iteration}: expected an event-first index: #{inspect(node)}"
    end)
  end

  defp assert_order_access!(plan, path, iteration) do
    nodes = relation_nodes(plan, "sales_orders")

    assert nodes != [],
           "#{path} iteration #{iteration}: no sales_orders plan nodes: #{inspect(plan_nodes(plan))}"

    assert Enum.any?(nodes, fn node ->
             node["Node Type"] in @index_node_types and node["Index Name"] == "sales_orders_pkey"
           end),
           "#{path} iteration #{iteration}: expected bounded sales_orders primary-key access: #{inspect(nodes)}"
  end

  defp assert_no_seq_scan!(plan, relation, path, iteration) do
    seq_scans =
      relation_nodes(plan, relation)
      |> Enum.filter(&(Map.get(&1, "Node Type") == "Seq Scan"))

    assert seq_scans == [],
           "#{path} iteration #{iteration}: sequential scan on #{relation}: #{inspect(seq_scans)}"
  end

  defp select_queries(queries) do
    Enum.filter(queries, fn {sql, _params} ->
      String.match?(sql, ~r/^\s*(select|with)\b/i)
    end)
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
      {result, collect_sql(handler_id, [])}
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

  defp explain_plan_json(sql, params) do
    case Repo.query("EXPLAIN (FORMAT JSON) #{sql}", params) do
      {:ok, %{rows: [[plan_json]]}} when is_binary(plan_json) ->
        Jason.decode!(plan_json) |> normalize_explain_root()

      {:ok, %{rows: [[plan]]}} when is_list(plan) ->
        normalize_explain_root(plan)

      other ->
        flunk("EXPLAIN failed for dimensional SQL: #{inspect(other)}")
    end
  end

  defp normalize_explain_root([%{"Plan" => root} | _]), do: root
  defp normalize_explain_root(%{"Plan" => root}), do: root
  defp normalize_explain_root(other), do: other

  defp relation_nodes(plan, relation) do
    plan_nodes(plan)
    |> Enum.filter(fn node -> node["Relation Name"] == relation end)
  end

  defp plan_nodes(plan) when is_list(plan), do: Enum.flat_map(plan, &plan_nodes/1)

  defp plan_nodes(%{"Plans" => nested} = node) do
    [node | Enum.flat_map(nested, &plan_nodes/1)]
  end

  defp plan_nodes(node) when is_map(node), do: [node]
  defp plan_nodes(_), do: []
end
