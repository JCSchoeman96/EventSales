defmodule EventSales.Analytics.SnapshotRefresh do
  @moduledoc """
  Refreshes durable historical reporting snapshots from scoped sales rows.

  Snapshot rows are derived read models. This module may scan scoped durable
  sales data during refresh, but dashboard/reporting reads should use
  `EventSales.Analytics.SnapshotReader`.
  """

  require Ash.Query

  alias EventSales.Analytics
  alias EventSales.Analytics.DashboardCache
  alias EventSales.Analytics.MetricRules
  alias EventSales.Analytics.Resources.{DailySalesAggregateSnapshot, EventAggregateSnapshot}
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Sales
  alias EventSales.Sales.Resources.OrderItem

  @snapshot_version 1
  @doc "Refreshes the latest durable aggregate snapshot for one event."
  @spec refresh_event(Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, EventAggregateSnapshot.t()} | {:error, term()}
  def refresh_event(event_id, opts \\ []) when is_binary(event_id) do
    with {:ok, event_id} <- cast_uuid(event_id, :event_id),
         {:ok, _event} <- fetch_event(event_id),
         {:ok, rows} <- event_rows(event_id) do
      timezone = Keyword.get_lazy(opts, :business_timezone, &MetricRules.business_timezone/0)
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      refreshed_at = Keyword.get_lazy(opts, :refreshed_at, &DateTime.utc_now/0)
      attrs = snapshot_attrs(event_id, rows, timezone, now, refreshed_at)

      with {:ok, snapshot} <- upsert_event_snapshot(event_id, attrs) do
        DashboardCache.invalidate_event(event_id, :snapshot_refresh)
        {:ok, snapshot}
      end
    end
  end

  @doc "Refreshes the durable daily sales snapshot for one event and business date."
  @spec refresh_daily(Ecto.UUID.t() | String.t(), Date.t() | String.t(), keyword()) ::
          {:ok, DailySalesAggregateSnapshot.t()} | {:error, term()}
  def refresh_daily(event_id, business_date, opts \\ [])

  def refresh_daily(event_id, business_date, opts) when is_binary(event_id) do
    with {:ok, event_id} <- cast_uuid(event_id, :event_id),
         {:ok, business_date} <- cast_date(business_date),
         {:ok, _event} <- fetch_event(event_id),
         {:ok, rows} <- event_rows(event_id) do
      timezone = Keyword.get_lazy(opts, :business_timezone, &MetricRules.business_timezone/0)
      now = Keyword.get_lazy(opts, :now, fn -> snapshot_now(business_date) end)
      refreshed_at = Keyword.get_lazy(opts, :refreshed_at, &DateTime.utc_now/0)

      daily_rows =
        Enum.filter(rows, fn row ->
          row
          |> row_completed_at()
          |> same_business_date?(business_date, timezone)
        end)

      attrs =
        event_id
        |> snapshot_attrs(daily_rows, timezone, now, refreshed_at)
        |> Map.put(:business_date, business_date)

      with {:ok, snapshot} <- upsert_daily_snapshot(event_id, business_date, timezone, attrs) do
        DashboardCache.invalidate_event(event_id, :snapshot_refresh)
        {:ok, snapshot}
      end
    end
  end

  def refresh_daily(_event_id, _business_date, _opts), do: {:error, :invalid_event_id}

  defp fetch_event(event_id) do
    case Ash.get(Event, event_id, domain: Catalog) do
      {:ok, %Event{} = event} -> {:ok, event}
      {:ok, nil} -> {:error, :event_not_found}
      {:error, _reason} -> {:error, :event_not_found}
    end
  end

  defp event_rows(event_id) do
    OrderItem
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.Query.sort(woo_line_item_id: :asc)
    |> Ash.Query.load(:order)
    |> Ash.read(domain: Sales)
  end

  defp snapshot_attrs(event_id, rows, timezone, now, refreshed_at) do
    summary = MetricRules.summarize(rows, timezone: timezone, now: now)

    %{
      event_id: event_id,
      total_sold: summary.total_sold,
      total_revenue: summary.total_revenue,
      today_sold: summary.today_sold,
      today_revenue: summary.today_revenue,
      status_breakdown: stringify_status_breakdown(summary.status_breakdown),
      currency: currency(rows),
      business_timezone: timezone,
      refreshed_at: DateTime.truncate(refreshed_at, :microsecond),
      source_watermark_at: source_watermark_at(rows),
      source_row_count: length(rows),
      snapshot_version: @snapshot_version
    }
  end

  defp upsert_event_snapshot(event_id, attrs) do
    case read_event_snapshot(event_id) do
      {:ok, nil} ->
        Ash.create(EventAggregateSnapshot, attrs, action: :create_snapshot, domain: Analytics)

      {:ok, %EventAggregateSnapshot{} = snapshot} ->
        Ash.update(snapshot, Map.delete(attrs, :event_id),
          action: :update_snapshot,
          domain: Analytics
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upsert_daily_snapshot(event_id, business_date, timezone, attrs) do
    case read_daily_snapshot(event_id, business_date, timezone) do
      {:ok, nil} ->
        Ash.create(DailySalesAggregateSnapshot, attrs,
          action: :create_snapshot,
          domain: Analytics
        )

      {:ok, %DailySalesAggregateSnapshot{} = snapshot} ->
        Ash.update(snapshot, attrs |> Map.delete(:event_id) |> Map.delete(:business_date),
          action: :update_snapshot,
          domain: Analytics
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_event_snapshot(event_id) do
    EventAggregateSnapshot
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Analytics)
  end

  defp read_daily_snapshot(event_id, business_date, timezone) do
    DailySalesAggregateSnapshot
    |> Ash.Query.filter(
      event_id == ^event_id and business_date == ^business_date and business_timezone == ^timezone
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Analytics)
  end

  defp stringify_status_breakdown(status_breakdown) do
    Map.new(status_breakdown, fn {key, value} -> {to_string(key), value} end)
  end

  defp currency([%OrderItem{order: %{currency: currency}} | _rest]) when is_binary(currency),
    do: currency

  defp currency([_row | rest]), do: currency(rest)
  defp currency([]), do: Application.fetch_env!(:event_sales, :default_currency)

  defp source_watermark_at(rows) do
    rows
    |> Enum.map(&row_source_updated_at/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp row_source_updated_at(%OrderItem{order: %{updated_at_source: %DateTime{} = updated_at}}),
    do: updated_at

  defp row_source_updated_at(_row), do: nil

  defp row_completed_at(%OrderItem{order: %{completed_at: %DateTime{} = completed_at}}),
    do: completed_at

  defp row_completed_at(_row), do: nil

  defp same_business_date?(nil, _business_date, _timezone), do: false

  defp same_business_date?(%DateTime{} = completed_at, business_date, timezone) do
    case MetricRules.business_date(completed_at, timezone) do
      {:ok, ^business_date} -> true
      {:ok, _other_date} -> false
      {:error, :invalid_timezone} -> false
    end
  end

  defp snapshot_now(%Date{} = business_date) do
    business_date
    |> DateTime.new!(~T[12:00:00.000000], "Etc/UTC")
    |> DateTime.truncate(:microsecond)
  end

  defp cast_uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_uuid, field}}
    end
  end

  defp cast_date(%Date{} = date), do: {:ok, date}

  defp cast_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_business_date}
    end
  end

  defp cast_date(_value), do: {:error, :invalid_business_date}
end
