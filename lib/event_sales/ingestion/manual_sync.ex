defmodule EventSales.Ingestion.ManualSync do
  @moduledoc """
  Admin workflows for queuing scoped manual order reconciliation and
  historical backfill runs.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Audit.Logger, as: AuditLogger
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.Ingestion.Workers.BackfillOrdersWorker
  alias EventSales.Ingestion.Workers.ReconcileOrdersWorker
  alias EventSales.Repo

  @active_historical_index_name "ingestion_sync_runs_active_historical_event_idx"

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

  @type result ::
          {:ok, %{sync_run: SyncRun.t(), job: Oban.Job.t()}}
          | {:error, :forbidden | :enqueue_failed | term()}

  @type historical_result ::
          {:ok, %{sync_run: SyncRun.t(), sync_cursor: SyncCursor.t(), job: Oban.Job.t()}}
          | {:error, :forbidden | term()}

  @doc """
  Queues a scoped manual sync run, audits on success, and enqueues reconciliation.
  """
  @spec queue_manual_scoped(attrs(), audit_attrs(), keyword()) :: result()
  def queue_manual_scoped(run_attrs, audit_attrs, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with :ok <- authorize(opts),
         {:ok, run} <- create_sync_run(run_attrs, now),
         {:ok, _audit} <- audit_requested(run, audit_attrs) do
      case enqueue_worker(run) do
        {:ok, job} ->
          {:ok, %{sync_run: run, job: job}}

        {:error, _reason} ->
          _ = cancel_run_after_enqueue_failure(run)
          {:error, :enqueue_failed}
      end
    end
  end

  @doc """
  Queues one bounded historical backfill for an eligible Event.

  The Event is the only source of source_system_id and date_from.
  Historical queueing creates the run and its initial cursor in one Postgres
  transaction, audits the request, and enqueues exactly one bounded worker.
  """
  @spec queue_historical_backfill(Ecto.UUID.t(), DateTime.t() | nil, audit_attrs(), keyword()) ::
          historical_result()
  def queue_historical_backfill(event_id, date_to, audit_attrs, opts \\ [])

  def queue_historical_backfill(event_id, date_to, audit_attrs, opts)
      when is_map(audit_attrs) and is_list(opts) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with :ok <- authorize(opts),
         {:ok, event} <- load_event(event_id),
         {:ok, date_from} <- validate_historical_scope(event, date_to, now) do
      queue_persisted_historical_backfill(event, date_from, date_to, audit_attrs, opts)
    end
  rescue
    error in Postgrex.Error ->
      {:error, classify_historical_error(error)}
  end

  def queue_historical_backfill(_event_id, _date_to, _audit_attrs, _opts),
    do: {:error, :invalid_historical_backfill_attrs}

  defp authorize(opts) do
    if opts |> Keyword.get(:actor) |> Policies.global_admin?() do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp create_sync_run(attrs, now) do
    attrs =
      attrs
      |> Map.put_new(:sync_mode, :shallow)
      |> Map.put_new(:requested_via, :manual)

    SyncRun
    |> Ash.Changeset.for_create(:queue_manual_scoped, attrs,
      context: %{scoped_manual_sync_now: now}
    )
    |> Ash.create(domain: Ingestion)
  end

  defp load_event(event_id) when is_binary(event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, event_id} -> load_event_by_id(event_id)
      :error -> {:error, :invalid_event_id}
    end
  end

  defp load_event(_event_id), do: {:error, :invalid_event_id}

  defp load_event_by_id(event_id) do
    case Ash.get(Event, event_id, domain: Catalog) do
      {:ok, %Event{} = event} ->
        {:ok, event}

      {:ok, nil} ->
        {:error, :event_not_found}

      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} ->
        {:error, :event_not_found}

      {:error, _reason} ->
        {:error, :event_lookup_failed}
    end
  end

  defp queue_persisted_historical_backfill(event, date_from, date_to, audit_attrs, opts) do
    case Repo.transaction(fn ->
           persist_historical_backfill(event, date_from, date_to, audit_attrs, opts)
         end) do
      {:ok, %{sync_run: run, sync_cursor: cursor, notifications: notifications}} ->
        Ash.Notifier.notify(notifications)
        finalize_historical_queue(run, cursor, audit_attrs, opts)

      {:error, reason} ->
        {:error, classify_historical_error(reason)}
    end
  end

  defp finalize_historical_queue(run, cursor, audit_attrs, opts) do
    case audit_historical_requested(run, audit_attrs) do
      {:ok, _audit} ->
        enqueue_historical_result(run, cursor, opts)

      {:error, reason} ->
        _ = cleanup_historical_enqueue_failure(run)
        {:error, classify_historical_error(reason)}
    end
  end

  defp enqueue_historical_result(run, cursor, opts) do
    case enqueue_historical_worker(run, opts) do
      {:ok, job} ->
        {:ok, %{sync_run: run, sync_cursor: cursor, job: job}}

      {:error, _reason} ->
        _ = cleanup_historical_enqueue_failure(run)
        {:error, :enqueue_failed}
    end
  end

  defp validate_historical_scope(
         %Event{} = event,
         date_to,
         %DateTime{} = now
       ) do
    with :ok <- validate_event_identity(event),
         :ok <- validate_backfill_pending(event),
         {:ok, date_from} <- backfill_start(event),
         :ok <- validate_cutoff(date_to, date_from, now) do
      {:ok, date_from}
    end
  end

  defp validate_historical_scope(_event, _date_to, _now),
    do: {:error, :invalid_queue_time}

  defp validate_event_identity(%Event{
         external_event_kind: :tickera_event,
         external_event_id: external_event_id
       })
       when is_integer(external_event_id) and external_event_id > 0,
       do: :ok

  defp validate_event_identity(_event), do: {:error, :invalid_event_identity}

  defp validate_backfill_pending(%Event{analytics_onboarding_state: :backfill_pending}),
    do: :ok

  defp validate_backfill_pending(_event), do: {:error, :event_not_backfill_pending}

  defp backfill_start(%Event{source_created_at: %DateTime{} = source_created_at}),
    do: {:ok, source_created_at}

  defp backfill_start(_event), do: {:error, :missing_backfill_start}

  defp validate_cutoff(nil, _date_from, _now), do: {:error, :missing_backfill_cutoff}

  defp validate_cutoff(%DateTime{time_zone: "Etc/UTC"} = date_to, date_from, now) do
    cond do
      DateTime.compare(date_to, date_from) == :lt ->
        {:error, :cutoff_before_backfill_start}

      DateTime.compare(date_to, now) == :gt ->
        {:error, :future_backfill_cutoff}

      true ->
        :ok
    end
  end

  defp validate_cutoff(_date_to, _date_from, _now),
    do: {:error, :invalid_backfill_cutoff}

  defp persist_historical_backfill(event, date_from, date_to, _audit_attrs, opts) do
    with {:ok, run, run_notifications} <- create_historical_run(event, date_from, date_to),
         {:ok, cursor, cursor_notifications} <- create_initial_cursor(run, opts) do
      %{
        sync_run: run,
        sync_cursor: cursor,
        notifications: run_notifications ++ cursor_notifications
      }
    else
      {:error, reason} -> Repo.rollback(classify_historical_error(reason))
    end
  end

  defp create_historical_run(%Event{} = event, date_from, date_to) do
    SyncRun
    |> Ash.Changeset.for_create(:queue_historical_backfill, %{
      event_id: event.id,
      date_to: date_to
    })
    |> Ash.Changeset.force_change_attribute(:source_system_id, event.source_system_id)
    |> Ash.Changeset.force_change_attribute(:date_from, date_from)
    |> Ash.create(
      domain: Ingestion,
      context: %{warn_on_transaction_hooks?: false},
      return_notifications?: true
    )
    |> normalize_create_result()
  end

  defp create_initial_cursor(run, opts) do
    case Keyword.get(opts, :test_cursor_creator) do
      creator when is_function(creator, 1) -> creator.(run) |> normalize_create_result()
      nil -> persist_initial_cursor(run)
      _other -> {:error, :invalid_cursor_creator}
    end
  end

  defp persist_initial_cursor(%SyncRun{} = run) do
    SyncCursor
    |> Ash.Changeset.for_create(:upsert_active, %{
      sync_run_id: run.id,
      page: 1,
      modified_after: run.date_from,
      modified_before: run.date_to,
      last_seen_order_id: nil,
      metadata: %{}
    })
    |> Ash.create(
      domain: Ingestion,
      context: %{warn_on_transaction_hooks?: false},
      return_notifications?: true
    )
    |> normalize_create_result()
  end

  defp audit_historical_requested(%SyncRun{} = run, audit_attrs) do
    metadata =
      audit_attrs
      |> Map.get(:metadata, %{})
      |> Map.merge(%{
        "scope" => "event",
        "sync_type" => Atom.to_string(run.sync_type),
        "event_id" => run.event_id,
        "source_system_id" => run.source_system_id,
        "date_from" => DateTime.to_iso8601(run.date_from),
        "date_to" => DateTime.to_iso8601(run.date_to),
        "requested_via" => Atom.to_string(run.requested_via),
        "result" => "queued"
      })

    audit_attrs
    |> Map.drop([:metadata])
    |> Map.put(:subject_type, "sync_run")
    |> Map.put(:subject_id, run.id)
    |> Map.put(:event_id, run.event_id)
    |> Map.put(:metadata, metadata)
    |> then(&AuditLogger.historical_backfill_requested/1)
  end

  defp normalize_create_result({:ok, record, notifications}),
    do: {:ok, record, notifications || []}

  defp normalize_create_result({:ok, record}), do: {:ok, record, []}
  defp normalize_create_result(result), do: result

  defp classify_historical_error(%Ash.Error.Invalid{errors: errors} = error) do
    if Enum.any?(errors, &active_historical_constraint?/1) or
         String.contains?(inspect(error), @active_historical_index_name),
       do: :active_historical_run_exists,
       else: error
  end

  defp classify_historical_error(%Ash.Changeset{errors: errors} = error) do
    if Enum.any?(errors, &active_historical_constraint?/1) or
         String.contains?(inspect(error), @active_historical_index_name),
       do: :active_historical_run_exists,
       else: error
  end

  defp classify_historical_error(%Postgrex.Error{
         postgres: %{code: :unique_violation, constraint: @active_historical_index_name}
       }),
       do: :active_historical_run_exists

  defp classify_historical_error(error), do: error

  defp active_historical_constraint?(error) do
    private_vars = Map.get(error, :private_vars, [])

    constraint =
      cond do
        is_list(private_vars) -> Keyword.get(private_vars, :constraint)
        is_map(private_vars) -> Map.get(private_vars, :constraint)
        true -> nil
      end

    constraint == @active_historical_index_name or
      match?([constraint: @active_historical_index_name], private_vars) or
      String.contains?(Exception.message(error), @active_historical_index_name) or
      String.contains?(Exception.message(error), "an active historical backfill already exists")
  end

  defp enqueue_worker(%SyncRun{id: sync_run_id}) do
    %{"sync_run_id" => sync_run_id}
    |> ReconcileOrdersWorker.new()
    |> Oban.insert()
  end

  defp enqueue_historical_worker(%SyncRun{} = run, opts) do
    case Keyword.get(opts, :historical_worker_enqueuer) do
      enqueuer when is_function(enqueuer, 1) ->
        enqueuer.(run)

      nil ->
        %{"sync_run_id" => run.id}
        |> BackfillOrdersWorker.new()
        |> Oban.insert()

      _other ->
        {:error, :invalid_historical_worker_enqueuer}
    end
  rescue
    _error -> {:error, :enqueue_failed}
  end

  defp cancel_run_after_enqueue_failure(%SyncRun{} = run) do
    Ash.update(run, %{}, action: :cancel, domain: Ingestion)
  end

  defp cleanup_historical_enqueue_failure(%SyncRun{} = run) do
    _ = cancel_run_after_enqueue_failure(run)

    with {:ok, %SyncCursor{} = cursor} <-
           SyncCursor
           |> Ash.Query.filter(sync_run_id == ^run.id)
           |> Ash.read_one(domain: Ingestion),
         {:ok, _failed} <-
           Ash.update(cursor, %{metadata: %{"failure" => "worker_enqueue_failed"}},
             action: :mark_failed,
             domain: Ingestion
           ) do
      :ok
    else
      _error -> :ok
    end
  end

  defp audit_requested(%SyncRun{} = run, audit_attrs) do
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
