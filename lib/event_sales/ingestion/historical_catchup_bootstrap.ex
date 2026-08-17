defmodule EventSales.Ingestion.HistoricalCatchupBootstrap do
  @moduledoc """
  Establishes durable evidence for one historical catch-up manifest.

  This boundary requires a terminal historical manifest, atomically claims the
  one catch-up-create command on the existing SyncCursor, performs one source
  POST after that claim commits, and persists only the returned child identity
  and source high-water timestamp. It deliberately does not replay or process
  the first child page.
  """

  import Ecto.Query, only: [from: 2]

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Changes.NormalizeBaseUrl
  alias EventSales.Catalog.Resources.{Event, SourceSystem}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Clients.{WooOrderIndexClient, WooOrderIndexError}
  alias EventSales.Ingestion.HistoricalCatchupEvidence
  alias EventSales.Ingestion.HistoricalManifestEvidence
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.Repo

  @create_limit 100
  @source_error_reasons [
    :misconfigured,
    :invalid_request,
    :unauthorized,
    :busy,
    :manifest_expired,
    :manifest_not_found,
    :manifest_unavailable,
    :parent_manifest_not_found,
    :parent_manifest_expired,
    :parent_manifest_invalid,
    :parent_manifest_not_ready,
    :parent_manifest_changed,
    :parent_manifest_wrong_phase,
    :parent_manifest_wrong_source,
    :catchup_member_unresolved,
    :source_snapshot_before_parent,
    :source_authority_changed,
    :capture_budget_exceeded,
    :manifest_storage_failed,
    :manifest_finalize_failed,
    :source_preflight_failed,
    :source_snapshot_failed,
    :lock_unavailable,
    :server_error,
    :invalid_json,
    :invalid_response,
    :timeout,
    :transport_error,
    :ambiguous_create
  ]

  @type result ::
          {:ok, HistoricalCatchupEvidence.t()}
          | {:error, atom() | {atom(), atom()}}

  @doc "Ensures that one valid historical run has durable catch-up evidence."
  @spec ensure_catchup(Ecto.UUID.t(), keyword()) :: result()
  def ensure_catchup(sync_run_id, opts \\ [])

  def ensure_catchup(sync_run_id, opts) when is_list(opts) do
    with {:ok, sync_run_id} <- validate_uuid(sync_run_id, :invalid_sync_run_id),
         {:ok, run} <- load_sync_run(sync_run_id, opts),
         :ok <- validate_run(run),
         {:ok, cursor} <- load_sync_cursor(run, opts),
         {:ok, event} <- load_event(run, opts),
         {:ok, source_system} <- load_source_system(run, opts),
         :ok <- validate_cursor(run, cursor),
         :ok <- validate_event(run, event),
         :ok <- validate_source_system(run, source_system),
         {:ok, now} <- configured_now(opts),
         {:ok, parent} <- terminal_parent(cursor.metadata, now),
         {:ok, existing} <- existing_catchup(cursor.metadata, parent, now) do
      case existing do
        {:present, evidence} ->
          {:ok, evidence}

        :missing ->
          create_and_persist(run, cursor, event, source_system, parent, now, opts)
      end
    end
  end

  def ensure_catchup(_sync_run_id, _opts), do: {:error, :invalid_bootstrap_options}

  defp create_and_persist(run, cursor, event, source_system, parent, now, opts) do
    client = Keyword.get(opts, :client, WooOrderIndexClient)
    client_opts = Keyword.get(opts, :client_opts, [])

    with {:ok, configured_base_url} <- configured_base_url(client, client_opts),
         :ok <- validate_endpoint_binding(source_system, configured_base_url),
         {:ok, claim_result} <-
           claim_catchup_create(run, cursor, event, source_system, parent, now) do
      case claim_result do
        {:claimed, claimed_cursor, claimed_parent} ->
          context = %{
            client: client,
            client_opts: client_opts,
            run: run,
            event: event,
            source_system: source_system,
            claimed_cursor: claimed_cursor,
            parent: claimed_parent,
            now: now,
            opts: opts
          }

          create_and_record_evidence(context)

        {:present, evidence} ->
          {:ok, evidence}

        {:in_doubt, _current} ->
          {:error, :catchup_create_in_doubt}
      end
    else
      {:error, %WooOrderIndexError{reason: reason}} ->
        {:error, safe_source_reason(reason)}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, {reason, detail}} when is_atom(reason) and is_atom(detail) ->
        {:error, {reason, detail}}

      _error ->
        {:error, :catchup_create_claim_failed}
    end
  end

  defp create_and_record_evidence(
         %{
           client: client,
           client_opts: client_opts,
           run: run,
           claimed_cursor: claimed_cursor,
           parent: parent,
           now: now
         } = context
       ) do
    with {:ok, page} <- create_catchup(client, parent, run, client_opts),
         {:ok, evidence} <- HistoricalCatchupEvidence.from_page(page, parent),
         :ok <- HistoricalCatchupEvidence.validate_unexpired(evidence, now),
         {:ok, metadata} <-
           HistoricalCatchupEvidence.canonical_metadata(claimed_cursor.metadata, evidence),
         :ok <- persist_evidence(context, evidence, metadata) do
      {:ok, evidence}
    else
      {:error, %WooOrderIndexError{reason: reason}} ->
        {:error, safe_source_reason(reason)}

      {:error, :catchup_high_water_before_parent} ->
        {:error, :catchup_high_water_before_parent}

      {:error, :catchup_manifest_expired} ->
        {:error, :catchup_manifest_expired}

      {:error, :catchup_create_in_doubt} ->
        {:error, :catchup_create_in_doubt}

      {:error, reason} when reason in [:invalid_catchup_page, :invalid_catchup_evidence] ->
        {:error, :ambiguous_create}

      {:error, reason} when reason in [:metadata_too_large, :metadata_not_json_encodable] ->
        {:error, :catchup_evidence_persist_failed}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, {reason, detail}} when is_atom(reason) and is_atom(detail) ->
        {:error, {reason, detail}}

      _error ->
        {:error, :catchup_evidence_persist_failed}
    end
  end

  defp load_sync_run(sync_run_id, opts) do
    result =
      case Keyword.get(opts, :test_sync_run_loader) do
        loader when is_function(loader, 1) -> safe_loader_call(loader, sync_run_id)
        nil -> Ash.get(SyncRun, sync_run_id, domain: Ingestion)
        _other -> {:error, :invalid_sync_run_loader}
      end

    case result do
      {:ok, %SyncRun{} = run} -> {:ok, run}
      {:ok, nil} -> {:error, :sync_run_not_found}
      %SyncRun{} = run -> {:ok, run}
      {:error, :invalid_sync_run_loader} -> {:error, :invalid_sync_run_loader}
      _error -> {:error, :sync_run_load_failed}
    end
  end

  defp load_sync_cursor(%SyncRun{} = run, opts) do
    result =
      case Keyword.get(opts, :test_sync_cursor_loader) do
        loader when is_function(loader, 1) -> safe_loader_call(loader, run)
        nil -> read_sync_cursor(run.id)
        _other -> {:error, :invalid_sync_cursor_loader}
      end

    case result do
      {:ok, %SyncCursor{} = cursor} -> {:ok, cursor}
      %SyncCursor{} = cursor -> {:ok, cursor}
      {:error, :invalid_sync_cursor_loader} -> {:error, :invalid_sync_cursor_loader}
      _error -> {:error, :sync_cursor_load_failed}
    end
  end

  defp read_sync_cursor(sync_run_id) do
    case SyncCursor
         |> Ash.Query.filter(sync_run_id == ^sync_run_id)
         |> Ash.read(domain: Ingestion) do
      {:ok, [%SyncCursor{} = cursor]} -> {:ok, cursor}
      {:ok, []} -> {:error, :sync_cursor_not_found}
      {:ok, _cursors} -> {:error, :sync_cursor_invalid}
      {:error, _reason} -> {:error, :sync_cursor_load_failed}
    end
  end

  defp load_event(%SyncRun{} = run, opts) do
    result =
      case Keyword.get(opts, :test_event_loader) do
        loader when is_function(loader, 1) -> safe_loader_call(loader, run.event_id)
        nil -> Ash.get(Event, run.event_id, domain: Catalog)
        _other -> {:error, :invalid_event_loader}
      end

    case result do
      {:ok, %Event{} = event} -> {:ok, event}
      {:ok, nil} -> {:error, :historical_event_missing}
      %Event{} = event -> {:ok, event}
      {:error, :invalid_event_loader} -> {:error, :invalid_event_loader}
      _error -> {:error, :historical_event_load_failed}
    end
  end

  defp load_source_system(%SyncRun{} = run, opts) do
    result =
      case Keyword.get(opts, :test_source_system_loader) do
        loader when is_function(loader, 1) -> safe_loader_call(loader, run.source_system_id)
        nil -> Ash.get(SourceSystem, run.source_system_id, domain: Catalog)
        _other -> {:error, :invalid_source_system_loader}
      end

    case result do
      {:ok, %SourceSystem{} = source_system} -> {:ok, source_system}
      {:ok, nil} -> {:error, :source_system_not_found}
      %SourceSystem{} = source_system -> {:ok, source_system}
      {:error, :invalid_source_system_loader} -> {:error, :invalid_source_system_loader}
      _error -> {:error, :source_system_load_failed}
    end
  end

  defp validate_run(%SyncRun{} = run) do
    cond do
      run.sync_type != :historical_backfill ->
        {:error, :not_historical_backfill}

      run.status != :running ->
        {:error, :sync_run_not_running}

      not valid_uuid?(run.source_system_id) ->
        {:error, :invalid_source_system_id}

      not present_uuid?(run.event_id) ->
        {:error, :missing_event_id}

      not utc_datetime?(run.date_from) ->
        {:error, :invalid_backfill_start}

      not utc_datetime?(run.date_to) ->
        {:error, :invalid_backfill_cutoff}

      DateTime.compare(run.date_from, run.date_to) == :gt ->
        {:error, :invalid_backfill_bounds}

      true ->
        :ok
    end
  end

  defp validate_cursor(%SyncRun{} = run, %SyncCursor{} = cursor) do
    if cursor.sync_run_id == run.id and
         cursor.status == :active and
         is_integer(cursor.page) and cursor.page >= 1 and
         same_datetime?(cursor.modified_after, run.date_from) and
         same_datetime?(cursor.modified_before, run.date_to) and
         is_nil(cursor.last_seen_order_id) do
      :ok
    else
      {:error, :invalid_initial_cursor}
    end
  end

  defp validate_event(%SyncRun{} = run, %Event{} = event) do
    cond do
      event.id != run.event_id ->
        {:error, :historical_event_missing}

      event.source_system_id != run.source_system_id ->
        {:error, :historical_event_source_mismatch}

      not utc_datetime?(event.source_created_at) ->
        {:error, :historical_event_source_created_at_invalid}

      not same_datetime?(event.source_created_at, run.date_from) ->
        {:error, :historical_event_backfill_start_mismatch}

      event.analytics_onboarding_state != :backfill_pending ->
        {:error, {:historical_event_not_backfill_pending, event.analytics_onboarding_state}}

      event.external_event_kind != :tickera_event ->
        {:error, :historical_event_kind_invalid}

      not positive_external_event_id?(event.external_event_id) ->
        {:error, :historical_event_external_id_invalid}

      true ->
        :ok
    end
  end

  defp validate_source_system(%SyncRun{} = run, %SourceSystem{} = source_system) do
    cond do
      source_system.id != run.source_system_id ->
        {:error, :source_system_mismatch}

      source_system.kind != :woocommerce ->
        {:error, :source_system_kind_mismatch}

      source_system.active != true ->
        {:error, :source_system_inactive}

      not valid_base_url?(source_system.base_url) ->
        {:error, :invalid_source_system_base_url}

      true ->
        :ok
    end
  end

  defp terminal_parent(metadata, now) when is_map(metadata) do
    case HistoricalManifestEvidence.state(metadata) do
      :manifest_terminal ->
        with {:ok, parent} <- HistoricalManifestEvidence.from_metadata(metadata),
             :ok <- HistoricalManifestEvidence.validate_unexpired(parent, now) do
          {:ok, parent}
        else
          {:error, :manifest_expired} -> {:error, :manifest_expired}
          _error -> {:error, :corrupt_manifest_evidence}
        end

      :manifest_in_progress ->
        {:error, :manifest_not_terminal}

      :pending_first_page ->
        {:error, :manifest_not_terminal}

      :create_claimed ->
        {:error, :manifest_create_in_doubt}

      :missing ->
        {:error, :manifest_evidence_missing}

      :corrupt ->
        {:error, :corrupt_manifest_evidence}
    end
  end

  defp terminal_parent(_metadata, _now), do: {:error, :corrupt_manifest_evidence}

  defp existing_catchup(metadata, parent, now) when is_map(metadata) do
    case HistoricalCatchupEvidence.state(metadata) do
      :missing ->
        {:ok, :missing}

      :create_claimed ->
        {:error, :catchup_create_in_doubt}

      state when state in [:pending_first_page, :catchup_in_progress, :catchup_terminal] ->
        with {:ok, evidence} <- HistoricalCatchupEvidence.from_metadata(metadata),
             :ok <- HistoricalCatchupEvidence.validate_unexpired(evidence, now),
             :ok <- HistoricalCatchupEvidence.validate_parent_binding(evidence, parent) do
          {:ok, {:present, evidence}}
        else
          {:error, :catchup_manifest_expired} ->
            {:error, :catchup_manifest_expired}

          {:error, :catchup_high_water_before_parent} ->
            {:error, :corrupt_catchup_evidence}

          _error ->
            {:error, :corrupt_catchup_evidence}
        end

      :corrupt ->
        {:error, :corrupt_catchup_evidence}
    end
  end

  defp existing_catchup(_metadata, _parent, _now),
    do: {:error, :corrupt_catchup_evidence}

  defp claim_catchup_create(run, cursor, event, source_system, parent, now) do
    Repo.transaction(fn ->
      claim_catchup_create_transaction(run, cursor, event, source_system, parent, now)
    end)
    |> normalize_claim_transaction()
  rescue
    _error -> {:error, :catchup_create_claim_failed}
  end

  defp claim_catchup_create_transaction(
         %SyncRun{} = expected_run,
         %SyncCursor{} = cursor,
         %Event{} = expected_event,
         %SourceSystem{} = expected_source,
         %HistoricalManifestEvidence{} = expected_parent,
         now
       ) do
    case lock_cursor(cursor.id) do
      nil ->
        Repo.rollback(:sync_cursor_not_found)

      _locked_id ->
        with {:ok, current_cursor} <- current_cursor(cursor.id),
             {:ok, current_run} <- current_sync_run(expected_run.id),
             {:ok, current_event} <- current_event(expected_run.event_id),
             {:ok, current_source} <- current_source_system(expected_run.source_system_id),
             :ok <- validate_run(current_run),
             :ok <- same_run_scope(expected_run, current_run),
             :ok <- validate_cursor(current_run, current_cursor),
             :ok <- validate_event(current_run, current_event),
             :ok <- same_event_scope(expected_event, current_event),
             :ok <- validate_source_system(current_run, current_source),
             :ok <- same_source_scope(expected_source, current_source),
             {:ok, current_parent} <- terminal_parent(current_cursor.metadata, now),
             :ok <- same_parent_scope(expected_parent, current_parent) do
          claim_locked_cursor(current_cursor, current_parent, now)
        else
          {:error, reason} -> Repo.rollback(reason)
        end
    end
  end

  defp normalize_claim_transaction(
         {:ok, {:claimed, %SyncCursor{} = claimed, parent, notifications}}
       ) do
    Ash.Notifier.notify(notifications)
    {:ok, {:claimed, claimed, parent}}
  end

  defp normalize_claim_transaction({:ok, value}), do: {:ok, value}
  defp normalize_claim_transaction({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize_claim_transaction({:error, {reason, detail}}), do: {:error, {reason, detail}}

  defp normalize_claim_transaction({:error, _reason}),
    do: {:error, :catchup_create_claim_failed}

  defp lock_cursor(cursor_id) do
    Repo.one(
      from cursor in "ingestion_sync_cursors",
        where: cursor.id == type(^cursor_id, :binary_id),
        lock: "FOR UPDATE",
        select: cursor.id
    )
  end

  defp current_cursor(cursor_id) do
    case Ash.get(SyncCursor, cursor_id, domain: Ingestion) do
      {:ok, %SyncCursor{} = cursor} -> {:ok, cursor}
      {:ok, nil} -> {:error, :sync_cursor_not_found}
      {:error, _reason} -> {:error, :sync_cursor_load_failed}
    end
  end

  defp current_sync_run(run_id) do
    case Ash.get(SyncRun, run_id, domain: Ingestion) do
      {:ok, %SyncRun{} = run} -> {:ok, run}
      {:ok, nil} -> {:error, :sync_run_not_found}
      {:error, _reason} -> {:error, :sync_run_load_failed}
    end
  end

  defp current_event(event_id) do
    case Ash.get(Event, event_id, domain: Catalog) do
      {:ok, %Event{} = event} -> {:ok, event}
      {:ok, nil} -> {:error, :historical_event_missing}
      {:error, _reason} -> {:error, :historical_event_load_failed}
    end
  end

  defp current_source_system(source_system_id) do
    case Ash.get(SourceSystem, source_system_id, domain: Catalog) do
      {:ok, %SourceSystem{} = source_system} -> {:ok, source_system}
      {:ok, nil} -> {:error, :source_system_not_found}
      {:error, _reason} -> {:error, :source_system_load_failed}
    end
  end

  defp same_run_scope(expected, current) do
    if expected.id == current.id and
         expected.sync_type == current.sync_type and
         expected.source_system_id == current.source_system_id and
         expected.event_id == current.event_id and
         same_datetime?(expected.date_from, current.date_from) and
         same_datetime?(expected.date_to, current.date_to) do
      :ok
    else
      {:error, :historical_run_changed}
    end
  end

  defp same_event_scope(expected, current) do
    if expected.id == current.id and
         expected.source_system_id == current.source_system_id and
         same_datetime?(expected.source_created_at, current.source_created_at) do
      :ok
    else
      {:error, :historical_event_changed}
    end
  end

  defp same_source_scope(expected, current) do
    if expected.id == current.id and
         expected.kind == current.kind and
         expected.active == current.active and
         expected.base_url == current.base_url do
      :ok
    else
      {:error, :source_system_changed}
    end
  end

  defp same_parent_scope(expected, current) do
    if HistoricalManifestEvidence.metadata(expected) ==
         HistoricalManifestEvidence.metadata(current) do
      :ok
    else
      {:error, :historical_manifest_changed}
    end
  end

  defp claim_locked_cursor(%SyncCursor{} = current, parent, now) do
    case HistoricalCatchupEvidence.state(current.metadata) do
      :missing ->
        {:claimed, claimed, notifications} = persist_create_claim(current)
        {:claimed, claimed, parent, notifications}

      :create_claimed ->
        {:in_doubt, current}

      state when state in [:pending_first_page, :catchup_in_progress, :catchup_terminal] ->
        with {:ok, evidence} <- HistoricalCatchupEvidence.from_metadata(current.metadata),
             :ok <- HistoricalCatchupEvidence.validate_unexpired(evidence, now),
             :ok <- HistoricalCatchupEvidence.validate_parent_binding(evidence, parent) do
          {:present, evidence}
        else
          {:error, :catchup_manifest_expired} -> Repo.rollback(:catchup_manifest_expired)
          _error -> Repo.rollback(:corrupt_catchup_evidence)
        end

      :corrupt ->
        Repo.rollback(:corrupt_catchup_evidence)
    end
  end

  defp persist_create_claim(%SyncCursor{} = cursor) do
    metadata = Map.merge(cursor.metadata, HistoricalCatchupEvidence.claim_metadata())

    case Ash.update(cursor, %{metadata: metadata},
           action: :claim_catchup_create,
           domain: Ingestion,
           return_notifications?: true
         ) do
      {:ok, %SyncCursor{} = claimed, notifications} -> {:claimed, claimed, notifications}
      {:ok, %SyncCursor{} = claimed} -> {:claimed, claimed, []}
      {:error, _reason} -> Repo.rollback(:catchup_create_claim_failed)
    end
  end

  defp configured_base_url(client, client_opts) when is_atom(client) and is_list(client_opts) do
    if client == WooOrderIndexClient do
      WooOrderIndexClient.configured_base_url(client_opts)
    else
      configured_base_url_with_client(client, client_opts)
    end
  end

  defp configured_base_url(_client, _client_opts),
    do: {:error, :source_endpoint_misconfigured}

  defp configured_base_url_with_client(client, client_opts) do
    if function_exported?(client, :configured_base_url, 1) do
      case safe_apply(client, :configured_base_url, [client_opts]) do
        {:ok, base_url} when is_binary(base_url) -> {:ok, base_url}
        {:error, %WooOrderIndexError{} = error} -> {:error, error}
        _error -> {:error, :source_endpoint_misconfigured}
      end
    else
      {:error, :source_endpoint_misconfigured}
    end
  end

  defp validate_endpoint_binding(%SourceSystem{base_url: source_base_url}, configured_base_url)
       when is_binary(source_base_url) and is_binary(configured_base_url) do
    if NormalizeBaseUrl.normalize(configured_base_url) == source_base_url,
      do: :ok,
      else: {:error, :source_endpoint_mismatch}
  end

  defp validate_endpoint_binding(_source_system, _configured_base_url),
    do: {:error, :source_endpoint_mismatch}

  defp create_catchup(
         client,
         %HistoricalManifestEvidence{} = parent,
         %SyncRun{} = run,
         client_opts
       )
       when is_atom(client) and is_list(client_opts) do
    args = [parent.boundary_token, run.source_system_id, @create_limit]

    result =
      cond do
        client_opts != [] and function_exported?(client, :create_catchup_manifest, 4) ->
          safe_apply(client, :create_catchup_manifest, args ++ [client_opts])

        function_exported?(client, :create_catchup_manifest, 3) ->
          safe_apply(client, :create_catchup_manifest, args)

        function_exported?(client, :create_catchup_manifest, 4) ->
          safe_apply(client, :create_catchup_manifest, args ++ [client_opts])

        true ->
          {:error, :source_client_unavailable}
      end

    normalize_create_result(result)
  end

  defp create_catchup(_client, _parent, _run, _client_opts),
    do: {:error, :source_client_unavailable}

  defp normalize_create_result({:ok, page}), do: {:ok, page}

  defp normalize_create_result({:error, %WooOrderIndexError{} = error}),
    do: {:error, error}

  defp normalize_create_result({:error, reason}) when is_atom(reason),
    do: {:error, safe_source_reason(reason)}

  defp normalize_create_result(_result), do: {:error, :ambiguous_create}

  defp persist_evidence(context, evidence, metadata) do
    result =
      Repo.transaction(fn ->
        persist_evidence_transaction(context, evidence, metadata)
      end)

    case result do
      {:ok, {:persisted, notifications}} ->
        Ash.Notifier.notify(notifications)
        :ok

      {:ok, :persisted} ->
        :ok

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      {:error, {reason, detail}} when is_atom(reason) and is_atom(detail) ->
        {:error, {reason, detail}}

      {:error, _reason} ->
        {:error, :catchup_evidence_persist_failed}
    end
  rescue
    _error -> {:error, :catchup_evidence_persist_failed}
  end

  defp persist_evidence_transaction(
         %{
           claimed_cursor: cursor,
           run: expected_run,
           event: expected_event,
           source_system: expected_source,
           parent: expected_parent,
           now: now,
           opts: opts
         },
         %HistoricalCatchupEvidence{} = evidence,
         metadata
       ) do
    case lock_cursor(cursor.id) do
      nil ->
        Repo.rollback(:sync_cursor_not_found)

      _locked_id ->
        with {:ok, current_cursor} <- current_cursor(cursor.id),
             {:ok, current_run} <- current_sync_run(expected_run.id),
             {:ok, current_event} <- current_event(expected_run.event_id),
             {:ok, current_source} <- current_source_system(expected_run.source_system_id),
             :ok <- validate_run(current_run),
             :ok <- same_run_scope(expected_run, current_run),
             :ok <- validate_cursor(current_run, current_cursor),
             :ok <- validate_event(current_run, current_event),
             :ok <- same_event_scope(expected_event, current_event),
             :ok <- validate_source_system(current_run, current_source),
             :ok <- same_source_scope(expected_source, current_source),
             {:ok, current_parent} <- terminal_parent(current_cursor.metadata, now),
             :ok <- same_parent_scope(expected_parent, current_parent),
             :ok <- ensure_claimed_child(current_cursor.metadata),
             {:ok, expected_metadata} <-
               HistoricalCatchupEvidence.canonical_metadata(current_cursor.metadata, evidence),
             true <- expected_metadata == metadata do
          persist_final_metadata(current_cursor, metadata, opts)
        else
          {:error, reason} -> Repo.rollback(reason)
          false -> Repo.rollback(:catchup_evidence_stale)
        end
    end
  end

  defp ensure_claimed_child(metadata) do
    if HistoricalCatchupEvidence.state(metadata) == :create_claimed,
      do: :ok,
      else: {:error, :catchup_create_in_doubt}
  end

  defp persist_final_metadata(cursor, metadata, opts) do
    case Keyword.get(opts, :test_evidence_persister) do
      persister when is_function(persister, 2) ->
        persist_with_test_persister(persister, cursor, metadata)

      nil ->
        persist_with_action(cursor, metadata)

      _other ->
        Repo.rollback(:catchup_evidence_persist_failed)
    end
  end

  defp persist_with_test_persister(persister, cursor, metadata) do
    case safe_apply_function(persister, [cursor, metadata]) do
      {:ok, %SyncCursor{}} -> {:persisted, []}
      :ok -> {:persisted, []}
      _error -> Repo.rollback(:catchup_evidence_persist_failed)
    end
  end

  defp persist_with_action(cursor, metadata) do
    case Ash.update(cursor, %{metadata: metadata},
           action: :record_catchup_evidence,
           domain: Ingestion,
           return_notifications?: true
         ) do
      {:ok, %SyncCursor{}, notifications} -> {:persisted, notifications}
      {:ok, %SyncCursor{}} -> {:persisted, []}
      {:error, _reason} -> Repo.rollback(:catchup_evidence_persist_failed)
    end
  end

  defp configured_now(opts) do
    case Keyword.get(opts, :now, &DateTime.utc_now/0) do
      %DateTime{} = now -> validate_now(now)
      fun when is_function(fun, 0) -> normalize_now_result(safe_apply_function(fun, []))
      _other -> {:error, :invalid_now}
    end
  end

  defp normalize_now_result({:ok, %DateTime{} = now}), do: validate_now(now)
  defp normalize_now_result(%DateTime{} = now), do: validate_now(now)
  defp normalize_now_result(_result), do: {:error, :invalid_now}

  defp validate_now(%DateTime{} = now) do
    if utc_datetime?(now), do: {:ok, now}, else: {:error, :invalid_now}
  end

  defp validate_uuid(value, reason) do
    if valid_uuid?(value), do: {:ok, value}, else: {:error, reason}
  end

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_value), do: false

  defp present_uuid?(value), do: is_binary(value) and value != "" and valid_uuid?(value)

  defp utc_datetime?(%DateTime{} = value) do
    value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0
  end

  defp utc_datetime?(_value), do: false

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false

  defp positive_external_event_id?(value), do: is_integer(value) and value > 0

  defp valid_base_url?(value) when is_binary(value) do
    uri = URI.parse(value)
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  rescue
    _error -> false
  end

  defp valid_base_url?(_value), do: false

  defp safe_source_reason(reason) when reason in @source_error_reasons, do: reason
  defp safe_source_reason(_reason), do: :source_request_failed

  defp safe_loader_call(fun, value), do: safe_apply_function(fun, [value])

  defp safe_apply(module, function, args) do
    apply(module, function, args)
  rescue
    _error -> {:error, :source_request_failed}
  catch
    :exit, _reason -> {:error, :source_request_failed}
    :throw, _value -> {:error, :source_request_failed}
  end

  defp safe_apply_function(fun, args) do
    apply(fun, args)
  rescue
    _error -> {:error, :callback_failed}
  catch
    :exit, _reason -> {:error, :callback_failed}
    :throw, _value -> {:error, :callback_failed}
  end
end
