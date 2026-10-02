defmodule EventSales.Analytics.MetricRulesTest do
  use ExUnit.Case, async: true

  alias EventSales.Analytics.MetricRules
  alias EventSales.Sales.FinancialPrimitives
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

  describe "legacy summarize today uses sale effective time" do
    @now ~U[2026-06-01 12:00:00.000000Z]
    @timezone "Africa/Johannesburg"

    test "paid_at inside today wins over completed_at outside today" do
      order =
        order(:completed, %{
          paid_at: ~U[2026-06-01 10:00:00.000000Z],
          completed_at: ~U[2026-05-31 10:00:00.000000Z]
        })

      summary =
        MetricRules.summarize(
          [%{order: order, item: ticket_item(%{quantity: 1, line_total: Decimal.new("100.00")})}],
          now: @now,
          timezone: @timezone
        )

      assert summary.total_sold == 1
      assert summary.today_sold == 1
      assert summary.today_revenue == Decimal.new("100.00")
      assert summary.status_breakdown == %{completed: 1}
    end

    test "paid_at outside today excludes row even when completed_at is inside today" do
      order =
        order(:completed, %{
          paid_at: ~U[2026-05-31 10:00:00.000000Z],
          completed_at: ~U[2026-06-01 10:00:00.000000Z]
        })

      summary =
        MetricRules.summarize(
          [%{order: order, item: ticket_item(%{quantity: 1, line_total: Decimal.new("100.00")})}],
          now: @now,
          timezone: @timezone
        )

      assert summary.total_sold == 1
      assert summary.total_revenue == Decimal.new("100.00")
      assert summary.today_sold == 0
      assert summary.today_revenue == Decimal.new("0")
      assert summary.status_breakdown == %{completed: 1}
    end

    test "falls back to completed_at when paid_at is nil" do
      order =
        order(:completed, %{
          paid_at: nil,
          completed_at: ~U[2026-06-01 10:00:00.000000Z]
        })

      summary =
        MetricRules.summarize(
          [%{order: order, item: ticket_item(%{quantity: 2, line_total: Decimal.new("200.00")})}],
          now: @now,
          timezone: @timezone
        )

      assert summary.today_sold == 2
      assert summary.today_revenue == Decimal.new("200.00")
    end

    test "completed row with both clocks nil keeps totals but excludes today" do
      order = order(:completed, %{paid_at: nil, completed_at: nil})

      summary =
        MetricRules.summarize(
          [%{order: order, item: ticket_item(%{quantity: 2, line_total: Decimal.new("200.00")})}],
          now: @now,
          timezone: @timezone
        )

      assert summary.total_sold == 2
      assert summary.total_revenue == Decimal.new("200.00")
      assert summary.today_sold == 0
      assert summary.today_revenue == Decimal.new("0")
    end

    test "pending row with paid_at inside today does not count toward totals or today" do
      order =
        order(:pending, %{
          paid_at: ~U[2026-06-01 10:00:00.000000Z],
          completed_at: nil
        })

      summary =
        MetricRules.summarize(
          [%{order: order, item: ticket_item(%{quantity: 1, line_total: Decimal.new("100.00")})}],
          now: @now,
          timezone: @timezone
        )

      assert summary.total_sold == 0
      assert summary.total_revenue == Decimal.new("0")
      assert summary.today_sold == 0
      assert summary.today_revenue == Decimal.new("0")
      assert summary.status_breakdown == %{pending: 1}
    end

    test "Johannesburg civil boundary uses sale effective completed_at fallback" do
      inside_today =
        order(:completed, %{paid_at: nil, completed_at: ~U[2026-05-31 22:30:00.000000Z]})

      previous_day =
        order(:completed, %{paid_at: nil, completed_at: ~U[2026-05-31 21:30:00.000000Z]})

      now = ~U[2026-06-01 10:00:00.000000Z]

      summary =
        MetricRules.summarize(
          [
            %{
              order: inside_today,
              item: ticket_item(%{quantity: 1, line_total: Decimal.new("50.00")})
            },
            {previous_day, ticket_item(%{quantity: 1, line_total: Decimal.new("25.00")})}
          ],
          now: now,
          timezone: @timezone
        )

      assert summary.total_sold == 2
      assert summary.total_revenue == Decimal.new("75.00")
      assert summary.today_sold == 1
      assert summary.today_revenue == Decimal.new("50.00")
    end

    test "nil timezone preserves totals and zeroes today" do
      order =
        order(:completed, %{
          paid_at: nil,
          completed_at: ~U[2026-06-01 10:00:00.000000Z]
        })

      summary =
        MetricRules.summarize(
          [%{order: order, item: ticket_item(%{quantity: 1, line_total: Decimal.new("100.00")})}],
          now: @now,
          timezone: nil
        )

      assert summary.total_sold == 1
      assert summary.total_revenue == Decimal.new("100.00")
      assert summary.today_sold == 0
      assert summary.today_revenue == Decimal.new("0")
      assert summary.status_breakdown == %{completed: 1}
    end

    test "invalid timezone preserves totals and zeroes today" do
      order =
        order(:completed, %{
          paid_at: nil,
          completed_at: ~U[2026-06-01 10:00:00.000000Z]
        })

      summary =
        MetricRules.summarize(
          [%{order: order, item: ticket_item(%{quantity: 1, line_total: Decimal.new("100.00")})}],
          now: @now,
          timezone: "Invalid/Timezone"
        )

      assert summary.total_sold == 1
      assert summary.total_revenue == Decimal.new("100.00")
      assert summary.today_sold == 0
      assert summary.today_revenue == Decimal.new("0")
      assert summary.status_breakdown == %{completed: 1}
    end
  end

  describe "derive_financial_metrics/1" do
    test "standard net and ATV derivation" do
      assert {:ok, metrics} =
               MetricRules.derive_financial_metrics(%{
                 gross_ticket_quantity: Decimal.new(2),
                 refund_ticket_quantity: Decimal.new(1),
                 gross_ticket_value: Decimal.new("115"),
                 refund_ticket_value: Decimal.new("57.50")
               })

      assert metrics.net_ticket_quantity == Decimal.new(1)
      assert metrics.net_ticket_value == Decimal.new("57.50")
      assert metrics.average_ticket_value == Decimal.new("57.50")
    end

    test "value-only refund adjusts net value and ATV" do
      assert {:ok, metrics} =
               MetricRules.derive_financial_metrics(%{
                 gross_ticket_quantity: Decimal.new(2),
                 refund_ticket_quantity: Decimal.new(0),
                 gross_ticket_value: Decimal.new("100"),
                 refund_ticket_value: Decimal.new("25")
               })

      assert metrics.net_ticket_quantity == Decimal.new(2)
      assert metrics.net_ticket_value == Decimal.new("75")
      assert metrics.average_ticket_value == Decimal.new("37.5")
    end

    test "over-refund preserves negative net without clamping" do
      assert {:ok, metrics} =
               MetricRules.derive_financial_metrics(%{
                 gross_ticket_quantity: Decimal.new(1),
                 refund_ticket_quantity: Decimal.new(2),
                 gross_ticket_value: Decimal.new("50"),
                 refund_ticket_value: Decimal.new("120")
               })

      assert metrics.net_ticket_quantity == Decimal.new(-1)
      assert metrics.net_ticket_value == Decimal.new("-70")
      assert metrics.average_ticket_value == Decimal.new("70")
    end

    test "zero net ticket quantity yields nil average ticket value" do
      assert {:ok, metrics} =
               MetricRules.derive_financial_metrics(%{
                 gross_ticket_quantity: Decimal.new(2),
                 refund_ticket_quantity: Decimal.new(2),
                 gross_ticket_value: Decimal.new("200"),
                 refund_ticket_value: Decimal.new("50")
               })

      assert Decimal.equal?(metrics.net_ticket_quantity, Decimal.new(0))
      assert metrics.average_ticket_value == nil
    end

    test "rejects invalid primitive inputs" do
      valid_base = %{
        gross_ticket_quantity: Decimal.new(1),
        refund_ticket_quantity: Decimal.new(0),
        gross_ticket_value: Decimal.new("10"),
        refund_ticket_value: Decimal.new("0")
      }

      assert MetricRules.derive_financial_metrics(%{}) == {:error, :invalid_primitive_totals}

      assert MetricRules.derive_financial_metrics(Map.delete(valid_base, :gross_ticket_value)) ==
               {:error, :invalid_primitive_totals}

      assert MetricRules.derive_financial_metrics(
               Map.put(valid_base, :gross_ticket_quantity, Decimal.new("1.5"))
             ) == {:error, :invalid_primitive_totals}

      assert MetricRules.derive_financial_metrics(
               Map.put(valid_base, :refund_ticket_quantity, Decimal.new("-1"))
             ) == {:error, :invalid_primitive_totals}

      assert MetricRules.derive_financial_metrics(
               Map.put(valid_base, :gross_ticket_value, Decimal.new("-0.01"))
             ) == {:error, :invalid_primitive_totals}

      assert MetricRules.derive_financial_metrics(
               Map.put(valid_base, :refund_ticket_value, Decimal.new("-0.01"))
             ) == {:error, :invalid_primitive_totals}

      assert MetricRules.derive_financial_metrics(Map.put(valid_base, :gross_ticket_value, 1.0)) ==
               {:error, :invalid_primitive_totals}

      assert MetricRules.derive_financial_metrics(
               Map.put(valid_base, :refund_ticket_value, "10.00")
             ) == {:error, :invalid_primitive_totals}
    end
  end

  describe "financial_summary/3" do
    test "derives tax-inclusive canonical summary from primitive totals and order count" do
      primitives =
        FinancialPrimitives.empty_totals()
        |> Map.merge(%{
          gross_ticket_quantity: Decimal.new(2),
          gross_ticket_value: FinancialPrimitives.gross_ticket_value("100.00", "15.00"),
          refund_ticket_quantity: Decimal.new(1),
          refund_ticket_value: FinancialPrimitives.refund_ticket_value("50.00", "7.50")
        })

      assert {:ok, summary} = MetricRules.financial_summary("ZAR", primitives, 1)

      assert summary.currency == "ZAR"
      assert summary.gross_ticket_quantity == Decimal.new(2)
      assert summary.gross_ticket_value == Decimal.new("115.00")
      assert summary.refund_ticket_quantity == Decimal.new(1)
      assert summary.refund_ticket_value == Decimal.new("57.50")
      assert summary.net_ticket_quantity == Decimal.new(1)
      assert summary.net_ticket_value == Decimal.new("57.50")
      assert summary.recognised_order_count == 1
      assert summary.average_ticket_value == Decimal.new("57.50")
    end

    test "preserves gross components when refunds reduce net only" do
      primitives =
        FinancialPrimitives.empty_totals()
        |> Map.merge(%{
          gross_ticket_quantity: Decimal.new(3),
          gross_ticket_value: Decimal.new("300.00"),
          refund_ticket_quantity: Decimal.new(1),
          refund_ticket_value: Decimal.new("100.00")
        })

      assert {:ok, summary} = MetricRules.financial_summary("ZAR", primitives, 2)

      assert summary.gross_ticket_quantity == Decimal.new(3)
      assert summary.gross_ticket_value == Decimal.new("300.00")
      assert summary.refund_ticket_quantity == Decimal.new(1)
      assert summary.refund_ticket_value == Decimal.new("100.00")
      assert summary.net_ticket_quantity == Decimal.new(2)
      assert summary.net_ticket_value == Decimal.new("200.00")
      assert summary.recognised_order_count == 2
    end

    test "over-refund preserves negative net without clamping" do
      primitives =
        FinancialPrimitives.empty_totals()
        |> Map.merge(%{
          gross_ticket_quantity: Decimal.new(1),
          gross_ticket_value: Decimal.new("50.00"),
          refund_ticket_quantity: Decimal.new(2),
          refund_ticket_value: Decimal.new("120.00")
        })

      assert {:ok, summary} = MetricRules.financial_summary("ZAR", primitives, 1)

      assert summary.net_ticket_quantity == Decimal.new("-1")
      assert summary.net_ticket_value == Decimal.new("-70.00")
      assert summary.average_ticket_value == Decimal.new("70.00")
    end

    test "zero net ticket quantity yields undefined average ticket value" do
      primitives =
        FinancialPrimitives.empty_totals()
        |> Map.merge(%{
          gross_ticket_quantity: Decimal.new(2),
          gross_ticket_value: Decimal.new("200.00"),
          refund_ticket_quantity: Decimal.new(2),
          refund_ticket_value: Decimal.new("200.00")
        })

      assert {:ok, summary} = MetricRules.financial_summary("ZAR", primitives, 1)

      assert Decimal.equal?(summary.net_ticket_quantity, Decimal.new(0))
      assert Decimal.equal?(summary.net_ticket_value, Decimal.new(0))
      assert summary.average_ticket_value == nil
    end

    test "rejects missing or blank currency" do
      primitives = FinancialPrimitives.empty_totals()

      assert MetricRules.financial_summary("", primitives, 0) == {:error, :invalid_currency}
      assert MetricRules.financial_summary(nil, primitives, 0) == {:error, :invalid_currency}
    end

    test "rejects non-integral quantity primitives" do
      primitives =
        FinancialPrimitives.empty_totals()
        |> Map.put(:gross_ticket_quantity, Decimal.new("1.5"))

      assert MetricRules.financial_summary("ZAR", primitives, 1) ==
               {:error, :invalid_primitive_totals}
    end

    test "delegates net and ATV semantics through derive_financial_metrics/1" do
      primitives =
        FinancialPrimitives.empty_totals()
        |> Map.merge(%{
          gross_ticket_quantity: Decimal.new(2),
          refund_ticket_quantity: Decimal.new(0),
          gross_ticket_value: Decimal.new("100"),
          refund_ticket_value: Decimal.new("25")
        })

      assert {:ok, summary} = MetricRules.financial_summary("ZAR", primitives, 3)
      assert {:ok, derived} = MetricRules.derive_financial_metrics(primitives)

      assert summary.net_ticket_value == derived.net_ticket_value
      assert summary.average_ticket_value == derived.average_ticket_value
      assert summary.recognised_order_count == 3
      assert summary.currency == "ZAR"
    end

    test "historical gross totals remain when refund adjustment facts are present" do
      primitives =
        FinancialPrimitives.empty_totals()
        |> Map.merge(%{
          gross_ticket_quantity: Decimal.new(2),
          gross_ticket_value: Decimal.new("230.00"),
          refund_ticket_quantity: Decimal.new(2),
          refund_ticket_value: Decimal.new("230.00")
        })

      assert {:ok, summary} = MetricRules.financial_summary("ZAR", primitives, 1)

      assert summary.gross_ticket_quantity == Decimal.new(2)
      assert summary.gross_ticket_value == Decimal.new("230.00")
      assert summary.net_ticket_quantity == Decimal.new(0)
      assert summary.average_ticket_value == nil
    end
  end

  describe "comparison classification and deltas" do
    test "both missing resolves to current_missing" do
      state =
        MetricRules.classify_comparison_state(%{
          current_readiness: :not_ready,
          comparison_readiness: :not_ready,
          comparable: true,
          comparison_grain_zero_activity: false,
          current_metric: Decimal.new("10"),
          comparison_metric: Decimal.new("5")
        })

      assert state == :current_missing
    end

    test "ready current with missing comparison resolves to comparison_missing" do
      state =
        MetricRules.classify_comparison_state(%{
          current_readiness: :ready,
          comparison_readiness: :not_ready,
          comparable: true,
          comparison_grain_zero_activity: false,
          current_metric: Decimal.new("10"),
          comparison_metric: Decimal.new("5")
        })

      assert state == :comparison_missing
    end

    test "ready incompatible scopes resolve to not_comparable" do
      current_scope = scope("ZAR", :event)
      comparison_scope = scope("USD", :event)

      refute MetricRules.projections_comparable?(current_scope, comparison_scope)

      state =
        MetricRules.classify_comparison_state(%{
          current_readiness: :ready,
          comparison_readiness: :ready,
          comparable: false,
          comparison_grain_zero_activity: false,
          current_metric: Decimal.new("10"),
          comparison_metric: Decimal.new("5")
        })

      assert state == :not_comparable

      assert MetricRules.derive_comparison_deltas(state, Decimal.new("10"), Decimal.new("5")) ==
               %{absolute_delta: nil, percentage_delta: nil}
    end

    test "zero versus zero resolves to flat_zero before baseline_zero" do
      state =
        MetricRules.classify_comparison_state(%{
          current_readiness: :ready,
          comparison_readiness: :ready,
          comparable: true,
          comparison_grain_zero_activity: false,
          current_metric: Decimal.new("0"),
          comparison_metric: Decimal.new("0")
        })

      assert state == :flat_zero

      assert MetricRules.derive_comparison_deltas(state, Decimal.new("0"), Decimal.new("0")) ==
               %{absolute_delta: Decimal.new("0"), percentage_delta: nil}
    end

    test "positive current with confirmed zero comparison activity resolves to new_activity" do
      state =
        MetricRules.classify_comparison_state(%{
          current_readiness: :ready,
          comparison_readiness: :ready,
          comparable: true,
          comparison_grain_zero_activity: true,
          current_metric: Decimal.new("25"),
          comparison_metric: Decimal.new("0")
        })

      assert state == :new_activity

      assert MetricRules.derive_comparison_deltas(state, Decimal.new("25"), Decimal.new("0")) ==
               %{absolute_delta: Decimal.new("25"), percentage_delta: nil}
    end

    test "zero denominator that is not flat_zero or new_activity resolves to baseline_zero" do
      state =
        MetricRules.classify_comparison_state(%{
          current_readiness: :ready,
          comparison_readiness: :ready,
          comparable: true,
          comparison_grain_zero_activity: false,
          current_metric: Decimal.new("10"),
          comparison_metric: Decimal.new("0")
        })

      assert state == :baseline_zero
    end

    test "non-zero denominator resolves to available with decimal percentage arithmetic" do
      current = Decimal.new("125")
      comparison = Decimal.new("100")

      state =
        MetricRules.classify_comparison_state(%{
          current_readiness: :ready,
          comparison_readiness: :ready,
          comparable: true,
          comparison_grain_zero_activity: false,
          current_metric: current,
          comparison_metric: comparison
        })

      assert state == :available

      assert MetricRules.derive_comparison_deltas(state, current, comparison) == %{
               absolute_delta: Decimal.new("25"),
               percentage_delta: Decimal.new("25.00")
             }
    end

    test "negative net values remain legitimate and are not clamped" do
      current = Decimal.new("-20")
      comparison = Decimal.new("-50")

      state =
        MetricRules.classify_comparison_state(%{
          current_readiness: :ready,
          comparison_readiness: :ready,
          comparable: true,
          comparison_grain_zero_activity: false,
          current_metric: current,
          comparison_metric: comparison
        })

      assert state == :available

      deltas = MetricRules.derive_comparison_deltas(state, current, comparison)
      assert deltas.absolute_delta == Decimal.new("30")
      assert Decimal.equal?(deltas.percentage_delta, Decimal.new("-60"))
    end

    test "not_comparable suppresses percentage evaluation" do
      state = :not_comparable

      assert MetricRules.derive_comparison_deltas(state, Decimal.new("10"), Decimal.new("0")) ==
               %{absolute_delta: nil, percentage_delta: nil}
    end
  end

  defp scope(currency, grain) do
    %{
      currency: currency,
      grain: grain,
      period_scope: :event,
      semantic_version: 1,
      coverage_identity: :complete
    }
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
