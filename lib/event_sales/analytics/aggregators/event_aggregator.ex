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
  alias EventSales.Analytics.TimeRules.Period
  alias EventSales.Repo
  alias EventSales.Sales.FinancialPrimitives

  @supported_financial_period_kinds [:today, :yesterday, {:rolling_days, 7}, {:rolling_days, 30}]
  @johannesburg_timezone "Africa/Johannesburg"
  @day_seconds 24 * 60 * 60

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
  Returns canonical financial summaries keyed by currency for one event and reporting period.

  Only supports preset period kinds (`:today`, `:yesterday`, rolling 7d/30d). Gross and refund
  facts are placed by sale-effective `COALESCE(paid_at, completed_at)` and refund
  `source_created_at` respectively inside the half-open UTC window `[start_utc, end_utc)`.
  """
  @spec financial_summaries_for_event_period(Ecto.UUID.t(), Period.t()) ::
          {:ok, financial_summaries()}
          | {:error,
             :invalid_event_id
             | :invalid_period
             | :unsupported_period_kind
             | :missing_sale_effective_time
             | :missing_refund_effective_time
             | :incomplete_financial_primitives}
  def financial_summaries_for_event_period(event_id, %Period{} = period)
      when is_binary(event_id) do
    with {:ok, event_id} <- cast_event_id(event_id),
         :ok <- validate_financial_period(period),
         :ok <- assert_no_missing_sale_effective_time(event_id),
         :ok <- assert_no_missing_refund_effective_time(event_id),
         :ok <- assert_gross_lines_complete_for_period(event_id, period) do
      gross_rows = Repo.all(gross_aggregate_query(event_id, period))
      refund_rows = Repo.all(refund_aggregate_query(event_id, period))
      order_count_rows = Repo.all(recognised_order_count_query(event_id, period))

      build_financial_summaries(event_id, gross_rows, refund_rows, order_count_rows)
    end
  end

  @doc """
  Summarizes event-scoped metrics for legacy dashboard compatibility.

  `total_sold` and `total_revenue` use bounded completed-only PostgreSQL
  aggregation (`status == completed`, mapped ticket, positive quantity,
  ex-tax `line_total`). They do not use canonical historical gross.

  Operational `status_breakdown` and today buckets are derived from the same
  bounded aggregate query as completed totals. Mixed currency on completed legacy
  sales returns `{:error, :mixed_currency}`.
  """
  @spec summary_for_event(Ecto.UUID.t(), keyword()) ::
          {:ok, MetricRules.summary()} | {:error, term()}
  def summary_for_event(event_id, opts \\ []) when is_binary(event_id) do
    with {:ok, event_id} <- cast_event_id(event_id) do
      rows = legacy_summary_aggregate_rows(event_id, opts)

      case legacy_summary_from_aggregate_rows(rows) do
        {:ok, summary} -> {:ok, summary}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Returns operational status row counts for one event.

  Uses the same bounded legacy aggregate query as `summary_for_event/2` but
  does not fail when completed legacy sales span multiple currencies.
  """
  @spec operational_status_breakdown_for_event(Ecto.UUID.t(), keyword()) ::
          {:ok, %{optional(atom()) => non_neg_integer()}} | {:error, term()}
  def operational_status_breakdown_for_event(event_id, opts \\ []) when is_binary(event_id) do
    with {:ok, event_id} <- cast_event_id(event_id) do
      event_id
      |> legacy_summary_aggregate_rows(opts)
      |> status_breakdown_from_aggregate_rows()
      |> then(&{:ok, &1})
    end
  end

  defp status_breakdown_from_aggregate_rows(rows) do
    rows
    |> Enum.group_by(fn {status, _currency, _item_count, _cq, _cr, _tq, _tr} -> status end)
    |> Map.new(fn {status, status_rows} ->
      item_count =
        Enum.reduce(status_rows, 0, fn {_s, _c, count, _cq, _cr, _tq, _tr}, acc ->
          acc + count
        end)

      {String.to_existing_atom(status), item_count}
    end)
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
          ^dynamic(
            [oi, o],
            ^recognised_sale_item_filters(event_id) and
              (is_nil(oi.line_total) or is_nil(oi.line_total_tax))
          ),
        select: 1,
        limit: 1

    if Repo.one(query), do: {:error, :incomplete_financial_primitives}, else: :ok
  end

  defp validate_financial_period(%Period{
         kind: kind,
         start_utc: start_utc,
         end_utc: end_utc,
         timezone: timezone
       }) do
    cond do
      not supported_financial_period_kind?(kind) ->
        {:error, :unsupported_period_kind}

      not valid_utc_period_bounds?(start_utc, end_utc) ->
        {:error, :invalid_period}

      true ->
        validate_supported_period_semantics(kind, start_utc, end_utc, timezone)
    end
  end

  defp validate_supported_period_semantics(:today, start_utc, end_utc, timezone) do
    validate_johannesburg_civil_day_period(start_utc, end_utc, timezone)
  end

  defp validate_supported_period_semantics(:yesterday, start_utc, end_utc, timezone) do
    validate_johannesburg_civil_day_period(start_utc, end_utc, timezone)
  end

  defp validate_supported_period_semantics({:rolling_days, days}, start_utc, end_utc, timezone)
       when days in [7, 30] do
    validate_exact_rolling_period(days, start_utc, end_utc, timezone)
  end

  defp validate_johannesburg_civil_day_period(start_utc, end_utc, timezone) do
    if timezone != @johannesburg_timezone,
      do: {:error, :invalid_period},
      else: validate_johannesburg_civil_shape(start_utc, end_utc)
  end

  defp validate_johannesburg_civil_shape(start_utc, end_utc) do
    case shift_both_to_johannesburg(start_utc, end_utc) do
      {:ok, start_local, end_local} ->
        if johannesburg_civil_day_shape?(start_local, end_local),
          do: :ok,
          else: {:error, :invalid_period}

      :error ->
        {:error, :invalid_period}
    end
  end

  defp shift_both_to_johannesburg(start_utc, end_utc) do
    with {:ok, start_local} <- DateTime.shift_zone(start_utc, @johannesburg_timezone),
         {:ok, end_local} <- DateTime.shift_zone(end_utc, @johannesburg_timezone) do
      {:ok, start_local, end_local}
    else
      _ -> :error
    end
  end

  defp johannesburg_civil_day_shape?(start_local, end_local) do
    local_midnight?(start_local) and local_midnight?(end_local) and
      Date.add(DateTime.to_date(start_local), 1) == DateTime.to_date(end_local)
  end

  defp local_midnight?(%DateTime{} = datetime) do
    datetime.hour == 0 and datetime.minute == 0 and datetime.second == 0 and
      elem(datetime.microsecond, 0) == 0
  end

  defp validate_exact_rolling_period(days, start_utc, end_utc, timezone) do
    if timezone != nil or DateTime.diff(end_utc, start_utc, :second) != days * @day_seconds do
      {:error, :invalid_period}
    else
      :ok
    end
  end

  defp supported_financial_period_kind?(kind) do
    kind in @supported_financial_period_kinds
  end

  defp valid_utc_period_bounds?(%DateTime{} = start_utc, %DateTime{} = end_utc) do
    utc_instant?(start_utc) and utc_instant?(end_utc) and
      DateTime.compare(start_utc, end_utc) == :lt
  end

  defp valid_utc_period_bounds?(_, _), do: false

  defp utc_instant?(%DateTime{time_zone: tz, utc_offset: 0, std_offset: 0})
       when tz in ["Etc/UTC", "UTC"],
       do: true

  defp utc_instant?(_), do: false

  defp assert_no_missing_sale_effective_time(event_id) do
    query =
      from oi in "sales_order_items",
        join: o in "sales_orders",
        on: oi.order_id == o.id,
        where:
          ^dynamic(
            [oi, o],
            ^recognised_sale_item_filters(event_id) and is_nil(o.paid_at) and
              is_nil(o.completed_at)
          ),
        select: 1,
        limit: 1

    if Repo.one(query), do: {:error, :missing_sale_effective_time}, else: :ok
  end

  defp assert_no_missing_refund_effective_time(event_id) do
    tickets = event_ticket_items_subquery(event_id)

    query =
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
        where: ^dynamic([rl, r, o], ^refund_primitives_filters() and is_nil(r.source_created_at)),
        select: 1,
        limit: 1

    if Repo.one(query), do: {:error, :missing_refund_effective_time}, else: :ok
  end

  defp assert_gross_lines_complete_for_period(event_id, %Period{
         start_utc: start_utc,
         end_utc: end_utc
       }) do
    query =
      from oi in "sales_order_items",
        join: o in "sales_orders",
        on: oi.order_id == o.id,
        where:
          ^dynamic(
            [oi, o],
            ^recognised_sale_item_filters(event_id) and
              ^sale_effective_in_period?(start_utc, end_utc) and
              (is_nil(oi.line_total) or is_nil(oi.line_total_tax))
          ),
        select: 1,
        limit: 1

    if Repo.one(query), do: {:error, :incomplete_financial_primitives}, else: :ok
  end

  defp recognised_sale_item_filters(event_id) do
    dynamic(
      [oi, o],
      oi.event_id == ^event_id and
        (o.status == "completed" or not is_nil(o.completed_at)) and
        oi.mapping_status == "mapped" and oi.item_kind == "ticket" and oi.quantity > 0
    )
  end

  defp sale_effective_in_period?(start_utc, end_utc) do
    dynamic(
      [_oi, o],
      fragment(
        "? <= COALESCE(?, ?) AND COALESCE(?, ?) < ?",
        ^start_utc,
        o.paid_at,
        o.completed_at,
        o.paid_at,
        o.completed_at,
        ^end_utc
      )
    )
  end

  defp refund_effective_in_period?(start_utc, end_utc) do
    dynamic(
      [_rl, r, _o],
      fragment("? <= ? AND ? < ?", ^start_utc, r.source_created_at, r.source_created_at, ^end_utc)
    )
  end

  defp gross_aggregate_query(event_id, %Period{start_utc: start_utc, end_utc: end_utc} = _period) do
    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where:
        ^dynamic(
          [oi, o],
          ^recognised_sale_item_filters(event_id) and
            ^sale_effective_in_period?(start_utc, end_utc)
        ),
      group_by: o.currency,
      select:
        {o.currency, sum(oi.quantity), sum(fragment("? + ?", oi.line_total, oi.line_total_tax))}
  end

  defp gross_aggregate_query(event_id) do
    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where: ^recognised_sale_item_filters(event_id),
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

  defp refund_aggregate_query(event_id, %Period{start_utc: start_utc, end_utc: end_utc}) do
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
      where:
        ^dynamic(
          [rl, r, o],
          ^refund_primitives_filters() and ^refund_effective_in_period?(start_utc, end_utc)
        ),
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

  defp recognised_order_count_query(event_id, %Period{start_utc: start_utc, end_utc: end_utc}) do
    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where:
        ^dynamic(
          [oi, o],
          ^recognised_sale_item_filters(event_id) and
            ^sale_effective_in_period?(start_utc, end_utc)
        ),
      group_by: o.currency,
      select: {o.currency, count(o.id, :distinct)}
  end

  defp recognised_order_count_query(event_id) do
    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where: ^recognised_sale_item_filters(event_id),
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

  defp legacy_summary_aggregate_rows(event_id, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    timezone = Keyword.get_lazy(opts, :timezone, &MetricRules.business_timezone/0)

    case MetricRules.business_date(now, timezone) do
      {:ok, business_date} ->
        event_id
        |> legacy_summary_aggregate_query(business_date, timezone)
        |> Repo.all()

      {:error, :invalid_timezone} ->
        event_id
        |> legacy_summary_aggregate_query(nil, timezone)
        |> Repo.all()
    end
  end

  defp legacy_summary_aggregate_query(event_id, nil, _timezone) do
    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where: oi.event_id == ^event_id,
      group_by: [o.status, o.currency],
      select: {
        o.status,
        o.currency,
        count(oi.id),
        sum(
          fragment(
            "CASE WHEN ? = 'completed' AND ? = 'mapped' AND ? = 'ticket' AND ? > 0 THEN ? ELSE 0 END",
            o.status,
            oi.mapping_status,
            oi.item_kind,
            oi.quantity,
            oi.quantity
          )
        ),
        sum(
          fragment(
            "CASE WHEN ? = 'completed' AND ? = 'mapped' AND ? = 'ticket' AND ? > 0 THEN ? ELSE 0 END",
            o.status,
            oi.mapping_status,
            oi.item_kind,
            oi.quantity,
            oi.line_total
          )
        ),
        sum(fragment("0")),
        sum(fragment("0"))
      }
  end

  defp legacy_summary_aggregate_query(event_id, business_date, "Africa/Johannesburg") do
    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where: oi.event_id == ^event_id,
      group_by: [o.status, o.currency],
      select: {
        o.status,
        o.currency,
        count(oi.id),
        sum(
          fragment(
            "CASE WHEN ? = 'completed' AND ? = 'mapped' AND ? = 'ticket' AND ? > 0 THEN ? ELSE 0 END",
            o.status,
            oi.mapping_status,
            oi.item_kind,
            oi.quantity,
            oi.quantity
          )
        ),
        sum(
          fragment(
            "CASE WHEN ? = 'completed' AND ? = 'mapped' AND ? = 'ticket' AND ? > 0 THEN ? ELSE 0 END",
            o.status,
            oi.mapping_status,
            oi.item_kind,
            oi.quantity,
            oi.line_total
          )
        ),
        sum(
          fragment(
            "CASE WHEN ? = 'completed' AND ? = 'mapped' AND ? = 'ticket' AND ? > 0 AND ? IS NOT NULL AND date(? + interval '2 hours') = ? THEN ? ELSE 0 END",
            o.status,
            oi.mapping_status,
            oi.item_kind,
            oi.quantity,
            o.completed_at,
            o.completed_at,
            ^business_date,
            oi.quantity
          )
        ),
        sum(
          fragment(
            "CASE WHEN ? = 'completed' AND ? = 'mapped' AND ? = 'ticket' AND ? > 0 AND ? IS NOT NULL AND date(? + interval '2 hours') = ? THEN ? ELSE 0 END",
            o.status,
            oi.mapping_status,
            oi.item_kind,
            oi.quantity,
            o.completed_at,
            o.completed_at,
            ^business_date,
            oi.line_total
          )
        )
      }
  end

  defp legacy_summary_aggregate_query(event_id, business_date, timezone)
       when timezone in ["UTC", "Etc/UTC"] do
    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where: oi.event_id == ^event_id,
      group_by: [o.status, o.currency],
      select: {
        o.status,
        o.currency,
        count(oi.id),
        sum(
          fragment(
            "CASE WHEN ? = 'completed' AND ? = 'mapped' AND ? = 'ticket' AND ? > 0 THEN ? ELSE 0 END",
            o.status,
            oi.mapping_status,
            oi.item_kind,
            oi.quantity,
            oi.quantity
          )
        ),
        sum(
          fragment(
            "CASE WHEN ? = 'completed' AND ? = 'mapped' AND ? = 'ticket' AND ? > 0 THEN ? ELSE 0 END",
            o.status,
            oi.mapping_status,
            oi.item_kind,
            oi.quantity,
            oi.line_total
          )
        ),
        sum(
          fragment(
            "CASE WHEN ? = 'completed' AND ? = 'mapped' AND ? = 'ticket' AND ? > 0 AND ? IS NOT NULL AND date(?) = ? THEN ? ELSE 0 END",
            o.status,
            oi.mapping_status,
            oi.item_kind,
            oi.quantity,
            o.completed_at,
            o.completed_at,
            ^business_date,
            oi.quantity
          )
        ),
        sum(
          fragment(
            "CASE WHEN ? = 'completed' AND ? = 'mapped' AND ? = 'ticket' AND ? > 0 AND ? IS NOT NULL AND date(?) = ? THEN ? ELSE 0 END",
            o.status,
            oi.mapping_status,
            oi.item_kind,
            oi.quantity,
            o.completed_at,
            o.completed_at,
            ^business_date,
            oi.line_total
          )
        )
      }
  end

  defp legacy_summary_aggregate_query(event_id, business_date, timezone)
       when is_binary(timezone) do
    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where: oi.event_id == ^event_id,
      group_by: [o.status, o.currency],
      select: {
        o.status,
        o.currency,
        count(oi.id),
        sum(
          fragment(
            "CASE WHEN ? = 'completed' AND ? = 'mapped' AND ? = 'ticket' AND ? > 0 THEN ? ELSE 0 END",
            o.status,
            oi.mapping_status,
            oi.item_kind,
            oi.quantity,
            oi.quantity
          )
        ),
        sum(
          fragment(
            "CASE WHEN ? = 'completed' AND ? = 'mapped' AND ? = 'ticket' AND ? > 0 THEN ? ELSE 0 END",
            o.status,
            oi.mapping_status,
            oi.item_kind,
            oi.quantity,
            oi.line_total
          )
        ),
        sum(
          fragment(
            "CASE WHEN ? = 'completed' AND ? = 'mapped' AND ? = 'ticket' AND ? > 0 AND ? IS NOT NULL AND date(? AT TIME ZONE ?) = ? THEN ? ELSE 0 END",
            o.status,
            oi.mapping_status,
            oi.item_kind,
            oi.quantity,
            o.completed_at,
            o.completed_at,
            ^timezone,
            ^business_date,
            oi.quantity
          )
        ),
        sum(
          fragment(
            "CASE WHEN ? = 'completed' AND ? = 'mapped' AND ? = 'ticket' AND ? > 0 AND ? IS NOT NULL AND date(? AT TIME ZONE ?) = ? THEN ? ELSE 0 END",
            o.status,
            oi.mapping_status,
            oi.item_kind,
            oi.quantity,
            o.completed_at,
            o.completed_at,
            ^timezone,
            ^business_date,
            oi.line_total
          )
        )
      }
  end

  defp legacy_summary_from_aggregate_rows(rows) do
    status_breakdown = status_breakdown_from_aggregate_rows(rows)

    completed_currencies =
      rows
      |> Enum.group_by(fn {_status, currency, _ic, _cq, _cr, _tq, _tr} -> currency end)
      |> Enum.flat_map(fn {currency, currency_rows} ->
        {qty, revenue} =
          Enum.reduce(currency_rows, {Decimal.new(0), Decimal.new(0)}, fn
            {_s, _c, _ic, cq, cr, _tq, _tr}, {q_acc, r_acc} ->
              {Decimal.add(q_acc, decimal!(cq)), Decimal.add(r_acc, decimal!(cr))}
          end)

        if Decimal.compare(qty, 0) == :gt or Decimal.compare(revenue, 0) == :gt do
          [{currency, qty, revenue}]
        else
          []
        end
      end)
      |> Enum.map(fn {currency, _qty, _rev} -> currency end)
      |> Enum.uniq()
      |> Enum.sort()

    {today_sold, today_revenue} =
      Enum.reduce(rows, {0, Decimal.new(0)}, fn {_s, _c, _ic, _cq, _cr, tq, tr},
                                                {sold_acc, rev_acc} ->
        {sold_acc + int!(tq), Decimal.add(rev_acc, decimal!(tr))}
      end)

    case completed_currencies do
      [] ->
        {:ok,
         %{
           total_sold: 0,
           total_revenue: Decimal.new(0),
           today_sold: today_sold,
           today_revenue: today_revenue,
           status_breakdown: status_breakdown
         }}

      [_single] ->
        {total_sold, total_revenue} =
          Enum.reduce(rows, {0, Decimal.new(0)}, fn {_s, _c, _ic, cq, cr, _tq, _tr},
                                                    {sold_acc, rev_acc} ->
            {sold_acc + int!(cq), Decimal.add(rev_acc, decimal!(cr))}
          end)

        {:ok,
         %{
           total_sold: total_sold,
           total_revenue: total_revenue,
           today_sold: today_sold,
           today_revenue: today_revenue,
           status_breakdown: status_breakdown
         }}

      _ ->
        {:error, :mixed_currency}
    end
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
