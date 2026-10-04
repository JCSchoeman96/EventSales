defmodule EventSales.Analytics.PeriodReadPlanTest do
  use ExUnit.Case, async: true

  alias EventSales.Analytics.{MetricRules, PeriodReadPlan, TimeRules}

  @johannesburg "Africa/Johannesburg"

  test "yesterday operands use one Johannesburg day bucket and no edge fragments" do
    now = ~U[2026-05-17 10:00:00.000000Z]
    {:ok, windows} = TimeRules.comparison_windows(@johannesburg, now, :yesterday)
    assert {:ok, plan} = PeriodReadPlan.build(windows)

    refute plan.uses_edge_queries?
    assert plan.edge_fragment_count == 0

    for operand <- plan.operands do
      assert operand.strategy == :johannesburg_day
      assert length(operand.fixed_buckets) == 1
      assert operand.fixed_buckets |> hd() |> Map.fetch!(:bucket_kind) == :johannesburg_day
      assert operand.edge_fragments == []
    end
  end

  test "elapsed today decomposes interiors and optional edges" do
    now = ~U[2026-05-17 10:17:33.000000Z]
    {:ok, windows} = TimeRules.comparison_windows(@johannesburg, now, :today)
    assert {:ok, plan} = PeriodReadPlan.build(windows)

    assert plan.edge_fragment_count > 0
    assert plan.edge_fragment_count <= 4

    current = Enum.find(plan.operands, &(&1.operand == :current))
    assert current.strategy == :utc_hour_interior_and_edges
    assert plan.uses_edge_queries?
  end

  test "decompose_period exposes sub-hour edge only windows" do
    period = %TimeRules.Period{
      start_utc: ~U[2026-05-17 10:15:00.000000Z],
      end_utc: ~U[2026-05-17 10:45:00.000000Z],
      timezone: @johannesburg,
      kind: {:comparison, :today}
    }

    %{fixed_buckets: fixed, edge_fragments: edges} =
      PeriodReadPlan.decompose_period(period, :utc_hour_interior_and_edges)

    assert fixed == []
    assert length(edges) == 1
    assert hd(edges).envelope_hour_start_utc == ~U[2026-05-17 10:00:00.000000Z]
  end

  test "rolling seven day plan stays within edge fragment limit" do
    now = ~U[2026-05-17 10:17:33.000000Z]
    {:ok, windows} = TimeRules.comparison_windows(@johannesburg, now, {:rolling_days, 7})
    assert {:ok, plan} = PeriodReadPlan.build(windows)
    assert plan.edge_fragment_count <= 4
  end
end
