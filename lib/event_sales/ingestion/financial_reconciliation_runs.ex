defmodule EventSales.Ingestion.FinancialReconciliationRuns do
  @moduledoc """
  Facade for durable financial reconciliation run state.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Ingestion
  alias EventSales.Ingestion.FinancialReconciliation.FindingFingerprint
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
         {:ok, run} <- get_or_create_run(sync_run.id, :queue_manual),
         {:ok, job} <- enqueue_run(run, oban_insert) do
      {:ok, %{financial_reconciliation_run: run, job: job}}
    end
  end

  def queue_system_for_event(event_id, opts \\ []) do
    oban_insert = Keyword.get(opts, :oban_insert, &Oban.insert/1)

    with :ok <- authorize_internal(opts),
         {:ok, %SyncRun{} = sync_run} <- HistoricalCoverageResolver.resolve_current(event_id),
         {:ok, run} <- get_or_create_run(sync_run.id, :queue_system),
         {:ok, job} <- enqueue_run(run, oban_insert) do
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
    with {:ok, %FinancialReconciliationRun{} = run} <- lock_run(run_id),
         :ok <- ensure_running(run),
         :ok <- persist_metrics(run, evidence),
         :ok <- persist_findings(run, evidence),
         {:ok, finalized} <- transition_terminal(run, evidence) do
      finalized
    else
      {:error, :terminal} -> Repo.rollback(:terminal)
      {:error, reason} -> Repo.rollback(reason)
    end
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
      {:ok, run} -> {:ok, run}
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
        {:ok, run}

      {:error, %Ash.Error.Invalid{}} ->
        case find_active_run_for_certificate(sync_run_id) do
          {:ok, run} -> {:ok, run}
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

  defp enqueue_run(run, oban_insert) do
    case oban_insert.(
           ReconcileFinancialsWorker.new(%{"financial_reconciliation_run_id" => run.id})
         ) do
      {:ok, job} ->
        {:ok, job}

      {:error, _reason} ->
        _ = cancel(run, internal?: true)
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
