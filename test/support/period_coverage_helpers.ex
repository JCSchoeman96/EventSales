defmodule EventSales.TestSupport.PeriodCoverageHelpers do
  @moduledoc false

  alias EventSales.Analytics
  alias EventSales.Analytics.Resources.EventAggregateSnapshot

  @refreshed_at ~U[2026-07-10 10:00:00.000000Z]

  @doc false
  def seed_v2_currency!(event, currency \\ "ZAR") do
    Ash.create!(
      EventAggregateSnapshot,
      %{
        event_id: event.id,
        total_sold: 0,
        total_revenue: Decimal.new("0"),
        today_sold: 0,
        today_revenue: Decimal.new("0"),
        gross_ticket_quantity: 0,
        refund_ticket_quantity: 0,
        gross_ticket_value: Decimal.new("0"),
        refund_ticket_value: Decimal.new("0"),
        recognised_order_count: 0,
        currency: currency,
        business_timezone: "Africa/Johannesburg",
        refreshed_at: @refreshed_at,
        source_row_count: 0,
        snapshot_version: 2
      },
      action: :create_snapshot,
      domain: Analytics
    )
  end
end
