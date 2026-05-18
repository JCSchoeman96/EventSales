defmodule EventSales.Analytics.Workers.RebuildHotStateWorker do
  @moduledoc """
  Rebuilds dashboard hot-state summaries from durable Postgres state.

  The worker is intentionally single-concurrency and unique because it may scan
  many events after a restart. It writes through `DashboardCache` and the warm
  snapshot adapter; Redis remains a recoverable read model, not durable truth.
  """

  use Oban.Worker,
    queue: :analytics_rebuilds,
    max_attempts: 3,
    unique: [
      period: 300,
      fields: [:args],
      keys: [:scope],
      states: ~w(available scheduled executing retryable)a
    ]

  alias EventSales.Analytics.Aggregators.EventAggregator
  alias EventSales.Analytics.{CacheKeys, DashboardCache, HotStateAggregator, SnapshotQueries}
  alias EventSales.Telemetry

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scope" => "hot_state"}}) do
    started_at = System.monotonic_time()
    emit_start()

    case rebuild_all_events() do
      {:ok, %{rebuilt_count: rebuilt_count, failed_count: failed_count}} ->
        duration = System.monotonic_time() - started_at
        emit_stop(duration, rebuilt_count, failed_count)

        HotStateAggregator.rebuild_finished(%{
          result: :ok,
          rebuilt_count: rebuilt_count,
          failed_count: failed_count,
          finished_at: DateTime.utc_now()
        })

        :ok

      {:error, reason} ->
        emit_exception(reason)

        HotStateAggregator.rebuild_finished(%{
          result: :error,
          reason: reason,
          finished_at: DateTime.utc_now()
        })

        {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: :discard

  @impl Oban.Worker
  def timeout(_job), do: rebuild_timeout_ms()

  defp rebuild_all_events do
    rebuild_pages(nil, %{rebuilt_count: 0, failed_count: 0})
  end

  defp rebuild_pages(after_event_id, counts) do
    batch = SnapshotQueries.event_ids_page(after_event_id, rebuild_batch_size())

    case rebuild_batch(batch, counts) do
      {:ok, counts} when batch == [] ->
        {:ok, counts}

      {:ok, counts} ->
        rebuild_pages(List.last(batch), counts)
    end
  rescue
    _ -> {:error, :query_failed}
  end

  defp rebuild_batch([], counts), do: {:ok, counts}

  defp rebuild_batch([event_id | rest], counts) do
    case rebuild_event(event_id) do
      :ok ->
        rebuild_batch(rest, Map.update!(counts, :rebuilt_count, &(&1 + 1)))

      {:error, reason} ->
        emit_event_failure(reason)
        rebuild_batch(rest, Map.update!(counts, :failed_count, &(&1 + 1)))
    end
  end

  defp rebuild_event(event_id) do
    case event_aggregator().summary_for_event(event_id) do
      {:ok, summary} ->
        updated_at = DateTime.utc_now()
        summary = Map.put(summary, :updated_at, updated_at)

        case DashboardCache.put_event_summary(event_id, summary) do
          :ok -> write_snapshot(event_id, summary)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_snapshot(event_id, summary) do
    adapter = snapshot_adapter()

    if adapter == EventSales.Analytics.SnapshotStore.NoopAdapter do
      :ok
    else
      adapter.put(CacheKeys.redis_event_snapshot(event_id), summary, ttl_ms: snapshot_ttl_ms())
    end
  end

  defp emit_start do
    Telemetry.emit(Telemetry.hot_state_rebuild_start(), %{count: 1}, %{source: :postgres})
  end

  defp emit_stop(duration, rebuilt_count, failed_count) do
    Telemetry.emit(Telemetry.hot_state_rebuild_stop(), %{duration: duration}, %{
      source: :postgres,
      result: :ok,
      rebuilt_count: rebuilt_count,
      failed_count: failed_count
    })
  end

  defp emit_event_failure(reason) do
    Telemetry.emit(Telemetry.hot_state_rebuild_exception(), %{count: 1}, %{
      source: :postgres,
      scope: :event,
      reason: low_cardinality_reason(reason)
    })
  end

  defp emit_exception(reason) do
    Telemetry.emit(Telemetry.hot_state_rebuild_exception(), %{count: 1}, %{
      source: :postgres,
      reason: low_cardinality_reason(reason)
    })
  end

  defp low_cardinality_reason(reason) when is_atom(reason), do: reason
  defp low_cardinality_reason(_reason), do: :error

  defp event_aggregator do
    :event_sales
    |> Application.get_env(:hot_state_aggregator, [])
    |> Keyword.get(:event_aggregator, EventAggregator)
  end

  defp snapshot_adapter do
    :event_sales
    |> Application.get_env(:hot_state_aggregator, [])
    |> Keyword.get(:snapshot_adapter, EventSales.Analytics.SnapshotStore.NoopAdapter)
  end

  defp snapshot_ttl_ms do
    :event_sales
    |> Application.get_env(:hot_state_aggregator, [])
    |> Keyword.get(:snapshot_ttl_ms, :timer.hours(1))
  end

  defp rebuild_batch_size do
    :event_sales
    |> Application.get_env(:hot_state_aggregator, [])
    |> Keyword.get(:rebuild_batch_size, 50)
  end

  defp rebuild_timeout_ms do
    :event_sales
    |> Application.get_env(:hot_state_aggregator, [])
    |> Keyword.get(:rebuild_timeout_ms, :timer.minutes(5))
  end
end
