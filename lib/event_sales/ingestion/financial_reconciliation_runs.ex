defmodule EventSales.Ingestion.FinancialReconciliationRuns do
  @moduledoc """
  Facade for durable financial reconciliation run state.

  Terminal evidence finalization acquires `HistoricalCoverageFence` before row locks,
  re-verifies the bound M3 certificate, optionally invalidates that certificate for
  proven source drift, and commits metrics, findings, and the terminal run transition
  in one transaction. Woo source extraction remains outside this transaction.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Ingestion
  alias EventSales.Ingestion.FinancialReconciliation.FindingFingerprint
  alias EventSales.Ingestion.HistoricalCoverageFence
  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.Resources.FinancialReconciliationFinding
  alias EventSales.Ingestion.Resources.FinancialReconciliationMetric
  alias EventSales.Ingestion.Resources.FinancialReconciliationRun
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Ingestion.Workers.ReconcileFinancialsWorker
  alias EventSales.Repo

  @default_limit 100
  @max_limit 500
  @authorized_context %{
    financial_reconciliation_state_authorized?: true,
    financial_reconciliation_state_authorized: true
  }

  @terminal_statuses [:passed, :mismatched, :superseded, :failed, :cancelled]
  @invalidation_config_key :financial_reconciliation_coverage_invalidation
  @finalize_hooks_key :financial_reconciliation_finalize_hooks
  @sync_run_lock_query """
  SELECT id
  FROM ingestion_sync_runs
  WHERE id = $1
  FOR UPDATE
  """

  def list_runs(opts \\ []) do
    with :ok <- authorize_read(opts) do
      FinancialReconciliationRun
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.Query.limit(limit(opts))
      |> Ash.read(domain: Ingestion)
    end
  end

  def get_run(id, opts \\ []) do
    with :ok <- authorize_read(opts) do
      Ash.get(FinancialReconciliationRun, id, domain: Ingestion)
    end
  end

  def queue_manual_for_event(event_id, opts \\ []) do
    oban_insert = Keyword.get(opts, :oban_insert, &Oban.insert/1)

    with :ok <- authorize_admin(opts),
         {:ok, %SyncRun{} = sync_run} <- HistoricalCoverageResolver.resolve_current(event_id),
         {:ok, run, provenance} <- get_or_create_run(sync_run.id, :queue_manual),
         {:ok, job} <- enqueue_run(run, oban_insert, provenance) do
      {:ok, %{financial_reconciliation_run: run, job: job}}
    end
  end

  def queue_system_for_event(event_id, opts \\ []) do
    oban_insert = Keyword.get(opts, :oban_insert, &Oban.insert/1)

    with :ok <- authorize_internal(opts),
         {:ok, %SyncRun{} = sync_run} <- HistoricalCoverageResolver.resolve_current(event_id),
         {:ok, run, provenance} <- get_or_create_run(sync_run.id, :queue_system),
         {:ok, job} <- enqueue_run(run, oban_insert, provenance) do
      {:ok, %{financial_reconciliation_run: run, job: job}}
    end
  end

  def cancel(%FinancialReconciliationRun{} = run, opts \\ []) do
    update_internal(run, %{}, :cancel, opts)
  end

  def mark_started(%FinancialReconciliationRun{} = run, opts \\ []),
    do: update_internal(run, %{}, :start, opts)

  def mark_failed(%FinancialReconciliationRun{} = run, attrs, opts \\ []),
    do: update_internal(run, attrs, :fail, opts)

  @doc """
  Atomically persists metrics, structural findings, and the terminal run transition.
  """
  def finalize_evidence(%FinancialReconciliationRun{} = run, evidence, opts \\ []) do
    with :ok <- authorize_internal_or_admin(opts) do
      Repo.transaction(fn -> finalize_evidence_transaction(run.id, evidence) end)
      |> case do
        {:ok, finalized} -> {:ok, finalized}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp finalize_evidence_transaction(run_id, evidence) do
    with {:ok, %FinancialReconciliationRun{} = peek} <- fetch_run_peek(run_id),
         :ok <- HistoricalCoverageFence.acquire([peek.event_id]),
         :ok <- run_finalize_hook(:after_fence, peek.event_id),
         {:ok, %SyncRun{} = bound_sync_run} <- lock_sync_run(peek.historical_sync_run_id),
         {:ok, certificate_current?} <- {:ok, bound_certificate_current?(bound_sync_run)},
         {:ok, %FinancialReconciliationRun{} = run} <- lock_run(run_id),
         :ok <- ensure_running(run),
         :ok <- verify_bound_scope(run, bound_sync_run),
         {:ok, evidence} <- reconcile_certificate_authority(evidence, run, certificate_current?),
         {:ok, evidence} <-
           maybe_invalidate_for_drift(bound_sync_run, evidence, certificate_current?),
         :ok <- validate_supersede_evidence(evidence),
         :ok <- persist_metrics(run, evidence),
         :ok <- persist_findings(run, evidence),
         {:ok, finalized} <- transition_terminal(run, evidence) do
      finalized
    else
      {:error, :terminal} -> Repo.rollback(:terminal)
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp fetch_run_peek(run_id) do
    case Ash.get(FinancialReconciliationRun, run_id, domain: Ingestion) do
      {:ok, %FinancialReconciliationRun{} = run} -> {:ok, run}
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_sync_run(sync_run_id) do
    case Repo.query(@sync_run_lock_query, [Ecto.UUID.dump!(sync_run_id)]) do
      {:ok, %{num_rows: 1}} ->
        Ash.get(SyncRun, sync_run_id, domain: Ingestion)

      {:ok, %{num_rows: 0}} ->
        {:error, :bound_sync_run_not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp bound_certificate_current?(%SyncRun{id: bound_id, event_id: event_id} = bound_sync_run) do
    case HistoricalCoverageResolver.resolve_current(event_id) do
      {:ok, %SyncRun{id: current_id} = current} ->
        current_id == bound_id and sync_run_scope_equal?(bound_sync_run, current)

      _other ->
        false
    end
  end

  defp sync_run_scope_equal?(left, right) do
    left.source_system_id == right.source_system_id and
      left.event_id == right.event_id and
      left.coverage_start == right.coverage_start and
      left.sales_covered_through == right.sales_covered_through and
      left.refunds_covered_through == right.refunds_covered_through
  end

  defp verify_bound_scope(%FinancialReconciliationRun{} = run, %SyncRun{} = sync_run) do
    if run.historical_sync_run_id == sync_run.id and
         run.source_system_id == sync_run.source_system_id and
         run.event_id == sync_run.event_id and
         run.coverage_start == sync_run.coverage_start and
         run.sales_covered_through == sync_run.sales_covered_through and
         run.refunds_covered_through == sync_run.refunds_covered_through do
      :ok
    else
      {:error, :bound_scope_mismatch}
    end
  end

  defp reconcile_certificate_authority(evidence, _run, true), do: {:ok, evidence}

  defp reconcile_certificate_authority(evidence, run, false) do
    findings = Map.get(evidence, :structural_findings, [])

    updated_findings =
      if stale_certificate_finding?(findings) do
        findings
      else
        findings ++ [stale_certificate_finding(run)]
      end

    {:ok,
     %{
       evidence
       | disposition: :superseded,
         structural_findings: updated_findings
     }}
  end

  defp maybe_invalidate_for_drift(bound_sync_run, evidence, true) do
    findings = Map.get(evidence, :structural_findings, [])

    cond do
      Enum.any?(findings, &(&1.category == :source_snapshot_stale)) ->
        with :ok <- invalidate_order_coverage_for_reconciliation(bound_sync_run) do
          {:ok, evidence}
        end

      Enum.any?(findings, &(&1.category == :refund_identity_drift)) ->
        with :ok <- invalidate_refund_coverage_for_reconciliation(bound_sync_run) do
          {:ok, evidence}
        end

      true ->
        {:ok, evidence}
    end
  end

  defp maybe_invalidate_for_drift(_bound_sync_run, evidence, false), do: {:ok, evidence}

  defp invalidate_order_coverage_for_reconciliation(%SyncRun{} = sync_run) do
    case invalidation_callback(:invalidate_order_coverage) do
      fun when is_function(fun, 1) ->
        fun.(sync_run)

      _ ->
        default_invalidate_order_coverage(sync_run)
    end
  end

  defp invalidate_refund_coverage_for_reconciliation(%SyncRun{} = sync_run) do
    case invalidation_callback(:invalidate_refund_coverage) do
      fun when is_function(fun, 1) ->
        fun.(sync_run)

      _ ->
        default_invalidate_refund_coverage(sync_run)
    end
  end

  defp invalidation_callback(key) do
    Application.get_env(:event_sales, @invalidation_config_key, [])
    |> Keyword.get(key)
  end

  defp run_finalize_hook(name, event_id) do
    case Application.get_env(:event_sales, @finalize_hooks_key, []) |> Keyword.get(name) do
      fun when is_function(fun, 1) -> fun.(event_id)
      _ -> :ok
    end
  end

  defp default_invalidate_order_coverage(%SyncRun{} = sync_run) do
    case Ash.update(
           sync_run,
           %{coverage_invalidation_reason: :historical_order_changed},
           action: :invalidate_order_coverage,
           domain: Ingestion
         ) do
      {:ok, %SyncRun{}} -> :ok
      {:ok, %SyncRun{}, _notifications} -> :ok
      _other -> {:error, :order_coverage_invalidation_failed}
    end
  rescue
    _error -> {:error, :order_coverage_invalidation_failed}
  catch
    :exit, _reason -> {:error, :order_coverage_invalidation_failed}
    :throw, _value -> {:error, :order_coverage_invalidation_failed}
  end

  defp default_invalidate_refund_coverage(%SyncRun{} = sync_run) do
    case Ash.update(
           sync_run,
           %{coverage_invalidation_reason: :historical_refund_changed},
           action: :invalidate_refund_coverage,
           domain: Ingestion
         ) do
      {:ok, %SyncRun{}} -> :ok
      {:ok, %SyncRun{}, _notifications} -> :ok
      _other -> {:error, :refund_coverage_invalidation_failed}
    end
  rescue
    _error -> {:error, :refund_coverage_invalidation_failed}
  catch
    :exit, _reason -> {:error, :refund_coverage_invalidation_failed}
    :throw, _value -> {:error, :refund_coverage_invalidation_failed}
  end

  defp validate_supersede_evidence(%{disposition: :superseded} = evidence) do
    if supersede_cause_present?(evidence) do
      :ok
    else
      {:error, :invalid_supersede_evidence}
    end
  end

  defp validate_supersede_evidence(_evidence), do: :ok

  defp supersede_cause_present?(%{structural_findings: findings}) when is_list(findings) do
    Enum.any?(findings, &supersede_cause_finding?/1)
  end

  defp supersede_cause_present?(_evidence), do: false

  defp supersede_cause_finding?(%{category: :source_snapshot_stale}), do: true
  defp supersede_cause_finding?(%{category: :refund_identity_drift}), do: true

  defp supersede_cause_finding?(%{category: :invalid_scope, details: details})
       when is_map(details),
       do: Map.get(details, :reason) == :historical_certificate_not_current

  defp supersede_cause_finding?(_finding), do: false

  defp stale_certificate_finding(%FinancialReconciliationRun{} = run) do
    %{
      category: :invalid_scope,
      origin: :local,
      scope: run_scope_map(run),
      details: %{reason: :historical_certificate_not_current}
    }
  end

  defp stale_certificate_finding?(findings) when is_list(findings) do
    Enum.any?(findings, fn finding ->
      finding.category == :invalid_scope and
        is_map(finding.details) and
        Map.get(finding.details, :reason) == :historical_certificate_not_current
    end)
  end

  defp lock_run(run_id) do
    case Repo.query(
           """
           SELECT id
           FROM ingestion_financial_reconciliation_runs
           WHERE id = $1
           FOR UPDATE
           """,
           [Ecto.UUID.dump!(run_id)]
         ) do
      {:ok, %{num_rows: 1}} ->
        Ash.get(FinancialReconciliationRun, run_id, domain: Ingestion)

      {:ok, %{num_rows: 0}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_running(%FinancialReconciliationRun{status: :running}), do: :ok

  defp ensure_running(%FinancialReconciliationRun{status: status})
       when status in @terminal_statuses,
       do: {:error, :terminal}

  defp ensure_running(_run), do: {:error, :invalid_status}

  defp persist_metrics(run, %{comparisons: comparisons} = evidence)
       when is_list(comparisons) and comparisons != [] do
    mismatch_lookup = mismatch_lookup(Map.get(evidence, :metric_mismatches, []))

    Enum.reduce_while(comparisons, :ok, fn row, :ok ->
      attrs = metric_attrs(run.id, row, mismatch_lookup)

      case create_metric(attrs) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_metrics(_run, _evidence), do: :ok

  defp persist_findings(run, %{structural_findings: findings}) when is_list(findings) do
    Enum.reduce_while(findings, :ok, fn finding, :ok ->
      case persist_structural_finding(run, finding) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp persist_findings(_run, _evidence), do: :ok

  defp transition_terminal(run, %{disposition: disposition}) do
    action = terminal_action(disposition)

    run
    |> Ash.Changeset.new()
    |> Ash.Changeset.set_context(@authorized_context)
    |> Ash.Changeset.for_update(action, %{})
    |> Ash.update(domain: Ingestion)
    |> case do
      {:ok, finalized} -> {:ok, finalized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp terminal_action(:matched), do: :pass
  defp terminal_action(:mismatched), do: :mismatch
  defp terminal_action(:failed), do: :fail
  defp terminal_action(:superseded), do: :supersede

  defp metric_attrs(run_id, row, mismatch_lookup) do
    key = {row.currency, row.primitive}
    mismatch_category = if row.matched?, do: nil, else: Map.fetch!(mismatch_lookup, key)

    %{
      financial_reconciliation_run_id: run_id,
      currency: row.currency,
      primitive: row.primitive,
      source_value: row.source_value,
      local_value: row.local_value,
      delta: Decimal.sub(row.local_value, row.source_value),
      matched?: row.matched?,
      mismatch_category: mismatch_category
    }
  end

  defp mismatch_lookup(metric_mismatches) do
    Map.new(metric_mismatches, fn mismatch ->
      {{mismatch.currency, mismatch.primitive}, mismatch.category}
    end)
  end

  defp create_metric(attrs) do
    case FinancialReconciliationMetric
         |> Ash.Changeset.new()
         |> Ash.Changeset.set_context(@authorized_context)
         |> Ash.Changeset.for_create(:persist, attrs)
         |> Ash.create(domain: Ingestion) do
      {:ok, _metric} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp persist_structural_finding(run, finding) do
    with :ok <- validate_finding_scope(run, finding),
         {:ok, normalized_details} <- FindingFingerprint.normalize_details(finding.details),
         {:ok, fingerprint} <-
           FindingFingerprint.compute(finding.category, finding.origin, normalized_details) do
      attrs = %{
        financial_reconciliation_run_id: run.id,
        category: finding.category,
        origin: finding.origin,
        details: normalized_details,
        fingerprint: fingerprint
      }

      case FinancialReconciliationFinding
           |> Ash.Changeset.new()
           |> Ash.Changeset.set_context(@authorized_context)
           |> Ash.Changeset.for_create(:persist, attrs)
           |> Ash.create(domain: Ingestion) do
        {:ok, _finding} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_finding_scope(run, %{scope: scope}) when is_map(scope) do
    expected = run_scope_map(run)

    if scope_matches?(scope, expected) do
      :ok
    else
      {:error, :finding_scope_mismatch}
    end
  end

  defp validate_finding_scope(_run, _finding), do: {:error, :invalid_finding_scope}

  defp run_scope_map(run) do
    %{
      sync_run_id: run.historical_sync_run_id,
      event_id: run.event_id,
      source_system_id: run.source_system_id,
      coverage_start: run.coverage_start,
      sales_covered_through: run.sales_covered_through,
      refunds_covered_through: run.refunds_covered_through
    }
  end

  defp scope_matches?(scope, expected) do
    Enum.all?(expected, fn {key, value} ->
      Map.get(scope, key) == value
    end)
  end

  defp get_or_create_run(sync_run_id, action) do
    case find_active_run_for_certificate(sync_run_id) do
      {:ok, run} -> {:ok, run, :existing_active}
      :not_found -> create_run(sync_run_id, action)
    end
  end

  defp create_run(sync_run_id, action) do
    case FinancialReconciliationRun
         |> Ash.Changeset.new()
         |> Ash.Changeset.set_context(@authorized_context)
         |> Ash.Changeset.for_create(action, %{historical_sync_run_id: sync_run_id})
         |> Ash.create(domain: Ingestion) do
      {:ok, run} ->
        {:ok, run, :newly_created}

      {:error, %Ash.Error.Invalid{}} ->
        case find_active_run_for_certificate(sync_run_id) do
          {:ok, run} -> {:ok, run, :existing_active}
          :not_found -> {:error, :active_run_conflict}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_active_run_for_certificate(sync_run_id) do
    case Ash.get(SyncRun, sync_run_id, domain: Ingestion) do
      {:ok, %SyncRun{} = sync_run} ->
        case FinancialReconciliationRun
             |> Ash.Query.filter(
               event_id == ^sync_run.event_id and
                 historical_sync_run_id == ^sync_run.id and
                 status in [:queued, :running]
             )
             |> Ash.Query.sort(inserted_at: :desc, id: :desc)
             |> Ash.Query.limit(1)
             |> Ash.read_one(domain: Ingestion) do
          {:ok, %FinancialReconciliationRun{} = run} -> {:ok, run}
          _ -> :not_found
        end

      _ ->
        :not_found
    end
  end

  defp enqueue_run(run, oban_insert, provenance) do
    case oban_insert.(
           ReconcileFinancialsWorker.new(%{"financial_reconciliation_run_id" => run.id})
         ) do
      {:ok, job} ->
        {:ok, job}

      {:error, _reason} ->
        if provenance == :newly_created do
          _ = cancel(run, internal?: true)
        end

        {:error, :enqueue_failed}
    end
  end

  defp update_internal(run, attrs, action, opts) do
    with :ok <- authorize_internal_or_admin(opts) do
      run
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_context(@authorized_context)
      |> Ash.Changeset.for_update(action, attrs)
      |> Ash.update(domain: Ingestion)
    end
  end

  defp authorize_read(opts), do: authorize_internal_or_admin(opts)

  defp authorize_internal_or_admin(opts) do
    cond do
      Keyword.get(opts, :internal?) == true -> :ok
      opts |> Keyword.get(:actor) |> Policies.global_admin?() -> :ok
      true -> {:error, :forbidden}
    end
  end

  defp authorize_admin(opts) do
    if opts |> Keyword.get(:actor) |> Policies.global_admin?() do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp authorize_internal(opts) do
    if Keyword.get(opts, :internal?) == true do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp limit(opts) do
    opts
    |> Keyword.get(:limit, @default_limit)
    |> normalize_limit()
    |> min(@max_limit)
  end

  defp normalize_limit(value) when is_integer(value) and value > 0, do: value

  defp normalize_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> @default_limit
    end
  end

  defp normalize_limit(_value), do: @default_limit
end
