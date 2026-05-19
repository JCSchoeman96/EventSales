defmodule EventSales.Ingestion.Workers.ReconcileTickeraAttendeesWorker do
  @moduledoc """
  Oban worker that drives one local Tickera/Woo reconciliation run.
  """

  use Oban.Worker,
    queue: :tickera_reconciliation,
    max_attempts: 5,
    unique: [
      period: :infinity,
      fields: [:args],
      keys: [:reconciliation_run_id],
      states: ~w(available scheduled executing retryable)a
    ]

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraReconciliationRun
  alias EventSales.Ingestion.TickeraReconciliation
  alias EventSales.Ingestion.TickeraReconciliationRuns

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"reconciliation_run_id" => run_id}}) when is_binary(run_id) do
    case load_run(run_id) do
      :discard -> :discard
      {:error, reason} -> {:error, reason}
      {:ok, run} -> handle_result(run_engine(run))
    end
  end

  def perform(%Oban.Job{args: _args}), do: :discard

  defp load_run(run_id) do
    case Ash.get(TickeraReconciliationRun, run_id, domain: Ingestion) do
      {:ok, %TickeraReconciliationRun{status: status}}
      when status in [:completed, :failed, :cancelled] ->
        :discard

      {:ok, %TickeraReconciliationRun{} = run} ->
        {:ok, run}

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        :discard

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_engine(run) do
    engine =
      Application.get_env(:event_sales, :tickera_reconciliation_engine, TickeraReconciliation)

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
      TickeraReconciliationRuns.mark_failed(
        run,
        %{last_error: Exception.message(exception)},
        internal?: true
      )
    end
  end

  defp ensure_running(%TickeraReconciliationRun{status: :queued} = run) do
    TickeraReconciliationRuns.mark_started(run, internal?: true)
  end

  defp ensure_running(%TickeraReconciliationRun{} = run), do: {:ok, run}

  defp handle_result({:ok, _run}), do: :ok
  defp handle_result({:error, {:failed, _run, _reason}}), do: :ok
  defp handle_result({:error, reason}), do: {:error, reason}
end
