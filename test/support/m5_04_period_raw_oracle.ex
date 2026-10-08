# credo:disable-for-this-file Credo.Check.Readability.ModuleNames
defmodule EventSales.TestSupport.M5_04PeriodRawOracle do
  @moduledoc """
  Certification-only financial oracle for arbitrary half-open UTC bounds.

  Uses the same canonical sale/refund predicates as `EventAggregator` without
  preset period-kind validation. Not a production API.
  """

  import Ecto.Query

  alias EventSales.Analytics.Aggregators.EventAggregator
  alias EventSales.Analytics.MetricRules
  alias EventSales.Repo

  @doc false
  def financial_summary!(event_id, start_utc, end_utc, currency)
      when is_binary(event_id) and is_binary(currency) do
    event_id = cast_event_id!(event_id)

    gross_rows = Repo.all(gross_aggregate_query(event_id, start_utc, end_utc))
    refund_rows = Repo.all(refund_aggregate_query(event_id, start_utc, end_utc))
    order_count_rows = Repo.all(recognised_order_count_query(event_id, start_utc, end_utc))

    {gross_qty, gross_val} = row_amounts(gross_rows, currency)
    {refund_qty, refund_val} = row_amounts(refund_rows, currency)
    recognised_order_count = row_count(order_count_rows, currency)

    primitives =
      EventSales.Sales.FinancialPrimitives.empty_totals()
      |> Map.put(:gross_ticket_quantity, gross_qty)
      |> Map.put(:gross_ticket_value, gross_val)
      |> Map.put(:refund_ticket_quantity, refund_qty)
      |> Map.put(:refund_ticket_value, refund_val)

    case MetricRules.financial_summary(currency, primitives, recognised_order_count) do
      {:ok, summary} -> summary
      {:error, reason} -> raise "raw oracle summary failed: #{inspect(reason)}"
    end
  end

  defp gross_aggregate_query(event_id, start_utc, end_utc) do
    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where:
        ^dynamic(
          [oi, o],
          ^EventAggregator.recognised_sale_item_filters(event_id) and
            ^sale_effective_in_period?(start_utc, end_utc)
        ),
      group_by: o.currency,
      select:
        {o.currency, sum(oi.quantity), sum(fragment("? + ?", oi.line_total, oi.line_total_tax))}
  end

  defp refund_aggregate_query(event_id, start_utc, end_utc) do
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
          ^EventAggregator.refund_primitives_filters() and
            ^refund_effective_in_period?(start_utc, end_utc)
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

  defp recognised_order_count_query(event_id, start_utc, end_utc) do
    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where:
        ^dynamic(
          [oi, o],
          ^EventAggregator.recognised_sale_item_filters(event_id) and
            ^sale_effective_in_period?(start_utc, end_utc)
        ),
      group_by: o.currency,
      select: {o.currency, count(o.id, :distinct)}
  end

  defp event_ticket_items_subquery(event_id) do
    from oi in "sales_order_items",
      where:
        oi.event_id == ^event_id and oi.mapping_status == "mapped" and oi.item_kind == "ticket",
      select: %{id: oi.id, order_id: oi.order_id, woo_line_item_id: oi.woo_line_item_id}
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

  defp decimal!(value) when is_integer(value), do: Decimal.new(value)
  defp decimal!(%Decimal{} = value), do: value
  defp decimal!(nil), do: Decimal.new(0)

  defp cast_event_id!(event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, uuid} -> Ecto.UUID.dump!(uuid)
      :error -> raise "invalid event_id for raw oracle: #{inspect(event_id)}"
    end
  end
end
