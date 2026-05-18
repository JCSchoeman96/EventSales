defmodule EventSales.Analytics.SnapshotBoundariesTest do
  use ExUnit.Case, async: true

  test "SnapshotReader stays on snapshot resources only" do
    source = File.read!("lib/event_sales/analytics/snapshot_reader.ex")

    refute source =~ "EventAggregator"
    refute source =~ "sales_order_items"
    refute source =~ "OrderItem"
    refute source =~ "WooCommerce"
    refute source =~ "SnapshotStore"
    refute source =~ "Redix"
  end

  test "future dashboard live code does not scan sales rows directly" do
    dashboard_files =
      "lib/event_sales_web/live/admin/dashboard*"
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)

    for path <- dashboard_files do
      source = File.read!(path)

      refute source =~ "EventAggregator"
      refute source =~ "sales_order_items"
      refute source =~ "OrderItem"
      refute source =~ "Repo"
      refute source =~ "WooCommerce"
    end
  end
end
