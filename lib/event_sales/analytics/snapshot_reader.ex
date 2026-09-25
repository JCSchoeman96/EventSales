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
  alias EventSales.Sales.FinancialPrimitives

  @canonical_snapshot_version 2

  @doc """
  Returns canonical financial summaries keyed by currency for one event.

  Only version-2 snapshot rows are authoritative. Version-1 rows are ignored.
  """
  @spec financial_summaries_for_event(Ecto.UUID.t() | String.t()) ::
          {:ok, %{String.t() => MetricRules.financial_summary()}} | :miss | {:error, term()}
  def financial_summaries_for_event(event_id) when is_binary(event_id) do
    with {:ok, event_id} <- cast_uuid(event_id, :event_id),
         {:ok, snapshots} <- read_canonical_event_snapshots(event_id) do
      case snapshots do
        [] ->
          :miss

        rows ->
          {:ok,
           rows
           |> Enum.map(fn snapshot ->
             {snapshot.currency, canonical_summary_from_snapshot(snapshot)}
           end)
           |> Map.new()}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the canonical financial summary for one event and currency.

  Only version-2 snapshot rows are authoritative.
  """
  @spec financial_summary_for_event(Ecto.UUID.t() | String.t(), String.t()) ::
          {:ok, MetricRules.financial_summary()} | :miss | {:error, term()}
  def financial_summary_for_event(event_id, currency)
      when is_binary(event_id) and is_binary(currency) do
    with {:ok, event_id} <- cast_uuid(event_id, :event_id),
         {:ok, snapshot} when not is_nil(snapshot) <-
           read_canonical_event_snapshot(event_id, currency) do
      {:ok, canonical_summary_from_snapshot(snapshot)}
    else
      {:ok, nil} -> :miss
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the legacy scalar event aggregate snapshot summary for an event.

  Multiple canonical currencies fail closed. Canonical version-2 rows take
  precedence over legacy version-1 compatibility rows.
  """
  @spec summary_for_event(Ecto.UUID.t() | String.t()) :: {:ok, map()} | :miss | {:error, term()}
  def summary_for_event(event_id) when is_binary(event_id) do
    with {:ok, event_id} <- cast_uuid(event_id, :event_id),
         {:ok, snapshots} <- read_all_event_snapshots(event_id) do
      legacy_summary_from_snapshots(event_id, snapshots)
    else
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

  defp legacy_summary_from_snapshots(_event_id, snapshots) do
    v2_rows =
      snapshots
      |> Enum.filter(&(&1.snapshot_version == @canonical_snapshot_version))
      |> Enum.sort_by(& &1.currency)

    v1_rows =
      snapshots
      |> Enum.filter(&(&1.snapshot_version == 1))
      |> Enum.sort_by(& &1.currency)

    cond do
      length(v2_rows) > 1 ->
        {:error, :mixed_currency}

      length(v2_rows) == 1 ->
        {:ok, legacy_event_summary(hd(v2_rows))}

      v1_rows == [] ->
        :miss

      length(v1_rows) > 1 ->
        {:error, :ambiguous_legacy_snapshots}

      true ->
        {:ok, legacy_event_summary(hd(v1_rows))}
    end
  end

  defp read_canonical_event_snapshots(event_id) do
    EventAggregateSnapshot
    |> Ash.Query.filter(
      event_id == ^event_id and snapshot_version == ^@canonical_snapshot_version
    )
    |> Ash.Query.sort(currency: :asc)
    |> Ash.read(domain: Analytics)
  end

  defp read_canonical_event_snapshot(event_id, currency) do
    EventAggregateSnapshot
    |> Ash.Query.filter(
      event_id == ^event_id and currency == ^currency and
        snapshot_version == ^@canonical_snapshot_version
    )
    |> Ash.read_one(domain: Analytics)
  end

  defp read_all_event_snapshots(event_id) do
    EventAggregateSnapshot
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.Query.sort(currency: :asc)
    |> Ash.read(domain: Analytics)
  end

  defp read_daily_snapshot(event_id, business_date, timezone) do
    DailySalesAggregateSnapshot
    |> Ash.Query.filter(
      event_id == ^event_id and business_date == ^business_date and business_timezone == ^timezone
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Analytics)
  end

  defp canonical_summary_from_snapshot(%EventAggregateSnapshot{} = snapshot) do
    primitives =
      FinancialPrimitives.empty_totals()
      |> Map.put(:gross_ticket_quantity, Decimal.new(snapshot.gross_ticket_quantity))
      |> Map.put(:refund_ticket_quantity, Decimal.new(snapshot.refund_ticket_quantity))
      |> Map.put(:gross_ticket_value, snapshot.gross_ticket_value)
      |> Map.put(:refund_ticket_value, snapshot.refund_ticket_value)

    {:ok, summary} =
      MetricRules.financial_summary(
        snapshot.currency,
        primitives,
        snapshot.recognised_order_count
      )

    summary
  end

  defp legacy_event_summary(%EventAggregateSnapshot{} = snapshot) do
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
