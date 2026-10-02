defmodule EventSales.Analytics.MetricRules do
  @moduledoc """
  Analytics metric facade for dashboard, cache, and snapshot code.

  Canonical financial arithmetic lives in `EventSales.Sales.FinancialPrimitives`.
  This module adds analytics-facing composition, legacy completed-only summaries,
  and business-day bucketing. Legacy `summarize/2`, `counts_as_sold?/2`, and
  `completed_revenue/2` retain their existing completed-only compatibility behavior.
  """

  alias EventSales.Analytics.TimeRules
  alias EventSales.Analytics.TimeRules.Period
  alias EventSales.Sales.FinancialPrimitives
  alias EventSales.Sales.Resources.{Order, OrderItem}

  @type summary :: %{
          total_sold: non_neg_integer(),
          total_revenue: Decimal.t(),
          today_sold: non_neg_integer(),
          today_revenue: Decimal.t(),
          status_breakdown: %{optional(atom()) => non_neg_integer()}
        }

  @type financial_summary :: %{
          currency: String.t(),
          gross_ticket_quantity: Decimal.t(),
          refund_ticket_quantity: Decimal.t(),
          net_ticket_quantity: Decimal.t(),
          gross_ticket_value: Decimal.t(),
          refund_ticket_value: Decimal.t(),
          net_ticket_value: Decimal.t(),
          recognised_order_count: non_neg_integer(),
          average_ticket_value: Decimal.t() | nil
        }

  @zero Decimal.new("0")
  @one_hundred Decimal.new("100")

  @comparison_scope_keys [
    :currency,
    :grain,
    :period_scope,
    :semantic_version,
    :coverage_identity
  ]

  @type comparison_readiness :: :ready | :not_ready

  @type comparison_state ::
          :available
          | :flat_zero
          | :new_activity
          | :baseline_zero
          | :current_missing
          | :comparison_missing
          | :not_comparable

  @type comparison_projection_scope :: %{
          required(:currency) => String.t(),
          required(:grain) => term(),
          required(:period_scope) => term(),
          required(:semantic_version) => term(),
          required(:coverage_identity) => term()
        }

  @type comparison_deltas :: %{
          absolute_delta: Decimal.t() | nil,
          percentage_delta: Decimal.t() | nil
        }

  @additive_primitive_keys [
    :gross_ticket_quantity,
    :refund_ticket_quantity,
    :gross_ticket_value,
    :refund_ticket_value
  ]

  @doc """
  Returns the configured business timezone used for date-bucketed metrics.
  """
  @spec business_timezone() :: String.t()
  def business_timezone do
    Application.fetch_env!(:event_sales, :business_timezone)
  end

  @doc """
  Converts a UTC datetime into a date in the configured business timezone.
  """
  @spec business_date(DateTime.t(), String.t()) :: {:ok, Date.t()} | {:error, :invalid_timezone}
  def business_date(%DateTime{} = datetime, timezone) do
    TimeRules.business_date(datetime, timezone)
  end

  @doc """
  Returns true when both datetimes land on the same business date.
  """
  @spec same_business_date?(DateTime.t() | nil, DateTime.t(), String.t()) :: boolean()
  def same_business_date?(nil, %DateTime{}, _timezone), do: false

  def same_business_date?(%DateTime{} = left, %DateTime{} = right, timezone) do
    with {:ok, left_date} <- business_date(left, timezone),
         {:ok, right_date} <- business_date(right, timezone) do
      Date.compare(left_date, right_date) == :eq
    else
      {:error, :invalid_timezone} -> false
    end
  end

  @doc """
  Returns true when a line item counts toward sold ticket totals.
  """
  @spec counts_as_sold?(Order.t(), OrderItem.t()) :: boolean()
  def counts_as_sold?(%Order{status: :completed}, %OrderItem{} = item) do
    item.mapping_status == :mapped and item.item_kind == :ticket and item.quantity > 0
  end

  def counts_as_sold?(_order, _item), do: false

  @doc """
  Returns the sold ticket quantity for a normalized order line.
  """
  @spec sold_quantity(Order.t(), OrderItem.t()) :: non_neg_integer()
  def sold_quantity(%Order{} = order, %OrderItem{} = item) do
    if counts_as_sold?(order, item), do: item.quantity, else: 0
  end

  @doc """
  Returns completed MVP revenue for a normalized order line.
  """
  @spec completed_revenue(Order.t(), OrderItem.t()) :: Decimal.t()
  def completed_revenue(%Order{} = order, %OrderItem{} = item) do
    if counts_as_sold?(order, item), do: item.line_total, else: @zero
  end

  @doc """
  Returns true when a row should be represented in operational status breakdowns.
  """
  @spec visible_in_status_breakdown?(Order.t(), OrderItem.t()) :: boolean()
  def visible_in_status_breakdown?(%Order{}, %OrderItem{}), do: true
  def visible_in_status_breakdown?(_order, _item), do: false

  @doc """
  Returns the order status bucket used by summaries.
  """
  @spec status_bucket(Order.t()) :: atom()
  def status_bucket(%Order{status: status}), do: status

  @doc """
  Summarizes normalized order/item rows using completed-only metric rules.
  """
  @spec summarize(Enumerable.t(), keyword()) :: summary()
  def summarize(rows, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    timezone = Keyword.get_lazy(opts, :timezone, &business_timezone/0)

    today_period = legacy_today_period(timezone, now)

    rows
    |> Enum.reduce(empty_summary(), fn row, summary ->
      case normalize_row(row) do
        {:ok, order, item} -> add_row(summary, order, item, today_period)
        :error -> summary
      end
    end)
  end

  @doc """
  Derives net ticket metrics and average ticket value from canonical additive primitives.

  Accepts a map containing at least `gross_ticket_quantity`, `refund_ticket_quantity`,
  `gross_ticket_value`, and `refund_ticket_value` as `Decimal` values. Quantities must be
  non-negative and integral; values must be non-negative. Net quantities and values may be
  negative when refunds exceed gross components.
  """
  @spec derive_financial_metrics(map()) ::
          {:ok,
           %{
             gross_ticket_quantity: Decimal.t(),
             refund_ticket_quantity: Decimal.t(),
             net_ticket_quantity: Decimal.t(),
             gross_ticket_value: Decimal.t(),
             refund_ticket_value: Decimal.t(),
             net_ticket_value: Decimal.t(),
             average_ticket_value: Decimal.t() | nil
           }}
          | {:error, :invalid_primitive_totals}
  def derive_financial_metrics(primitives) do
    with :ok <- validate_additive_primitives(primitives),
         {:ok, additive} <- extract_validated_additive(primitives) do
      totals = FinancialPrimitives.derive_net_totals(additive)
      net_quantity = Map.fetch!(totals, :net_ticket_quantity)
      net_value = Map.fetch!(totals, :net_ticket_value)

      {:ok,
       %{
         gross_ticket_quantity: Map.fetch!(additive, :gross_ticket_quantity),
         refund_ticket_quantity: Map.fetch!(additive, :refund_ticket_quantity),
         net_ticket_quantity: net_quantity,
         gross_ticket_value: Map.fetch!(additive, :gross_ticket_value),
         refund_ticket_value: Map.fetch!(additive, :refund_ticket_value),
         net_ticket_value: net_value,
         average_ticket_value: average_ticket_value(net_value, net_quantity)
       }}
    end
  end

  @doc """
  Derives the canonical financial summary for one currency partition.

  Accepts additive gross/refund primitive totals (typically produced by bounded
  aggregation in later slices) plus a distinct recognised-order count for the
  same scope. Net metrics and average ticket value are derived via
  `derive_financial_metrics/1`; they are not persisted here.
  """
  @spec financial_summary(String.t(), FinancialPrimitives.totals(), non_neg_integer()) ::
          {:ok, financial_summary()} | {:error, :invalid_currency | :invalid_primitive_totals}
  def financial_summary(currency, primitive_totals, recognised_order_count)
      when is_integer(recognised_order_count) and recognised_order_count >= 0 do
    with :ok <- validate_currency(currency),
         {:ok, metrics} <- derive_financial_metrics(primitive_totals) do
      {:ok,
       Map.merge(metrics, %{
         currency: currency,
         recognised_order_count: recognised_order_count
       })}
    end
  end

  @doc """
  Returns true when two ready projection scopes share currency, grain, period scope,
  semantic version, and coverage identity.
  """
  @spec projections_comparable?(comparison_projection_scope(), comparison_projection_scope()) ::
          boolean()
  def projections_comparable?(current_scope, comparison_scope)
      when is_map(current_scope) and is_map(comparison_scope) do
    Enum.all?(@comparison_scope_keys, fn key ->
      Map.fetch!(current_scope, key) == Map.fetch!(comparison_scope, key)
    end)
  end

  @doc """
  Classifies a metric comparison using the locked M5-04 precedence (JC-310 Section 10.2).

  Expects:

  * `:current_readiness` and `:comparison_readiness` — `:ready` or `:not_ready`
  * `:comparable` — whether ready projections can be compared (currency/grain/scope/coverage)
  * `:comparison_grain_zero_activity` — confirmed complete zero activity on the comparison grain
  * `:current_metric` and `:comparison_metric` — `Decimal` operands for the selected metric
  """
  @spec classify_comparison_state(map()) :: comparison_state()
  def classify_comparison_state(%{} = input) do
    current_readiness = Map.fetch!(input, :current_readiness)
    comparison_readiness = Map.fetch!(input, :comparison_readiness)
    comparable? = Map.fetch!(input, :comparable)
    comparison_grain_zero_activity? = Map.fetch!(input, :comparison_grain_zero_activity)
    current_metric = Map.fetch!(input, :current_metric)
    comparison_metric = Map.fetch!(input, :comparison_metric)

    cond do
      current_readiness != :ready ->
        :current_missing

      comparison_readiness != :ready ->
        :comparison_missing

      not comparable? ->
        :not_comparable

      Decimal.equal?(current_metric, @zero) and Decimal.equal?(comparison_metric, @zero) ->
        :flat_zero

      comparison_grain_zero_activity? and Decimal.compare(current_metric, @zero) == :gt ->
        :new_activity

      zero_comparison_denominator?(comparison_metric) ->
        :baseline_zero

      true ->
        :available
    end
  end

  @doc """
  Derives absolute and percentage deltas for a classified comparison state.

  Percentage change exists only for `:available` with a non-zero comparison denominator.
  Never returns infinity, NaN, or a fabricated 100% placeholder.
  """
  @spec derive_comparison_deltas(comparison_state(), Decimal.t(), Decimal.t()) ::
          comparison_deltas()
  def derive_comparison_deltas(state, %Decimal{} = current_metric, %Decimal{} = comparison_metric) do
    case state do
      :current_missing ->
        %{absolute_delta: nil, percentage_delta: nil}

      :comparison_missing ->
        %{absolute_delta: nil, percentage_delta: nil}

      :not_comparable ->
        %{absolute_delta: nil, percentage_delta: nil}

      :flat_zero ->
        %{absolute_delta: @zero, percentage_delta: nil}

      :new_activity ->
        %{
          absolute_delta: Decimal.sub(current_metric, comparison_metric),
          percentage_delta: nil
        }

      :baseline_zero ->
        %{
          absolute_delta: Decimal.sub(current_metric, comparison_metric),
          percentage_delta: nil
        }

      :available ->
        absolute = Decimal.sub(current_metric, comparison_metric)

        percentage =
          if zero_comparison_denominator?(comparison_metric) do
            nil
          else
            comparison_metric
            |> then(&Decimal.sub(current_metric, &1))
            |> Decimal.div(comparison_metric)
            |> Decimal.mult(@one_hundred)
          end

        %{absolute_delta: absolute, percentage_delta: percentage}
    end
  end

  defp zero_comparison_denominator?(%Decimal{} = comparison_metric) do
    Decimal.equal?(comparison_metric, @zero)
  end

  defp validate_currency(currency) when is_binary(currency) and byte_size(currency) > 0, do: :ok
  defp validate_currency(_currency), do: {:error, :invalid_currency}

  defp validate_additive_primitives(%{} = totals) do
    if Enum.all?(@additive_primitive_keys, &Map.has_key?(totals, &1)) do
      with :ok <- validate_quantity_primitive(Map.fetch!(totals, :gross_ticket_quantity)),
           :ok <- validate_quantity_primitive(Map.fetch!(totals, :refund_ticket_quantity)),
           :ok <- validate_value_primitive(Map.fetch!(totals, :gross_ticket_value)) do
        validate_value_primitive(Map.fetch!(totals, :refund_ticket_value))
      end
    else
      {:error, :invalid_primitive_totals}
    end
  end

  defp validate_additive_primitives(_totals), do: {:error, :invalid_primitive_totals}

  defp extract_validated_additive(totals) do
    {:ok, Map.take(totals, @additive_primitive_keys)}
  end

  defp validate_quantity_primitive(%Decimal{} = quantity) do
    if FinancialPrimitives.integral_quantity?(quantity),
      do: :ok,
      else: {:error, :invalid_primitive_totals}
  end

  defp validate_quantity_primitive(_quantity), do: {:error, :invalid_primitive_totals}

  defp validate_value_primitive(%Decimal{} = value) do
    if Decimal.compare(value, @zero) == :lt,
      do: {:error, :invalid_primitive_totals},
      else: :ok
  end

  defp validate_value_primitive(_value), do: {:error, :invalid_primitive_totals}

  defp average_ticket_value(net_value, %Decimal{} = net_quantity) do
    if Decimal.equal?(net_quantity, @zero) do
      nil
    else
      Decimal.div(net_value, net_quantity)
    end
  end

  defp empty_summary do
    %{
      total_sold: 0,
      total_revenue: @zero,
      today_sold: 0,
      today_revenue: @zero,
      status_breakdown: %{}
    }
  end

  defp add_row(summary, %Order{} = order, %OrderItem{} = item, today_period) do
    sold = sold_quantity(order, item)
    revenue = completed_revenue(order, item)
    today? = sold > 0 and sale_effective_in_period?(order, today_period)

    summary
    |> add_totals(sold, revenue)
    |> add_today_totals(today?, sold, revenue)
    |> add_status_breakdown(order, item)
  end

  defp legacy_today_period(timezone, now) when is_binary(timezone) do
    case TimeRules.today_bounds(timezone, now) do
      {:ok, period} -> period
      {:error, :invalid_timezone} -> nil
    end
  end

  defp legacy_today_period(_timezone, _now), do: nil

  defp sale_effective_in_period?(_order, nil), do: false

  defp sale_effective_in_period?(%Order{} = order, %Period{} = period) do
    case TimeRules.sale_effective_at(order) do
      {:ok, effective_at} -> TimeRules.period_contains?(period, effective_at)
      {:error, :missing_sale_effective_time} -> false
    end
  end

  defp add_totals(summary, sold, revenue) do
    %{
      summary
      | total_sold: summary.total_sold + sold,
        total_revenue: Decimal.add(summary.total_revenue, revenue)
    }
  end

  defp add_today_totals(summary, true, sold, revenue) do
    %{
      summary
      | today_sold: summary.today_sold + sold,
        today_revenue: Decimal.add(summary.today_revenue, revenue)
    }
  end

  defp add_today_totals(summary, false, _sold, _revenue), do: summary

  defp add_status_breakdown(summary, %Order{} = order, %OrderItem{} = item) do
    if visible_in_status_breakdown?(order, item) do
      bucket = status_bucket(order)

      %{
        summary
        | status_breakdown: Map.update(summary.status_breakdown, bucket, 1, &(&1 + 1))
      }
    else
      summary
    end
  end

  defp normalize_row(%{order: %Order{} = order, item: %OrderItem{} = item}) do
    {:ok, order, item}
  end

  defp normalize_row({%Order{} = order, %OrderItem{} = item}) do
    {:ok, order, item}
  end

  defp normalize_row(%OrderItem{order: %Order{} = order} = item) do
    {:ok, order, item}
  end

  defp normalize_row(_row), do: :error
end
