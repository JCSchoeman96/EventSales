defmodule EventSales.Ingestion.FinancialReconciliation.Orchestrator do
  @moduledoc """
  Composes M4-01..04 financial reconciliation components and durably finalizes evidence.
  """

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, SourceSystem}
  alias EventSales.Ingestion

  alias EventSales.Ingestion.FinancialReconciliation.{
    Comparator,
    Diagnostics,
    LocalTotals,
    SourceExtractor
  }

  alias EventSales.Ingestion.FinancialReconciliationRuns
  alias EventSales.Ingestion.Resources.{FinancialReconciliationRun, SyncRun}
  alias EventSales.Repo

  @terminal_statuses [:passed, :mismatched, :superseded, :failed, :cancelled]

  @spec run(FinancialReconciliationRun.t(), keyword()) ::
          {:ok, FinancialReconciliationRun.t()} | {:error, term()}
  def run(%FinancialReconciliationRun{} = run, opts \\ []) do
    case maybe_start(run) do
      {:ok, started} ->
        with {:ok, sync_run, event, source} <- load_scope(started),
             :ok <- verify_run_scope(started, sync_run, event, source) do
          execute_reconciliation(
            started,
            scope_map(sync_run),
            sync_run,
            event,
            source,
            opts
          )
        else
          {:error, reason} -> mark_internal_failure(started, reason)
        end

      {:error, :terminal} ->
        {:error, :terminal}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_start(%FinancialReconciliationRun{status: :queued} = run) do
    FinancialReconciliationRuns.mark_started(run, internal?: true)
  end

  defp maybe_start(%FinancialReconciliationRun{status: :running} = run), do: {:ok, run}

  defp maybe_start(%FinancialReconciliationRun{status: status})
       when status in @terminal_statuses,
       do: {:error, :terminal}

  defp maybe_start(%FinancialReconciliationRun{} = run), do: {:ok, run}

  defp load_scope(%FinancialReconciliationRun{} = run) do
    with {:ok, %SyncRun{} = sync_run} <-
           Ash.get(SyncRun, run.historical_sync_run_id, domain: Ingestion),
         {:ok, %Event{} = event} <- Ash.get(Event, run.event_id, domain: Catalog),
         {:ok, %SourceSystem{} = source} <-
           Ash.get(SourceSystem, run.source_system_id, domain: Catalog) do
      {:ok, sync_run, event, source}
    end
  end

  defp verify_run_scope(run, sync_run, event, source) do
    cond do
      run.historical_sync_run_id != sync_run.id ->
        {:error, :scope_mismatch}

      run.event_id != event.id ->
        {:error, :scope_mismatch}

      run.source_system_id != source.id ->
        {:error, :scope_mismatch}

      run.coverage_start != sync_run.coverage_start ->
        {:error, :scope_mismatch}

      run.sales_covered_through != sync_run.sales_covered_through ->
        {:error, :scope_mismatch}

      run.refunds_covered_through != sync_run.refunds_covered_through ->
        {:error, :scope_mismatch}

      true ->
        :ok
    end
  end

  defp execute_reconciliation(run, scope, sync_run, event, source, opts) do
    source_extractor = Keyword.get(opts, :source_extractor, configured_source_extractor())
    local_totals = Keyword.get(opts, :local_totals, configured_local_totals())

    if Repo.in_transaction?() do
      raise "source extraction must not run inside a database transaction"
    end

    case invoke_source_extractor(source_extractor, sync_run, event, source, opts) do
      {:ok, source_result} ->
        reconcile_local(run, scope, sync_run, event, source, source_result, local_totals, opts)

      {:error, {category, details}} when is_atom(category) and is_map(details) ->
        finalize_stage_error(run, scope, :source, category, details)

      {:error, reason} ->
        mark_internal_failure(run, reason)
    end
  end

  defp reconcile_local(run, scope, sync_run, event, source, source_result, local_totals, opts) do
    case invoke_local_totals(local_totals, sync_run, event, source, opts) do
      {:ok, local_result} ->
        reconcile_compare(run, scope, source_result, local_result)

      {:error, {category, details}} when is_atom(category) and is_map(details) ->
        finalize_stage_error(run, scope, :local, category, details)

      {:error, reason} ->
        mark_internal_failure(run, reason)
    end
  end

  defp reconcile_compare(run, scope, source_result, local_result) do
    case Comparator.compare(source_result, local_result) do
      {:ok, comparison_result} ->
        case Diagnostics.from_comparison(comparison_result) do
          {:ok, diagnostic_result} ->
            finalize_diagnostic(run, diagnostic_result, comparison_result)

          {:error, reason} ->
            mark_internal_failure(run, reason)
        end

      {:error, {category, details}} when is_atom(category) and is_map(details) ->
        finalize_stage_error(run, scope, :comparator, category, details)

      {:error, reason} ->
        mark_internal_failure(run, reason)
    end
  end

  defp finalize_stage_error(run, scope, :source, category, details) do
    case Diagnostics.from_source_error(scope, {category, details}) do
      {:ok, result} -> finalize_diagnostic(run, result, nil)
      {:error, reason} -> mark_internal_failure(run, reason)
    end
  end

  defp finalize_stage_error(run, scope, :local, category, details) do
    case Diagnostics.from_local_error(scope, {category, details}) do
      {:ok, result} -> finalize_diagnostic(run, result, nil)
      {:error, reason} -> mark_internal_failure(run, reason)
    end
  end

  defp finalize_stage_error(run, scope, :comparator, category, details) do
    case Diagnostics.from_comparator_error(scope, {category, details}) do
      {:ok, result} -> finalize_diagnostic(run, result, nil)
      {:error, reason} -> mark_internal_failure(run, reason)
    end
  end

  defp invoke_source_extractor(module_or_fun, sync_run, event, source, opts) do
    if Repo.in_transaction?() do
      {:error, {:http_under_lock, %{reason: :repo_in_transaction}}}
    else
      invoke_extractor(module_or_fun, sync_run, event, source, opts)
    end
  end

  defp invoke_local_totals(module_or_fun, sync_run, event, source, opts) do
    invoke_extractor(module_or_fun, sync_run, event, source, opts)
  end

  defp invoke_extractor(module_or_fun, sync_run, event, source, opts)
       when is_function(module_or_fun, 4) do
    dropped_opts = Keyword.drop(opts, [:source_extractor, :local_totals])
    module_or_fun.(sync_run, event, source, dropped_opts)
  end

  defp invoke_extractor(module, sync_run, event, source, opts) when is_atom(module) do
    dropped_opts = Keyword.drop(opts, [:source_extractor, :local_totals])
    module.extract_for_run(sync_run, event, source, dropped_opts)
  end

  defp finalize_diagnostic(run, diagnostic_result, comparison_result) do
    evidence =
      diagnostic_result
      |> Map.put(:comparisons, comparison_rows(comparison_result))
      |> Map.put_new(:metric_mismatches, [])

    FinancialReconciliationRuns.finalize_evidence(run, evidence, internal?: true)
  end

  defp comparison_rows(%{comparisons: comparisons}) when is_list(comparisons), do: comparisons
  defp comparison_rows(_comparison_result), do: nil

  defp mark_internal_failure(run, reason) do
    message =
      reason
      |> inspect(limit: :infinity, printable_limit: 120, pretty: false)
      |> String.slice(0, 500)

    case FinancialReconciliationRuns.mark_failed(run, %{last_error: message}, internal?: true) do
      {:ok, failed} -> {:error, {:failed, failed, reason}}
      {:error, error} -> {:error, error}
    end
  end

  defp scope_map(%SyncRun{} = sync_run) do
    %{
      sync_run_id: sync_run.id,
      event_id: sync_run.event_id,
      source_system_id: sync_run.source_system_id,
      coverage_start: sync_run.coverage_start,
      sales_covered_through: sync_run.sales_covered_through,
      refunds_covered_through: sync_run.refunds_covered_through
    }
  end

  defp configured_source_extractor do
    Application.get_env(
      :event_sales,
      :financial_reconciliation_source_extractor,
      SourceExtractor
    )
  end

  defp configured_local_totals do
    Application.get_env(:event_sales, :financial_reconciliation_local_totals, LocalTotals)
  end
end
