defmodule EventSalesWeb.Live.Admin.ComponentNamespaceTest do
  use ExUnit.Case, async: true

  test "admin-only components live under the admin namespace" do
    generic_component_modules =
      "lib/event_sales_web/live/components/*.ex"
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        path
        |> File.read!()
        |> then(
          &Regex.scan(~r/defmodule\s+(EventSalesWeb\.Live\.Components\.[A-Za-z0-9_.]+)/, &1)
        )
        |> Enum.map(fn [_match, module] -> module end)
      end)

    assert generic_component_modules == []
  end

  test "admin dashboard aliases admin component namespace" do
    source = File.read!("lib/event_sales_web/live/admin/dashboard_live.ex")

    assert source =~ "EventSalesWeb.Live.Admin.Components"
    refute source =~ "EventSalesWeb.Live.Components"
  end

  test "client dashboard infrastructure is not introduced by Slice 19" do
    refute File.exists?("lib/event_sales_web/live/client")
  end
end
