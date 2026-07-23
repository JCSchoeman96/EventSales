defmodule EventSales.Ingestion.Workers.EvaluateTickeraCatalogAutoApplyWorker do
  @moduledoc "Evaluates one durable Catalog Sync dry-run for conservative auto-Apply."

  use Oban.Worker,
    queue: :tickera_sync,
    max_attempts: 20,
    unique: [
      period: :infinity,
      fields: [:args],
      keys: [:run_id, :dry_run_hash],
      states: ~w(available scheduled executing retryable completed)a
    ]

  alias EventSales.Ingestion.TickeraCatalogAutoApply

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"run_id" => run_id, "dry_run_hash" => dry_run_hash}
      }) do
    case TickeraCatalogAutoApply.evaluate_run(run_id) do
      {:ok, %{dry_run_hash: ^dry_run_hash, enqueue_state: :pending} = decision} ->
        case TickeraCatalogAutoApply.enqueue_decision(decision.id) do
          {:ok, _linked} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, %{dry_run_hash: ^dry_run_hash}} ->
        :ok

      {:ok, _decision} ->
        {:discard, :stale_dry_run_hash}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(_job), do: {:discard, :invalid_args}
end
