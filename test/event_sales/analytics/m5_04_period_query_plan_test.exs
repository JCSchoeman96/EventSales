# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule EventSales.Analytics.M5_04PeriodQueryPlanTest do
  @moduledoc """
  M5-04 G2 query-plan certification entry point.

  EXPLAIN evidence is recorded in the focused plan suites; this module
  re-runs the sale/refund population gate against the shared fixture.
  """

  use EventSales.DataCase, async: false

  alias EventSales.Analytics.PeriodProjectionRefresh
  alias EventSales.Repo
  alias EventSales.TestSupport.Analytics.EventAggregatorQueryPlanFixture

  @event_first_indexes [
    "sales_order_items_event_id_idx",
    "sales_order_items_event_mapping_status_idx"
  ]

  test "G2 sale and refund population plans stay event-bounded" do
    fixture = EventAggregatorQueryPlanFixture.seed!()
    window = period_window(fixture)

    sale_plan =
      fixture.target_event.id
      |> PeriodProjectionRefresh.sale_population_query([window])
      |> explain_plan!()

    refund_plan =
      fixture.target_event.id
      |> PeriodProjectionRefresh.refund_population_query([window])
      |> explain_plan!()

    sale_items = relation_nodes(sale_plan, "sales_order_items")
    assert Enum.any?(sale_items, &(&1["Index Name"] in @event_first_indexes))
    assert Enum.any?(relation_nodes(refund_plan, "sales_refund_lines"), &refund_line_index?/1)
  end

  test "G2 reader and coverage plan suites remain present" do
    for file <- [
          "test/event_sales/analytics/period_comparison_reader_query_plan_test.exs",
          "test/event_sales/analytics/period_coverage_query_plan_test.exs",
          "test/event_sales/analytics/period_projection_query_plan_test.exs"
        ] do
      assert File.exists?(file)
    end
  end

  defp period_window(fixture) do
    %{
      currency: "ZAR",
      start_utc: fixture.target_period.start_utc,
      end_utc: fixture.target_period.end_utc
    }
  end

  defp explain_plan!(query) do
    {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Repo, query)
    {:ok, %{rows: [[plan_json]]}} = Repo.query("EXPLAIN (FORMAT JSON) " <> sql, params)
    normalize_explain(plan_json)
  end

  defp normalize_explain(plan_json) when is_map(plan_json), do: plan_json
  defp normalize_explain(plan_json) when is_binary(plan_json), do: Jason.decode!(plan_json)
  defp normalize_explain([plan_json]), do: normalize_explain(plan_json)

  defp relation_nodes(plan, table) do
    walk_nodes(plan, [])
    |> Enum.filter(&(&1["Relation Name"] == table))
  end

  defp walk_nodes(%{"Plan" => child}, acc), do: walk_nodes(child, acc)

  defp walk_nodes(%{"Plans" => children}, acc) when is_list(children) do
    Enum.reduce(children, acc, &walk_nodes(&1, &2))
  end

  defp walk_nodes(%{"Node Type" => _} = node, acc) do
    node
    |> Map.get("Plans", [])
    |> Enum.reduce([node | acc], &walk_nodes(&1, &2))
  end

  defp walk_nodes(_other, acc), do: acc

  defp refund_line_index?(node) do
    String.contains?(to_string(Map.get(node, "Index Name", "")), "sales_refund_lines")
  end
end
