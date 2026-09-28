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

  @type event_freshness_result ::
          {:ok, freshness_result()} | {:error, :missing_source_freshness_anchor}

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
  Advances an event's durable refund source watermark after its Sales write commits.

  Equal and older source timestamps are idempotent no-ops. The Ash/Postgres
  upsert condition is the concurrency authority for the component watermark.
  """
  @spec advance_refund(Ecto.UUID.t(), DateTime.t()) :: :ok | {:error, term()}
  def advance_refund(event_id, %DateTime{} = refund_source_created_at)
      when is_binary(event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, _uuid} ->
        advance_refund_watermark(event_id, refund_source_created_at)

      :error ->
        {:error, :invalid_event_id}
    end
  end

  def advance_refund(_event_id, _refund_source_created_at),
    do: {:error, :invalid_refund_source_watermark}

  @doc """
  Advances an event's durable sync source-observed watermark after a successful
  bounded historical catch-up has committed.

  Equal and older source timestamps are idempotent no-ops. The Ash/Postgres
  upsert condition is the concurrency authority for the component watermark.
  """
  @spec advance_sync_source_observed(Ecto.UUID.t(), DateTime.t()) :: :ok | {:error, term()}
  def advance_sync_source_observed(event_id, %DateTime{} = source_observed_at)
      when is_binary(event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, _uuid} ->
        advance_sync_source_observed_watermark(event_id, source_observed_at)

      :error ->
        {:error, :invalid_event_id}
    end
  end

  def advance_sync_source_observed(_event_id, _source_observed_at),
    do: {:error, :invalid_sync_source_observed_at}

  @doc """
  Returns source-freshness classification for one event.

  Pass `now` in `opts` for deterministic tests.
  """
  @spec for_event(Ecto.UUID.t(), keyword()) ::
          {:ok, freshness_result()} | {:error, :missing_source_freshness_anchor | term()}
  def for_event(event_id, opts \\ []) when is_binary(event_id) do
    with {:ok, results} <- for_events([event_id], opts) do
      Map.fetch!(results, event_id)
    end
  end

  @doc """
  Returns source-freshness results for a bounded set of events with one projection read.

  Missing rows and rows without any component watermark return the typed missing-anchor
  result. Pass `now` in `opts` to classify every result against the same instant.
  """
  @spec for_events([Ecto.UUID.t()], keyword()) ::
          {:ok, %{optional(Ecto.UUID.t()) => event_freshness_result()}} | {:error, term()}
  def for_events([], _opts), do: {:ok, %{}}

  def for_events(event_ids, opts) when is_list(event_ids) do
    requested_ids = Enum.uniq(event_ids)
    query_ids = requested_ids |> Enum.map(&normalized_event_id/1) |> Enum.uniq()
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, snapshots} <- fetch_snapshots(query_ids) do
      snapshots_by_event_id = Map.new(snapshots, &{&1.event_id, &1})

      results =
        Map.new(requested_ids, fn event_id ->
          snapshot = Map.get(snapshots_by_event_id, normalized_event_id(event_id))
          {event_id, classify_snapshot(snapshot, now)}
        end)

      {:ok, results}
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

  defp advance_refund_watermark(event_id, refund_source_created_at) do
    case Ash.create(
           EventSourceFreshnessSnapshot,
           %{
             event_id: event_id,
             refund_source_watermark_at: refund_source_created_at,
             projection_refreshed_at: DateTime.utc_now()
           },
           action: :advance_refund_watermark,
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

  defp advance_sync_source_observed_watermark(event_id, source_observed_at) do
    case Ash.create(
           EventSourceFreshnessSnapshot,
           %{
             event_id: event_id,
             sync_source_observed_at: source_observed_at,
             projection_refreshed_at: DateTime.utc_now()
           },
           action: :advance_sync_source_observed,
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

  defp fetch_snapshots(event_ids) do
    case EventSourceFreshnessSnapshot
         |> Ash.Query.filter(expr(event_id in ^event_ids))
         |> Ash.read(domain: EventSales.Analytics) do
      {:ok, snapshots} -> {:ok, snapshots}
      {:error, reason} -> {:error, reason}
    end
  end

  defp classify_snapshot(nil, _now), do: {:error, :missing_source_freshness_anchor}

  defp classify_snapshot(%EventSourceFreshnessSnapshot{} = snapshot, now) do
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

  defp normalized_event_id(event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, uuid} -> uuid
      :error -> event_id
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
