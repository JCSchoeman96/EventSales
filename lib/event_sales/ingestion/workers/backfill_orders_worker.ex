defmodule EventSales.Ingestion.Workers.BackfillOrdersWorker do
  @moduledoc """
  Oban worker for one bounded immutable historical backfill page.

  A perform call bootstraps existing manifest evidence, executes one page, and
  snoozes only after that page has been durably checkpointed. It never uses
  mutable WooCommerce collection paging.
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
  alias EventSales.Ingestion.HistoricalCatchupBootstrap
  alias EventSales.Ingestion.HistoricalCatchupEvidence
  alias EventSales.Ingestion.HistoricalCatchupExecution
  alias EventSales.Ingestion.HistoricalManifestBootstrap
  alias EventSales.Ingestion.HistoricalManifestEvidence
  alias EventSales.Ingestion.HistoricalManifestExecution
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}

  @transient_reasons [
    :rate_limited,
    :timeout,
    :server_error,
    :queue_timeout,
    :circuit_open,
    :transport_error
  ]

  @permanent_reasons [
    :manifest_create_in_doubt,
    :manifest_evidence_missing,
    :corrupt_manifest_evidence,
    :manifest_expired,
    :manifest_continuity_mismatch,
    :invalid_manifest_page,
    :invalid_manifest_page_response,
    :invalid_source_order_response,
    :source_order_id_mismatch,
    :source_order_not_found,
    :invalid_source_order_line_items,
    :order_upsert_failed,
    :source_system_not_found,
    :source_system_mismatch,
    :source_system_kind_mismatch,
    :source_system_inactive,
    :source_system_invalid,
    :source_endpoint_mismatch,
    :source_client_misconfigured,
    :historical_cursor_required,
    :invalid_historical_cursor,
    :cursor_run_mismatch,
    :historical_bounds_mismatch,
    :historical_cursor_repurposed,
    :not_historical_backfill,
    :invalid_historical_bounds,
    :invalid_historical_run,
    :invalid_historical_execution_input,
    :product_mappings_unavailable,
    :invalid_product_mappings,
    :historical_event_missing,
    :historical_event_source_mismatch,
    :historical_event_backfill_start_mismatch,
    :historical_event_not_backfill_pending,
    :invalid_manifest_evidence,
    :invalid_now,
    :checkpoint_conflict,
    :metadata_too_large,
    :invalid_catchup_evidence,
    :catchup_create_in_doubt,
    :catchup_create_claim_failed,
    :catchup_evidence_persist_failed,
    :catchup_high_water_before_parent,
    :ambiguous_create,
    :source_client_unavailable,
    :catchup_evidence_missing,
    :corrupt_catchup_evidence,
    :catchup_manifest_expired,
    :catchup_continuity_mismatch,
    :invalid_catchup_page,
    :invalid_catchup_page_response,
    :historical_catchup_already_terminal,
    :historical_event_line_selection_failed,
    :historical_event_kind_invalid,
    :historical_event_external_id_invalid,
    :completion_failed,
    :order_reconcile_failed,
    :catchup_bootstrap_failed
  ]

  @failure_reasons MapSet.new(
                     @transient_reasons ++
                       @permanent_reasons ++
                       [
                         :manifest_source_error,
                         :source_order_fetch_failed,
                         :invalid_checkpoint_callback,
                         :checkpoint_failed
                       ]
                   )

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
      {:snooze, seconds} -> {:snooze, seconds}
      :ok -> run_historical_step(job, run)
    end
  end

  defp run_historical_step(%Oban.Job{} = job, %SyncRun{} = run) do
    case maybe_start_or_resume(run) do
      {:ok, active_run} ->
        with {:ok, _evidence} <- ensure_manifest(active_run),
             {:ok, cursor} <- load_required_cursor(active_run) do
          route_historical_step(active_run, cursor, job)
        else
          {:error, reason} -> handle_error(active_run, job, reason)
        end

      {:error, reason} ->
        handle_error(run, job, reason)
    end
  end

  defp route_historical_step(run, cursor, job) do
    case HistoricalManifestEvidence.state(cursor.metadata) do
      :manifest_terminal ->
        route_catchup_step(run, cursor, job)

      state when state in [:pending_first_page, :manifest_in_progress] ->
        execute_manifest_step(run, cursor, job)

      :create_claimed ->
        handle_error(run, job, :manifest_create_in_doubt)

      :missing ->
        handle_error(run, job, :manifest_evidence_missing)

      :corrupt ->
        handle_error(run, job, :corrupt_manifest_evidence)
    end
  end

  defp execute_manifest_step(run, cursor, job) do
    execution_module().run_step(run, cursor, execution_opts())
    |> handle_manifest_result(job, run)
  end

  defp route_catchup_step(run, cursor, job) do
    case HistoricalCatchupEvidence.state(cursor.metadata) do
      :missing ->
        case ensure_catchup(run) do
          {:ok, _evidence} -> {:snooze, 1}
          {:error, reason} -> handle_error(run, job, reason)
        end

      state when state in [:pending_first_page, :catchup_in_progress] ->
        catchup_execution_module().run_step(run, cursor, catchup_execution_opts())
        |> handle_catchup_result(job, run)

      :create_claimed ->
        handle_error(run, job, :catchup_create_in_doubt)

      :catchup_terminal ->
        handle_error(run, job, :historical_catchup_already_terminal)

      :corrupt ->
        handle_error(run, job, :corrupt_catchup_evidence)
    end
  end

  defp load_run(sync_run_id) do
    case Ash.get(SyncRun, sync_run_id, domain: Ingestion) do
      {:ok, %SyncRun{status: status}} when status in [:completed, :failed, :cancelled] ->
        :discard

      {:ok, %SyncRun{sync_type: :historical_backfill} = run} ->
        {:ok, run}

      {:ok, %SyncRun{}} ->
        :discard

      {:ok, nil} ->
        :discard

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        :discard

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_manifest(%SyncRun{} = run) do
    bootstrap = bootstrap_module()

    case bootstrap.ensure_manifest(run.id, bootstrap_opts()) do
      {:ok, evidence} -> {:ok, evidence}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :manifest_bootstrap_failed}
    end
  end

  defp ensure_catchup(%SyncRun{} = run) do
    bootstrap = catchup_bootstrap_module()

    case bootstrap.ensure_catchup(run.id, catchup_bootstrap_opts()) do
      {:ok, evidence} -> {:ok, evidence}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :catchup_bootstrap_failed}
    end
  end

  defp check_future_paused(%SyncRun{status: :paused, paused_until: %DateTime{} = paused_until}) do
    seconds = DateTime.diff(paused_until, DateTime.utc_now(), :second)

    if seconds > 0, do: {:snooze, max(seconds, 1)}, else: :ok
  end

  defp check_future_paused(_run), do: :ok

  defp maybe_start_or_resume(%SyncRun{status: :queued} = run) do
    normalize_update(Ash.update(run, %{}, action: :start, domain: Ingestion))
  end

  defp maybe_start_or_resume(%SyncRun{status: :paused} = run) do
    normalize_update(Ash.update(run, %{}, action: :resume, domain: Ingestion))
  end

  defp maybe_start_or_resume(%SyncRun{} = run), do: {:ok, run}

  defp load_required_cursor(%SyncRun{id: sync_run_id}) do
    case SyncCursor
         |> Ash.Query.filter(sync_run_id == ^sync_run_id)
         |> Ash.read_one(domain: Ingestion) do
      {:ok, %SyncCursor{} = cursor} -> {:ok, cursor}
      {:ok, nil} -> {:error, :historical_cursor_required}
      {:error, _reason} -> {:error, :historical_cursor_required}
    end
  end

  defp handle_manifest_result({:continue, _run, _cursor}, _job, _loaded_run), do: {:snooze, 1}

  defp handle_manifest_result({:manifest_terminal, _run, _cursor}, _job, _loaded_run),
    do: {:snooze, 1}

  defp handle_manifest_result({:error, reason}, job, loaded_run),
    do: handle_error(loaded_run, job, reason)

  defp handle_manifest_result(_other, job, loaded_run),
    do: handle_error(loaded_run, job, :historical_execution_failed)

  defp handle_catchup_result({:continue, _run, _cursor}, _job, _loaded_run), do: {:snooze, 1}
  defp handle_catchup_result(:ok, _job, _loaded_run), do: :ok

  defp handle_catchup_result({:error, reason}, job, loaded_run),
    do: handle_error(loaded_run, job, reason)

  defp handle_catchup_result(_other, job, loaded_run),
    do: handle_error(loaded_run, job, :historical_execution_failed)

  defp handle_error(%SyncRun{} = run, %Oban.Job{} = job, reason) do
    cond do
      permanent_reason?(reason) or final_attempt?(job) ->
        fail_closed(run, reason)
        {:discard, reason}

      transient_reason?(reason) ->
        case pause_for_retry(run, reason) do
          {:ok, _paused} -> {:snooze, retry_delay(reason)}
          {:error, _pause_error} -> {:error, :sync_run_pause_failed}
        end

      true ->
        {:error, reason}
    end
  end

  defp transient_reason?(reason), do: reason in @transient_reasons
  defp permanent_reason?({:historical_event_not_backfill_pending, _state}), do: true
  defp permanent_reason?({:historical_event_line_unresolved, _line_id, _reason}), do: true
  defp permanent_reason?(reason), do: reason in @permanent_reasons

  defp pause_for_retry(%SyncRun{} = run, reason) do
    pause_reason = pause_reason(reason)
    seconds = retry_delay(reason)

    normalize_update(
      Ash.update(
        run,
        %{
          paused_until: DateTime.add(DateTime.utc_now(), seconds, :second),
          pause_reason: pause_reason,
          last_error: failure_summary(reason)
        },
        action: :pause,
        domain: Ingestion
      )
    )
  end

  defp pause_reason(:rate_limited), do: :rate_limited
  defp pause_reason(:server_error), do: :server_error
  defp pause_reason(:circuit_open), do: :circuit_open
  defp pause_reason(_reason), do: :timeout

  defp retry_delay(:rate_limited), do: 60
  defp retry_delay(_reason), do: 30

  defp final_attempt?(%Oban.Job{attempt: attempt, max_attempts: max_attempts})
       when is_integer(attempt) and is_integer(max_attempts),
       do: attempt >= max_attempts

  defp final_attempt?(_job), do: false

  defp fail_closed(%SyncRun{} = run, reason) do
    failure = failure_summary(reason)
    _ = mark_cursor_failed(run, failure)
    _ = mark_run_failed(run, failure)
    :ok
  end

  defp mark_cursor_failed(%SyncRun{id: sync_run_id}, failure) do
    with {:ok, %SyncCursor{} = cursor} <- load_cursor_by_id(sync_run_id),
         {:ok, metadata} <- HistoricalManifestEvidence.with_failure(cursor.metadata, failure) do
      persist_failed_cursor(cursor, metadata)
    else
      _other ->
        {:error, :cursor_failure_persist_failed}
    end
  end

  defp persist_failed_cursor(cursor, metadata) do
    case Ash.update(cursor, %{metadata: metadata},
           action: :mark_failed,
           domain: Ingestion,
           return_notifications?: true
         ) do
      {:ok, _failed, notifications} ->
        Ash.Notifier.notify(notifications)
        :ok

      {:ok, _failed} ->
        :ok

      _other ->
        {:error, :cursor_failure_persist_failed}
    end
  end

  defp load_cursor_by_id(sync_run_id) do
    case SyncCursor
         |> Ash.Query.filter(sync_run_id == ^sync_run_id)
         |> Ash.read_one(domain: Ingestion) do
      {:ok, %SyncCursor{} = cursor} -> {:ok, cursor}
      _other -> {:error, :historical_cursor_required}
    end
  end

  defp mark_run_failed(%SyncRun{status: :running} = run, failure) do
    normalize_update(Ash.update(run, %{last_error: failure}, action: :fail, domain: Ingestion))
  end

  defp mark_run_failed(%SyncRun{status: :paused} = run, failure) do
    normalize_update(
      Ash.update(run, %{last_error: failure}, action: :fail_paused, domain: Ingestion)
    )
  end

  defp mark_run_failed(%SyncRun{status: :queued} = run, _failure) do
    normalize_update(Ash.update(run, %{}, action: :cancel, domain: Ingestion))
  end

  defp mark_run_failed(%SyncRun{} = run, _failure), do: {:ok, run}

  defp failure_summary({:historical_event_not_backfill_pending, _state}),
    do: "historical_event_not_backfill_pending"

  defp failure_summary({:historical_event_line_unresolved, _line_id, _reason}),
    do: "historical_event_line_unresolved"

  defp failure_summary(reason) when is_atom(reason) do
    if MapSet.member?(@failure_reasons, reason),
      do: Atom.to_string(reason),
      else: "historical_execution_failed"
  end

  defp failure_summary(_reason), do: "historical_execution_failed"

  defp normalize_update({:ok, record}), do: {:ok, record}
  defp normalize_update({:ok, record, _notifications}), do: {:ok, record}
  defp normalize_update({:error, reason}), do: {:error, reason}

  defp bootstrap_module,
    do:
      Application.get_env(
        :event_sales,
        :historical_manifest_bootstrap,
        HistoricalManifestBootstrap
      )

  defp bootstrap_opts,
    do: Application.get_env(:event_sales, :historical_manifest_bootstrap_opts, [])

  defp catchup_bootstrap_module,
    do:
      Application.get_env(
        :event_sales,
        :historical_catchup_bootstrap,
        HistoricalCatchupBootstrap
      )

  defp catchup_bootstrap_opts,
    do: Application.get_env(:event_sales, :historical_catchup_bootstrap_opts, [])

  defp execution_module,
    do:
      Application.get_env(
        :event_sales,
        :historical_manifest_execution,
        HistoricalManifestExecution
      )

  defp execution_opts do
    configured =
      [
        manifest_client: Application.get_env(:event_sales, :woo_order_index_client),
        woocommerce_client: Application.get_env(:event_sales, :woocommerce_client),
        order_upserter: Application.get_env(:event_sales, :order_upserter)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    Keyword.merge(
      configured,
      Application.get_env(:event_sales, :historical_manifest_execution_opts, [])
    )
  end

  defp catchup_execution_module,
    do:
      Application.get_env(
        :event_sales,
        :historical_catchup_execution,
        HistoricalCatchupExecution
      )

  defp catchup_execution_opts do
    configured =
      [
        catchup_client: Application.get_env(:event_sales, :woo_order_index_client),
        woocommerce_client: Application.get_env(:event_sales, :woocommerce_client),
        order_upserter: Application.get_env(:event_sales, :order_upserter)
      ]
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    Keyword.merge(
      configured,
      Application.get_env(:event_sales, :historical_catchup_execution_opts, [])
    )
  end
end
