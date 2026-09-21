defmodule EventSales.Ingestion.Workers.ReconcileFinancialsWorker do
  @moduledoc """
  Oban worker that drives one durable financial reconciliation run.
  """

  use Oban.Worker,
    queue: :financial_reconciliation,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:args],
      keys: [:financial_reconciliation_run_id],
      states: ~w(available scheduled executing retryable)a
    ]

  alias EventSales.Ingestion
  alias EventSales.Ingestion.FinancialReconciliation.Orchestrator
  alias EventSales.Ingestion.FinancialReconciliationRuns
  alias EventSales.Ingestion.Resources.FinancialReconciliationRun

  @terminal_statuses [:passed, :mismatched, :superseded, :failed, :cancelled]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"financial_reconciliation_run_id" => run_id}})
      when is_binary(run_id) do
    case load_run(run_id) do
      :discard -> :discard
      {:error, reason} -> {:error, reason}
      {:ok, run} -> handle_result(run_engine(run))
    end
  end

  def perform(%Oban.Job{args: _args}), do: :discard

  defp load_run(run_id) do
    case Ash.get(FinancialReconciliationRun, run_id, domain: Ingestion) do
      {:ok, %FinancialReconciliationRun{status: status}} when status in @terminal_statuses ->
        :discard

      {:ok, %FinancialReconciliationRun{} = run} ->
        {:ok, run}

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        :discard

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_engine(run) do
    engine = Application.get_env(:event_sales, :financial_reconciliation_engine, Orchestrator)

    try do
      engine.run(run)
    rescue
      exception ->
        mark_failed_after_raise(run, exception)
        {:error, exception}
    end
  end

  defp mark_failed_after_raise(run, exception) do
    with {:ok, run} <- ensure_running(run) do
      FinancialReconciliationRuns.mark_failed(
        run,
        %{last_error: Exception.message(exception)},
        internal?: true
      )
    end
  end

  defp ensure_running(%FinancialReconciliationRun{status: :queued} = run) do
    FinancialReconciliationRuns.mark_started(run, internal?: true)
  end

  defp ensure_running(%FinancialReconciliationRun{} = run), do: {:ok, run}

  defp handle_result({:ok, _run}), do: :ok
  defp handle_result({:error, {:failed, _, _reason}}), do: :ok
  defp handle_result({:error, reason}), do: {:error, reason}
end
