defmodule EventSales.Analytics.SourceFreshness do
  @moduledoc """
  Postgres-backed reader for event source-freshness classification.

  Component watermarks are persisted on
  `EventSales.Analytics.Resources.EventSourceFreshnessSnapshot`. This module
  derives the authoritative anchor on read and delegates age classification to
  `EventSales.Analytics.TimeRules`.
  """

  require Ash.Query
  import Ash.Expr

  alias EventSales.Analytics.{DashboardPubSub, Resources.EventSourceFreshnessSnapshot}
  alias EventSales.Analytics.TimeRules
  alias EventSales.Analytics.TimeRules.Freshness
  alias EventSales.Telemetry

  @type classification :: :normal | :aging | :stale

  @type freshness_result :: %{
          classification: classification(),
          anchor_at: DateTime.t(),
          age_ms: non_neg_integer()
        }

  @doc """
  Advances an event's durable order source watermark after its Sales write commits.

  Equal and older source timestamps are idempotent no-ops. The Ash/Postgres
  upsert condition is the concurrency authority for the component watermark.
  """
  @spec advance_order(Ecto.UUID.t(), DateTime.t()) :: :ok | {:error, term()}
  def advance_order(event_id, %DateTime{} = order_updated_at_source)
      when is_binary(event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, _uuid} ->
        advance_order_watermark(event_id, order_updated_at_source)

      :error ->
        {:error, :invalid_event_id}
    end
  end

  def advance_order(_event_id, _order_updated_at_source),
    do: {:error, :invalid_order_source_watermark}

  @doc """
  Returns source-freshness classification for one event.

  Pass `now` in `opts` for deterministic tests.
  """
  @spec for_event(Ecto.UUID.t(), keyword()) ::
          {:ok, freshness_result()} | {:error, :missing_source_freshness_anchor | term()}
  def for_event(event_id, opts \\ []) when is_binary(event_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with {:ok, %EventSourceFreshnessSnapshot{} = snapshot} <- fetch_snapshot(event_id) do
      case source_freshness_anchor_at(snapshot) do
        %DateTime{} = anchor_at ->
          freshness = TimeRules.classify_source_freshness(anchor_at, now)
          emit_clock_skew_telemetry(freshness)

          {:ok,
           %{
             classification: freshness.classification,
             anchor_at: anchor_at,
             age_ms: div(freshness.age_microseconds, 1_000)
           }}

        nil ->
          {:error, :missing_source_freshness_anchor}
      end
    end
  end

  defp advance_order_watermark(event_id, order_updated_at_source) do
    case Ash.create(
           EventSourceFreshnessSnapshot,
           %{
             event_id: event_id,
             order_source_watermark_at: order_updated_at_source,
             projection_refreshed_at: DateTime.utc_now()
           },
           action: :advance_order_watermark,
           return_skipped_upsert?: true,
           domain: EventSales.Analytics
         ) do
      {:ok, %EventSourceFreshnessSnapshot{} = snapshot} ->
        if Ash.Resource.get_metadata(snapshot, :upsert_skipped) do
          :ok
        else
          DashboardPubSub.broadcast_source_freshness_updated(event_id)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_snapshot(event_id) do
    case EventSourceFreshnessSnapshot
         |> Ash.Query.filter(expr(event_id == ^event_id))
         |> Ash.read_one(domain: EventSales.Analytics) do
      {:ok, nil} -> {:error, :missing_source_freshness_anchor}
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, reason} -> {:error, reason}
    end
  end

  defp emit_clock_skew_telemetry(%Freshness{clock_skew?: true}) do
    Telemetry.emit(Telemetry.source_freshness_clock_skew(), %{count: 1}, %{scope: :event})
  end

  defp emit_clock_skew_telemetry(%Freshness{clock_skew?: false}), do: :ok

  defp source_freshness_anchor_at(%EventSourceFreshnessSnapshot{} = snapshot) do
    snapshot
    |> Map.take([
      :order_source_watermark_at,
      :refund_source_watermark_at,
      :sync_source_observed_at
    ])
    |> Map.values()
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      datetimes -> Enum.max_by(datetimes, &DateTime.to_unix(&1, :microsecond))
    end
  end
end
