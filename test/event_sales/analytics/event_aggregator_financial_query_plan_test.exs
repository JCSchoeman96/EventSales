defmodule EventSales.Analytics.EventAggregatorFinancialQueryPlanTest do
  @moduledoc false
  use EventSales.DataCase, async: false

  alias EventSales.Analytics.Aggregators.EventAggregator
  alias EventSales.Repo
  alias EventSales.TestSupport.Analytics.EventAggregatorQueryPlanFixture

  @allowed_order_item_indexes [
    "sales_order_items_event_id_idx",
    "sales_order_items_event_mapping_status_idx"
  ]

  @canonical_paths [
    :incomplete_primitive_guard,
    :gross_aggregate,
    :refund_aggregate,
    :recognised_order_count
  ]

  setup do
    fixture = EventAggregatorQueryPlanFixture.seed!()
    {:ok, fixture}
  end

  test "financial_summaries_for_event uses indexed event-scoped plans under selective data",
       %{target_event: event, noise_line_count: noise_line_count} do
    {summaries, queries} =
      capture_sql(fn ->
        EventAggregator.financial_summaries_for_event(event.id)
      end)

    assert {:ok, %{"ZAR" => _}} = summaries

    classified =
      queries
      |> Enum.uniq()
      |> Enum.map(fn {sql, params} ->
        {classify_query(sql), sql, params}
      end)
      |> Enum.group_by(fn {kind, _sql, _params} -> kind end, fn {_kind, sql, params} ->
        {sql, params}
      end)

    for path <- @canonical_paths do
      assert Map.has_key?(classified, path),
             "missing canonical query path #{path}; captured kinds: #{inspect(Map.keys(classified))}"
    end

    for path <- @canonical_paths, {sql, params} <- classified[path] do
      assert_event_scoped_sql!(sql, params, event.id)

      plan = explain_plan_json(sql, params)
      assert is_map(plan), "expected EXPLAIN JSON for #{path}"

      case path do
        :incomplete_primitive_guard ->
          assert_order_items_index_access!(plan, path)

        :gross_aggregate ->
          assert_order_items_index_access!(plan, path)

        :recognised_order_count ->
          assert_order_items_index_access!(plan, path)

        :refund_aggregate ->
          assert_refund_path_index_use!(plan, path)
      end
    end

    # Fixture cardinality recorded for certification evidence (see pre-m5-02f-metrics-certification.md).
    assert noise_line_count >= 500
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

  defp assert_order_items_index_access!(plan, path) do
    item_nodes = relation_nodes(plan, "sales_order_items")

    assert item_nodes != [],
           "#{path}: expected sales_order_items in plan, got: #{inspect(plan_summary(plan))}"

    assert Enum.all?(item_nodes, &event_scoped_order_item_access?/1),
           "#{path}: sales_order_items must use event-bounded index access, got #{inspect(plan_summary(plan))}"
  end

  defp event_scoped_order_item_access?(node) do
    node["Node Type"] in ["Index Scan", "Bitmap Index Scan", "Index Only Scan"] and
      (node["Index Name"] in @allowed_order_item_indexes or
         event_id_in_plan_predicate?(node))
  end

  defp event_id_in_plan_predicate?(node) do
    predicate = [node["Filter"], node["Index Cond"]] |> List.to_string()

    String.contains?(predicate, "event_id")
  end

  defp assert_refund_path_index_use!(plan, path) do
    item_nodes = relation_nodes(plan, "sales_order_items")

    assert item_nodes != [],
           "#{path}: expected event-bounded ticket subquery on sales_order_items"

    assert Enum.any?(item_nodes, &event_scoped_order_item_access?/1),
           "#{path}: expected indexed event-scoped sales_order_items access, got #{inspect(plan_summary(plan))}"
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
