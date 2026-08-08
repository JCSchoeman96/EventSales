defmodule EventSales.Ingestion.Workers.ApplyTickeraCatalogWorker do
  @moduledoc """
  Applies approved Tickera catalog dry-run snapshots.
  """

  use Oban.Worker,
    queue: :tickera_sync,
    max_attempts: 3,
    unique: [
      period: 300,
      fields: [:args],
      keys: [:run_id],
      states: ~w(available scheduled executing retryable)a
    ]

  import Ash.Expr

  alias EventSales.Catalog.TickeraCatalog.{Applier, PubSub}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Ingestion.TickeraCatalogAutoApply

  @failure_transition_statuses [:queued, :discovering, :dry_run_ready]
  @terminal_statuses [:cancelled, :applying, :applied, :failed]
  @review_only_snapshot_version "tickera_catalog_plan.v3"

  @impl Oban.Worker
  def perform(%Oban.Job{
        id: job_id,
        args: %{
          "run_id" => run_id,
          "dry_run_hash" => dry_run_hash,
          "decision_id" => decision_id
        }
      })
      when is_integer(job_id) and is_binary(run_id) and is_binary(dry_run_hash) and
             is_binary(decision_id) do
    with {:ok, _decision} <-
           TickeraCatalogAutoApply.validate_automatic_claim(
             decision_id,
             job_id,
             run_id,
             dry_run_hash
           ),
         {:ok, %TickeraCatalogSyncRun{} = run} <-
           Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion),
         :ok <- reject_review_only_snapshot(run),
         {:ok, _applied} <-
           Applier.apply(run.id, dry_run_hash, automatic_decision_id: decision_id),
         :ok <- PubSub.broadcast(run.id, :catalog_sync_applied, %{run_id: run.id}) do
      :ok
    else
      {:error, :unsupported_snapshot_version} ->
        _result = TickeraCatalogAutoApply.record_apply_audit(decision_id, :claim_rejected)
        :discard

      {:error, reason}
      when reason in [
             :automatic_claim_rejected,
             :missing_auto_apply_decision,
             :invalid_automatic_claim
           ] ->
        _result = TickeraCatalogAutoApply.record_apply_audit(decision_id, :claim_rejected)
        :discard

      {:ok, nil} ->
        _result = TickeraCatalogAutoApply.record_apply_audit(decision_id, :claim_rejected)
        :discard

      {:error, reason} ->
        _result = TickeraCatalogAutoApply.record_apply_audit(decision_id, :failed)
        {:error, bounded_error(reason)}
    end
  end

  def perform(%Oban.Job{args: %{"run_id" => run_id, "dry_run_hash" => dry_run_hash}})
      when is_binary(run_id) and is_binary(dry_run_hash) do
    with {:ok, %TickeraCatalogSyncRun{} = run} <-
           Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion),
         :ok <- reject_review_only_snapshot(run),
         {:ok, _applied} <- Applier.apply(run.id, dry_run_hash),
         :ok <- PubSub.broadcast(run.id, :catalog_sync_applied, %{run_id: run.id}) do
      :ok
    else
      {:ok, nil} -> :discard
      {:error, :unsupported_snapshot_version} -> :discard
      {:error, :run_not_ready} -> discard_stale_run(run_id)
      {:error, reason} -> fail_run(run_id, reason)
    end
  end

  def perform(_job), do: :discard

  # Defense in depth: reject plan.v3 before Applier so a stale/wrong hash never
  # reaches Applier hash validation first.
  defp reject_review_only_snapshot(%TickeraCatalogSyncRun{} = run) do
    if review_only_snapshot?(run.plan_snapshot) do
      {:error, :unsupported_snapshot_version}
    else
      :ok
    end
  end

  defp review_only_snapshot?(%{"snapshot_schema_version" => @review_only_snapshot_version}),
    do: true

  defp review_only_snapshot?(%{snapshot_schema_version: @review_only_snapshot_version}), do: true
  defp review_only_snapshot?(_snapshot), do: false

  @doc false
  def fail_run(run_id, reason, opts \\ []) do
    case Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion) do
      {:ok, %TickeraCatalogSyncRun{status: status}}
      when status in @terminal_statuses ->
        :discard

      {:ok, %TickeraCatalogSyncRun{} = run} ->
        invoke_before_failure_update(opts)

        case mark_failed_if_current(run, reason) do
          {:ok, _failed} ->
            PubSub.broadcast(run.id, :catalog_sync_failed, %{run_id: run.id})
            {:error, bounded_error(reason)}

          {:error, _update_error} ->
            classify_failed_race(run_id, reason)
        end

      _other ->
        {:error, bounded_error(reason)}
    end
  end

  defp mark_failed_if_current(run, reason) do
    statuses = @failure_transition_statuses

    run
    |> Ash.Changeset.for_update(:mark_failed, %{last_error: sanitize_error(reason)})
    |> Ash.Changeset.filter(expr(status in ^statuses))
    |> Ash.update(domain: Ingestion)
  end

  defp classify_failed_race(run_id, reason) do
    case Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion) do
      {:ok, %TickeraCatalogSyncRun{status: status}}
      when status in @terminal_statuses ->
        :discard

      {:ok, %TickeraCatalogSyncRun{}} ->
        {:error, bounded_error(reason)}

      _other ->
        {:error, :not_found}
    end
  end

  defp invoke_before_failure_update(opts) do
    case Keyword.get(opts, :before_update) do
      callback when is_function(callback, 0) -> callback.()
      _other -> :ok
    end
  end

  defp discard_stale_run(run_id) do
    case Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion) do
      {:ok, %TickeraCatalogSyncRun{status: status}}
      when status in @terminal_statuses ->
        :discard

      _other ->
        fail_run(run_id, :run_not_ready)
    end
  end

  defp sanitize_error(:stale_dry_run_hash), do: "stale_dry_run_hash"
  defp sanitize_error(:missing_plan_snapshot), do: "missing_plan_snapshot"
  defp sanitize_error(:blocking_findings), do: "blocking_findings"
  defp sanitize_error(:run_not_ready), do: "run_not_ready"
  defp sanitize_error(:not_found), do: "not_found"
  defp sanitize_error(:automatic_claim_rejected), do: "automatic_claim_rejected"
  defp sanitize_error(_reason), do: "catalog_sync_apply_failed"

  defp bounded_error(reason)
       when reason in [
              :stale_dry_run_hash,
              :missing_plan_snapshot,
              :blocking_findings,
              :run_not_ready,
              :not_found,
              :automatic_claim_rejected
            ],
       do: reason

  defp bounded_error(_reason), do: :catalog_sync_apply_failed
end
