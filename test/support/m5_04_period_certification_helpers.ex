# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule EventSales.TestSupport.M5_04PeriodCertificationHelpers do
  @moduledoc """
  Deterministic fixtures and oracle reconciliation for M5-04 G2 certification.

  Financial truth remains `EventAggregator.financial_summaries_for_event_period/2`.
  """

  import ExUnit.Assertions
  require Ash.Query

  alias EventSales.Analytics
  alias EventSales.Analytics.Aggregators.EventAggregator
  alias EventSales.Analytics.MetricRules
  alias EventSales.Analytics.PeriodComparisonReader
  alias EventSales.Analytics.PeriodCoverage
  alias EventSales.Analytics.PeriodProjectionInvalidator
  alias EventSales.Analytics.SnapshotRefresh
  alias EventSales.Analytics.TimeRules
  alias EventSales.Analytics.TimeRules.{ComparisonWindows, Period}
  alias EventSales.Ingestion.HistoricalOrderMutationDetector
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem, Refund, RefundLine}
  alias EventSales.TestSupport.EventDetailCertificationHelpers
  alias EventSales.TestSupport.PeriodCoverageHelpers
  alias EventSales.TestSupport.SalesHelpers

  @comparison_metrics [
    :gross_ticket_quantity,
    :gross_ticket_value,
    :refund_ticket_quantity,
    :refund_ticket_value,
    :net_ticket_quantity,
    :net_ticket_value,
    :average_ticket_value
  ]

  @primitive_sum_metrics [
    :gross_ticket_quantity,
    :gross_ticket_value,
    :refund_ticket_quantity,
    :refund_ticket_value
  ]

  @supported_requests [:today, :yesterday, {:rolling_days, 7}, {:rolling_days, 30}]

  @doc false
  def supported_requests, do: @supported_requests

  @doc false
  def comparison_metrics, do: @comparison_metrics

  @doc false
  def comparison_windows!(request, now) do
    timezone = MetricRules.business_timezone()

    case TimeRules.comparison_windows(timezone, now, request) do
      {:ok, windows} -> windows
      {:error, reason} -> flunk("comparison_windows!: #{inspect(reason)}")
    end
  end

  @doc false
  def oracle_summary!(event_id, %Period{} = period, currency) do
    case EventAggregator.financial_summaries_for_event_period(event_id, period) do
      {:ok, summaries} ->
        Map.get(summaries, currency) || zero_financial_summary(currency)

      {:error, reason} ->
        flunk("oracle_summary!: #{inspect(reason)}")
    end
  end

  @doc false
  def oracle_summary_for_operand!(event_id, %ComparisonWindows{} = windows, operand, currency) do
    period = financial_oracle_period(windows, operand)
    oracle_summary!(event_id, period, currency)
  end

  @doc false
  def financial_oracle_period(%ComparisonWindows{} = windows, operand) do
    timezone = MetricRules.business_timezone()
    comparison_period = if operand == :current, do: windows.current, else: windows.previous

    case windows.request do
      :yesterday ->
        period_fields(comparison_period, :yesterday, timezone)

      {:rolling_days, days} ->
        period_fields(comparison_period, {:rolling_days, days}, nil)

      :today ->
        case operand do
          :current ->
            {:ok, today} = TimeRules.today_bounds(timezone, windows.captured_now_utc)
            today

          :previous ->
            windows.previous
        end
    end
  end

  @doc false
  def oracle_operand_supported?(
        event_id,
        %ComparisonWindows{request: :today} = windows,
        :previous,
        _currency
      ) do
    period = financial_oracle_period(windows, :previous)

    candidate = %Period{
      start_utc: period.start_utc,
      end_utc: period.end_utc,
      kind: :yesterday,
      timezone: MetricRules.business_timezone()
    }

    case EventAggregator.financial_summaries_for_event_period(event_id, candidate) do
      {:ok, _} -> true
      _ -> false
    end
  end

  def oracle_operand_supported?(_event_id, _windows, _operand, _currency), do: true

  @doc false
  def prepare_analytics_ready_event!(source, attrs \\ %{}) do
    event = SalesHelpers.create_event!(source, Map.merge(%{name: "M5-04 cert event"}, attrs))
    EventDetailCertificationHelpers.certify_analytics_ready!(event)
    PeriodCoverageHelpers.seed_v2_currency!(event, "ZAR")
    event
  end

  @doc false
  def seed_currency!(event, currency) when is_binary(currency) do
    PeriodCoverageHelpers.seed_v2_currency!(event, currency)
  end

  @doc false
  def refresh_period_projections!(event_id, now) do
    assert {:ok, _} =
             PeriodCoverage.ensure_event_buckets(event_id, now, enqueue_refresh?: false)

    assert {:ok, _} =
             SnapshotRefresh.refresh_event(event_id, now: now, refreshed_at: now)
  end

  @doc false
  def capture_order_snapshot!(order) do
    assert {:ok, snapshot} = HistoricalOrderMutationDetector.capture(order)
    snapshot
  end

  @doc false
  def invalidate_order_change!(before_snapshot, after_snapshot) do
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               PeriodProjectionInvalidator.invalidate_order_change(
                 before_snapshot,
                 after_snapshot
               )
             end)
  end

  @doc false
  def invalidate_refund_change!(before_snapshot, after_snapshot) do
    assert {:ok, :ok} =
             Repo.transaction(fn ->
               PeriodProjectionInvalidator.invalidate_refund_change(
                 before_snapshot,
                 after_snapshot
               )
             end)
  end

  @doc false
  def create_completed_sale!(
        source,
        event,
        ticket,
        paid_at,
        overrides \\ %{}
      ) do
    overrides = Map.new(overrides)
    currency = Map.get(overrides, :currency, "ZAR")
    qty = Map.get(overrides, :quantity, 1)
    line_total = Map.get(overrides, :line_total, Decimal.new("100.00"))
    line_tax = Map.get(overrides, :line_tax, Decimal.new("15.00"))
    woo_line = Map.get(overrides, :woo_line_item_id, System.unique_integer([:positive]))
    woo_product = Map.get(overrides, :woo_product_id, 81_001)
    woo_variation = Map.get(overrides, :woo_variation_id, 81_002)

    order =
      Ash.create!(
        Order,
        %{
          source_system_id: source.id,
          woo_order_id: System.unique_integer([:positive]),
          order_number: "m5-04-#{System.unique_integer([:positive])}",
          status: Map.get(overrides, :status, :completed),
          currency: currency,
          paid_at: paid_at,
          completed_at: Map.get(overrides, :completed_at),
          created_at_source: DateTime.add(paid_at, -3600, :second),
          updated_at_source: paid_at,
          raw_total: Decimal.add(line_total, line_tax),
          raw_discount_total: Decimal.new("0"),
          raw_tax_total: line_tax
        },
        action: :create_normalized,
        domain: Sales
      )

    item =
      Ash.create!(
        OrderItem,
        %{
          order_id: order.id,
          event_id: event.id,
          ticket_type_id: ticket.id,
          woo_line_item_id: woo_line,
          woo_product_id: woo_product,
          woo_variation_id: woo_variation,
          name: "Cert ticket",
          quantity: qty,
          line_subtotal: line_total,
          line_total: line_total,
          line_total_tax: line_tax,
          discount_total: Decimal.new("0"),
          item_kind: :ticket,
          mapping_status: :mapped
        },
        action: :create_normalized,
        domain: Sales
      )

    {order, item}
  end

  @doc false
  def create_qualifying_refund!(
        source,
        order,
        item,
        source_created_at,
        overrides \\ %{}
      ) do
    overrides = Map.new(overrides)
    refunded_qty = Map.get(overrides, :refunded_quantity, 1)
    refund_total = Map.get(overrides, :refund_total_amount, Decimal.new("10.00"))
    refund_tax = Map.get(overrides, :refund_total_tax, Decimal.new("2.00"))

    refund =
      Ash.create!(
        Refund,
        %{
          source_system_id: source.id,
          order_id: order.id,
          woo_order_id: order.woo_order_id,
          woo_refund_id: System.unique_integer([:positive]),
          currency: order.currency,
          source_state: Map.get(overrides, :source_state, :active),
          detail_status: Map.get(overrides, :detail_status, :complete),
          summary_total_amount: Decimal.add(refund_total, refund_tax),
          header_amount: Map.get(overrides, :header_amount, Decimal.new("0")),
          shipping_refund_amount: Decimal.new("0"),
          shipping_refund_tax: Decimal.new("0"),
          fee_refund_amount: Decimal.new("0"),
          fee_refund_tax: Decimal.new("0"),
          unallocated_header_amount: Decimal.new("0"),
          source_created_at: source_created_at
        },
        action: :create_normalized,
        domain: Sales
      )

    line =
      Ash.create!(
        RefundLine,
        %{
          refund_id: refund.id,
          order_item_id: item.id,
          woo_refund_line_item_id: System.unique_integer([:positive]),
          woo_refunded_item_id: item.woo_line_item_id,
          woo_product_id: item.woo_product_id,
          woo_variation_id: item.woo_variation_id,
          refunded_quantity: refunded_qty,
          refund_subtotal_amount: refund_total,
          refund_total_amount: refund_total,
          refund_total_tax: refund_tax,
          binding_reason: Map.get(overrides, :binding_reason),
          validation_reason: Map.get(overrides, :validation_reason)
        },
        action: :create_normalized,
        domain: Sales
      )

    {refund, line}
  end

  @doc false
  def ingest_sale_and_refresh!(
        event,
        before_snapshot,
        source,
        ticket,
        paid_at,
        now,
        overrides \\ %{}
      ) do
    overrides = Map.new(overrides)
    {order, item} = create_completed_sale!(source, event, ticket, paid_at, overrides)
    after_snapshot = capture_order_snapshot!(order)
    invalidate_order_change!(before_snapshot, after_snapshot)
    refresh_period_projections!(event.id, now)
    {order, item, after_snapshot}
  end

  @doc false
  def compare_event!(event_id, currency, request, actor, now) do
    case PeriodComparisonReader.compare_event(event_id, currency, request, actor: actor, now: now) do
      {:ok, result} -> result
      {:error, reason} -> flunk("compare_event!: #{inspect(reason)}")
    end
  end

  @doc false
  def assert_reader_operands_match_oracle!(
        event_id,
        currency,
        request,
        actor,
        %DateTime{} = now
      ) do
    windows = comparison_windows!(request, now)
    result = compare_event!(event_id, currency, request, actor, now)

    assert result.current.readiness == :ready
    assert result.comparison.readiness == :ready

    assert_operand_metrics_match_oracle!(
      event_id,
      currency,
      windows,
      :current,
      result.current.metrics
    )

    assert_operand_metrics_match_oracle!(
      event_id,
      currency,
      windows,
      :previous,
      result.comparison.metrics
    )

    result
  end

  @doc false
  def assert_operand_metrics_match_oracle!(event_id, currency, windows, operand, reader_metrics) do
    if windows.request == :today and operand == :previous and
         not oracle_operand_supported?(event_id, windows, operand, currency) do
      :ok
    else
      do_assert_operand_metrics_match_oracle!(
        event_id,
        currency,
        windows,
        operand,
        reader_metrics
      )
    end
  end

  defp do_assert_operand_metrics_match_oracle!(
         event_id,
         currency,
         windows,
         operand,
         reader_metrics
       ) do
    oracle = oracle_summary_for_operand!(event_id, windows, operand, currency)

    for metric <- @comparison_metrics do
      reader_value = Map.fetch!(reader_metrics, metric)
      oracle_value = Map.fetch!(oracle, metric)

      assert decimal_equal?(reader_value, oracle_value),
             "metric #{metric} reader #{inspect(reader_value)} oracle #{inspect(oracle_value)}"
    end
  end

  @doc false
  def assert_dimensional_sums_match_event!(result, dimension_kind) do
    rows = Map.fetch!(result.dimensions, dimension_kind)

    if rows == [] do
      :ok
    else
      for metric <- @primitive_sum_metrics do
        dimensional_sum =
          rows
          |> Enum.map(fn row -> Map.fetch!(row.metric_comparisons, metric).current end)
          |> sum_decimals()

        event_current = Map.fetch!(result.current.metrics, metric)

        assert decimal_equal?(dimensional_sum, event_current),
               "#{dimension_kind} #{metric} sum #{inspect(dimensional_sum)} != event #{inspect(event_current)}"
      end
    end
  end

  @doc false
  def assert_variation_subset_matches_facts!(event_id, currency, windows, result) do
    variation_rows = result.dimensions.source_variation

    if variation_rows == [] do
      :ok
    else
      oracle_variation_gross =
        variation_contribution_sum(event_id, currency, windows.current, :gross)

      reader_variation_gross =
        variation_rows
        |> Enum.map(&Map.fetch!(&1.metric_comparisons, :gross_ticket_quantity).current)
        |> sum_decimals()

      assert decimal_equal?(oracle_variation_gross, reader_variation_gross)
    end
  end

  defp variation_contribution_sum(event_id, currency, period, :gross) do
    alias EventSales.Analytics.Resources.AnalyticsContributionFact

    AnalyticsContributionFact
    |> Ash.Query.filter(
      event_id == ^event_id and currency == ^currency and
        effective_at >= ^period.start_utc and effective_at < ^period.end_utc and
        not is_nil(woo_variation_id) and woo_variation_id > 0
    )
    |> Ash.read!(domain: Analytics)
    |> Enum.reduce(Decimal.new("0"), fn row, acc ->
      Decimal.add(acc, Decimal.new(row.gross_ticket_quantity))
    end)
  end

  @doc false
  def contribution_semantic_fingerprint(event_id) do
    alias EventSales.Analytics.Resources.AnalyticsContributionFact

    AnalyticsContributionFact
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.Query.sort([
      :contribution_kind,
      :source_contribution_id,
      :currency,
      :effective_at,
      :ticket_type_id
    ])
    |> Ash.read!(domain: Analytics)
    |> Enum.map(fn row ->
      %{
        kind: row.contribution_kind,
        source_id: row.source_contribution_id,
        currency: row.currency,
        effective_at: row.effective_at,
        gross_q: row.gross_ticket_quantity,
        gross_v: decimal_string(row.gross_ticket_value),
        refund_q: row.refund_ticket_quantity,
        refund_v: decimal_string(row.refund_ticket_value),
        generation_id: row.generation_id,
        semantic_version: row.semantic_version,
        coverage_identity: row.coverage_identity
      }
    end)
  end

  @doc false
  def period_bucket_semantic_fingerprint(event_id) do
    alias EventSales.Analytics.Resources.EventPeriodAggregateSnapshot

    EventPeriodAggregateSnapshot
    |> Ash.Query.filter(event_id == ^event_id and projection_state == :current)
    |> Ash.Query.sort([:currency, :bucket_kind, :bucket_start_utc])
    |> Ash.read!(domain: Analytics)
    |> Enum.map(fn row ->
      %{
        currency: row.currency,
        bucket_kind: row.bucket_kind,
        start: row.bucket_start_utc,
        end: row.bucket_end_utc,
        gross_q: row.gross_ticket_quantity,
        gross_v: decimal_string(row.gross_ticket_value),
        refund_q: row.refund_ticket_quantity,
        refund_v: decimal_string(row.refund_ticket_value),
        generation_id: row.generation_id,
        semantic_version: row.semantic_version,
        coverage_identity: row.coverage_identity,
        projection_state: row.projection_state
      }
    end)
  end

  defp decimal_string(%Decimal{} = d), do: Decimal.normalize(d) |> Decimal.to_string(:normal)
  defp decimal_string(nil), do: "0"

  defp sum_decimals(values) do
    Enum.reduce(values, Decimal.new("0"), fn value, acc ->
      Decimal.add(acc, value || Decimal.new("0"))
    end)
  end

  defp decimal_equal?(left, right) do
    Decimal.equal?(normalize(left), normalize(right))
  end

  defp normalize(%Decimal{} = d), do: Decimal.normalize(d)
  defp normalize(nil), do: Decimal.new("0")
  defp normalize(n) when is_integer(n), do: Decimal.new(n)

  defp period_fields(%Period{} = period, kind, timezone) do
    %Period{
      start_utc: period.start_utc,
      end_utc: period.end_utc,
      kind: kind,
      timezone: timezone
    }
  end

  defp zero_financial_summary(currency) do
    primitives = EventSales.Sales.FinancialPrimitives.empty_totals()

    {:ok, summary} = MetricRules.financial_summary(currency, primitives, 0)
    summary
  end
end
