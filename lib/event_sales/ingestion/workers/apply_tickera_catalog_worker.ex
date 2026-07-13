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

  alias EventSales.Catalog.TickeraCatalog.{Applier, PubSub}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"run_id" => run_id, "dry_run_hash" => dry_run_hash}})
      when is_binary(run_id) and is_binary(dry_run_hash) do
    with {:ok, %TickeraCatalogSyncRun{} = run} <-
           Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion),
         {:ok, _applied} <- Applier.apply(run.id, dry_run_hash),
         :ok <- PubSub.broadcast(run.id, :catalog_sync_applied, %{run_id: run.id}) do
      :ok
    else
      {:ok, nil} -> :discard
      {:error, :run_not_ready} -> discard_stale_run(run_id)
      {:error, reason} -> fail(run_id, reason)
    end
  end

  def perform(_job), do: :discard

  defp update_run(run, action, attrs) do
    run
    |> Ash.Changeset.for_update(action, attrs)
    |> Ash.update(domain: Ingestion)
  end

  defp fail(run_id, reason) do
    case Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion) do
      {:ok, %TickeraCatalogSyncRun{status: status}}
      when status in [:cancelled, :applying, :applied, :failed] ->
        :discard

      {:ok, %TickeraCatalogSyncRun{} = run} ->
        update_run(run, :mark_failed, %{last_error: sanitize_error(reason)})
        PubSub.broadcast(run.id, :catalog_sync_failed, %{run_id: run.id})
        {:error, reason}

      _other ->
        {:error, reason}
    end
  end

  defp discard_stale_run(run_id) do
    case Ash.get(TickeraCatalogSyncRun, run_id, domain: Ingestion) do
      {:ok, %TickeraCatalogSyncRun{status: status}}
      when status in [:cancelled, :applying, :applied, :failed] ->
        :discard

      _other ->
        fail(run_id, :run_not_ready)
    end
  end

  defp sanitize_error(:stale_dry_run_hash), do: "stale_dry_run_hash"
  defp sanitize_error(:missing_plan_snapshot), do: "missing_plan_snapshot"
  defp sanitize_error(:blocking_findings), do: "blocking_findings"
  defp sanitize_error(:run_not_ready), do: "run_not_ready"
  defp sanitize_error(:not_found), do: "not_found"
  defp sanitize_error(_reason), do: "catalog_sync_apply_failed"
end
