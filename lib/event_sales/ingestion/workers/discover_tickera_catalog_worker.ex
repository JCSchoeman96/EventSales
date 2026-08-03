defmodule EventSales.Ingestion.Workers.DiscoverTickeraCatalogWorker do
  @moduledoc """
  Builds Tickera catalog dry-run plans asynchronously.
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
  require Ash.Query
  require Logger

  alias EventSales.Catalog.TickeraCatalog.{Cache, ConfiguredDiscoverySource, Planner, PubSub}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{TickeraCatalogSyncFinding, TickeraCatalogSyncRun}
  alias EventSales.Ingestion.Workers.EvaluateTickeraCatalogAutoApplyWorker
  alias EventSales.Repo

  @safe_error_strings %{
    not_configured: "discovery_source_not_configured",
    invalid_manual_rows: "invalid_manual_rows",
    missing_manual_rows: "missing_manual_rows",
    misconfigured: "catalog_feed_misconfigured",
    unauthorized: "catalog_feed_unauthorized",
    forbidden: "catalog_feed_forbidden",
    timeout: "catalog_feed_timeout",
    pagination_limit: "catalog_feed_pagination_limit",
    invalid_feed_response: "invalid_catalog_feed_response",
    invalid_json: "invalid_catalog_feed_response",
    rate_limited: "catalog_feed_rate_limited",
    server_error: "catalog_feed_server_error",
    transport_error: "catalog_feed_transport_error"
  }
  @transient_failures [:timeout, :rate_limited, :server_error, :transport_error]
  @claimable_statuses [:queued, :retry_scheduled, :discovering]
  @advanced_statuses [:dry_run_ready, :applying, :applied, :failed, :cancelled]

  @doc false
  def retryable_failure?(reason) when is_atom(reason), do: reason in @transient_failures
  def retryable_failure?(_reason), do: false

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: perform(job, [])

  @doc false
  def perform(%Oban.Job{args: %{"run_id" => run_id}} = job, opts) when is_binary(run_id) do
    {owner_attempt, owner_max_attempts} = owner_metadata(job)

    case claim_run(run_id, owner_attempt, owner_max_attempts, opts) do
      {:ok, discovering} ->
        execute_discovery(discovering, owner_attempt, owner_max_attempts, opts)

      result ->
        result
    end
  end

  def perform(_job, _opts), do: :discard

  defp owner_metadata(%Oban.Job{attempt: attempt, max_attempts: max_attempts}) do
    attempt = max(attempt || 1, 1)
    {attempt, max(max_attempts || 1, attempt)}
  end

  defp claim_run(run_id, owner_attempt, owner_max_attempts, opts) do
    with {:ok, %TickeraCatalogSyncRun{} = run} <-
           Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion),
         :ok <- invoke_hook(opts, :before_claim_update),
         {:ok, discovering} <- claim_update(run, owner_attempt, owner_max_attempts) do
      {:ok, discovering}
    else
      {:ok, nil} -> :discard
      {:error, _reason} -> classify_claim_failure(run_id, owner_attempt, owner_max_attempts)
    end
  end

  defp claim_update(run, owner_attempt, owner_max_attempts) do
    run
    |> Ash.Changeset.for_update(:mark_discovering, %{
      owner_attempt: owner_attempt,
      owner_max_attempts: owner_max_attempts
    })
    |> Ash.Changeset.filter(
      expr(
        status in ^@claimable_statuses and
          (is_nil(retry_attempt) or retry_attempt < ^owner_attempt)
      )
    )
    |> Ash.update(domain: Ingestion)
  end

  defp classify_claim_failure(run_id, owner_attempt, owner_max_attempts) do
    case Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion) do
      {:ok, nil} ->
        :discard

      {:ok, %TickeraCatalogSyncRun{} = run} ->
        cond do
          run.status in @advanced_statuses ->
            :discard

          is_integer(run.retry_attempt) and run.retry_attempt >= owner_attempt ->
            :discard

          owner_attempt < owner_max_attempts ->
            {:error, :catalog_sync_claim_failed}

          true ->
            reconcile_final_claim_failure(run, owner_attempt, owner_max_attempts)
        end

      {:error, _reason} ->
        Logger.error("catalog sync claim reload failed run_id=#{run_id}")
        {:error, :catalog_sync_claim_failed}
    end
  end

  defp reconcile_final_claim_failure(run, owner_attempt, owner_max_attempts) do
    result =
      run
      |> Ash.Changeset.for_update(:mark_claim_failed, %{
        owner_attempt: owner_attempt,
        owner_max_attempts: owner_max_attempts
      })
      |> Ash.Changeset.filter(
        expr(
          status in ^@claimable_statuses and
            (is_nil(retry_attempt) or retry_attempt < ^owner_attempt)
        )
      )
      |> Ash.update(domain: Ingestion)

    case result do
      {:ok, failed} ->
        broadcast(failed.id, :catalog_sync_failed)
        :discard

      {:error, _reason} ->
        classify_lost_owner(run.id, owner_attempt, :catalog_sync_claim_failed)
    end
  end

  defp execute_discovery(discovering, owner_attempt, owner_max_attempts, opts) do
    with :ok <- broadcast(discovering.id, :catalog_sync_started),
         {:ok, discovery_result} <-
           ConfiguredDiscoverySource.discover(discovering.source_system_id, discovering.scope),
         discovery_result <- %{discovery_result | origin: discovering.origin},
         {:ok, plan} <- Planner.plan(discovering.source_system_id, discovery_result) do
      case finalize_ready(discovering, plan, owner_attempt) do
        {:ok, ready, notifications} ->
          run_post_commit_side_effects(ready, plan, notifications, opts)
          :ok

        {:error, reason} ->
          fail_owned(discovering.id, reason, owner_attempt, owner_max_attempts)
      end
    else
      {:error, reason} ->
        fail_owned(discovering.id, reason, owner_attempt, owner_max_attempts)
    end
  end

  defp finalize_ready(run, plan, owner_attempt) do
    case Repo.transaction(fn -> finalize_ready_transaction(run, plan, owner_attempt) end) do
      {:ok, {:ok, ready, notifications}} -> {:ok, ready, notifications}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp finalize_ready_transaction(run, plan, owner_attempt) do
    with {:ok, destroy_notifications} <- destroy_existing_findings(run.id),
         {:ok, create_notifications} <- create_findings(run.id, plan.findings),
         {:ok, ready, ready_notifications} <- mark_ready(run, plan, owner_attempt),
         {:ok, _job} <- enqueue_auto_apply_evaluation(ready) do
      {:ok, ready, destroy_notifications ++ create_notifications ++ ready_notifications}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp enqueue_auto_apply_evaluation(ready) do
    %{"run_id" => ready.id, "dry_run_hash" => ready.dry_run_hash}
    |> EvaluateTickeraCatalogAutoApplyWorker.new()
    |> Oban.insert()
  end

  defp destroy_existing_findings(run_id) do
    result =
      TickeraCatalogSyncFinding
      |> Ash.Query.filter(run_id == ^run_id)
      |> Ash.bulk_destroy(:destroy_for_retry, %{},
        domain: Ingestion,
        strategy: [:atomic],
        return_notifications?: true,
        return_errors?: true
      )

    case result do
      %Ash.BulkResult{status: :success, notifications: notifications} ->
        {:ok, notifications || []}

      %Ash.BulkResult{errors: errors} ->
        {:error, errors || :finding_cleanup_failed}
    end
  end

  defp create_findings(run_id, findings) do
    Enum.reduce_while(findings, {:ok, []}, fn finding, {:ok, notifications} ->
      attrs = %{
        run_id: run_id,
        severity: finding.severity,
        code: persisted_finding_code(finding.code),
        message: finding.message,
        tickera_event_id: finding.tickera_event_id,
        woo_product_id: finding.woo_product_id,
        woo_variation_id: finding.woo_variation_id,
        metadata: finding.metadata
      }

      case Ash.create(TickeraCatalogSyncFinding, attrs,
             action: :create,
             domain: Ingestion,
             return_notifications?: true
           ) do
        {:ok, _finding, new_notifications} ->
          {:cont, {:ok, notifications ++ new_notifications}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp persisted_finding_code(code) when is_atom(code) do
    code
    |> Atom.to_string()
    |> persisted_finding_code()
  end

  defp persisted_finding_code(code) when is_binary(code) do
    code = String.trim(code)

    if code == "" or byte_size(code) > 120 do
      raise ArgumentError, "invalid persisted catalogue finding code"
    end

    code
  end

  defp mark_ready(run, plan, owner_attempt) do
    run
    |> Ash.Changeset.for_update(:mark_dry_run_ready, ready_attrs(plan))
    |> owner_filter(owner_attempt)
    |> Ash.update(domain: Ingestion, return_notifications?: true)
  end

  defp ready_attrs(plan) do
    %{
      dry_run_hash: plan.dry_run_hash,
      summary: plan.summary,
      plan_snapshot: plan.plan_snapshot
    }
  end

  defp run_post_commit_side_effects(ready, plan, notifications, opts) do
    run_side_effect(ready.id, :notify, fn ->
      invoke_side_effect(opts, :notify, fn -> Ash.Notifier.notify(notifications) end)
    end)

    run_side_effect(ready.id, :cache, fn ->
      invoke_side_effect(opts, :cache, fn -> Cache.put_preview(ready.id, plan.plan_snapshot) end)
    end)

    run_side_effect(ready.id, :pubsub, fn ->
      invoke_side_effect(opts, :pubsub, fn -> broadcast(ready.id, :catalog_sync_preview_ready) end)
    end)
  end

  defp run_side_effect(run_id, kind, fun) do
    case fun.() do
      :ok ->
        :ok

      {:error, _reason} ->
        Logger.warning("catalog sync post-commit #{kind} failed run_id=#{run_id}")

      _other ->
        :ok
    end
  rescue
    _error -> Logger.warning("catalog sync post-commit #{kind} raised run_id=#{run_id}")
  catch
    _kind, _reason -> Logger.warning("catalog sync post-commit #{kind} threw run_id=#{run_id}")
  end

  defp invoke_side_effect(opts, key, default) do
    case Keyword.get(opts, key) do
      callback when is_function(callback, 0) -> callback.()
      _other -> default.()
    end
  end

  defp invoke_hook(opts, key) do
    case Keyword.get(opts, key) do
      callback when is_function(callback, 0) -> callback.()
      _other -> :ok
    end
  end

  defp fail_owned(run_id, reason, owner_attempt, owner_max_attempts) do
    case Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion) do
      {:ok, %TickeraCatalogSyncRun{} = run} ->
        persist_failure(run, reason, owner_attempt, owner_max_attempts)

      _other ->
        {:error, bounded_worker_error(reason)}
    end
  end

  defp persist_failure(run, reason, owner_attempt, owner_max_attempts)
       when owner_attempt < owner_max_attempts and reason in @transient_failures do
    attrs = %{
      last_error: sanitize_error(reason),
      retry_attempt: owner_attempt,
      retry_max_attempts: owner_max_attempts
    }

    case update_owned(run, :mark_retry_scheduled, attrs, owner_attempt) do
      {:ok, scheduled} ->
        PubSub.broadcast(scheduled.id, :catalog_sync_retry_scheduled, %{
          run_id: scheduled.id,
          retry_attempt: owner_attempt,
          retry_max_attempts: owner_max_attempts
        })

        {:error, reason}

      {:error, _error} ->
        classify_lost_owner(run.id, owner_attempt, reason)
    end
  end

  defp persist_failure(run, reason, owner_attempt, _owner_max_attempts) do
    case update_owned(
           run,
           :mark_failed,
           %{last_error: sanitize_error(reason)},
           owner_attempt
         ) do
      {:ok, failed} ->
        broadcast(failed.id, :catalog_sync_failed)
        terminal_worker_result(reason)

      {:error, _error} ->
        classify_lost_owner(run.id, owner_attempt, reason)
    end
  end

  defp update_owned(run, action, attrs, owner_attempt) do
    run
    |> Ash.Changeset.for_update(action, attrs)
    |> owner_filter(owner_attempt)
    |> Ash.update(domain: Ingestion)
  end

  defp owner_filter(changeset, owner_attempt) do
    Ash.Changeset.filter(
      changeset,
      expr(status == :discovering and retry_attempt == ^owner_attempt)
    )
  end

  defp classify_lost_owner(run_id, owner_attempt, reason) do
    case Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion) do
      {:ok, %TickeraCatalogSyncRun{status: :discovering, retry_attempt: ^owner_attempt}} ->
        {:error, bounded_worker_error(reason)}

      {:ok, %TickeraCatalogSyncRun{}} ->
        :discard

      _other ->
        {:error, bounded_worker_error(reason)}
    end
  end

  defp terminal_worker_result(reason) when reason in @transient_failures, do: {:error, reason}
  defp terminal_worker_result(_reason), do: :discard

  defp bounded_worker_error(reason) when reason in @transient_failures, do: reason
  defp bounded_worker_error(:catalog_sync_claim_failed), do: :catalog_sync_claim_failed
  defp bounded_worker_error(_reason), do: :catalog_sync_discovery_failed

  defp broadcast(run_id, event), do: PubSub.broadcast(run_id, event, %{run_id: run_id})

  defp sanitize_error(reason) do
    case reason do
      {:enqueue_failed, _reason} ->
        "enqueue_failed"

      reason when is_atom(reason) ->
        Map.get(@safe_error_strings, reason, "catalog_sync_discovery_failed")

      _reason ->
        "catalog_sync_discovery_failed"
    end
  end
end
