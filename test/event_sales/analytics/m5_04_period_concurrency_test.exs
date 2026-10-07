# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule EventSales.Analytics.M5_04PeriodConcurrencyTest do
  @moduledoc """
  M5-04 G2 concurrency certification entry points.

  Detailed proofs live in the focused suites referenced below; this module
  records the G2 regression contract without duplicating every barrier test.
  """

  use ExUnit.Case, async: false

  @g2_regression_files [
    "test/event_sales/analytics/period_comparison_reader_concurrency_test.exs",
    "test/event_sales/analytics/period_coverage_concurrency_test.exs",
    "test/event_sales/analytics/event_snapshot_refresh_enqueue_concurrency_test.exs",
    "test/event_sales/analytics/event_snapshot_refresh_concurrency_test.exs"
  ]

  test "G2 concurrency regression suites remain present" do
    for path <- @g2_regression_files do
      assert File.exists?(path)
    end
  end
end
