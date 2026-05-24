defmodule EventSalesWeb.Live.Admin.Components.SalesChartTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias EventSalesWeb.Live.Admin.Components.SalesChart

  test "renders the actual canvas id into chart boot script" do
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
end
