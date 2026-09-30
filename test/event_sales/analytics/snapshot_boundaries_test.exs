defmodule EventSales.Analytics.SnapshotBoundariesTest do
  use ExUnit.Case, async: true

  test "SnapshotReader stays on snapshot resources only" do
    source = File.read!("lib/event_sales/analytics/snapshot_reader.ex")

    refute source =~ "EventAggregator"
    refute source =~ "sales_order_items"
    refute source =~ "sales_orders"
    refute source =~ "sales_refunds"
    refute source =~ "sales_refund_lines"
    refute source =~ "OrderItem"
    refute source =~ "Order"
    refute source =~ "RefundLine"
    refute source =~ "Refund"
    refute source =~ "WooCommerce"
    refute source =~ "SnapshotStore"
    refute source =~ "Redix"

    assert source =~ "EventAggregateSnapshot"
  end

  test "EventDetail financial path uses snapshot readers inside coherent transaction" do
    source = File.read!("lib/event_sales/analytics/event_detail.ex")

    assert source =~ "SnapshotReader.financial_summaries_for_event"
    assert source =~ "DimensionSnapshotReader"
    assert source =~ "EventSnapshotRefreshFence.coherent_transaction_opts"
    assert source =~ "AnalyticsReadinessResolver"
    refute source =~ "scoped_summary"
    refute source =~ "ticket_type_aggregate_rows"
    refute source =~ "EventAggregator"
    refute source =~ "DimensionAggregator"
  end

  test "EventScopedDashboard uses hot-state and snapshot readers only" do
    source = File.read!("lib/event_sales/analytics/event_scoped_dashboard.ex")

    assert source =~ "HotStateAggregator"
    assert source =~ "SnapshotReader"
    refute source =~ "EventAggregator"
    refute source =~ "sales_order_items"
    refute source =~ "sales_orders"
    refute source =~ "sales_refunds"
    refute source =~ "sales_refund_lines"
    refute source =~ "OrderItem"
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
