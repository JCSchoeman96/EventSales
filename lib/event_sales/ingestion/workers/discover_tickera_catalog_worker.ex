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

  alias EventSales.Catalog.TickeraCatalog.{Cache, ConfiguredDiscoverySource, Planner, PubSub}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{TickeraCatalogSyncFinding, TickeraCatalogSyncRun}

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

  @doc false
  def retryable_failure?(reason) when is_atom(reason), do: reason in @transient_failures
  def retryable_failure?(_reason), do: false

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id}}) when is_binary(run_id) do
    with {:ok, %TickeraCatalogSyncRun{} = run} <-
           Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion),
         {:ok, discovering} <- update_run(run, :mark_discovering, %{}),
         :ok <- broadcast(discovering.id, :catalog_sync_started),
         {:ok, discovery_result} <-
           ConfiguredDiscoverySource.discover(discovering.source_system_id, discovering.scope),
         {:ok, plan} <- Planner.plan(discovering.source_system_id, discovery_result),
         :ok <- store_findings(discovering.id, plan.findings),
         {:ok, ready} <- update_run(discovering, :mark_dry_run_ready, ready_attrs(plan)),
         :ok <- Cache.put_preview(ready.id, plan.plan_snapshot),
         :ok <- broadcast(ready.id, :catalog_sync_preview_ready) do
      :ok
    else
      {:ok, nil} -> :discard
      {:error, reason} -> fail(run_id, reason)
    end
  end

  def perform(_job), do: :discard

  defp store_findings(run_id, findings) do
    Enum.reduce_while(findings, :ok, fn finding, :ok ->
      attrs = %{
        run_id: run_id,
        severity: finding.severity,
        code: finding.code,
        message: finding.message,
        tickera_event_id: finding.tickera_event_id,
        woo_product_id: finding.woo_product_id,
        woo_variation_id: finding.woo_variation_id,
        metadata: finding.metadata
      }

      case Ash.create(TickeraCatalogSyncFinding, attrs, action: :create, domain: Ingestion) do
        {:ok, _finding} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp ready_attrs(plan) do
    %{
      dry_run_hash: plan.dry_run_hash,
      summary: plan.summary,
      plan_snapshot: plan.plan_snapshot
    }
  end

  defp update_run(run, action, attrs) do
    run
    |> Ash.Changeset.for_update(action, attrs)
    |> Ash.update(domain: Ingestion)
  end

  defp fail(run_id, reason) do
    case Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion) do
      {:ok, %TickeraCatalogSyncRun{} = run} ->
        update_run(run, :mark_failed, %{last_error: sanitize_error(reason)})
        broadcast(run.id, :catalog_sync_failed)
        if retryable_failure?(reason), do: {:error, reason}, else: :discard

      _other ->
        {:error, reason}
    end
  end

  defp broadcast(run_id, event) do
    PubSub.broadcast(run_id, event, %{run_id: run_id})
  end

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
