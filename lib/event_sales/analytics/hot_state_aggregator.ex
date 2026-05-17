defmodule EventSales.Analytics.HotStateAggregator do
  @moduledoc """
  Supervised GenServer for hot dashboard event summaries.

  This process accepts post-commit aggregate events, recomputes summaries from
  durable Postgres state via `EventAggregator`, writes ETS hot cache, attempts a
  warm snapshot write, and broadcasts a small PubSub update.
  """

  use GenServer

  alias EventSales.Analytics.Aggregators.EventAggregator

  alias EventSales.Analytics.{
    AggregateEvent,
    AggregateEventIdempotency,
    CacheKeys,
    DashboardCache
  }

  alias EventSales.Telemetry

  @default_max_applied_event_ids 10_000

  @type apply_result :: :ok | {:error, term()}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Applies an aggregate recompute signal to the hot read model.
  """
  @spec apply_event(map() | AggregateEvent.t(), keyword()) :: apply_result()
  def apply_event(event_or_attrs, opts \\ []) do
    GenServer.call(__MODULE__, {:apply_event, event_or_attrs, opts}, :timer.seconds(30))
  end

  @doc "Returns the current hot event summary."
  @spec summary_for_event(Ecto.UUID.t() | String.t()) :: {:ok, map()} | :miss
  def summary_for_event(event_id), do: DashboardCache.get_event_summary(event_id)

  @doc false
  @spec reset_for_test!() :: :ok
  def reset_for_test! do
    case Process.whereis(__MODULE__) do
      nil ->
        DashboardCache.ensure_table!()
        clear_table()
        :ok

      _pid ->
        GenServer.call(__MODULE__, :reset_for_test)
    end
  end

  @doc false
  @spec delete_cache_table_for_test!() :: :ok
  def delete_cache_table_for_test! do
    case Process.whereis(__MODULE__) do
      nil -> DashboardCache.delete_table_for_test!()
      _pid -> GenServer.call(__MODULE__, :delete_cache_table_for_test)
    end
  end

  @impl true
  def init(opts) do
    DashboardCache.ensure_table!()

    {:ok,
     %{
       applied: MapSet.new(),
       in_flight: MapSet.new(),
       latest_source_updated_at: %{},
       max_applied_event_ids: Keyword.get(opts, :max_applied_event_ids, max_applied_event_ids())
     }}
  end

  @impl true
  def handle_call({:apply_event, event_or_attrs, opts}, _from, state) do
    case AggregateEvent.new(event_or_attrs) do
      {:ok, event} -> handle_valid_event(event, opts, state)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:reset_for_test, _from, state) do
    DashboardCache.ensure_table!()
    clear_table()

    {:reply, :ok,
     %{state | applied: MapSet.new(), in_flight: MapSet.new(), latest_source_updated_at: %{}}}
  end

  def handle_call(:delete_cache_table_for_test, _from, state) do
    DashboardCache.delete_table_for_test!()
    {:reply, :ok, state}
  end

  defp handle_valid_event(%AggregateEvent{} = event, opts, state) do
    cond do
      AggregateEventIdempotency.duplicate?(state, event.aggregate_event_id) ->
        emit_ignored(:duplicate, event)
        {:reply, :ok, state}

      stale?(event, state) ->
        emit_ignored(:stale_source_update, event)

        state =
          state
          |> AggregateEventIdempotency.reserve(event.aggregate_event_id)
          |> AggregateEventIdempotency.mark_applied(
            event.aggregate_event_id,
            state.max_applied_event_ids
          )

        {:reply, :ok, state}

      true ->
        event
        |> recompute_and_publish(
          opts,
          AggregateEventIdempotency.reserve(state, event.aggregate_event_id)
        )
    end
  end

  defp recompute_and_publish(%AggregateEvent{} = event, opts, state) do
    event_aggregator = Keyword.get(opts, :event_aggregator, event_aggregator())
    summary_opts = Keyword.get(opts, :summary_opts, [])

    case event_aggregator.summary_for_event(event.event_id, summary_opts) do
      {:ok, summary} ->
        write_hot_cache(event, summary, opts, state)

      {:error, reason} ->
        emit_ignored(reason, event, :error)
        state = AggregateEventIdempotency.clear_in_flight(state, event.aggregate_event_id)
        {:reply, {:error, reason}, state}
    end
  end

  defp write_hot_cache(%AggregateEvent{} = event, summary, opts, state) do
    updated_at = DateTime.utc_now()
    summary = Map.put(summary, :updated_at, updated_at)

    DashboardCache.ensure_table!()

    case DashboardCache.put_event_summary(event.event_id, summary) do
      :ok ->
        state =
          state
          |> AggregateEventIdempotency.mark_applied(
            event.aggregate_event_id,
            state.max_applied_event_ids
          )
          |> update_latest_source(event)

        write_snapshot(event, summary, opts)
        broadcast_update(event.event_id, updated_at)
        emit_applied(event)

        {:reply, :ok, state}

      {:error, reason} ->
        emit_ignored(reason, event, :error)
        state = AggregateEventIdempotency.clear_in_flight(state, event.aggregate_event_id)
        {:reply, {:error, reason}, state}
    end
  end

  defp stale?(%AggregateEvent{reason: :manual_refresh}, _state), do: false
  defp stale?(%AggregateEvent{source_updated_at: nil}, _state), do: false

  defp stale?(%AggregateEvent{source_updated_at: %DateTime{} = incoming} = event, state) do
    case Map.get(state.latest_source_updated_at, stale_key(event)) do
      %DateTime{} = latest -> DateTime.compare(incoming, latest) == :lt
      nil -> false
    end
  end

  defp update_latest_source(state, %AggregateEvent{source_updated_at: nil}), do: state
  defp update_latest_source(state, %AggregateEvent{reason: :manual_refresh}), do: state

  defp update_latest_source(
         state,
         %AggregateEvent{source_updated_at: %DateTime{} = incoming} = event
       ) do
    key = stale_key(event)

    latest =
      case Map.get(state.latest_source_updated_at, key) do
        %DateTime{} = existing ->
          if DateTime.compare(incoming, existing) == :gt, do: incoming, else: existing

        nil ->
          incoming
      end

    %{state | latest_source_updated_at: Map.put(state.latest_source_updated_at, key, latest)}
  end

  defp stale_key(%AggregateEvent{source_system_id: source_system_id, order_id: order_id})
       when is_binary(source_system_id) and is_binary(order_id) do
    {:order, source_system_id, order_id}
  end

  defp stale_key(%AggregateEvent{event_id: event_id}), do: {:event, event_id}

  defp write_snapshot(%AggregateEvent{} = event, summary, opts) do
    adapter = Keyword.get(opts, :snapshot_adapter, snapshot_adapter())
    do_write_snapshot(adapter, event, summary)
  end

  defp do_write_snapshot(EventSales.Analytics.SnapshotStore.NoopAdapter, _event, _summary),
    do: :ok

  defp do_write_snapshot(adapter, %AggregateEvent{} = event, summary) do
    key = CacheKeys.redis_event_snapshot(event.event_id)
    snapshot_opts = [ttl_ms: snapshot_ttl_ms()]

    case adapter.put(key, summary, snapshot_opts) do
      :ok ->
        emit_snapshot(:ok, nil)

      {:error, reason} ->
        emit_snapshot(:error, reason)
    end
  end

  defp broadcast_update(event_id, updated_at) do
    Phoenix.PubSub.broadcast(
      EventSales.PubSub,
      "analytics:event:#{event_id}",
      {:hot_state_updated, event_id, updated_at}
    )
  end

  defp clear_table do
    case :ets.whereis(DashboardCache.table_name()) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end
  end

  defp emit_applied(%AggregateEvent{} = event) do
    Telemetry.emit(Telemetry.hot_state_event_applied(), %{count: 1}, %{
      reason: event.reason,
      result: :ok,
      source: :postgres
    })
  end

  defp emit_ignored(reason, %AggregateEvent{} = event, result \\ :ignored) do
    Telemetry.emit(Telemetry.hot_state_event_ignored(), %{count: 1}, %{
      reason: low_cardinality_reason(reason),
      event_reason: event.reason,
      result: result,
      source: :postgres
    })
  end

  defp emit_snapshot(result, reason) do
    Telemetry.emit(Telemetry.hot_state_snapshot_write(), %{count: 1}, %{
      result: result,
      reason: low_cardinality_reason(reason),
      source: :redis
    })
  end

  defp low_cardinality_reason(nil), do: :none
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

  defp max_applied_event_ids do
    :event_sales
    |> Application.get_env(:hot_state_aggregator, [])
    |> Keyword.get(:max_applied_event_ids, @default_max_applied_event_ids)
  end
end
