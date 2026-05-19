defmodule EventSales.Ingestion.TickeraAttendeeSyncQueue do
  @moduledoc """
  Admin workflow for queuing Tickera attendee sync runs and enqueueing the worker.
  """

  alias EventSales.Accounts.Policies
  alias EventSales.Ingestion.Resources.TickeraEventSource
  alias EventSales.Ingestion.TickeraAttendeeSyncRuns
  alias EventSales.Ingestion.Workers.SyncTickeraAttendeesWorker

  @type result ::
          {:ok, %{sync_run: struct(), job: Oban.Job.t()}}
          | {:error, :forbidden | :inactive_source | :enqueue_failed | term()}

  @doc """
  Queues a manual Tickera attendee sync run and enqueues `SyncTickeraAttendeesWorker`.
  """
  @spec queue_manual(TickeraEventSource.t(), map(), keyword()) :: result()
  def queue_manual(%TickeraEventSource{} = source, attrs \\ %{}, opts \\ []) do
    oban_insert = Keyword.get(opts, :oban_insert, &Oban.insert/1)

    with :ok <- authorize_admin(opts),
         :ok <- validate_source_active(source),
         {:ok, run} <-
           TickeraAttendeeSyncRuns.queue_manual(source, attrs, actor: Keyword.get(opts, :actor)),
         {:ok, job} <- enqueue_run(run, oban_insert) do
      {:ok, %{sync_run: run, job: job}}
    end
  end

  defp authorize_admin(opts) do
    if opts |> Keyword.get(:actor) |> Policies.global_admin?() do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp validate_source_active(%TickeraEventSource{active: false}), do: {:error, :inactive_source}
  defp validate_source_active(_source), do: :ok

  defp enqueue_run(run, oban_insert) do
    case oban_insert.(SyncTickeraAttendeesWorker.new(%{"sync_run_id" => run.id})) do
      {:ok, job} ->
        {:ok, job}

      {:error, _reason} ->
        _ = TickeraAttendeeSyncRuns.cancel(run, internal?: true)
        {:error, :enqueue_failed}
    end
  end
end
