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
      {:ok, rebuilt_count} ->
        duration = System.monotonic_time() - started_at
        emit_stop(duration, rebuilt_count)

        HotStateAggregator.rebuild_finished(%{
          result: :ok,
          rebuilt_count: rebuilt_count,
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
    rebuild_pages(nil, 0)
  end

  defp rebuild_pages(after_event_id, rebuilt_count) do
    batch = SnapshotQueries.event_ids_page(after_event_id, rebuild_batch_size())

    case rebuild_batch(batch, rebuilt_count) do
      {:ok, rebuilt_count} when batch == [] ->
        {:ok, rebuilt_count}

      {:ok, rebuilt_count} ->
        rebuild_pages(List.last(batch), rebuilt_count)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp rebuild_batch([], rebuilt_count), do: {:ok, rebuilt_count}

  defp rebuild_batch([event_id | rest], rebuilt_count) do
    case rebuild_event(event_id) do
      :ok -> rebuild_batch(rest, rebuilt_count + 1)
      {:error, reason} -> {:error, reason}
    end
  end

  defp rebuild_event(event_id) do
    case event_aggregator().summary_for_event(event_id) do
      {:ok, summary} ->
        updated_at = DateTime.utc_now()
        summary = Map.put(summary, :updated_at, updated_at)

        with :ok <- DashboardCache.put_event_summary(event_id, summary),
             :ok <- write_snapshot(event_id, summary) do
          :ok
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

  defp emit_stop(duration, rebuilt_count) do
    Telemetry.emit(Telemetry.hot_state_rebuild_stop(), %{duration: duration}, %{
      source: :postgres,
      result: :ok,
      rebuilt_count: rebuilt_count
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
