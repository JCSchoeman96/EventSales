defmodule EventSales.Ingestion.Workers.CatalogChangeDispatchWorker do
  @moduledoc "Dispatches one exact catalogue-change target per source."
  use Oban.Worker,
    queue: :tickera_sync,
    max_attempts: 100,
    unique: [
      period: :infinity,
      fields: [:args],
      keys: [:source_system_id],
      states: ~w(available scheduled retryable)a
    ]

  @impl true
  def perform(%Oban.Job{args: %{"source_system_id" => source_system_id}}) do
    EventSales.Ingestion.CatalogChangeDispatch.perform(source_system_id)
  end

  def perform(_job), do: :discard
end
