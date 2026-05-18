defmodule EventSales.Analytics.SnapshotReader do
  @moduledoc """
  Snapshot-only read facade for historical reporting and future dashboards.

  This module intentionally reads durable analytics snapshot resources only.
  Refresh logic owns any scoped scans of durable sales data.
  """

  require Ash.Query

  alias EventSales.Analytics
  alias EventSales.Analytics.MetricRules
  alias EventSales.Analytics.Resources.{DailySalesAggregateSnapshot, EventAggregateSnapshot}

  @doc "Returns the latest event aggregate snapshot summary for an event."
  @spec summary_for_event(Ecto.UUID.t() | String.t()) :: {:ok, map()} | :miss | {:error, term()}
  def summary_for_event(event_id) when is_binary(event_id) do
    with {:ok, event_id} <- cast_uuid(event_id, :event_id),
         {:ok, snapshot} when not is_nil(snapshot) <- read_event_snapshot(event_id) do
      {:ok, event_summary(snapshot)}
    else
      {:ok, nil} -> :miss
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns a daily aggregate snapshot summary for an event and business date."
  @spec daily_summary_for_event(Ecto.UUID.t() | String.t(), Date.t() | String.t(), keyword()) ::
          {:ok, map()} | :miss | {:error, term()}
  def daily_summary_for_event(event_id, business_date, opts \\ []) when is_binary(event_id) do
    with {:ok, event_id} <- cast_uuid(event_id, :event_id),
         {:ok, business_date} <- cast_date(business_date),
         timezone <- Keyword.get_lazy(opts, :business_timezone, &MetricRules.business_timezone/0),
         {:ok, snapshot} when not is_nil(snapshot) <-
           read_daily_snapshot(event_id, business_date, timezone) do
      {:ok, daily_summary(snapshot)}
    else
      {:ok, nil} -> :miss
      {:error, reason} -> {:error, reason}
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

  defp event_summary(%EventAggregateSnapshot{} = snapshot) do
    %{
      event_id: snapshot.event_id,
      total_sold: snapshot.total_sold,
      total_revenue: snapshot.total_revenue,
      today_sold: snapshot.today_sold,
      today_revenue: snapshot.today_revenue,
      status_breakdown: snapshot.status_breakdown,
      currency: snapshot.currency,
      business_timezone: snapshot.business_timezone,
      refreshed_at: snapshot.refreshed_at,
      source_watermark_at: snapshot.source_watermark_at,
      source_row_count: snapshot.source_row_count,
      snapshot_version: snapshot.snapshot_version
    }
  end

  defp daily_summary(%DailySalesAggregateSnapshot{} = snapshot) do
    snapshot
    |> Map.from_struct()
    |> Map.take([
      :event_id,
      :business_date,
      :total_sold,
      :total_revenue,
      :today_sold,
      :today_revenue,
      :status_breakdown,
      :currency,
      :business_timezone,
      :refreshed_at,
      :source_watermark_at,
      :source_row_count,
      :snapshot_version
    ])
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
