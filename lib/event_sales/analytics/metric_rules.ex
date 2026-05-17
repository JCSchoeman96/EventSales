defmodule EventSales.Analytics.MetricRules do
  @moduledoc """
  Deterministic completed-only analytics rules.

  These functions are the source of truth for sold-ticket, completed-revenue,
  status-breakdown, and business-day metric math. Dashboard, cache, and snapshot
  code must delegate to this module instead of recalculating sales rules.
  """

  alias EventSales.Sales.Resources.{Order, OrderItem}

  @type summary :: %{
          total_sold: non_neg_integer(),
          total_revenue: Decimal.t(),
          today_sold: non_neg_integer(),
          today_revenue: Decimal.t(),
          status_breakdown: %{optional(atom()) => non_neg_integer()}
        }

  @zero Decimal.new("0")

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
  def business_date(%DateTime{} = datetime, "Africa/Johannesburg") do
    datetime
    |> DateTime.add(2, :hour)
    |> DateTime.to_date()
    |> then(&{:ok, &1})
  end

  def business_date(%DateTime{} = datetime, timezone) when timezone in ["Etc/UTC", "UTC"] do
    {:ok, DateTime.to_date(datetime)}
  end

  def business_date(%DateTime{} = datetime, timezone) when is_binary(timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> {:ok, DateTime.to_date(shifted)}
      {:error, _reason} -> {:error, :invalid_timezone}
    end
  end

  def business_date(%DateTime{}, _timezone), do: {:error, :invalid_timezone}

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

    rows
    |> Enum.reduce(empty_summary(), fn row, summary ->
      case normalize_row(row) do
        {:ok, order, item} -> add_row(summary, order, item, now, timezone)
        :error -> summary
      end
    end)
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

  defp add_row(summary, %Order{} = order, %OrderItem{} = item, now, timezone) do
    sold = sold_quantity(order, item)
    revenue = completed_revenue(order, item)
    today? = sold > 0 and same_business_date?(order.completed_at, now, timezone)

    summary
    |> add_totals(sold, revenue)
    |> add_today_totals(today?, sold, revenue)
    |> add_status_breakdown(order, item)
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
