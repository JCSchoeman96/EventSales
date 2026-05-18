defmodule EventSales.Ingestion.Workers.ReconcileOrdersWorker do
  @moduledoc """
  Oban worker that drives scoped WooCommerce order reconciliation for a `SyncRun`.
  """

  use Oban.Worker,
    queue: :reconciliation,
    max_attempts: 25,
    unique: [
      period: :infinity,
      fields: [:args],
      keys: [:sync_run_id],
      states: ~w(available scheduled executing retryable)a
    ]

  require Ash.Query

  alias EventSales.Ingestion
  alias EventSales.Ingestion.OrderReconciliation
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.Telemetry

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"sync_run_id" => sync_run_id}}) when is_binary(sync_run_id) do
    case load_run(sync_run_id) do
      :discard ->
        :discard

      {:error, reason} ->
        {:error, reason}

      {:ok, run} ->
        perform_loaded_run(run)
    end
  end

  def perform(%Oban.Job{args: _args}), do: :discard

  defp perform_loaded_run(run) do
    case check_future_paused(run) do
      {:snooze, seconds} ->
        {:snooze, seconds}

      :ok ->
        run_reconciliation_step(run)
    end
  end

  defp run_reconciliation_step(run) do
    with {:ok, run} <- maybe_start_or_resume(run),
         {:ok, cursor} <- load_cursor(run) do
      run
      |> OrderReconciliation.run_step(cursor, opts())
      |> handle_result()
    end
  end

  defp load_run(sync_run_id) do
    case Ash.get(SyncRun, sync_run_id, domain: Ingestion) do
      {:ok, %SyncRun{status: status}} when status in [:completed, :failed, :cancelled] ->
        :discard

      {:ok, %SyncRun{} = run} ->
        {:ok, run}

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        :discard

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp check_future_paused(%SyncRun{status: :paused, paused_until: %DateTime{} = paused_until}) do
    seconds = DateTime.diff(paused_until, DateTime.utc_now(), :second)

    if seconds > 0 do
      {:snooze, max(seconds, 1)}
    else
      :ok
    end
  end

  defp check_future_paused(%SyncRun{paused_until: %DateTime{} = paused_until}) do
    seconds = DateTime.diff(paused_until, DateTime.utc_now(), :second)

    if seconds > 0 do
      {:snooze, max(seconds, 1)}
    else
      :ok
    end
  end

  defp check_future_paused(_run), do: :ok

  defp maybe_start_or_resume(%SyncRun{status: :queued} = run) do
    Ash.update(run, %{}, action: :start, domain: Ingestion)
  end

  defp maybe_start_or_resume(%SyncRun{status: :paused} = run) do
    Ash.update(run, %{}, action: :resume, domain: Ingestion)
  end

  defp maybe_start_or_resume(%SyncRun{} = run), do: {:ok, run}

  defp load_cursor(%SyncRun{id: sync_run_id}) do
    case SyncCursor
         |> Ash.Query.filter(sync_run_id == ^sync_run_id)
         |> Ash.read_one(domain: Ingestion) do
      {:ok, cursor} -> {:ok, cursor}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_result({:pause, _run, _pause_reason, seconds}), do: {:snooze, seconds}

  defp handle_result({:continue, _run}), do: {:snooze, 1}

  defp handle_result({:complete, run}) do
    Telemetry.emit(Telemetry.reconciliation_stop(), %{count: 1}, %{
      sync_mode: run.sync_mode,
      requested_via: run.requested_via,
      result: :completed,
      source: :reconciliation
    })

    :ok
  end

  defp handle_result({:ok, _run}), do: :ok

  defp handle_result({:error, reason}), do: {:error, reason}

  defp opts do
    [
      woocommerce_client: woocommerce_client(),
      order_upserter: order_upserter(),
      order_processed_notifier: order_processed_notifier(),
      transport: transport()
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp woocommerce_client do
    Application.get_env(:event_sales, :woocommerce_client)
  end

  defp order_upserter do
    Application.get_env(:event_sales, :order_upserter)
  end

  defp order_processed_notifier do
    Application.get_env(:event_sales, :order_processed_notifier)
  end

  defp transport do
    Application.get_env(:event_sales, :woocommerce_rest, [])
    |> Keyword.get(:transport)
  end
end
