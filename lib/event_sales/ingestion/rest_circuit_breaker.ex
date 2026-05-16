defmodule EventSales.Ingestion.RestCircuitBreaker do
  @moduledoc """
  Node-local WooCommerce REST circuit breaker.
  """

  use GenServer

  alias EventSales.Ingestion.Clients.WooCommerceError

  @default_failure_threshold 3
  @default_cooldown_ms 30_000
  @retryable_reasons MapSet.new([:rate_limited, :server_error, :timeout, :transport_error])

  @type state_name :: :closed | :open | :half_open
  @type snapshot :: %{
          state: state_name(),
          failures: non_neg_integer(),
          probe_in_flight?: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Runs `fun` when the breaker allows a request.
  """
  @spec run((-> result)) :: result | {:error, WooCommerceError.t()} when result: term()
  def run(fun) when is_function(fun, 0) do
    case GenServer.call(__MODULE__, :before_request) do
      {:ok, token} ->
        result = fun.()
        GenServer.call(__MODULE__, {:after_request, token, classify(result)})
        result

      {:error, :circuit_open} ->
        {:error, WooCommerceError.exception(reason: :circuit_open)}
    end
  end

  @doc "Returns current breaker state for tests and operational checks."
  @spec snapshot() :: snapshot()
  def snapshot do
    GenServer.call(__MODULE__, :snapshot)
  end

  @doc false
  @spec reset_for_test!() :: :ok
  def reset_for_test! do
    GenServer.call(__MODULE__, :reset)
  end

  @impl true
  def init(_opts) do
    {:ok, closed_state()}
  end

  @impl true
  def handle_call(:before_request, _from, %{state: :closed} = state) do
    {:reply, {:ok, make_ref()}, state}
  end

  def handle_call(:before_request, _from, %{state: :open, opened_at: opened_at} = state) do
    if now_ms() - opened_at >= cooldown_ms() do
      token = make_ref()

      {:reply, {:ok, token},
       %{state | state: :half_open, probe_ref: token, probe_in_flight?: true}}
    else
      {:reply, {:error, :circuit_open}, state}
    end
  end

  def handle_call(:before_request, _from, %{state: :half_open, probe_in_flight?: true} = state) do
    {:reply, {:error, :circuit_open}, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       state: state.state,
       failures: state.failures,
       probe_in_flight?: state.probe_in_flight?
     }, state}
  end

  def handle_call(:reset, _from, _state) do
    {:reply, :ok, closed_state()}
  end

  def handle_call({:after_request, _token, :success}, _from, %{state: :half_open} = state) do
    {:reply, :ok,
     %{
       closed_state()
       | failure_threshold: state.failure_threshold,
         cooldown_ms: state.cooldown_ms
     }}
  end

  def handle_call({:after_request, _token, :success}, _from, state) do
    {:reply, :ok, %{state | failures: 0}}
  end

  def handle_call(
        {:after_request, _token, {:failure, reason}},
        _from,
        %{state: :half_open} = state
      ) do
    {:reply, :ok, open_state_after_half_open_failure(state, reason)}
  end

  def handle_call({:after_request, _token, {:failure, reason}}, _from, state) do
    state =
      if retryable?(reason) do
        failures = state.failures + 1

        if failures >= state.failure_threshold do
          open_state(%{state | failures: failures})
        else
          %{state | failures: failures}
        end
      else
        state
      end

    {:reply, :ok, state}
  end

  defp classify({:error, %WooCommerceError{reason: reason}}), do: {:failure, reason}
  defp classify({:ok, _}), do: :success
  defp classify(_other), do: :success

  defp retryable?(reason), do: MapSet.member?(@retryable_reasons, reason)

  defp open_state_after_half_open_failure(state, reason) do
    if retryable?(reason) do
      open_state(state)
    else
      open_state(%{state | failures: state.failures})
    end
  end

  defp open_state(state) do
    %{state | state: :open, opened_at: now_ms(), probe_ref: nil, probe_in_flight?: false}
  end

  defp closed_state do
    cfg = Application.get_env(:event_sales, :rest_circuit_breaker, [])

    %{
      state: :closed,
      failures: 0,
      opened_at: nil,
      probe_ref: nil,
      probe_in_flight?: false,
      failure_threshold: Keyword.get(cfg, :failure_threshold, @default_failure_threshold),
      cooldown_ms: Keyword.get(cfg, :cooldown_ms, @default_cooldown_ms)
    }
  end

  defp cooldown_ms do
    :event_sales
    |> Application.get_env(:rest_circuit_breaker, [])
    |> Keyword.get(:cooldown_ms, @default_cooldown_ms)
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
