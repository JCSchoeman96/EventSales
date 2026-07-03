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
         {:ok, applying} <- update_run(run, :mark_applying, %{}),
         {:ok, _applied} <- Applier.apply(applying.id, dry_run_hash),
         :ok <- PubSub.broadcast(applying.id, :catalog_sync_applied, %{run_id: applying.id}) do
      :ok
    else
      {:ok, nil} -> :discard
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
      {:ok, %TickeraCatalogSyncRun{} = run} ->
        update_run(run, :mark_failed, %{last_error: sanitize_error(reason)})
        PubSub.broadcast(run.id, :catalog_sync_failed, %{run_id: run.id})
        {:error, reason}

      _other ->
        {:error, reason}
    end
  end

  defp sanitize_error(reason), do: reason |> inspect() |> String.slice(0, 255)
end
