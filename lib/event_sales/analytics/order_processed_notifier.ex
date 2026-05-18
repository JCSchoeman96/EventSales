defmodule EventSales.Analytics.OrderProcessedNotifier do
  @moduledoc """
  Bridges durable processed order writes to event-scoped dashboard hot state.

  This module runs after Sales writes have succeeded. It invalidates stale event
  cache entries, requests hot-state recompute from durable Postgres state, and
  leaves PubSub broadcasting to `HotStateAggregator` after recompute succeeds.
  """

  require Ash.Query

  alias EventSales.Analytics.{DashboardCache, HotStateAggregator}
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.Telemetry

  @doc """
  Notifies dashboard hot state that a durable order upsert has completed.
  """
  @spec notify_order_processed(Order.t(), WebhookEvent.t(), keyword()) :: :ok
  def notify_order_processed(%Order{} = order, %WebhookEvent{} = webhook_event, opts \\ []) do
    case affected_event_ids(order) do
      {:ok, event_ids} ->
        Enum.each(event_ids, &notify_event(&1, order, webhook_event, opts))

      {:error, _reason} ->
        emit_failure(:notifier_query_failed)
    end

    :ok
  end

  defp affected_event_ids(%Order{id: order_id}) do
    OrderItem
    |> Ash.Query.filter(
      order_id == ^order_id and
        mapping_status == :mapped and
        item_kind == :ticket and
        not is_nil(event_id)
    )
    |> Ash.read(domain: Sales)
    |> case do
      {:ok, rows} ->
        event_ids =
          rows
          |> Enum.map(& &1.event_id)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()

        {:ok, event_ids}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp notify_event(event_id, %Order{} = order, %WebhookEvent{} = webhook_event, opts) do
    DashboardCache.invalidate_event(event_id, :order_processed)
    emit_cache_invalidate()

    event = aggregate_event(event_id, order, webhook_event)
    hot_state_aggregator = Keyword.get(opts, :hot_state_aggregator, HotStateAggregator)

    case hot_state_aggregator.apply_event(event) do
      :ok -> :ok
      {:error, _reason} -> emit_failure(:notifier_apply_failed)
    end
  rescue
    _exception -> emit_failure(:notifier_apply_failed)
  catch
    _kind, _reason -> emit_failure(:notifier_apply_failed)
  end

  defp aggregate_event(event_id, %Order{} = order, %WebhookEvent{} = webhook_event) do
    source_updated_at = webhook_event.source_updated_at || order.updated_at_source
    occurred_at = DateTime.utc_now()

    %{
      aggregate_event_id: aggregate_event_id(order, event_id, source_updated_at, webhook_event),
      event_id: event_id,
      reason: :order_processed,
      occurred_at: occurred_at,
      source_system_id: order.source_system_id,
      order_id: order.id,
      source_updated_at: source_updated_at,
      payload_hash: webhook_event.payload_hash
    }
  end

  defp aggregate_event_id(%Order{} = order, event_id, source_updated_at, webhook_event) do
    source_timestamp =
      case source_updated_at do
        %DateTime{} = datetime -> DateTime.to_iso8601(datetime)
        _other -> "unknown"
      end

    [
      "order",
      order.id,
      "event",
      event_id,
      "source",
      source_timestamp,
      "payload",
      webhook_event.payload_hash || "none"
    ]
    |> Enum.join(":")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp emit_cache_invalidate do
    Telemetry.emit(Telemetry.cache_invalidate(), %{count: 1}, %{
      scope: :event,
      reason: :order_processed,
      source: :webhook
    })
  end

  defp emit_failure(reason) do
    Telemetry.emit(Telemetry.hot_state_event_ignored(), %{count: 1}, %{
      reason: reason,
      event_reason: :order_processed,
      result: :ignored,
      source: :webhook
    })
  end
end
