defmodule EventSales.Analytics.MetricRulesTest do
  use ExUnit.Case, async: true

  alias EventSales.Analytics.MetricRules
  alias EventSales.Sales.Resources.{Order, OrderItem}

  @non_completed_statuses [:pending, :processing, :on_hold, :cancelled, :refunded, :failed]
  @excluded_mapping_statuses [:pending_mapping_resolution, :unmapped, :non_ticket, :ignored]

  test "completed mapped ticket line counts sold tickets and completed revenue" do
    order = order(:completed)
    item = ticket_item(%{quantity: 2, line_total: Decimal.new("900.00")})

    assert MetricRules.counts_as_sold?(order, item)
    assert MetricRules.sold_quantity(order, item) == 2
    assert MetricRules.completed_revenue(order, item) == Decimal.new("900.00")
  end

  test "non-completed statuses are visible but excluded from sold and revenue totals" do
    item = ticket_item(%{quantity: 3, line_total: Decimal.new("1200.00")})

    for status <- @non_completed_statuses do
      order = order(status)

      refute MetricRules.counts_as_sold?(order, item)
      assert MetricRules.sold_quantity(order, item) == 0
      assert MetricRules.completed_revenue(order, item) == Decimal.new("0")
      assert MetricRules.visible_in_status_breakdown?(order, item)
      assert MetricRules.status_bucket(order) == status
    end
  end

  test "refunded mapped ticket remains visible but is excluded from MVP revenue" do
    order = order(:refunded)
    item = ticket_item(%{quantity: 1, line_total: Decimal.new("450.00")})

    assert MetricRules.visible_in_status_breakdown?(order, item)
    refute MetricRules.counts_as_sold?(order, item)
    assert MetricRules.completed_revenue(order, item) == Decimal.new("0")
  end

  test "excluded mapping statuses and non-ticket item kind do not count" do
    order = order(:completed)

    for mapping_status <- @excluded_mapping_statuses do
      item = ticket_item(%{mapping_status: mapping_status})

      refute MetricRules.counts_as_sold?(order, item)
      assert MetricRules.sold_quantity(order, item) == 0
      assert MetricRules.completed_revenue(order, item) == Decimal.new("0")
    end

    non_ticket = ticket_item(%{mapping_status: :mapped, item_kind: :non_ticket})

    refute MetricRules.counts_as_sold?(order, non_ticket)
    assert MetricRules.sold_quantity(order, non_ticket) == 0
    assert MetricRules.completed_revenue(order, non_ticket) == Decimal.new("0")
  end

  test "summarize returns total and today metrics using Africa Johannesburg timezone" do
    today_order =
      order(:completed, %{completed_at: ~U[2026-05-16 22:30:00.000000Z]})

    previous_business_day_order =
      order(:completed, %{completed_at: ~U[2026-05-16 21:30:00.000000Z]})

    now = ~U[2026-05-17 10:00:00.000000Z]

    summary =
      MetricRules.summarize(
        [
          %{
            order: today_order,
            item: ticket_item(%{quantity: 2, line_total: Decimal.new("900.00")})
          },
          {previous_business_day_order,
           ticket_item(%{quantity: 1, line_total: Decimal.new("450.00")})}
        ],
        now: now,
        timezone: "Africa/Johannesburg"
      )

    assert summary == %{
             total_sold: 3,
             total_revenue: Decimal.new("1350.00"),
             today_sold: 2,
             today_revenue: Decimal.new("900.00"),
             status_breakdown: %{completed: 2}
           }
  end

  test "business_date uses configured Africa Johannesburg timezone and reports invalid zones" do
    utc_boundary = ~U[2026-05-16 22:30:00.000000Z]

    assert MetricRules.business_timezone() == "Africa/Johannesburg"
    assert MetricRules.business_date(utc_boundary, "Africa/Johannesburg") == {:ok, ~D[2026-05-17]}

    assert MetricRules.business_date(utc_boundary, "Invalid/Timezone") ==
             {:error, :invalid_timezone}
  end

  test "nil completed_at is excluded from today totals" do
    summary =
      MetricRules.summarize(
        [
          %{order: order(:completed, %{completed_at: nil}), item: ticket_item(%{quantity: 2})}
        ],
        now: ~U[2026-05-17 10:00:00.000000Z],
        timezone: "Africa/Johannesburg"
      )

    assert summary.total_sold == 2
    assert summary.today_sold == 0
    assert summary.today_revenue == Decimal.new("0")
  end

  defp order(status, attrs \\ %{}) do
    struct!(
      Order,
      Map.merge(
        %{
          status: status,
          completed_at: ~U[2026-05-17 08:00:00.000000Z]
        },
        attrs
      )
    )
  end

  defp ticket_item(attrs) do
    struct!(
      OrderItem,
      Map.merge(
        %{
          mapping_status: :mapped,
          item_kind: :ticket,
          quantity: 1,
          line_total: Decimal.new("450.00")
        },
        attrs
      )
    )
  end
end
