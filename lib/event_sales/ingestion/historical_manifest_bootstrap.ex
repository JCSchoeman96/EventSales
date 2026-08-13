defmodule EventSales.Ingestion.HistoricalManifestBootstrap do
  @moduledoc """
  Establishes durable evidence for one immutable historical order manifest.

  This boundary loads and validates the persisted historical scope, proves that
  the configured order-index endpoint belongs to the exact SourceSystem, makes
  one manifest-create request, and records only bounded evidence in the
  existing SyncCursor. It never traverses or processes manifest pages.
  """

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Changes.NormalizeBaseUrl
  alias EventSales.Catalog.Resources.SourceSystem
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Clients.{WooOrderIndexClient, WooOrderIndexError}
  alias EventSales.Ingestion.HistoricalManifestEvidence
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}

  @create_limit 100
  @source_error_reasons [
    :misconfigured,
    :invalid_request,
    :unauthorized,
    :busy,
    :manifest_expired,
    :manifest_not_found,
    :manifest_unavailable,
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
          {:ok, HistoricalManifestEvidence.t()}
          | {:error, atom()}

  @doc """
  Ensures that one valid historical run has durable manifest evidence.

  A run without evidence may make one source POST. A run with valid evidence
  never makes another source request. All options are local dependency
  injection points for deterministic tests; production defaults use the
  existing Ash resources and Woo client.
  """
  @spec ensure_manifest(Ecto.UUID.t(), keyword()) :: result()
  def ensure_manifest(sync_run_id, opts \\ [])

  def ensure_manifest(sync_run_id, opts) when is_list(opts) do
    with {:ok, sync_run_id} <- validate_uuid(sync_run_id, :invalid_sync_run_id),
         {:ok, run} <- load_sync_run(sync_run_id, opts),
         {:ok, cursor} <- load_sync_cursor(run, opts),
         {:ok, source_system} <- load_source_system(run, opts),
         :ok <- validate_run(run),
         :ok <- validate_cursor(run, cursor),
         :ok <- validate_source_system(run, source_system),
         {:ok, now} <- configured_now(opts),
         {:ok, existing} <- existing_evidence(cursor.metadata, now) do
      case existing do
        {:present, evidence} ->
          {:ok, evidence}

        :missing ->
          create_and_persist(run, cursor, source_system, now, opts)
      end
    end
  end

  def ensure_manifest(_sync_run_id, _opts), do: {:error, :invalid_bootstrap_options}

  defp create_and_persist(run, cursor, source_system, now, opts) do
    client = Keyword.get(opts, :client, WooOrderIndexClient)
    client_opts = Keyword.get(opts, :client_opts, [])

    with {:ok, configured_base_url} <- configured_base_url(client, client_opts),
         :ok <- validate_endpoint_binding(source_system, configured_base_url),
         {:ok, page} <- create_manifest(client, run, client_opts),
         {:ok, evidence} <- HistoricalManifestEvidence.from_page(page),
         :ok <- HistoricalManifestEvidence.validate_unexpired(evidence, now),
         {:ok, metadata} <-
           HistoricalManifestEvidence.canonical_metadata(cursor.metadata, evidence),
         :ok <- persist_evidence(cursor, metadata, opts) do
      {:ok, evidence}
    else
      {:error, %WooOrderIndexError{reason: reason}} -> {:error, safe_source_reason(reason)}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _error -> {:error, :manifest_evidence_persist_failed}
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

  defp load_source_system(%SyncRun{} = run, opts) do
    result =
      case Keyword.get(opts, :test_source_system_loader) do
        loader when is_function(loader, 1) ->
          safe_loader_call(loader, run.source_system_id)

        nil ->
          Ash.get(SourceSystem, run.source_system_id, domain: Catalog)

        _other ->
          {:error, :invalid_source_system_loader}
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
         cursor.page == 1 and
         same_datetime?(cursor.modified_after, run.date_from) and
         same_datetime?(cursor.modified_before, run.date_to) and
         is_nil(cursor.last_seen_order_id) do
      :ok
    else
      {:error, :invalid_initial_cursor}
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

      not is_binary(source_system.base_url) ->
        {:error, :invalid_source_system_base_url}

      true ->
        :ok
    end
  end

  defp existing_evidence(metadata, now) when is_map(metadata) do
    case Map.has_key?(metadata, HistoricalManifestEvidence.metadata_key()) do
      false ->
        if Map.has_key?(metadata, :historical_manifest),
          do: {:error, :corrupt_manifest_evidence},
          else: {:ok, :missing}

      true ->
        with {:ok, evidence} <- HistoricalManifestEvidence.from_metadata(metadata),
             :ok <- HistoricalManifestEvidence.validate_unexpired(evidence, now) do
          {:ok, {:present, evidence}}
        else
          {:error, :manifest_expired} -> {:error, :manifest_expired}
          _error -> {:error, :corrupt_manifest_evidence}
        end
    end
  end

  defp existing_evidence(_metadata, _now), do: {:error, :corrupt_manifest_evidence}

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

  defp create_manifest(client, %SyncRun{} = run, client_opts)
       when is_atom(client) and is_list(client_opts) do
    args = [run.source_system_id, run.date_from, run.date_to, @create_limit]

    result =
      cond do
        client_opts != [] and function_exported?(client, :create_manifest, 5) ->
          safe_apply(client, :create_manifest, args ++ [client_opts])

        function_exported?(client, :create_manifest, 4) ->
          safe_apply(client, :create_manifest, args)

        function_exported?(client, :create_manifest, 5) ->
          safe_apply(client, :create_manifest, args ++ [client_opts])

        true ->
          {:error, :source_client_unavailable}
      end

    normalize_create_result(result)
  end

  defp create_manifest(_client, _run, _client_opts),
    do: {:error, :source_client_unavailable}

  defp normalize_create_result({:ok, page}), do: {:ok, page}

  defp normalize_create_result({:error, %WooOrderIndexError{} = error}),
    do: {:error, error}

  defp normalize_create_result({:error, reason}) when is_atom(reason),
    do: {:error, safe_source_reason(reason)}

  defp normalize_create_result(_result), do: {:error, :source_request_failed}

  defp persist_evidence(cursor, metadata, opts) do
    result =
      case Keyword.get(opts, :test_evidence_persister) do
        persister when is_function(persister, 2) ->
          safe_apply_function(persister, [cursor, metadata])

        nil ->
          Ash.update(cursor, %{metadata: metadata},
            action: :record_manifest_evidence,
            domain: Ingestion
          )

        _other ->
          {:error, :invalid_evidence_persister}
      end

    case result do
      {:ok, %SyncCursor{}} -> :ok
      _error -> {:error, :manifest_evidence_persist_failed}
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
