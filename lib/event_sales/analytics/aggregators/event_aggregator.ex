defmodule EventSales.Analytics.Aggregators.EventAggregator do
  @moduledoc """
  Event-scoped analytics aggregation.

  Canonical financial metrics use bounded PostgreSQL aggregation partitioned by
  currency and `EventSales.Analytics.MetricRules.financial_summary/3`.

  Legacy `summary_for_event/2` remains a compatibility surface for scalar
  dashboards and operational context.
  """

  import Ecto.Query

  alias EventSales.Analytics.MetricRules
  alias EventSales.Repo
  alias EventSales.Sales.FinancialPrimitives

  @type financial_summaries :: %{String.t() => MetricRules.financial_summary()}

  @doc """
  Returns canonical financial summaries keyed by currency for one event.

  Gross and refund primitives are aggregated in separate queries to avoid join
  multiplication between order lines and refund lines.
  """
  @spec financial_summaries_for_event(Ecto.UUID.t()) ::
          {:ok, financial_summaries()} | {:error, term()}
  def financial_summaries_for_event(event_id) when is_binary(event_id) do
    with {:ok, event_id} <- cast_event_id(event_id),
         :ok <- assert_gross_lines_complete(event_id) do
      gross_rows = Repo.all(gross_aggregate_query(event_id))
      refund_rows = Repo.all(refund_aggregate_query(event_id))
      order_count_rows = Repo.all(recognised_order_count_query(event_id))

      build_financial_summaries(event_id, gross_rows, refund_rows, order_count_rows)
    end
  end

  @doc """
  Summarizes event-scoped metrics for legacy dashboard compatibility.

  `total_sold` and `total_revenue` use bounded completed-only PostgreSQL
  aggregation (`status == completed`, mapped ticket, positive quantity,
  ex-tax `line_total`). They do not use canonical historical gross.

  Operational `status_breakdown` and today buckets use separate bounded queries.
  Mixed currency on completed legacy sales returns `{:error, :mixed_currency}`.
  """
  @spec summary_for_event(Ecto.UUID.t(), keyword()) ::
          {:ok, MetricRules.summary()} | {:error, term()}
  def summary_for_event(event_id, opts \\ []) when is_binary(event_id) do
    with {:ok, event_id} <- cast_event_id(event_id) do
      case Repo.all(legacy_completed_currencies_query(event_id)) do
        [] ->
          {:ok, legacy_empty_summary(event_id, opts)}

        [currency] ->
          {:ok, legacy_summary_for_currency(event_id, currency, opts)}

        _ ->
          {:error, :mixed_currency}
      end
    end
  end

  defp cast_event_id(event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, uuid} -> {:ok, Ecto.UUID.dump!(uuid)}
      :error -> {:error, :invalid_event_id}
    end
  end

  defp assert_gross_lines_complete(event_id) do
    query =
      from oi in "sales_order_items",
        join: o in "sales_orders",
        on: oi.order_id == o.id,
        where:
          oi.event_id == ^event_id and
            (o.status == "completed" or not is_nil(o.completed_at)) and
            oi.mapping_status == "mapped" and oi.item_kind == "ticket" and oi.quantity > 0 and
            (is_nil(oi.line_total) or is_nil(oi.line_total_tax)),
        select: 1,
        limit: 1

    if Repo.one(query), do: {:error, :incomplete_financial_primitives}, else: :ok
  end

  defp gross_aggregate_query(event_id) do
    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where:
        oi.event_id == ^event_id and
          (o.status == "completed" or not is_nil(o.completed_at)) and
          oi.mapping_status == "mapped" and oi.item_kind == "ticket" and oi.quantity > 0,
      group_by: o.currency,
      select:
        {o.currency, sum(oi.quantity), sum(fragment("? + ?", oi.line_total, oi.line_total_tax))}
  end

  defp event_ticket_items_subquery(event_id) do
    from oi in "sales_order_items",
      where:
        oi.event_id == ^event_id and oi.mapping_status == "mapped" and oi.item_kind == "ticket",
      select: %{id: oi.id, order_id: oi.order_id, woo_line_item_id: oi.woo_line_item_id}
  end

  defp refund_primitives_filters do
    dynamic(
      [rl, r, o],
      r.source_state == "active" and r.detail_status == "complete" and
        (o.status == "completed" or not is_nil(o.completed_at)) and
        is_nil(rl.binding_reason) and is_nil(rl.validation_reason) and
        not is_nil(rl.refund_total_amount) and not is_nil(rl.refund_total_tax) and
        fragment("? IS NOT DISTINCT FROM ?", r.currency, o.currency)
    )
  end

  defp refund_aggregate_query(event_id) do
    tickets = event_ticket_items_subquery(event_id)

    from rl in "sales_refund_lines",
      join: r in "sales_refunds",
      on: rl.refund_id == r.id,
      join: o in "sales_orders",
      on: r.order_id == o.id,
      join: parent in "sales_order_items",
      on:
        parent.order_id == o.id and parent.woo_line_item_id == rl.woo_refunded_item_id and
          parent.id == rl.order_item_id,
      join: ticket in subquery(tickets),
      on: ticket.id == parent.id,
      where: ^refund_primitives_filters(),
      group_by: o.currency,
      select:
        {o.currency,
         sum(
           fragment(
             "CASE WHEN ? > 0 THEN ? ELSE 0 END",
             rl.refunded_quantity,
             rl.refunded_quantity
           )
         ), sum(fragment("? + ?", rl.refund_total_amount, rl.refund_total_tax))}
  end

  defp recognised_order_count_query(event_id) do
    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where:
        oi.event_id == ^event_id and
          (o.status == "completed" or not is_nil(o.completed_at)) and
          oi.mapping_status == "mapped" and oi.item_kind == "ticket" and oi.quantity > 0,
      group_by: o.currency,
      select: {o.currency, count(o.id, :distinct)}
  end

  defp build_financial_summaries(_event_id, gross_rows, refund_rows, order_count_rows) do
    gross_rows
    |> Enum.map(&elem(&1, 0))
    |> Kernel.++(Enum.map(refund_rows, &elem(&1, 0)))
    |> Kernel.++(Enum.map(order_count_rows, &elem(&1, 0)))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.reduce_while({:ok, %{}}, fn currency, {:ok, acc} ->
      case build_financial_summary(currency, gross_rows, refund_rows, order_count_rows) do
        {:ok, summary} -> {:cont, {:ok, Map.put(acc, currency, summary)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_financial_summary(currency, gross_rows, refund_rows, order_count_rows) do
    {gross_qty, gross_val} = row_amounts(gross_rows, currency)
    {refund_qty, refund_val} = row_amounts(refund_rows, currency)
    recognised_order_count = row_count(order_count_rows, currency)

    primitives =
      FinancialPrimitives.empty_totals()
      |> Map.put(:gross_ticket_quantity, gross_qty)
      |> Map.put(:gross_ticket_value, gross_val)
      |> Map.put(:refund_ticket_quantity, refund_qty)
      |> Map.put(:refund_ticket_value, refund_val)

    MetricRules.financial_summary(currency, primitives, recognised_order_count)
  end

  defp row_amounts(rows, currency) do
    case Enum.find(rows, fn {row_currency, _, _} -> row_currency == currency end) do
      {^currency, quantity, value} -> {decimal!(quantity), decimal!(value)}
      _ -> {Decimal.new(0), Decimal.new(0)}
    end
  end

  defp row_count(rows, currency) do
    case Enum.find(rows, fn {row_currency, _} -> row_currency == currency end) do
      {^currency, count} -> count
      _ -> 0
    end
  end

  defp legacy_completed_currencies_query(event_id) do
    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where:
        oi.event_id == ^event_id and o.status == "completed" and
          oi.mapping_status == "mapped" and oi.item_kind == "ticket" and oi.quantity > 0,
      distinct: o.currency,
      order_by: o.currency,
      select: o.currency
  end

  defp legacy_completed_totals_query(event_id) do
    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where:
        oi.event_id == ^event_id and o.status == "completed" and
          oi.mapping_status == "mapped" and oi.item_kind == "ticket" and oi.quantity > 0,
      select: {sum(oi.quantity), sum(oi.line_total)}
  end

  defp legacy_summary_for_currency(event_id, _currency, opts) do
    status_breakdown = status_breakdown_for_event(event_id)
    today = legacy_today_totals(event_id, opts)

    {total_sold, total_revenue} =
      case Repo.one(legacy_completed_totals_query(event_id)) do
        {sold, revenue} -> {int!(sold), decimal!(revenue)}
        nil -> {0, Decimal.new(0)}
      end

    %{
      total_sold: total_sold,
      total_revenue: total_revenue,
      today_sold: today.today_sold,
      today_revenue: today.today_revenue,
      status_breakdown: status_breakdown
    }
  end

  defp legacy_empty_summary(event_id, opts) do
    today = legacy_today_totals(event_id, opts)

    %{
      total_sold: 0,
      total_revenue: Decimal.new(0),
      today_sold: today.today_sold,
      today_revenue: today.today_revenue,
      status_breakdown: status_breakdown_for_event(event_id)
    }
  end

  defp status_breakdown_for_event(event_id) do
    query =
      from oi in "sales_order_items",
        join: o in "sales_orders",
        on: oi.order_id == o.id,
        where: oi.event_id == ^event_id,
        group_by: o.status,
        select: {o.status, count(oi.id)}

    query
    |> Repo.all()
    |> Map.new(fn {status, count} -> {String.to_existing_atom(status), count} end)
  end

  defp legacy_today_totals(event_id, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    timezone = Keyword.get_lazy(opts, :timezone, &MetricRules.business_timezone/0)

    case MetricRules.business_date(now, timezone) do
      {:ok, business_date} ->
        query = legacy_today_query(event_id, business_date, timezone)

        case Repo.one(query) do
          {sold, revenue} ->
            %{today_sold: int!(sold), today_revenue: decimal!(revenue)}

          nil ->
            %{today_sold: 0, today_revenue: Decimal.new(0)}
        end

      {:error, :invalid_timezone} ->
        %{today_sold: 0, today_revenue: Decimal.new(0)}
    end
  end

  defp legacy_today_query(event_id, business_date, "Africa/Johannesburg") do
    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where:
        oi.event_id == ^event_id and o.status == "completed" and
          oi.mapping_status == "mapped" and oi.item_kind == "ticket" and oi.quantity > 0 and
          not is_nil(o.completed_at) and
          fragment("date(? + interval '2 hours') = ?", o.completed_at, ^business_date),
      select: {sum(oi.quantity), sum(oi.line_total)}
  end

  defp legacy_today_query(event_id, business_date, timezone)
       when timezone in ["UTC", "Etc/UTC"] do
    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where:
        oi.event_id == ^event_id and o.status == "completed" and
          oi.mapping_status == "mapped" and oi.item_kind == "ticket" and oi.quantity > 0 and
          not is_nil(o.completed_at) and fragment("date(?) = ?", o.completed_at, ^business_date),
      select: {sum(oi.quantity), sum(oi.line_total)}
  end

  defp legacy_today_query(event_id, business_date, timezone) when is_binary(timezone) do
    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where:
        oi.event_id == ^event_id and o.status == "completed" and
          oi.mapping_status == "mapped" and oi.item_kind == "ticket" and oi.quantity > 0 and
          not is_nil(o.completed_at) and
          fragment("date(? AT TIME ZONE ?) = ?", o.completed_at, ^timezone, ^business_date),
      select: {sum(oi.quantity), sum(oi.line_total)}
  end

  defp decimal!(%Decimal{} = value), do: value
  defp decimal!(value) when is_integer(value), do: Decimal.new(value)
  defp decimal!(nil), do: Decimal.new(0)

  defp decimal_to_nonneg_int(%Decimal{} = value) do
    value
    |> Decimal.round(0)
    |> Decimal.to_integer()
  end

  defp int!(%Decimal{} = value), do: decimal_to_nonneg_int(value)
  defp int!(value) when is_integer(value), do: value
  defp int!(nil), do: 0
end
