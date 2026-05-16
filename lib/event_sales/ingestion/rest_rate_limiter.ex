defmodule EventSales.Ingestion.RestRateLimiter do
  @moduledoc """
  Node-local semaphore for WooCommerce REST calls.

  The limiter grants permits only. Callers execute REST work in their own
  process and release permits through `after` blocks.
  """

  use GenServer

  alias EventSales.Ingestion.Clients.WooCommerceError

  @default_max_concurrency 2
  @default_queue_timeout_ms 5_000

  @type snapshot :: %{
          active: non_neg_integer(),
          queued: non_neg_integer(),
          max_concurrency: pos_integer()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Executes `fun` in the caller process while holding a REST permit.
  """
  @spec checkout((-> result), keyword()) :: result | {:error, WooCommerceError.t()}
        when result: term()
  def checkout(fun, opts \\ []) when is_function(fun, 0) do
    queue_timeout_ms = Keyword.get(opts, :queue_timeout_ms, configured_queue_timeout_ms())

    case GenServer.call(__MODULE__, {:acquire, queue_timeout_ms}, queue_timeout_ms + 1_000) do
      {:ok, permit_ref} ->
        try do
          fun.()
        after
          release(permit_ref)
        end

      {:error, :queue_timeout} ->
        {:error, WooCommerceError.exception(reason: :queue_timeout)}
    end
  end

  @doc "Returns current limiter state for tests and operational checks."
  @spec snapshot() :: snapshot()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc false
  @spec reset_for_test!(keyword()) :: :ok
  def reset_for_test!(opts \\ []) do
    GenServer.call(__MODULE__, {:reset, opts})
  end

  @impl true
  def init(opts) do
    max_concurrency = Keyword.get(opts, :max_concurrency, configured_max_concurrency())

    {:ok,
     %{
       max_concurrency: max_concurrency,
       active: %{},
       queue: :queue.new()
     }}
  end

  @impl true
  def handle_call({:acquire, queue_timeout_ms}, from, state) do
    caller = caller_pid(from)

    if map_size(state.active) < state.max_concurrency do
      {grant_ref, state} = grant_permit(state, caller)
      {:reply, {:ok, grant_ref}, state}
    else
      monitor_ref = Process.monitor(caller)
      timer_ref = Process.send_after(self(), {:queue_timeout, from}, queue_timeout_ms)
      entry = %{from: from, caller: caller, monitor_ref: monitor_ref, timer_ref: timer_ref}
      {:noreply, %{state | queue: :queue.in(entry, state.queue)}}
    end
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       active: map_size(state.active),
       queued: :queue.len(state.queue),
       max_concurrency: state.max_concurrency
     }, state}
  end

  def handle_call({:reset, opts}, _from, _state) do
    max_concurrency = Keyword.get(opts, :max_concurrency, configured_max_concurrency())
    {:reply, :ok, %{max_concurrency: max_concurrency, active: %{}, queue: :queue.new()}}
  end

  @impl true
  def handle_cast({:release, permit_ref}, state) do
    state =
      case Map.pop(state.active, permit_ref) do
        {nil, active} ->
          %{state | active: active}

        {%{monitor_ref: monitor_ref}, active} ->
          Process.demonitor(monitor_ref, [:flush])
          %{state | active: active}
      end

    {:noreply, grant_waiting_callers(state)}
  end

  @impl true
  def handle_info({:queue_timeout, from}, state) do
    {entry, queue} = pop_queued_by_from(state.queue, from)

    if entry do
      Process.demonitor(entry.monitor_ref, [:flush])
      GenServer.reply(from, {:error, :queue_timeout})
    end

    {:noreply, %{state | queue: queue}}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, _reason}, state) do
    state = release_active_by_monitor(state, monitor_ref)
    {entry, queue} = pop_queued_by_monitor(state.queue, monitor_ref)

    if entry do
      Process.cancel_timer(entry.timer_ref)
    end

    {:noreply, grant_waiting_callers(%{state | queue: queue})}
  end

  defp release(permit_ref), do: GenServer.cast(__MODULE__, {:release, permit_ref})

  defp grant_permit(state, caller) do
    grant_ref = make_ref()
    monitor_ref = Process.monitor(caller)

    {grant_ref,
     %{
       state
       | active: Map.put(state.active, grant_ref, %{caller: caller, monitor_ref: monitor_ref})
     }}
  end

  defp grant_waiting_callers(state) do
    if map_size(state.active) < state.max_concurrency do
      case :queue.out(state.queue) do
        {{:value, entry}, queue} ->
          Process.cancel_timer(entry.timer_ref)
          Process.demonitor(entry.monitor_ref, [:flush])
          {grant_ref, state} = grant_permit(%{state | queue: queue}, entry.caller)
          GenServer.reply(entry.from, {:ok, grant_ref})

          grant_waiting_callers(state)

        {:empty, _queue} ->
          state
      end
    else
      state
    end
  end

  defp pop_queued_by_from(queue, from), do: pop_queued(queue, &(&1.from == from))

  defp pop_queued_by_monitor(queue, monitor_ref),
    do: pop_queued(queue, &(&1.monitor_ref == monitor_ref))

  defp pop_queued(queue, predicate) do
    queue
    |> :queue.to_list()
    |> Enum.reduce({nil, :queue.new()}, fn entry, {found, acc} ->
      cond do
        found -> {found, :queue.in(entry, acc)}
        predicate.(entry) -> {entry, acc}
        true -> {nil, :queue.in(entry, acc)}
      end
    end)
  end

  defp release_active_by_monitor(state, monitor_ref) do
    active =
      state.active
      |> Enum.reject(fn {_permit_ref, permit} -> permit.monitor_ref == monitor_ref end)
      |> Map.new()

    %{state | active: active}
  end

  defp caller_pid({pid, _tag}), do: pid

  defp configured_max_concurrency do
    :event_sales
    |> Application.get_env(:woocommerce_rest, [])
    |> Keyword.get(:max_concurrency, @default_max_concurrency)
  end

  defp configured_queue_timeout_ms do
    :event_sales
    |> Application.get_env(:woocommerce_rest, [])
    |> Keyword.get(:queue_timeout_ms, @default_queue_timeout_ms)
  end
end
