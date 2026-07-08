defmodule EventSales.Analytics.AdminDashboard do
  @moduledoc """
  Read facade for the first internal admin dashboard.

  This module is not a web module and not a metrics engine. It assembles
  bounded dashboard data from EventSales read models and local Postgres data.
  """

  require Ash.Query

  alias EventSales.Analytics.{HotStateAggregator, MetricRules, SnapshotReader}
  alias EventSales.Catalog
  alias EventSales.Catalog.EventLifecycle
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Sales
  alias EventSales.Sales.OrderItemMapper
  alias EventSales.Sales.Resources.{Order, OrderItem}

  @default_event_limit 50
  @default_recent_order_limit 10
  @default_unmapped_limit 10
  @default_row_limit 1_000

  @zero Decimal.new("0")

  @type snapshot :: %{
          kpis: map(),
          events: [map()],
          statuses: map(),
          ticket_types: [map()],
          recent_orders: [map()],
          unmapped_alerts: [map()],
          hot_state: map()
        }

  @doc """
  Returns bounded dashboard data for the internal admin dashboard.
  """
  @spec snapshot(keyword()) :: {:ok, snapshot()} | {:error, term()}
  def snapshot(opts \\ []) do
    with {:ok, events} <- list_events(limit(opts, :event_limit, @default_event_limit), opts),
         {:ok, event_rows} <- event_rows(events, opts),
         {:ok, ticket_types} <- ticket_type_breakdown(events, opts),
         {:ok, recent_orders} <- recent_orders(opts),
         {:ok, unmapped_alerts} <- unmapped_alerts(opts) do
      {:ok,
       %{
         kpis: kpis(event_rows),
         events: event_rows,
         statuses: statuses(event_rows),
         ticket_types: ticket_types,
         recent_orders: recent_orders,
         unmapped_alerts: unmapped_alerts,
         hot_state: HotStateAggregator.status()
       }}
    end
  end

  @doc """
  Returns one dashboard event row for the given event id.

  This reads event metadata plus hot/warm event summaries only. It does not
  backfill KPI totals from raw order item rows.
  """
  @spec event_row(Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, map()} | :not_found | {:error, term()}
  def event_row(event_id, opts \\ []) when is_binary(event_id) do
    case get_event(event_id) do
      {:ok, %Event{} = event} -> {:ok, build_event_row(event, opts)}
      {:ok, nil} -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Replaces a displayed event row and recomputes dashboard totals from displayed rows.
  """
  @spec replace_event_row(snapshot(), map()) :: {:ok, snapshot()} | :not_found
  def replace_event_row(%{events: events} = snapshot, %{event_id: event_id} = row)
      when is_list(events) and is_binary(event_id) do
    if Enum.any?(events, &(&1.event_id == event_id)) do
      events =
        Enum.map(events, fn
          %{event_id: ^event_id} -> row
          existing -> existing
        end)

      {:ok,
       snapshot
       |> Map.put(:events, events)
       |> Map.put(:kpis, kpis(events))
       |> Map.put(:statuses, statuses(events))}
    else
      :not_found
    end
  end

  defp list_events(limit, opts) do
    Event
    |> lifecycle_filter(
      Keyword.get(opts, :lifecycle, :current),
      Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    )
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.read(domain: Catalog)
  end

  defp get_event(event_id) do
    Event
    |> Ash.Query.filter(id == ^event_id)
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Catalog)
  end

  defp event_rows(events, opts) do
    events
    |> Enum.map(&build_event_row(&1, opts))
    |> then(&{:ok, &1})
  end

  defp build_event_row(%Event{} = event, opts) do
    summary =
      event.id
      |> summary_for_event(opts)
      |> merge_daily_summary(event.id, opts)

    %{
      event_id: event.id,
      event_name: event.name,
      venue_name: event.venue_name,
      lifecycle:
        EventLifecycle.classify(event, Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)),
      total_sold: summary.total_sold,
      total_revenue: summary.total_revenue,
      today_sold: summary.today_sold,
      today_revenue: summary.today_revenue,
      status_breakdown: normalize_status_breakdown(summary.status_breakdown),
      currency:
        Map.get(summary, :currency, Application.fetch_env!(:event_sales, :default_currency)),
      refreshed_at: Map.get(summary, :refreshed_at) || Map.get(summary, :updated_at)
    }
  end

  defp summary_for_event(event_id, opts) do
    case HotStateAggregator.summary_for_event(event_id) do
      {:ok, summary} ->
        normalize_summary(summary)

      :miss ->
        snapshot_or_bounded_summary(event_id, opts)
    end
  end

  defp snapshot_or_bounded_summary(event_id, _opts) do
    case SnapshotReader.summary_for_event(event_id) do
      {:ok, summary} -> normalize_summary(summary)
      :miss -> empty_summary()
      {:error, _reason} -> empty_summary()
    end
  end

  defp merge_daily_summary(summary, event_id, opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    timezone = MetricRules.business_timezone()

    with {:ok, business_date} <- MetricRules.business_date(now, timezone),
         {:ok, daily_summary} <-
           SnapshotReader.daily_summary_for_event(event_id, business_date,
             business_timezone: timezone
           ) do
      summary
      |> Map.put(:today_sold, daily_summary.today_sold)
      |> Map.put(:today_revenue, daily_summary.today_revenue)
    else
      _other -> summary
    end
  end

  defp ticket_type_breakdown([], _opts), do: {:ok, []}

  defp ticket_type_breakdown(events, opts) do
    event_ids = Enum.map(events, & &1.id)
    row_limit = limit(opts, :ticket_type_row_limit, @default_row_limit)

    OrderItem
    |> Ash.Query.filter(
      event_id in ^event_ids and mapping_status == :mapped and item_kind == :ticket
    )
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.Query.limit(row_limit)
    |> Ash.Query.load([:order, :event, :ticket_type])
    |> Ash.read(domain: Sales)
    |> case do
      {:ok, rows} -> {:ok, build_ticket_type_rows(rows)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_ticket_type_rows(rows) do
    rows
    |> Enum.filter(fn row -> match?(%{order: %Order{status: :completed}}, row) end)
    |> Enum.reduce(%{}, fn row, acc ->
      key = {row.event_id, row.ticket_type_id}

      Map.update(acc, key, ticket_type_row(row), fn current ->
        %{
          current
          | total_sold: current.total_sold + row.quantity,
            total_revenue: Decimal.add(current.total_revenue, row.line_total)
        }
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(&{&1.event_name, &1.ticket_type_name})
  end

  defp ticket_type_row(%OrderItem{} = row) do
    %{
      event_id: row.event_id,
      event_name: related_name(row.event, "Unknown event"),
      ticket_type_id: row.ticket_type_id,
      ticket_type_name: related_name(row.ticket_type, "Unknown ticket"),
      total_sold: row.quantity,
      total_revenue: row.line_total
    }
  end

  defp recent_orders(opts) do
    Order
    |> Ash.Query.sort(updated_at_source: :desc)
    |> Ash.Query.limit(limit(opts, :recent_order_limit, @default_recent_order_limit))
    |> Ash.read(domain: Sales)
    |> case do
      {:ok, orders} -> {:ok, Enum.map(orders, &recent_order_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp recent_order_row(%Order{} = order) do
    %{
      order_number: order.order_number,
      status: order.status,
      currency: order.currency,
      raw_total: order.raw_total,
      completed_at: order.completed_at,
      updated_at_source: order.updated_at_source
    }
  end

  defp unmapped_alerts(opts) do
    opts
    |> limit(:unmapped_limit, @default_unmapped_limit)
    |> then(&OrderItemMapper.list_unmapped_queue(limit: &1))
    |> case do
      {:ok, items} -> {:ok, Enum.map(items, &unmapped_alert_row/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp unmapped_alert_row(%OrderItem{} = item) do
    %{
      order_number: order_number(item),
      name: item.name,
      woo_product_id: item.woo_product_id,
      woo_variation_id: item.woo_variation_id,
      mapping_status: item.mapping_status,
      quantity: item.quantity,
      updated_at: item.updated_at
    }
  end

  defp kpis(event_rows) do
    Enum.reduce(event_rows, empty_kpis(), fn row, acc ->
      %{
        total_sold: acc.total_sold + row.total_sold,
        total_revenue: Decimal.add(acc.total_revenue, row.total_revenue),
        today_sold: acc.today_sold + row.today_sold,
        today_revenue: Decimal.add(acc.today_revenue, row.today_revenue)
      }
    end)
  end

  defp statuses(event_rows) do
    Enum.reduce(event_rows, %{}, fn row, acc ->
      Map.merge(acc, row.status_breakdown, fn _status, left, right -> left + right end)
    end)
  end

  defp normalize_summary(summary) when is_map(summary) do
    empty_summary()
    |> Map.merge(Map.take(summary, [:total_sold, :total_revenue, :today_sold, :today_revenue]))
    |> Map.put(
      :status_breakdown,
      normalize_status_breakdown(Map.get(summary, :status_breakdown, %{}))
    )
    |> Map.merge(Map.take(summary, [:currency, :refreshed_at, :updated_at]))
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

  defp empty_kpis do
    Map.take(empty_summary(), [:total_sold, :total_revenue, :today_sold, :today_revenue])
  end

  defp normalize_status_breakdown(status_breakdown) when is_map(status_breakdown) do
    Map.new(status_breakdown, fn {status, count} -> {to_string(status), count} end)
  end

  defp normalize_status_breakdown(_status_breakdown), do: %{}

  defp related_name(%{name: name}, _fallback) when is_binary(name), do: name
  defp related_name(_related, fallback), do: fallback

  defp order_number(%{order: %{order_number: order_number}}) when is_binary(order_number),
    do: order_number

  defp order_number(_item), do: nil

  defp limit(opts, key, default) do
    opts
    |> Keyword.get(key, default)
    |> min(default)
    |> max(1)
  end

  defp lifecycle_filter(query, :past, %DateTime{} = now) do
    Ash.Query.filter(query, not is_nil(starts_at) and not is_nil(ends_at) and ends_at < ^now)
  end

  defp lifecycle_filter(query, _current, %DateTime{} = now) do
    Ash.Query.filter(query, is_nil(starts_at) or is_nil(ends_at) or ends_at >= ^now)
  end
end
