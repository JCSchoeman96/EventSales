defmodule EventSales.Ingestion.AnalyticsReadinessResolver do
  @moduledoc """
  Derives historical financial analytics readiness from durable M3 and M4 evidence.

  The current `SyncRun` certificate is resolved by `HistoricalCoverageResolver`.
  This module then considers only the newest terminal financial reconciliation
  bound to that exact certificate. It does not persist, cache, or mutate readiness.

  Refinable finding priority is explicit and stable. Currency conflicts take
  precedence over incomplete effective times, incomplete financial primitives,
  and unresolved attribution. The resolver never relies on database row order.
  """

  require Ash.Query

  alias EventSales.Ingestion
  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.Resources.FinancialReconciliationFinding
  alias EventSales.Ingestion.Resources.FinancialReconciliationRun
  alias EventSales.Ingestion.Resources.SyncRun

  @terminal_statuses [:passed, :mismatched, :superseded, :failed, :cancelled]
  @refinable_finding_categories [
    :currency_conflict,
    :timestamp_incomplete,
    :financial_primitive_incomplete,
    :unresolved_attribution
  ]
  @finding_priority @refinable_finding_categories
  @finding_reasons %{
    currency_conflict: :currency_conflict,
    timestamp_incomplete: :effective_time_incomplete,
    financial_primitive_incomplete: :financial_primitive_incomplete,
    unresolved_attribution: :attribution_incomplete
  }
  @max_refinable_findings 100

  @type blocking_reason ::
          :historical_coverage_not_current
          | :historical_coverage_lookup_failed
          | :financial_reconciliation_pending
          | :financial_reconciliation_failed
          | :financial_reconciliation_evidence_invalid
          | :financial_reconciliation_lookup_failed
          | :currency_conflict
          | :effective_time_incomplete
          | :financial_primitive_incomplete
          | :attribution_incomplete
          | nil

  @type result :: %{
          analytics_ready?: boolean(),
          blocking_reason: blocking_reason(),
          event_id: binary(),
          historical_sync_run_id: binary() | nil,
          financial_reconciliation_run_id: binary() | nil,
          coverage_start: DateTime.t() | nil,
          sales_covered_through: DateTime.t() | nil,
          refunds_covered_through: DateTime.t() | nil
        }

  @spec resolve(term()) :: {:ok, result()} | {:error, :invalid_event_id}
  def resolve(event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, canonical_event_id} -> resolve_valid_event(canonical_event_id)
      _error -> {:error, :invalid_event_id}
    end
  end

  defp resolve_valid_event(event_id) do
    case HistoricalCoverageResolver.resolve_current(event_id) do
      {:ok, %SyncRun{} = sync_run} ->
        resolve_for_certificate(event_id, sync_run)

      {:error, :historical_coverage_not_current} ->
        {:ok, m3_not_ready_result(event_id, :historical_coverage_not_current)}

      {:error, :historical_coverage_lookup_failed} ->
        {:ok, m3_not_ready_result(event_id, :historical_coverage_lookup_failed)}

      {:error, _reason} ->
        {:ok, m3_not_ready_result(event_id, :historical_coverage_lookup_failed)}
    end
  end

  defp resolve_for_certificate(event_id, %SyncRun{} = sync_run) do
    base = certified_scope_result(event_id, sync_run)

    case newest_terminal_run(event_id, sync_run.id) do
      {:ok, nil} ->
        {:ok, %{base | blocking_reason: :financial_reconciliation_pending}}

      {:ok, %FinancialReconciliationRun{} = run} ->
        evaluate_terminal_run(base, sync_run, run)

      {:error, _reason} ->
        {:ok, %{base | blocking_reason: :financial_reconciliation_lookup_failed}}
    end
  end

  defp newest_terminal_run(event_id, sync_run_id) do
    query =
      FinancialReconciliationRun
      |> Ash.Query.filter(
        event_id == ^event_id and
          historical_sync_run_id == ^sync_run_id and
          status in ^@terminal_statuses
      )
      |> Ash.Query.sort(
        finished_at: :desc_nils_last,
        inserted_at: :desc,
        id: :desc
      )
      |> Ash.Query.limit(1)

    case Ash.read_one(query, domain: Ingestion) do
      {:ok, %FinancialReconciliationRun{} = run} -> {:ok, run}
      {:ok, nil} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :financial_reconciliation_lookup_failed}
  catch
    :exit, _reason -> {:error, :financial_reconciliation_lookup_failed}
    :throw, _value -> {:error, :financial_reconciliation_lookup_failed}
  end

  defp evaluate_terminal_run(base, %SyncRun{} = sync_run, %FinancialReconciliationRun{} = run) do
    result = %{base | financial_reconciliation_run_id: run.id}

    cond do
      not match?(%DateTime{}, run.finished_at) ->
        {:ok, %{result | blocking_reason: :financial_reconciliation_evidence_invalid}}

      not exact_scope_match?(sync_run, run) ->
        {:ok, %{result | blocking_reason: :financial_reconciliation_evidence_invalid}}

      true ->
        evaluate_terminal_status(result, run)
    end
  end

  defp evaluate_terminal_status(result, %FinancialReconciliationRun{status: :passed} = run) do
    case read_findings(run.id, :all) do
      {:ok, []} ->
        {:ok, %{result | analytics_ready?: true, blocking_reason: nil}}

      {:ok, _findings} ->
        {:ok, %{result | blocking_reason: :financial_reconciliation_evidence_invalid}}

      {:error, _reason} ->
        {:ok, %{result | blocking_reason: :financial_reconciliation_evidence_invalid}}
    end
  end

  defp evaluate_terminal_status(result, %FinancialReconciliationRun{status: status} = run)
       when status in [:mismatched, :failed] do
    reason =
      case read_findings(run.id, :refinable) do
        {:ok, findings} -> refined_reason(findings)
        {:error, _reason} -> :financial_reconciliation_failed
      end

    {:ok, %{result | blocking_reason: reason}}
  end

  defp evaluate_terminal_status(result, %FinancialReconciliationRun{status: :superseded}) do
    {:ok, %{result | blocking_reason: :financial_reconciliation_failed}}
  end

  defp evaluate_terminal_status(result, %FinancialReconciliationRun{status: :cancelled}) do
    {:ok, %{result | blocking_reason: :financial_reconciliation_pending}}
  end

  defp evaluate_terminal_status(result, _run) do
    {:ok, %{result | blocking_reason: :financial_reconciliation_evidence_invalid}}
  end

  defp read_findings(run_id, kind) do
    query =
      FinancialReconciliationFinding
      |> Ash.Query.filter(financial_reconciliation_run_id == ^run_id)
      |> Ash.Query.limit(@max_refinable_findings)

    query =
      case kind do
        :all -> query
        :refinable -> Ash.Query.filter(query, category in ^@refinable_finding_categories)
      end

    case Ash.read(query, domain: Ingestion) do
      {:ok, findings} -> {:ok, findings}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :financial_reconciliation_findings_lookup_failed}
  catch
    :exit, _reason -> {:error, :financial_reconciliation_findings_lookup_failed}
    :throw, _value -> {:error, :financial_reconciliation_findings_lookup_failed}
  end

  defp refined_reason(findings) do
    Enum.find_value(@finding_priority, :financial_reconciliation_failed, fn category ->
      if Enum.any?(findings, &(&1.category == category)) do
        Map.fetch!(@finding_reasons, category)
      end
    end)
  end

  defp exact_scope_match?(%SyncRun{} = sync_run, %FinancialReconciliationRun{} = run) do
    run.historical_sync_run_id == sync_run.id and
      run.event_id == sync_run.event_id and
      run.source_system_id == sync_run.source_system_id and
      run.coverage_start == sync_run.coverage_start and
      run.sales_covered_through == sync_run.sales_covered_through and
      run.refunds_covered_through == sync_run.refunds_covered_through
  end

  defp certified_scope_result(event_id, %SyncRun{} = sync_run) do
    %{
      analytics_ready?: false,
      blocking_reason: nil,
      event_id: event_id,
      historical_sync_run_id: sync_run.id,
      financial_reconciliation_run_id: nil,
      coverage_start: sync_run.coverage_start,
      sales_covered_through: sync_run.sales_covered_through,
      refunds_covered_through: sync_run.refunds_covered_through
    }
  end

  defp m3_not_ready_result(event_id, reason) do
    %{
      analytics_ready?: false,
      blocking_reason: reason,
      event_id: event_id,
      historical_sync_run_id: nil,
      financial_reconciliation_run_id: nil,
      coverage_start: nil,
      sales_covered_through: nil,
      refunds_covered_through: nil
    }
  end
end
