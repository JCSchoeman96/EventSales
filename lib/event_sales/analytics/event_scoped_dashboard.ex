defmodule EventSales.Analytics.EventScopedDashboard do
  @moduledoc """
  Read-only event-scoped aggregate facade for future dashboards.

  This module authorizes before checking event existence so unassigned actors do
  not learn whether a valid event UUID exists.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Analytics.{HotStateAggregator, SnapshotReader}
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event

  @zero Decimal.new("0")

  @type summary :: %{
          event_id: Ecto.UUID.t(),
          total_sold: non_neg_integer(),
          total_revenue: Decimal.t() | nil,
          today_sold: non_neg_integer(),
          today_revenue: Decimal.t() | nil,
          status_breakdown: map(),
          currency: String.t(),
          refreshed_at: DateTime.t() | nil,
          source_watermark_at: DateTime.t() | nil,
          source_row_count: non_neg_integer(),
          snapshot_version: pos_integer(),
          revenue_visible?: boolean(),
          pii_visibility: :none
        }

  @doc """
  Returns an event aggregate summary for authorized event-scoped dashboard reads.
  """
  @spec summary(Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, summary()}
          | :not_found
          | {:error, :forbidden | {:invalid_uuid, :event_id} | term()}
  def summary(event_id, opts \\ []) when is_binary(event_id) do
    with {:ok, event_id} <- cast_uuid(event_id),
         :ok <- authorize(Keyword.get(opts, :actor), event_id),
         {:ok, true} <- event_exists?(event_id) do
      {:ok, build_summary(event_id, Keyword.get(opts, :actor))}
    else
      {:ok, false} -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize(actor, event_id) do
    if Policies.can_access_event_dashboard?(actor, event_id) do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp event_exists?(event_id) do
    Event
    |> Ash.Query.filter(id == ^event_id)
    |> Ash.Query.select([:id])
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Catalog)
    |> case do
      {:ok, %Event{}} -> {:ok, true}
      {:ok, nil} -> {:ok, false}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_summary(event_id, actor) do
    event_id
    |> aggregate_summary()
    |> normalize_summary(event_id)
    |> apply_revenue_visibility(actor, event_id)
  end

  defp aggregate_summary(event_id) do
    case HotStateAggregator.summary_for_event(event_id) do
      {:ok, summary} ->
        summary

      :miss ->
        case SnapshotReader.summary_for_event(event_id) do
          {:ok, summary} -> summary
          :miss -> empty_summary()
          {:error, _reason} -> empty_summary()
        end
    end
  end

  defp normalize_summary(summary, event_id) when is_map(summary) do
    %{
      event_id: event_id,
      total_sold: Map.get(summary, :total_sold, 0),
      total_revenue: Map.get(summary, :total_revenue, @zero),
      today_sold: Map.get(summary, :today_sold, 0),
      today_revenue: Map.get(summary, :today_revenue, @zero),
      status_breakdown: normalize_status_breakdown(Map.get(summary, :status_breakdown, %{})),
      currency:
        Map.get(summary, :currency, Application.fetch_env!(:event_sales, :default_currency)),
      refreshed_at: Map.get(summary, :refreshed_at) || Map.get(summary, :updated_at),
      source_watermark_at: Map.get(summary, :source_watermark_at),
      source_row_count: Map.get(summary, :source_row_count, 0),
      snapshot_version: Map.get(summary, :snapshot_version, 1),
      pii_visibility: :none
    }
  end

  defp apply_revenue_visibility(summary, actor, event_id) do
    if Policies.can_view_revenue?(actor, event_id) do
      Map.put(summary, :revenue_visible?, true)
    else
      summary
      |> Map.put(:total_revenue, nil)
      |> Map.put(:today_revenue, nil)
      |> Map.put(:revenue_visible?, false)
    end
  end

  defp empty_summary do
    %{
      total_sold: 0,
      total_revenue: @zero,
      today_sold: 0,
      today_revenue: @zero,
      status_breakdown: %{},
      source_row_count: 0,
      snapshot_version: 1
    }
  end

  defp normalize_status_breakdown(status_breakdown) when is_map(status_breakdown) do
    Map.new(status_breakdown, fn {status, count} -> {to_string(status), count} end)
  end

  defp normalize_status_breakdown(_status_breakdown), do: %{}

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_uuid, :event_id}}
    end
  end
end
