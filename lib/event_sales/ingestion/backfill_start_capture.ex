defmodule EventSales.Ingestion.BackfillStartCapture do
  @moduledoc """
  Captures the authoritative Tickera Event creation instant from one verified
  event-scoped catalog dry-run snapshot.

  The caller supplies only the local Event and catalog SyncRun identities. The
  source timestamp is trusted only after the Event/run binding and canonical
  snapshot hash have been verified in one Postgres transaction.
  """

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizer
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Repo

  @event_lock_query "SELECT id FROM catalog_events WHERE id = $1 FOR UPDATE"
  @run_lock_query "SELECT id FROM ingestion_tickera_catalog_sync_runs WHERE id = $1 FOR UPDATE"
  @capture_context %{
    event_sales_backfill_start_capture_authority: {Event, :verified},
    warn_on_transaction_hooks?: false
  }

  @type reason ::
          :capture_failed
          | :event_not_found
          | :invalid_event_identity
          | :event_not_backfill_pending
          | :run_not_found
          | :run_not_ready
          | :run_source_mismatch
          | :run_scope_mismatch
          | :missing_plan_snapshot
          | :snapshot_hash_mismatch
          | :missing_source_created_at
          | :invalid_source_created_at
          | :foreign_event
          | :source_created_at_conflict

  @spec capture(Ecto.UUID.t(), Ecto.UUID.t()) :: {:ok, Event.t()} | {:error, reason()}
  def capture(event_id, sync_run_id)
      when is_binary(event_id) and is_binary(sync_run_id) do
    Repo.transaction(fn ->
      with :ok <- lock_uuid(@event_lock_query, event_id, :event_not_found),
           {:ok, event} <- load_event(event_id),
           :ok <- validate_event(event),
           :ok <- lock_uuid(@run_lock_query, sync_run_id, :run_not_found),
           {:ok, run} <- load_run(sync_run_id),
           :ok <- validate_run_binding(event, run),
           {:ok, snapshot} <- trusted_snapshot(run),
           {:ok, source_created_at} <- source_created_at(snapshot, event),
           {:ok, captured} <- persist_source_created_at(event, source_created_at) do
        {:ok, captured}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {:ok, %Event{} = event}} -> {:ok, event}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _reason} -> {:error, :capture_failed}
      _other -> {:error, :capture_failed}
    end
  rescue
    _error -> {:error, :capture_failed}
  end

  def capture(_event_id, _sync_run_id), do: {:error, :capture_failed}

  defp lock_uuid(query, id, missing_reason) do
    with {:ok, cast_id} <- Ecto.UUID.cast(id),
         {:ok, %{num_rows: 1}} <- Repo.query(query, [Ecto.UUID.dump!(cast_id)]) do
      :ok
    else
      _other -> {:error, missing_reason}
    end
  end

  defp load_event(event_id) do
    case Ash.get(Event, event_id, domain: Catalog) do
      {:ok, %Event{} = event} -> {:ok, event}
      {:ok, nil} -> {:error, :event_not_found}
      {:error, _reason} -> {:error, :event_not_found}
    end
  end

  defp validate_event(%Event{
         external_event_kind: :tickera_event,
         external_event_id: external_event_id,
         analytics_onboarding_state: :backfill_pending
       })
       when is_integer(external_event_id) and external_event_id > 0,
       do: :ok

  defp validate_event(%Event{analytics_onboarding_state: state})
       when state != :backfill_pending,
       do: {:error, :event_not_backfill_pending}

  defp validate_event(_event), do: {:error, :invalid_event_identity}

  defp load_run(sync_run_id) do
    case Ash.get(TickeraCatalogSyncRun, sync_run_id, domain: Ingestion) do
      {:ok, %TickeraCatalogSyncRun{} = run} -> {:ok, run}
      {:ok, nil} -> {:error, :run_not_found}
      {:error, _reason} -> {:error, :run_not_found}
    end
  end

  defp validate_run_binding(
         %Event{source_system_id: source_system_id, external_event_id: external_event_id},
         %TickeraCatalogSyncRun{
           status: :dry_run_ready,
           source_system_id: source_system_id,
           scope: scope
         }
       ) do
    if scope == %{"kind" => "wordpress_feed", "event_id" => external_event_id} do
      :ok
    else
      {:error, :run_scope_mismatch}
    end
  end

  defp validate_run_binding(
         %Event{source_system_id: source_system_id},
         %TickeraCatalogSyncRun{status: :dry_run_ready, source_system_id: run_source_system_id}
       )
       when source_system_id != run_source_system_id,
       do: {:error, :run_source_mismatch}

  defp validate_run_binding(%Event{}, %TickeraCatalogSyncRun{status: :dry_run_ready}),
    do: {:error, :run_scope_mismatch}

  defp validate_run_binding(%Event{}, %TickeraCatalogSyncRun{}),
    do: {:error, :run_not_ready}

  defp trusted_snapshot(%TickeraCatalogSyncRun{plan_snapshot: nil}),
    do: {:error, :missing_plan_snapshot}

  defp trusted_snapshot(%TickeraCatalogSyncRun{plan_snapshot: snapshot})
       when not is_map(snapshot),
       do: {:error, :missing_plan_snapshot}

  defp trusted_snapshot(%TickeraCatalogSyncRun{
         plan_snapshot: snapshot,
         dry_run_hash: dry_run_hash
       })
       when is_map(snapshot) and is_binary(dry_run_hash) and dry_run_hash != "" do
    case SnapshotCanonicalizer.canonicalize(snapshot) do
      {:ok, _bytes, ^dry_run_hash} -> {:ok, snapshot}
      _other -> {:error, :snapshot_hash_mismatch}
    end
  end

  defp trusted_snapshot(_run), do: {:error, :snapshot_hash_mismatch}

  defp source_created_at(snapshot, %Event{} = event) do
    case Map.get(snapshot, "event_actions") do
      actions when is_list(actions) -> extract_event_actions(actions, event)
      _other -> {:error, :missing_source_created_at}
    end
  end

  defp extract_event_actions(actions, %Event{} = event) do
    relations = Enum.map(actions, &event_action_relation(&1, event))

    if Enum.any?(relations, &(&1 == :foreign)) do
      {:error, :foreign_event}
    else
      actions
      |> Enum.zip(relations)
      |> Enum.filter(fn {_action, relation} -> relation == :selected end)
      |> Enum.map(&elem(&1, 0))
      |> extract_selected_source_created_at()
    end
  end

  defp event_action_relation(action, %Event{id: event_id, external_event_id: external_event_id})
       when is_map(action) do
    action_event_id = map_value(action, "event_id")
    action_external_event_id = map_value(action, "external_event_id")

    cond do
      is_binary(action_event_id) and action_event_id != event_id ->
        :foreign

      is_integer(action_external_event_id) and action_external_event_id != external_event_id ->
        :foreign

      action_event_id == event_id or action_external_event_id == external_event_id ->
        :selected

      true ->
        :unrelated
    end
  end

  defp event_action_relation(_action, _event), do: :foreign

  defp extract_selected_source_created_at([]), do: {:error, :missing_source_created_at}

  defp extract_selected_source_created_at(actions) do
    values = Enum.map(actions, &map_value(&1, "source_created_at"))

    if Enum.any?(values, &is_nil/1) do
      {:error, :missing_source_created_at}
    else
      with {:ok, datetimes} <- parse_source_created_at_values(values),
           :ok <- reject_conflicting_source_created_at(datetimes) do
        {:ok, hd(datetimes)}
      end
    end
  end

  defp parse_source_created_at_values(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case parse_source_created_at(value) do
        {:ok, datetime} -> {:cont, {:ok, [datetime | acc]}}
        {:error, _reason} -> {:halt, {:error, :invalid_source_created_at}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp parse_source_created_at(%DateTime{} = datetime),
    do: DateTime.shift_zone(datetime, "Etc/UTC")

  defp parse_source_created_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> DateTime.shift_zone(datetime, "Etc/UTC")
      _other -> {:error, :invalid_source_created_at}
    end
  end

  defp parse_source_created_at(_value), do: {:error, :invalid_source_created_at}

  defp reject_conflicting_source_created_at([_datetime]), do: :ok

  defp reject_conflicting_source_created_at([first | rest]) do
    if Enum.all?(rest, &(DateTime.compare(first, &1) == :eq)) do
      :ok
    else
      {:error, :source_created_at_conflict}
    end
  end

  defp persist_source_created_at(%Event{source_created_at: nil} = event, source_created_at) do
    case Ash.update(
           event,
           %{source_created_at: source_created_at},
           action: :capture_source_created_at,
           domain: Catalog,
           context: @capture_context,
           return_notifications?: true
         ) do
      {:ok, %Event{} = captured} -> {:ok, captured}
      {:ok, %Event{} = captured, _notifications} -> {:ok, captured}
      {:error, _reason} -> {:error, :source_created_at_conflict}
    end
  end

  defp persist_source_created_at(%Event{} = event, source_created_at) do
    persisted = event.source_created_at

    if DateTime.compare(persisted, source_created_at) == :eq do
      {:ok, event}
    else
      {:error, :source_created_at_conflict}
    end
  end

  defp map_value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_existing_atom(key))
    end
  end
end
