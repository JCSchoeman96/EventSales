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
  @default_restore_scan_count 100
  @default_restore_max_snapshots 1_000
  @default_stale_after_ms 300_000

  @type apply_result :: :ok | {:error, term()}
  @type lifecycle :: :warming | :ready | :stale

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

  @doc "Returns rebuild and restore status for dashboard-safe reads."
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc "Requests an async hot-state rebuild when one is not already running."
  @spec request_rebuild(atom() | String.t()) :: :ok | :already_running | {:error, term()}
  def request_rebuild(reason) do
    call_if_running({:request_rebuild, reason})
  end

  @doc "Notifies the aggregator that the async rebuild worker finished."
  @spec rebuild_finished(map()) :: :ok
  def rebuild_finished(result) when is_map(result) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      _pid -> GenServer.cast(__MODULE__, {:rebuild_finished, result})
    end
  end

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

    state = %{
      applied: MapSet.new(),
      in_flight: MapSet.new(),
      latest_source_updated_at: %{},
      max_applied_event_ids: Keyword.get(opts, :max_applied_event_ids, max_applied_event_ids()),
      lifecycle: :warming,
      rebuild_in_flight?: false,
      restored_snapshot_count: 0,
      restore_finished?: false,
      last_restore_finished_at: nil,
      last_fresh_at: nil,
      last_rebuild_started_at: nil,
      last_rebuild_finished_at: nil,
      last_failure: nil
    }

    {:ok, state, {:continue, :restore_snapshots}}
  end

  @impl true
  def handle_continue(:restore_snapshots, state) do
    state
    |> restore_snapshots()
    |> maybe_schedule_boot_rebuild()
    |> then(&{:noreply, &1})
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, status_from_state(state), state}
  end

  def handle_call({:request_rebuild, reason}, _from, state) do
    case schedule_rebuild(state, reason) do
      {:ok, state} -> {:reply, :ok, state}
      {:already_running, state} -> {:reply, :already_running, state}
      {{:error, reason}, state} -> {:reply, {:error, reason}, state}
    end
  end

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
     %{
       state
       | applied: MapSet.new(),
         in_flight: MapSet.new(),
         latest_source_updated_at: %{},
         lifecycle: :warming,
         rebuild_in_flight?: false,
         restored_snapshot_count: 0,
         restore_finished?: true,
         last_restore_finished_at: nil,
         last_fresh_at: nil,
         last_rebuild_started_at: nil,
         last_rebuild_finished_at: nil,
         last_failure: nil
     }}
  end

  def handle_call(:delete_cache_table_for_test, _from, state) do
    DashboardCache.delete_table_for_test!()
    {:reply, :ok, state}
  end

  @impl true
  def handle_cast({:rebuild_finished, result}, state) do
    {:noreply, mark_rebuild_finished(state, result)}
  end

  defp call_if_running(message) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_running}
      _pid -> GenServer.call(__MODULE__, message)
    end
  end

  defp restore_snapshots(state) do
    adapter = snapshot_adapter()

    opts = [
      scan_count: restore_scan_count(),
      max_snapshots: restore_max_snapshots()
    ]

    finished_at = DateTime.utc_now()

    case adapter.list_event_summaries(opts) do
      {:ok, snapshots} ->
        restored_count = restore_snapshot_entries(snapshots)
        last_fresh_at = newest_snapshot_updated_at(snapshots) || finished_at

        %{
          state
          | lifecycle: lifecycle_for_fresh_at(last_fresh_at, restored_count),
            restored_snapshot_count: restored_count,
            restore_finished?: true,
            last_restore_finished_at: finished_at,
            last_fresh_at: if(restored_count > 0, do: last_fresh_at, else: state.last_fresh_at),
            last_failure: nil
        }

      {:error, reason} ->
        %{
          state
          | lifecycle: if(state.restored_snapshot_count > 0, do: :stale, else: :warming),
            restore_finished?: true,
            last_restore_finished_at: finished_at,
            last_failure: low_cardinality_reason(reason)
        }
    end
  end

  defp restore_snapshot_entries(snapshots) do
    snapshots
    |> Enum.take(restore_max_snapshots())
    |> Enum.reduce(0, fn
      %{event_id: event_id, summary: summary}, count
      when is_binary(event_id) and is_map(summary) ->
        case DashboardCache.put_event_summary(event_id, summary) do
          :ok -> count + 1
          {:error, _reason} -> count
        end

      _snapshot, count ->
        count
    end)
  end

  defp newest_snapshot_updated_at(snapshots) do
    snapshots
    |> Enum.flat_map(fn
      %{summary: %{updated_at: %DateTime{} = updated_at}} -> [updated_at]
      _snapshot -> []
    end)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp lifecycle_for_fresh_at(_fresh_at, 0), do: :warming

  defp lifecycle_for_fresh_at(%DateTime{} = fresh_at, _count) do
    if stale_fresh_at?(fresh_at), do: :stale, else: :ready
  end

  defp lifecycle_for_fresh_at(_fresh_at, _count), do: :ready

  defp maybe_schedule_boot_rebuild(
         %{restored_snapshot_count: count, lifecycle: lifecycle} = state
       )
       when count == 0 or lifecycle == :stale do
    if schedule_rebuild_on_boot?() do
      case schedule_rebuild(state, :boot_restore) do
        {:ok, state} -> state
        {:already_running, state} -> state
        {{:error, reason}, state} -> %{state | last_failure: low_cardinality_reason(reason)}
      end
    else
      state
    end
  end

  defp maybe_schedule_boot_rebuild(state), do: state

  defp schedule_rebuild(%{rebuild_in_flight?: true} = state, _reason),
    do: {:already_running, state}

  defp schedule_rebuild(state, reason) do
    args = %{"scope" => "hot_state", "reason" => to_string(reason)}

    case args |> EventSales.Analytics.Workers.RebuildHotStateWorker.new() |> Oban.insert() do
      {:ok, _job} ->
        {:ok,
         %{
           state
           | rebuild_in_flight?: true,
             last_rebuild_started_at: DateTime.utc_now(),
             last_failure: nil
         }}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  rescue
    _ -> {{:error, :unavailable}, state}
  end

  defp mark_rebuild_finished(state, %{"result" => result} = payload) do
    payload
    |> atomize_result_payload(result)
    |> then(&mark_rebuild_finished(state, &1))
  end

  defp mark_rebuild_finished(state, %{result: :ok} = result) do
    finished_at = Map.get(result, :finished_at, DateTime.utc_now())

    %{
      state
      | lifecycle: :ready,
        rebuild_in_flight?: false,
        restored_snapshot_count: Map.get(result, :rebuilt_count, state.restored_snapshot_count),
        last_rebuild_finished_at: finished_at,
        last_fresh_at: finished_at,
        last_failure: nil
    }
  end

  defp mark_rebuild_finished(state, %{result: :error} = result) do
    finished_at = Map.get(result, :finished_at, DateTime.utc_now())

    %{
      state
      | lifecycle: if(state.restored_snapshot_count > 0, do: :stale, else: :warming),
        rebuild_in_flight?: false,
        last_rebuild_finished_at: finished_at,
        last_failure: low_cardinality_reason(Map.get(result, :reason))
    }
  end

  defp mark_rebuild_finished(state, _result), do: %{state | rebuild_in_flight?: false}

  defp atomize_result_payload(payload, result) when is_binary(result) do
    Map.put(payload, :result, String.to_existing_atom(result))
  rescue
    _ -> Map.put(payload, :result, :error)
  end

  defp atomize_result_payload(payload, result), do: Map.put(payload, :result, result)

  defp status_from_state(state) do
    lifecycle =
      case {state.lifecycle, state.last_fresh_at} do
        {:ready, %DateTime{} = fresh_at} ->
          if stale_fresh_at?(fresh_at), do: :stale, else: :ready

        {lifecycle, _fresh_at} ->
          lifecycle
      end

    %{
      state: lifecycle,
      rebuild_in_flight?: state.rebuild_in_flight?,
      restored_snapshot_count: state.restored_snapshot_count,
      restore_finished?: state.restore_finished?,
      last_restore_finished_at: state.last_restore_finished_at,
      last_rebuild_started_at: state.last_rebuild_started_at,
      last_rebuild_finished_at: state.last_rebuild_finished_at,
      last_failure: state.last_failure
    }
  end

  defp stale_fresh_at?(%DateTime{} = fresh_at) do
    DateTime.diff(DateTime.utc_now(), fresh_at, :millisecond) > stale_after_ms()
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

  defp restore_scan_count do
    :event_sales
    |> Application.get_env(:hot_state_aggregator, [])
    |> Keyword.get(:restore_scan_count, @default_restore_scan_count)
  end

  defp restore_max_snapshots do
    :event_sales
    |> Application.get_env(:hot_state_aggregator, [])
    |> Keyword.get(:restore_max_snapshots, @default_restore_max_snapshots)
  end

  defp schedule_rebuild_on_boot? do
    :event_sales
    |> Application.get_env(:hot_state_aggregator, [])
    |> Keyword.get(:schedule_rebuild_on_boot?, true)
  end

  defp stale_after_ms do
    :event_sales
    |> Application.get_env(:hot_state_aggregator, [])
    |> Keyword.get(:stale_after_ms, @default_stale_after_ms)
  end
end
