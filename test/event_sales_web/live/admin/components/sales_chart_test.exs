defmodule EventSalesWeb.Live.Admin.Components.SalesChartTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EventSalesWeb.Live.Admin.Components.SalesChart

  describe "empty chart data" do
    test "renders empty-state copy" do
      html =
        render_component(SalesChart,
          id: "main",
          labels: [],
          revenue: [],
          tickets: []
        )

      assert html =~ "No sales trend data yet"
    end

    test "does not render a canvas" do
      html =
        render_component(SalesChart,
          id: "main",
          labels: [],
          revenue: [],
          tickets: []
        )

      refute html =~ "<canvas"
    end

    test "does not render inline Chart.js boot script" do
      html =
        render_component(SalesChart,
          id: "main",
          labels: [],
          revenue: [],
          tickets: []
        )

      refute html =~ "new Chart"
      refute html =~ "waitForChartJs"
      refute html =~ "<script>"
    end
  end

  describe "non-empty chart data" do
    test "renders stable canvas id" do
      html =
        render_component(SalesChart,
          id: "main",
          labels: ["2026-05-24"],
          revenue: [1200],
          tickets: [3]
        )

      assert html =~ ~s(id="sales-chart-main")
      assert html =~ ~s(var canvasId = "sales-chart-main";)
      refute html =~ "{@canvas_id}"
    end

    test "renders data-* JSON attributes" do
      html =
        render_component(SalesChart,
          id: "main",
          labels: ["2026-05-24"],
          revenue: [1200],
          tickets: [3]
        )

      assert html =~ "data-labels="
      assert html =~ "data-revenue="
      assert html =~ "data-tickets="
      assert html =~ "2026-05-24"
      assert html =~ "1200"
      assert html =~ "3"
    end
  end
end
