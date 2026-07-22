defmodule EventSales.Health.DatabaseReadiness do
  @moduledoc """
  Maintains a hot, bounded snapshot of PostgreSQL readiness.

  One supervised process probes PostgreSQL periodically. HTTP callers read the
  resulting ETS snapshot without contacting the database.
  """

  use GenServer

  require Logger

  @table __MODULE__
  @interval_ms 5_000
  @query_timeout_ms 1_000
  @stale_after_ms 15_000

  @type readiness :: :ready | :not_ready

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Reads the current readiness snapshot directly from ETS."
  @spec status(atom(), keyword()) :: readiness()
  def status(table \\ @table, opts \\ []) do
    now = Keyword.get(opts, :now, &monotonic_milliseconds/0)
    stale_after_ms = Keyword.get(opts, :stale_after_ms, @stale_after_ms)

    case ready_checked_at(table) do
      {:ok, checked_at} ->
        if now.() - checked_at <= stale_after_ms, do: :ready, else: :not_ready

      :error ->
        :not_ready
    end
  end

  @doc false
  @spec probe_now(GenServer.server()) :: :ok
  def probe_now(server \\ __MODULE__) do
    GenServer.cast(server, :probe_now)
  end

  @impl true
  def init(opts) do
    table = Keyword.get(opts, :table, @table)
    :ets.new(table, [:named_table, :set, :protected, read_concurrency: true])

    state = %{
      table: table,
      probe: Keyword.get(opts, :probe, &probe_database/0),
      now: Keyword.get(opts, :now, &monotonic_milliseconds/0),
      schedule: Keyword.get(opts, :schedule, &Process.send_after(&1, :probe, &2)),
      interval_ms: Keyword.get(opts, :interval_ms, @interval_ms)
    }

    publish(state, false)
    {:ok, state, {:continue, :probe}}
  end

  @impl true
  def handle_continue(:probe, state), do: run_and_schedule(state)

  @impl true
  def handle_info(:probe, state), do: run_and_schedule(state)

  @impl true
  def handle_cast(:probe_now, state) do
    {:noreply, run_probe(state)}
  end

  defp run_and_schedule(state) do
    state.schedule.(self(), state.interval_ms)
    {:noreply, run_probe(state)}
  end

  defp run_probe(state) do
    was_ready? = snapshot_ready?(state.table)
    ready? = safe_probe(state.probe)

    if was_ready? and not ready? do
      Logger.warning("database_readiness_failed")
    end

    publish(state, ready?)
    state
  end

  defp safe_probe(probe) do
    case probe.() do
      :ok -> true
      {:ok, _result} -> true
      _other -> false
    end
  rescue
    _error -> false
  catch
    _kind, _reason -> false
  end

  defp probe_database do
    case EventSales.Repo.query("SELECT 1", [], timeout: @query_timeout_ms) do
      {:ok, _result} -> :ok
      {:error, _reason} -> :error
    end
  end

  defp publish(state, ready?) do
    :ets.insert(state.table, {:snapshot, ready?, state.now.()})
  end

  defp snapshot_ready?(table) do
    match?([{:snapshot, true, _checked_at}], :ets.lookup(table, :snapshot))
  end

  defp ready_checked_at(table) do
    with table_id when table_id != :undefined <- :ets.whereis(table),
         [{:snapshot, true, checked_at}] when is_integer(checked_at) <-
           :ets.lookup(table, :snapshot) do
      {:ok, checked_at}
    else
      _other -> :error
    end
  end

  defp monotonic_milliseconds, do: System.monotonic_time(:millisecond)
end
