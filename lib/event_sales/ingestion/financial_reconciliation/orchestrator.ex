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
    with {:ok, run} <- maybe_start(run),
         {:ok, %SyncRun{} = sync_run, %Event{} = event, %SourceSystem{} = source} <-
           load_scope(run),
         :ok <- verify_run_scope(run, sync_run, event, source) do
      scope = scope_map(sync_run)
      execute_reconciliation(run, scope, sync_run, event, source, opts)
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

    with {:ok, source_result} <-
           invoke_source_extractor(source_extractor, sync_run, event, source, opts),
         {:ok, local_result} <-
           invoke_local_totals(local_totals, sync_run, event, source, opts),
         {:ok, comparison_result} <- Comparator.compare(source_result, local_result),
         {:ok, diagnostic_result} <- Diagnostics.from_comparison(comparison_result) do
      finalize_diagnostic(run, diagnostic_result, comparison_result)
    else
      {:error, {category, details}} when is_atom(category) and is_map(details) ->
        finalize_upstream_error(run, scope, category, details, opts)

      {:error, reason} ->
        mark_internal_failure(run, reason)
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

  defp invoke_extractor(module_or_fun, sync_run, event, source, opts) do
    dropped_opts = Keyword.drop(opts, [:source_extractor, :local_totals])

    if is_function(module_or_fun, 4) do
      module_or_fun.(sync_run, event, source, dropped_opts)
    else
      apply(module_or_fun, :extract_for_run, [sync_run, event, source, dropped_opts])
    end
  end

  defp finalize_upstream_error(run, scope, category, details, _opts) do
    diagnostic_result =
      cond do
        source_error?(category) ->
          Diagnostics.from_source_error(scope, {category, details})

        local_error?(category) ->
          Diagnostics.from_local_error(scope, {category, details})

        comparator_error?(category) ->
          Diagnostics.from_comparator_error(scope, {category, details})

        true ->
          {:error, {:unclassified_upstream_error, category}}
      end

    case diagnostic_result do
      {:ok, result} ->
        finalize_diagnostic(run, result, nil)

      {:error, reason} ->
        mark_internal_failure(run, reason)
    end
  end

  defp source_error?(category) do
    category in [
      :source_snapshot_stale,
      :refund_identity_drift,
      :missing_source_fact,
      :historical_recognition_unproven,
      :timestamp_incomplete,
      :currency_conflict,
      :unresolved_attribution,
      :financial_primitive_incomplete,
      :invalid_currency,
      :http_under_lock,
      :invalid_scope
    ]
  end

  defp local_error?(category) do
    category in [
      :unresolved_attribution,
      :timestamp_incomplete,
      :currency_conflict,
      :financial_primitive_incomplete,
      :historical_recognition_unproven,
      :missing_local_fact,
      :invalid_scope
    ]
  end

  defp comparator_error?(category) do
    category in [
      :currency_set_mismatch,
      :scope_mismatch,
      :invalid_scope_field,
      :invalid_currency_key,
      :invalid_currencies,
      :invalid_primitive,
      :invalid_input
    ]
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
