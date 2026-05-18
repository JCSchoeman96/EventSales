defmodule EventSales.Ingestion.ManualSync do
  @moduledoc """
  Admin workflow for queuing scoped manual order reconciliation runs.
  """

  alias EventSales.Audit.Logger, as: AuditLogger
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Ingestion.Workers.ReconcileOrdersWorker

  @type attrs :: %{
          required(:source_system_id) => Ecto.UUID.t(),
          required(:event_id) => Ecto.UUID.t(),
          required(:date_from) => DateTime.t(),
          required(:date_to) => DateTime.t(),
          optional(:sync_mode) => :shallow | :deep,
          optional(:requested_via) => :manual
        }

  @type audit_attrs :: %{
          optional(:actor_type) => atom(),
          optional(:actor_user_id) => Ecto.UUID.t(),
          optional(:actor_role) => atom(),
          optional(:source) => atom(),
          optional(:ip) => String.t(),
          optional(:user_agent) => String.t(),
          optional(:metadata) => map()
        }

  @type result :: {:ok, %{sync_run: SyncRun.t(), job: Oban.Job.t()}} | {:error, term()}

  @doc """
  Queues a scoped manual sync run, audits on success, and enqueues reconciliation.
  """
  @spec queue_manual_scoped(attrs(), audit_attrs(), keyword()) :: result()
  def queue_manual_scoped(run_attrs, audit_attrs, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, run} <- create_sync_run(run_attrs, now),
         {:ok, job} <- enqueue_worker(run),
         {:ok, _audit} <- audit_success(run, audit_attrs) do
      {:ok, %{sync_run: run, job: job}}
    end
  end

  defp create_sync_run(attrs, now) do
    attrs =
      attrs
      |> Map.put_new(:sync_mode, :shallow)
      |> Map.put_new(:requested_via, :manual)

    SyncRun
    |> Ash.Changeset.for_create(:queue_manual_scoped, attrs)
    |> Ash.create(domain: Ingestion, context: %{scoped_manual_sync_now: now})
  end

  defp enqueue_worker(%SyncRun{id: sync_run_id}) do
    %{"sync_run_id" => sync_run_id}
    |> ReconcileOrdersWorker.new()
    |> Oban.insert()
  end

  defp audit_success(%SyncRun{} = run, audit_attrs) do
    metadata =
      audit_attrs
      |> Map.get(:metadata, %{})
      |> Map.merge(%{
        "scope" => "event",
        "event_id" => run.event_id,
        "date_from" => DateTime.to_iso8601(run.date_from),
        "date_to" => DateTime.to_iso8601(run.date_to),
        "sync_mode" => Atom.to_string(run.sync_mode),
        "requested_via" => Atom.to_string(run.requested_via),
        "result" => "queued"
      })

    audit_attrs
    |> Map.drop([:metadata])
    |> Map.put(:subject_type, "sync_run")
    |> Map.put(:subject_id, run.id)
    |> Map.put(:event_id, run.event_id)
    |> Map.put(:metadata, metadata)
    |> then(&AuditLogger.manual_sync_requested/1)
  end
end
