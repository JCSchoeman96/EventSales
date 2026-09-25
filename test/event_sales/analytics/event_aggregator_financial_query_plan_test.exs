defmodule EventSales.Analytics.EventAggregatorFinancialQueryPlanTest do
  @moduledoc false
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.Aggregators.EventAggregator
  alias EventSales.Repo
  alias EventSales.TestSupport.Analytics.EventAggregatorQueryPlanFixture

  @event_first_order_item_indexes [
    "sales_order_items_event_id_idx",
    "sales_order_items_event_mapping_status_idx"
  ]

  @canonical_paths [
    :incomplete_primitive_guard,
    :gross_aggregate,
    :refund_aggregate,
    :recognised_order_count
  ]

  @max_tiny_seq_scan_rows 25

  test "financial_summaries_for_event uses indexed event-scoped plans under selective data" do
    for iteration <- 1..3 do
      fixture = EventAggregatorQueryPlanFixture.seed!()
      certify_plans!(fixture, iteration)
    end
  end

  defp certify_plans!(fixture, iteration) do
    event = fixture.target_event

    {summaries, queries} =
      capture_sql(fn ->
        EventAggregator.financial_summaries_for_event(event.id)
      end)

    assert {:ok, summaries} = summaries
    summary = Map.fetch!(summaries, "ZAR")

    assert summary.recognised_order_count == 1
    assert Decimal.equal?(summary.gross_ticket_quantity, Decimal.new(2))
    assert Decimal.equal?(summary.gross_ticket_value, Decimal.new("92.00"))
    assert Decimal.equal?(summary.refund_ticket_quantity, Decimal.new(1))
    assert Decimal.equal?(summary.refund_ticket_value, Decimal.new("46.00"))
    assert Decimal.equal?(summary.net_ticket_value, Decimal.new("46.00"))

    classified = classify_queries(queries)

    for path <- @canonical_paths do
      assert Map.has_key?(classified, path),
             "iteration #{iteration}: missing #{path}; got #{inspect(Map.keys(classified))}"
    end

    for path <- @canonical_paths, {sql, params} <- classified[path] do
      assert_event_scoped_sql!(sql, params, event.id)

      plan = explain_plan_json(sql, params)
      assert is_map(plan), "iteration #{iteration}: expected EXPLAIN JSON for #{path}"

      case path do
        :incomplete_primitive_guard ->
          assert_event_first_order_item_indexes!(plan, path, iteration)

        :gross_aggregate ->
          assert_event_first_order_item_indexes!(plan, path, iteration)

        :recognised_order_count ->
          assert_event_first_order_item_indexes!(plan, path, iteration)

        :refund_aggregate ->
          assert_refund_path_index_use!(plan, path, iteration)
      end
    end

    assert fixture.noise_line_count >= 500
    assert fixture.noise_refund_count >= 500
  end

  defp classify_queries(queries) do
    queries
    |> Enum.uniq()
    |> Enum.map(fn {sql, params} -> {classify_query(sql), sql, params} end)
    |> Enum.group_by(fn {kind, _sql, _params} -> kind end, fn {_kind, sql, params} ->
      {sql, params}
    end)
  end

  defp classify_query(sql) when is_binary(sql) do
    cond do
      String.contains?(sql, "sales_refund_lines") ->
        :refund_aggregate

      String.match?(sql, ~r/count\s*\(\s*DISTINCT/i) ->
        :recognised_order_count

      String.contains?(sql, "SELECT TRUE") and String.contains?(sql, "LIMIT 1") ->
        :incomplete_primitive_guard

      String.contains?(sql, "sales_order_items") and String.contains?(sql, "sum(") ->
        :gross_aggregate

      true ->
        :other
    end
  end

  defp assert_event_scoped_sql!(sql, params, event_id) do
    dumped = Ecto.UUID.dump!(event_id)

    unless String.contains?(sql, "event_id") do
      flunk("expected event_id predicate in SQL, got: #{sql}")
    end

    unless dumped in params do
      flunk(
        "expected requested event UUID among query parameters, got params=#{inspect(params)} for SQL=#{sql}"
      )
    end

    :ok
  end

  defp assert_event_first_order_item_indexes!(plan, path, iteration) do
    item_nodes = relation_nodes(plan, "sales_order_items")

    assert item_nodes != [],
           "#{path} iteration #{iteration}: expected sales_order_items, got #{inspect(plan_summary(plan))}"

    Enum.each(item_nodes, fn node ->
      assert node["Node Type"] in ["Index Scan", "Bitmap Index Scan", "Index Only Scan"],
             "#{path} iteration #{iteration}: expected index access on sales_order_items, got #{inspect(node)}"

      assert node["Index Name"] in @event_first_order_item_indexes,
             "#{path} iteration #{iteration}: expected event-first index on sales_order_items, got #{inspect(node)}"
    end)
  end

  defp assert_refund_path_index_use!(plan, path, iteration) do
    item_nodes = relation_nodes(plan, "sales_order_items")

    event_first_nodes =
      Enum.filter(item_nodes, fn node ->
        node["Index Name"] in @event_first_order_item_indexes
      end)

    assert event_first_nodes != [],
           "#{path} iteration #{iteration}: missing event-first sales_order_items index scan, got #{inspect(plan_summary(plan))}"

    assert_no_high_volume_seq_scan!(plan, "sales_refund_lines", path, iteration)
    assert_no_high_volume_seq_scan!(plan, "sales_refunds", path, iteration)

    refund_line_nodes = relation_nodes(plan, "sales_refund_lines")

    assert refund_line_nodes != [],
           "#{path} iteration #{iteration}: expected sales_refund_lines in refund aggregate plan"

    assert Enum.any?(refund_line_nodes, &refund_line_index_access?/1),
           "#{path} iteration #{iteration}: expected sales_refund_lines_order_item_id_idx access, got #{inspect(plan_summary(plan))}"
  end

  defp refund_line_index_access?(node) do
    node["Node Type"] in ["Index Scan", "Bitmap Index Scan", "Index Only Scan"] and
      node["Index Name"] == "sales_refund_lines_order_item_id_idx"
  end

  defp assert_no_high_volume_seq_scan!(plan, relation, path, iteration) do
    for node <- relation_nodes(plan, relation),
        node["Node Type"] == "Seq Scan" do
      rows = node["Plan Rows"] || 0

      assert rows <= @max_tiny_seq_scan_rows,
             "#{path} iteration #{iteration}: unbounded seq scan on #{relation} (plan rows #{rows}): #{inspect(node)}"
    end
  end

  defp relation_nodes(plan, relation) do
    plan_nodes(plan)
    |> Enum.filter(fn node -> node["Relation Name"] == relation end)
  end

  defp plan_summary(plan) do
    plan_nodes(plan)
    |> Enum.map(fn node ->
      %{
        type: node["Node Type"],
        relation: node["Relation Name"],
        index: node["Index Name"],
        plan_rows: node["Plan Rows"],
        filter: node["Filter"] || node["Index Cond"]
      }
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

  defp explain_plan_json(sql, params) do
    case Repo.query("EXPLAIN (FORMAT JSON) #{sql}", params) do
      {:ok, %{rows: [[plan_json]]}} when is_binary(plan_json) ->
        Jason.decode!(plan_json) |> normalize_explain_root()

      {:ok, %{rows: [[plan]]}} when is_list(plan) ->
        normalize_explain_root(plan)

      other ->
        flunk("EXPLAIN failed for #{sql}: #{inspect(other)}")
    end
  end

  defp normalize_explain_root([%{"Plan" => root} | _]), do: root
  defp normalize_explain_root(%{"Plan" => root}), do: root
  defp normalize_explain_root(other), do: other

  defp plan_nodes(plan) when is_list(plan) do
    Enum.flat_map(plan, &plan_nodes/1)
  end

  defp plan_nodes(%{"Plans" => nested} = node) do
    [node | Enum.flat_map(nested, &plan_nodes/1)]
  end

  defp plan_nodes(node) when is_map(node), do: [node]
end
