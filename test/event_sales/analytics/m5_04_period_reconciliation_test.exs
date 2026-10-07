# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule EventSales.Analytics.M5_04PeriodReconciliationTest do
  @moduledoc """
  M5-04 G2 semantic and dimensional reconciliation against `EventAggregator`.
  """

  use EventSales.DataCase, async: false

  require Ash.Query

  alias EventSales.Accounts
  alias EventSales.Accounts.Resources.{Role, User, UserRole}
  alias EventSales.Analytics.Aggregators.EventAggregator
  alias EventSales.Analytics.MetricRules
  alias EventSales.Analytics.PeriodComparisonReader
  alias EventSales.Analytics.Resources.EventPeriodAggregateSnapshot
  alias EventSales.Ingestion.HistoricalOrderMutationDetector
  alias EventSales.Sales.Resources.Order
  alias EventSales.TestSupport.M5_04PeriodCertificationHelpers, as: Cert
  alias EventSales.TestSupport.SalesHelpers

  @now ~U[2026-05-17 10:17:33.000000Z]
  @yesterday_sale ~U[2026-05-16 08:00:00.000000Z]
  @today_refund ~U[2026-05-17 08:00:00.000000Z]
  @rolling_sale ~U[2026-05-12 12:00:00.000000Z]

  setup do
    source = SalesHelpers.create_source_system!()
    event = Cert.prepare_analytics_ready_event!(source)
    ticket_a = SalesHelpers.create_ticket_type!(event, %{name: "GA-A"})
    ticket_b = SalesHelpers.create_ticket_type!(event, %{name: "GA-B"})
    admin = admin_user!()

    %{
      source: source,
      event: event,
      ticket_a: ticket_a,
      ticket_b: ticket_b,
      admin: admin
    }
  end

  describe "event-level oracle reconciliation" do
    @tag :m5_04_semantic
    test "sale-only reconciles for all supported requests", ctx do
      {_order, _item, snap} =
        Cert.ingest_sale_and_refresh!(
          ctx.event,
          nil,
          ctx.source,
          ctx.ticket_a,
          @yesterday_sale,
          @now,
          line_total: Decimal.new("80.00"),
          line_tax: Decimal.new("12.00")
        )

      for request <- [:yesterday, {:rolling_days, 7}, {:rolling_days, 30}, :today] do
        Cert.assert_reader_operands_match_oracle!(
          ctx.event.id,
          "ZAR",
          request,
          ctx.admin,
          @now
        )
      end

      assert snap != nil
    end

    test "sale plus same-period refund reconciles yesterday", ctx do
      {order, item, order_snap} =
        Cert.ingest_sale_and_refresh!(
          ctx.event,
          nil,
          ctx.source,
          ctx.ticket_a,
          @yesterday_sale,
          @now
        )

      {_refund, _line} =
        Cert.create_qualifying_refund!(ctx.source, order, item, @yesterday_sale)

      after_snap = Cert.capture_order_snapshot!(order)
      Cert.invalidate_order_change!(order_snap, after_snap)
      Cert.refresh_period_projections!(ctx.event.id, @now)

      result =
        Cert.assert_reader_operands_match_oracle!(
          ctx.event.id,
          "ZAR",
          :yesterday,
          ctx.admin,
          @now
        )

      assert Decimal.compare(result.current.metrics.refund_ticket_quantity, Decimal.new("0")) ==
               :gt
    end

    test "late refund stays in refund period and preserves historical gross", ctx do
      {order, item, order_snap} =
        Cert.ingest_sale_and_refresh!(
          ctx.event,
          nil,
          ctx.source,
          ctx.ticket_a,
          @yesterday_sale,
          @now
        )

      Cert.create_qualifying_refund!(ctx.source, order, item, @today_refund)
      after_snap = Cert.capture_order_snapshot!(order)
      Cert.invalidate_order_change!(order_snap, after_snap)
      Cert.refresh_period_projections!(ctx.event.id, @now)

      windows = Cert.comparison_windows!(:yesterday, @now)

      yesterday_gross =
        Cert.oracle_summary_for_operand!(ctx.event.id, windows, :current, "ZAR").gross_ticket_value

      today_windows = Cert.comparison_windows!(:today, @now)

      today_refund =
        Cert.oracle_summary_for_operand!(ctx.event.id, today_windows, :current, "ZAR").refund_ticket_value

      assert Decimal.compare(yesterday_gross, Decimal.new("0")) == :gt
      assert Decimal.compare(today_refund, Decimal.new("0")) == :gt

      Cert.assert_reader_operands_match_oracle!(
        ctx.event.id,
        "ZAR",
        :yesterday,
        ctx.admin,
        @now
      )

      Cert.assert_reader_operands_match_oracle!(ctx.event.id, "ZAR", :today, ctx.admin, @now)
    end

    test "value-only refund and negative net reconcile on rolling 7", ctx do
      {order, item, order_snap} =
        Cert.ingest_sale_and_refresh!(
          ctx.event,
          nil,
          ctx.source,
          ctx.ticket_a,
          @rolling_sale,
          @now,
          quantity: 2,
          line_total: Decimal.new("40.00"),
          line_tax: Decimal.new("6.00")
        )

      Cert.create_qualifying_refund!(
        ctx.source,
        order,
        item,
        @rolling_sale,
        refunded_quantity: 0,
        refund_total_amount: Decimal.new("50.00"),
        refund_total_tax: Decimal.new("7.50")
      )

      after_snap = Cert.capture_order_snapshot!(order)
      Cert.invalidate_order_change!(order_snap, after_snap)
      Cert.refresh_period_projections!(ctx.event.id, @now)

      result =
        Cert.assert_reader_operands_match_oracle!(
          ctx.event.id,
          "ZAR",
          {:rolling_days, 7},
          ctx.admin,
          @now
        )

      assert Decimal.compare(result.current.metrics.net_ticket_value, Decimal.new("0")) == :lt
    end

    test "zero activity rolling 30 after coverage materialization", ctx do
      Cert.refresh_period_projections!(ctx.event.id, @now)

      Cert.assert_reader_operands_match_oracle!(
        ctx.event.id,
        "ZAR",
        {:rolling_days, 30},
        ctx.admin,
        @now
      )
    end

    test "multiple currencies reconcile independently", ctx do
      Cert.seed_currency!(ctx.event, "USD")

      Cert.ingest_sale_and_refresh!(
        ctx.event,
        nil,
        ctx.source,
        ctx.ticket_a,
        @yesterday_sale,
        @now,
        currency: "ZAR"
      )

      Cert.ingest_sale_and_refresh!(
        ctx.event,
        nil,
        ctx.source,
        ctx.ticket_b,
        @yesterday_sale,
        @now,
        currency: "USD",
        line_total: Decimal.new("25.00"),
        line_tax: Decimal.new("0")
      )

      for currency <- ["ZAR", "USD"] do
        Cert.assert_reader_operands_match_oracle!(
          ctx.event.id,
          currency,
          :yesterday,
          ctx.admin,
          @now
        )
      end
    end

    test "half-open sale boundaries match oracle", ctx do
      windows = Cert.comparison_windows!(:yesterday, @now)
      start = windows.current.start_utc
      ending = windows.current.end_utc

      Cert.ingest_sale_and_refresh!(
        ctx.event,
        nil,
        ctx.source,
        ctx.ticket_a,
        start,
        @now,
        line_total: Decimal.new("10.00"),
        line_tax: Decimal.new("1.00")
      )

      Cert.ingest_sale_and_refresh!(
        ctx.event,
        nil,
        ctx.source,
        ctx.ticket_b,
        ending,
        @now,
        line_total: Decimal.new("20.00"),
        line_tax: Decimal.new("2.00")
      )

      summary = Cert.oracle_summary_for_operand!(ctx.event.id, windows, :current, "ZAR")
      assert summary.gross_ticket_quantity == Decimal.new("1")

      Cert.assert_reader_operands_match_oracle!(
        ctx.event.id,
        "ZAR",
        :yesterday,
        ctx.admin,
        @now
      )
    end

    test "completed then refunded status retains gross in sale period", ctx do
      {order, _item, snap} =
        Cert.ingest_sale_and_refresh!(
          ctx.event,
          nil,
          ctx.source,
          ctx.ticket_a,
          @yesterday_sale,
          @now
        )

      EventSales.Repo.query!(
        "UPDATE sales_orders SET status = 'refunded' WHERE id = $1::text::uuid",
        [order.id]
      )

      order = Ash.get!(Order, order.id, domain: EventSales.Sales)
      after_snap = Cert.capture_order_snapshot!(order)
      Cert.invalidate_order_change!(snap, after_snap)
      Cert.refresh_period_projections!(ctx.event.id, @now)

      Cert.assert_reader_operands_match_oracle!(
        ctx.event.id,
        "ZAR",
        :yesterday,
        ctx.admin,
        @now
      )
    end

    test "missing sale effective clock fails closed on reader", ctx do
      Cert.refresh_period_projections!(ctx.event.id, @now)

      order =
        Ash.create!(
          Order,
          %{
            source_system_id: ctx.source.id,
            woo_order_id: System.unique_integer([:positive]),
            order_number: "clockless-#{System.unique_integer([:positive])}",
            status: :completed,
            currency: "ZAR",
            paid_at: nil,
            completed_at: nil,
            created_at_source: @yesterday_sale,
            updated_at_source: @yesterday_sale,
            raw_total: Decimal.new("115.00"),
            raw_discount_total: Decimal.new("0"),
            raw_tax_total: Decimal.new("15.00")
          },
          action: :create_normalized,
          domain: EventSales.Sales
        )

      Ash.create!(
        EventSales.Sales.Resources.OrderItem,
        %{
          order_id: order.id,
          event_id: ctx.event.id,
          ticket_type_id: ctx.ticket_a.id,
          woo_line_item_id: System.unique_integer([:positive]),
          woo_product_id: 81_001,
          name: "Clockless",
          quantity: 1,
          line_subtotal: Decimal.new("100.00"),
          line_total: Decimal.new("100.00"),
          line_total_tax: Decimal.new("15.00"),
          discount_total: Decimal.new("0"),
          item_kind: :ticket,
          mapping_status: :mapped
        },
        action: :create_normalized,
        domain: EventSales.Sales
      )

      after_snap = Cert.capture_order_snapshot!(order)
      Cert.invalidate_order_change!(nil, after_snap)
      Cert.refresh_period_projections!(ctx.event.id, @now)

      {:ok, yesterday} =
        EventSales.Analytics.TimeRules.yesterday_bounds(
          MetricRules.business_timezone(),
          @now
        )

      assert {:error, :missing_sale_effective_time} =
               EventAggregator.financial_summaries_for_event_period(ctx.event.id, yesterday)
    end
  end

  describe "dimensional reconciliation" do
    test "ticket_type and source_product sums match event totals", ctx do
      ticket_b = ctx.ticket_b

      Cert.ingest_sale_and_refresh!(
        ctx.event,
        nil,
        ctx.source,
        ctx.ticket_a,
        @yesterday_sale,
        @now,
        woo_product_id: 91_001,
        line_total: Decimal.new("30.00"),
        line_tax: Decimal.new("4.50")
      )

      Cert.ingest_sale_and_refresh!(
        ctx.event,
        nil,
        ctx.source,
        ticket_b,
        @yesterday_sale,
        @now,
        woo_product_id: 91_002,
        line_total: Decimal.new("20.00"),
        line_tax: Decimal.new("3.00")
      )

      result =
        Cert.assert_reader_operands_match_oracle!(
          ctx.event.id,
          "ZAR",
          :yesterday,
          ctx.admin,
          @now
        )

      Cert.assert_dimensional_sums_match_event!(result, :ticket_type)
      Cert.assert_dimensional_sums_match_event!(result, :source_product)
    end

    test "source_variation reconciles variation-bearing subset only", ctx do
      variation_ticket =
        SalesHelpers.create_variation_ticket_type!(ctx.event, 92_001, 92_101, %{name: "Var"})

      Cert.ingest_sale_and_refresh!(
        ctx.event,
        nil,
        ctx.source,
        variation_ticket,
        @yesterday_sale,
        @now,
        woo_product_id: 92_001,
        woo_variation_id: 92_101
      )

      Cert.ingest_sale_and_refresh!(
        ctx.event,
        nil,
        ctx.source,
        ctx.ticket_a,
        @yesterday_sale,
        @now,
        woo_product_id: 92_002,
        woo_variation_id: nil
      )

      windows = Cert.comparison_windows!(:yesterday, @now)

      result =
        Cert.assert_reader_operands_match_oracle!(
          ctx.event.id,
          "ZAR",
          :yesterday,
          ctx.admin,
          @now
        )

      Cert.assert_variation_subset_matches_facts!(
        ctx.event.id,
        "ZAR",
        windows,
        result
      )
    end
  end

  describe "JC-310 comparison states via reader" do
    test "seven-state matrix regression suite remains the reader authority" do
      assert File.exists?("test/event_sales/analytics/period_comparison_reader_matrix_test.exs")
    end
  end

  defp reset_period_snapshots!(event_id) do
    import Ecto.Query

    alias EventSales.Analytics.Resources.{
      AnalyticsContributionFact,
      EventDimensionPeriodAggregateSnapshot,
      EventPeriodAggregateSnapshot
    }

    EventSales.Repo.delete_all(
      from(f in AnalyticsContributionFact, where: f.event_id == ^event_id)
    )

    EventSales.Repo.delete_all(
      from(s in EventDimensionPeriodAggregateSnapshot, where: s.event_id == ^event_id)
    )

    EventSales.Repo.delete_all(
      from(s in EventPeriodAggregateSnapshot, where: s.event_id == ^event_id)
    )
  end

  defp assert_state!(ctx, expected) do
    assert {:ok, result} =
             PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :yesterday,
               actor: ctx.admin,
               now: @now
             )

    assert result.event.metric_comparisons.gross_ticket_quantity.state == expected
  end

  defp assert_net_state!(ctx, expected) do
    assert {:ok, result} =
             PeriodComparisonReader.compare_event(ctx.event.id, "ZAR", :yesterday,
               actor: ctx.admin,
               now: @now
             )

    assert result.event.metric_comparisons.net_ticket_quantity.state == expected
  end

  defp stale_current!(event_id) do
    row =
      EventPeriodAggregateSnapshot
      |> Ash.Query.filter(
        event_id == ^event_id and currency == ^"ZAR" and projection_state == :current
      )
      |> Ash.Query.sort(bucket_start_utc: :desc)
      |> Ash.read!(domain: EventSales.Analytics)
      |> hd()

    Ash.update!(row, %{projection_state: :stale},
      action: :update_snapshot,
      domain: EventSales.Analytics
    )
  end

  defp stale_previous!(event_id) do
    rows =
      EventPeriodAggregateSnapshot
      |> Ash.Query.filter(event_id == ^event_id and projection_state == :current)
      |> Ash.Query.sort(asc: :bucket_start_utc)
      |> Ash.read!(domain: EventSales.Analytics)

    Ash.update!(hd(rows), %{projection_state: :refresh_pending},
      action: :update_snapshot,
      domain: EventSales.Analytics
    )
  end

  defp mismatch_coverage!(event_id) do
    row =
      EventPeriodAggregateSnapshot
      |> Ash.Query.filter(event_id == ^event_id and projection_state == :current)
      |> Ash.Query.sort(asc: :bucket_start_utc)
      |> Ash.read_one!(domain: EventSales.Analytics)

    Ash.update!(row, %{coverage_identity: "m5_04_mismatch"},
      action: :update_snapshot,
      domain: EventSales.Analytics
    )
  end

  defp order_item!(order) do
    import Ecto.Query

    EventSales.Repo.one!(
      from oi in "sales_order_items",
        where: oi.order_id == ^order.id,
        select: oi.id,
        limit: 1
    )
    |> then(fn row ->
      Ash.get!(EventSales.Sales.Resources.OrderItem, row.id, domain: EventSales.Sales)
    end)
  end

  defp admin_user! do
    user =
      Ash.create!(
        User,
        %{
          email: "m5-04-cert-#{System.unique_integer()}@example.com",
          name: "M5-04 Cert",
          password: "valid-pass-123",
          password_confirmation: "valid-pass-123"
        },
        action: :register_with_password,
        domain: Accounts
      )

    role =
      Role
      |> Ash.Query.filter(name == ^:admin)
      |> Ash.read_one!(domain: Accounts)
      |> case do
        nil -> Ash.create!(Role, %{name: :admin}, action: :create, domain: Accounts)
        role -> role
      end

    Ash.create!(EventSales.Accounts.Resources.UserRole, %{user_id: user.id, role_id: role.id},
      action: :create,
      domain: Accounts
    )

    user
  end
end
