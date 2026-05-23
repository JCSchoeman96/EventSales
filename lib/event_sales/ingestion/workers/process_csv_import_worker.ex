defmodule EventSales.Ingestion.Workers.ProcessCsvImportWorker do
  @moduledoc """
  Oban worker that applies a validated CSV import batch asynchronously.
  """

  use Oban.Worker,
    queue: :csv_imports,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:args],
      keys: [:csv_import_batch_id],
      states: ~w(available scheduled executing retryable completed)a
    ]

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.CsvImportBatch

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"csv_import_batch_id" => batch_id}}) when is_binary(batch_id) do
    case Ash.get(CsvImportBatch, batch_id, domain: Ingestion) do
      {:ok, %CsvImportBatch{status: :applied}} ->
        :discard

      {:ok, %CsvImportBatch{status: status}} when status in [:dry_run_passed, :applying] ->
        handle_apply(apply_import().apply(batch_id))

      {:ok, %CsvImportBatch{}} ->
        :discard

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        :discard

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform(%Oban.Job{}), do: :discard

  defp handle_apply({:ok, %CsvImportBatch{}}), do: :ok
  defp handle_apply({:error, :invalid_status}), do: :discard
  defp handle_apply({:error, reason}), do: {:error, reason}

  defp apply_import do
    Application.get_env(:event_sales, :csv_apply_import, EventSales.Ingestion.Csv.ApplyImport)
  end
end
