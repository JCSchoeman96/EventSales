defmodule EventSales.Ingestion.Workers.BackfillOrdersWorker do
  @moduledoc """
  Oban worker for one bounded historical WooCommerce order page.

  A perform call delegates one page to `OrderReconciliation` and schedules the
  next call through Oban. It never loops through the complete historical range
  in one VM process.
  """

  use Oban.Worker,
    queue: :historical_backfill,
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

  @permanent_reasons [
    :historical_cursor_required,
    :historical_cursor_run_mismatch,
    :historical_cursor_not_active,
    :historical_cutoff_mismatch,
    :historical_event_missing,
    :historical_scope_changed,
    :historical_scope_missing
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"sync_run_id" => sync_run_id}} = job)
      when is_binary(sync_run_id) do
    case load_run(sync_run_id) do
      :discard ->
        :discard

      {:error, reason} ->
        {:error, reason}

      {:ok, run} ->
        perform_loaded_run(job, run)
    end
  end

  def perform(%Oban.Job{args: _args}), do: :discard

  defp perform_loaded_run(%Oban.Job{} = job, %SyncRun{} = run) do
    case check_future_paused(run) do
      {:snooze, seconds} ->
        {:snooze, seconds}

      :ok ->
        run_historical_step(job, run)
    end
  end

  defp run_historical_step(%Oban.Job{} = job, %SyncRun{} = run) do
    case maybe_start_or_resume(run) do
      {:ok, active_run} ->
        case load_required_cursor(active_run) do
          {:ok, cursor} ->
            active_run
            |> OrderReconciliation.run_historical_step(cursor, opts())
            |> handle_result(job, active_run)

          {:error, reason} ->
            handle_error(active_run, job, reason)
        end

      {:error, reason} ->
        handle_error(run, job, reason)
    end
  end

  defp load_run(sync_run_id) do
    case Ash.get(SyncRun, sync_run_id, domain: Ingestion) do
      {:ok, %SyncRun{status: status}} when status in [:completed, :failed, :cancelled] ->
        :discard

      {:ok, %SyncRun{sync_type: :reconciliation}} ->
        :discard

      {:ok, %SyncRun{sync_type: :historical_backfill} = run} ->
        {:ok, run}

      {:ok, nil} ->
        :discard

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

  defp check_future_paused(_run), do: :ok

  defp maybe_start_or_resume(%SyncRun{status: :queued} = run) do
    Ash.update(run, %{}, action: :start, domain: Ingestion)
  end

  defp maybe_start_or_resume(%SyncRun{status: :paused} = run) do
    Ash.update(run, %{}, action: :resume, domain: Ingestion)
  end

  defp maybe_start_or_resume(%SyncRun{} = run), do: {:ok, run}

  defp load_required_cursor(%SyncRun{id: sync_run_id}) do
    case SyncCursor
         |> Ash.Query.filter(sync_run_id == ^sync_run_id)
         |> Ash.read_one(domain: Ingestion) do
      {:ok, %SyncCursor{} = cursor} -> {:ok, cursor}
      {:ok, nil} -> {:error, :historical_cursor_required}
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_result({:pause, _run, _pause_reason, seconds}, _job, _loaded_run),
    do: {:snooze, seconds}

  defp handle_result({:continue, _run}, _job, _loaded_run), do: {:snooze, 1}

  defp handle_result({:complete, _run}, _job, _loaded_run), do: :ok

  defp handle_result({:error, reason}, job, loaded_run),
    do: handle_error(loaded_run, job, reason)

  defp handle_error(%SyncRun{} = run, %Oban.Job{} = job, reason) do
    if permanent_reason?(reason) or final_attempt?(job) do
      fail_closed(run, reason)
      {:discard, reason}
    else
      {:error, reason}
    end
  end

  defp permanent_reason?({:invalid_historical_source_order, _field}), do: true
  defp permanent_reason?({:historical_event_not_backfill_pending, _state}), do: true
  defp permanent_reason?({:failed, %SyncRun{}, _reason}), do: true
  defp permanent_reason?(reason) when reason in @permanent_reasons, do: true
  defp permanent_reason?(_reason), do: false

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max_attempts})
       when is_integer(attempt) and is_integer(max_attempts),
       do: attempt >= max_attempts

  defp final_attempt?(_job), do: false

  defp fail_closed(%SyncRun{} = run, reason) do
    error = bounded_error(reason)
    _ = mark_cursor_failed(run, error)
    _ = mark_run_failed(run, error)
    :ok
  end

  defp mark_cursor_failed(%SyncRun{id: sync_run_id}, error) do
    with {:ok, %SyncCursor{} = cursor} <- load_required_cursor_by_id(sync_run_id),
         {:ok, _failed} <-
           Ash.update(cursor, %{metadata: %{"failure" => error}},
             action: :mark_failed,
             domain: Ingestion
           ) do
      :ok
    else
      {:error, :historical_cursor_required} -> :ok
      {:error, _reason} -> {:error, :cursor_failure_persist_failed}
    end
  end

  defp load_required_cursor_by_id(sync_run_id) do
    case SyncCursor
         |> Ash.Query.filter(sync_run_id == ^sync_run_id)
         |> Ash.read_one(domain: Ingestion) do
      {:ok, %SyncCursor{} = cursor} -> {:ok, cursor}
      {:ok, nil} -> {:error, :historical_cursor_required}
      {:error, reason} -> {:error, reason}
    end
  end

  defp mark_run_failed(%SyncRun{status: :running} = run, error) do
    Ash.update(run, %{last_error: error}, action: :fail, domain: Ingestion)
  end

  defp mark_run_failed(%SyncRun{status: :paused} = run, error) do
    Ash.update(run, %{last_error: error}, action: :fail_paused, domain: Ingestion)
  end

  defp mark_run_failed(%SyncRun{status: :queued} = run, _error) do
    Ash.update(run, %{}, action: :cancel, domain: Ingestion)
  end

  defp mark_run_failed(%SyncRun{} = run, _error), do: {:ok, run}

  defp bounded_error(reason) do
    inspect(reason, limit: 8, printable_limit: 512)
    |> String.slice(0, 512)
  end

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
