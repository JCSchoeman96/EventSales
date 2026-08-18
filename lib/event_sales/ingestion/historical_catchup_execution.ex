defmodule EventSales.Ingestion.HistoricalCatchupExecution do
  @moduledoc """
  Executes exactly one immutable historical catch-up page for a SyncRun.

  Catch-up membership is frozen by the source manifest at H. This executor
  fetches every page member by exact ID, reconciles the current order through
  F4C1, and checkpoints only after all page writes have succeeded. It never
  holds a PostgreSQL lock across source HTTP.
  """

  import Ecto.Query
  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Changes.NormalizeBaseUrl
  alias EventSales.Catalog.Resources.{Event, SourceSystem}

  alias EventSales.Ingestion.Clients.{
    WooCommerceClient,
    WooCommerceError,
    WooOrderIndexClient,
    WooOrderIndexError
  }

  alias EventSales.Ingestion.HistoricalCatchupEvidence
  alias EventSales.Ingestion.HistoricalEventLineSelector
  alias EventSales.Ingestion.HistoricalManifestEvidence
  alias EventSales.Ingestion.OrderRefundSync
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.Repo
  alias EventSales.Sales.OrderUpserter
  alias EventSales.Sales.Resources.Order

  @catchup_client WooOrderIndexClient
  @woocommerce_client WooCommerceClient
  @order_upserter OrderUpserter
  @order_refund_sync OrderRefundSync
  @line_selector HistoricalEventLineSelector

  @type result ::
          {:continue, SyncRun.t(), SyncCursor.t()}
          | :ok
          | {:error, atom() | tuple()}

  @doc "Processes exactly one U page and checkpoints it after all F4C1 writes."
  @spec run_step(SyncRun.t(), SyncCursor.t(), keyword()) :: result()
  def run_step(run, cursor, opts \\ [])

  def run_step(%SyncRun{} = run, %SyncCursor{} = cursor, opts) do
    with {:ok, current_run} <- current_run(run),
         {:ok, current_cursor} <- current_cursor(cursor),
         :ok <- validate_run(current_run),
         :ok <- validate_cursor(current_run, current_cursor),
         {:ok, parent} <- load_parent(current_cursor, opts),
         {:ok, evidence} <- load_catchup(current_cursor, parent, opts),
         {:ok, event} <- load_event(current_run, opts),
         :ok <- validate_event(event, current_run),
         {:ok, source} <- load_source_system(current_run, opts),
         :ok <- validate_source_system(source, current_run),
         :ok <- validate_client_bindings(source, opts) do
      execute_state(current_run, current_cursor, parent, evidence, event, source, opts)
    end
  end

  def run_step(%SyncRun{}, nil, _opts), do: {:error, :historical_cursor_required}
  def run_step(_run, _cursor, _opts), do: {:error, :invalid_historical_execution_input}

  defp execute_state(run, cursor, parent, evidence, event, source, opts) do
    with :ok <- HistoricalCatchupEvidence.validate_unexpired(evidence, now(opts)),
         {:ok, page} <- fetch_one_page(evidence, opts),
         :ok <- HistoricalCatchupEvidence.validate_continuity(evidence, page),
         :ok <- HistoricalCatchupEvidence.validate_unexpired(evidence, now(opts)),
         :ok <- resolve_page(run, event, source, page, opts),
         :ok <- before_checkpoint(opts),
         {:ok, result} <- checkpoint_page(run, cursor, parent, evidence, page, opts) do
      result
    end
  end

  defp now(opts) do
    case Keyword.get(opts, :now, &DateTime.utc_now/0) do
      %DateTime{} = value -> value
      callback when is_function(callback, 0) -> callback.()
      other -> other
    end
  end

  defp validate_run(%SyncRun{
         sync_type: :historical_backfill,
         status: :running,
         source_system_id: source_system_id,
         event_id: event_id,
         date_from: %DateTime{} = date_from,
         date_to: %DateTime{} = date_to
       })
       when is_binary(source_system_id) and is_binary(event_id) do
    cond do
      not valid_uuid?(source_system_id) -> {:error, :invalid_source_system_id}
      not valid_uuid?(event_id) -> {:error, :missing_event_id}
      not utc_datetime?(date_from) -> {:error, :invalid_backfill_start}
      not utc_datetime?(date_to) -> {:error, :invalid_backfill_cutoff}
      DateTime.compare(date_from, date_to) == :gt -> {:error, :invalid_historical_bounds}
      true -> :ok
    end
  end

  defp validate_run(%SyncRun{sync_type: :historical_backfill, status: status})
       when status != :running,
       do: {:error, :sync_run_not_running}

  defp validate_run(%SyncRun{sync_type: _sync_type}), do: {:error, :not_historical_backfill}
  defp validate_run(_run), do: {:error, :invalid_historical_run}

  defp validate_cursor(%SyncRun{} = run, %SyncCursor{} = cursor) do
    cond do
      cursor.sync_run_id != run.id ->
        {:error, :cursor_run_mismatch}

      cursor.status != :active ->
        {:error, :invalid_historical_cursor}

      not is_integer(cursor.page) or cursor.page < 1 ->
        {:error, :invalid_historical_cursor}

      not same_datetime?(cursor.modified_after, run.date_from) ->
        {:error, :historical_bounds_mismatch}

      not same_datetime?(cursor.modified_before, run.date_to) ->
        {:error, :historical_bounds_mismatch}

      not is_nil(cursor.last_seen_order_id) ->
        {:error, :historical_cursor_repurposed}

      true ->
        :ok
    end
  end

  defp load_parent(%SyncCursor{metadata: metadata}, opts) when is_map(metadata) do
    case HistoricalManifestEvidence.state(metadata) do
      :manifest_terminal ->
        with {:ok, parent} <- HistoricalManifestEvidence.from_metadata(metadata),
             true <- is_nil(parent.next_cursor),
             :ok <- HistoricalManifestEvidence.validate_unexpired(parent, now(opts)) do
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

  defp load_parent(_cursor, _opts), do: {:error, :corrupt_manifest_evidence}

  defp load_catchup(%SyncCursor{metadata: metadata}, parent, opts) when is_map(metadata) do
    case HistoricalCatchupEvidence.state(metadata) do
      state when state in [:pending_first_page, :catchup_in_progress] ->
        with {:ok, evidence} <- HistoricalCatchupEvidence.from_metadata(metadata),
             :ok <- HistoricalCatchupEvidence.validate_unexpired(evidence, now(opts)),
             :ok <- HistoricalCatchupEvidence.validate_parent_binding(evidence, parent) do
          {:ok, evidence}
        else
          {:error, :catchup_manifest_expired} -> {:error, :catchup_manifest_expired}
          {:error, :catchup_high_water_before_parent} -> {:error, :corrupt_catchup_evidence}
          _error -> {:error, :corrupt_catchup_evidence}
        end

      :catchup_terminal ->
        {:error, :historical_catchup_already_terminal}

      :missing ->
        {:error, :catchup_evidence_missing}

      :create_claimed ->
        {:error, :catchup_create_in_doubt}

      :corrupt ->
        {:error, :corrupt_catchup_evidence}
    end
  end

  defp load_catchup(_cursor, _parent, _opts), do: {:error, :corrupt_catchup_evidence}

  defp load_event(%SyncRun{event_id: event_id}, opts) do
    result =
      case Keyword.get(opts, :test_event_loader) do
        loader when is_function(loader, 1) -> safe_loader_call(loader, event_id)
        nil -> Ash.get(Event, event_id, domain: Catalog)
        _other -> {:error, :invalid_event_loader}
      end

    case result do
      {:ok, %Event{} = event} -> {:ok, event}
      %Event{} = event -> {:ok, event}
      {:ok, nil} -> {:error, :historical_event_missing}
      {:error, :invalid_event_loader} -> {:error, :invalid_event_loader}
      _error -> {:error, :historical_event_missing}
    end
  end

  defp load_source_system(%SyncRun{source_system_id: source_system_id}, opts) do
    result =
      case Keyword.get(opts, :test_source_system_loader) do
        loader when is_function(loader, 1) -> safe_loader_call(loader, source_system_id)
        nil -> Ash.get(SourceSystem, source_system_id, domain: Catalog)
        _other -> {:error, :invalid_source_system_loader}
      end

    case result do
      {:ok, %SourceSystem{} = source} -> {:ok, source}
      %SourceSystem{} = source -> {:ok, source}
      {:ok, nil} -> {:error, :source_system_not_found}
      {:error, :invalid_source_system_loader} -> {:error, :invalid_source_system_loader}
      _error -> {:error, :source_system_not_found}
    end
  end

  defp validate_event(%Event{} = event, %SyncRun{} = run) do
    cond do
      event.id != run.event_id ->
        {:error, :historical_event_missing}

      event.source_system_id != run.source_system_id ->
        {:error, :historical_event_source_mismatch}

      not utc_datetime?(event.source_created_at) ->
        {:error, :historical_event_backfill_start_mismatch}

      not same_datetime?(event.source_created_at, run.date_from) ->
        {:error, :historical_event_backfill_start_mismatch}

      event.analytics_onboarding_state != :backfill_pending ->
        {:error, {:historical_event_not_backfill_pending, event.analytics_onboarding_state}}

      event.external_event_kind != :tickera_event ->
        {:error, :historical_event_kind_invalid}

      not positive_id?(event.external_event_id) ->
        {:error, :historical_event_external_id_invalid}

      true ->
        :ok
    end
  end

  defp validate_source_system(%SourceSystem{} = source, %SyncRun{} = run) do
    cond do
      source.id != run.source_system_id -> {:error, :source_system_mismatch}
      source.kind != :woocommerce -> {:error, :source_system_kind_mismatch}
      source.active != true -> {:error, :source_system_inactive}
      not valid_base_url?(source.base_url) -> {:error, :source_system_invalid}
      true -> :ok
    end
  end

  defp validate_client_bindings(%SourceSystem{} = source, opts) do
    catchup_client = catchup_client(opts)
    order_client = order_client(opts)
    source_url = NormalizeBaseUrl.normalize(source.base_url)

    with {:ok, catchup_url} <- configured_base_url(catchup_client, catchup_client_opts(opts)),
         {:ok, order_url} <- configured_base_url(order_client, woocommerce_client_opts(opts)),
         true <- NormalizeBaseUrl.normalize(catchup_url) == source_url,
         true <- NormalizeBaseUrl.normalize(order_url) == source_url do
      :ok
    else
      false -> {:error, :source_endpoint_mismatch}
      {:error, _reason} -> {:error, :source_client_misconfigured}
    end
  end

  defp fetch_one_page(%HistoricalCatchupEvidence{} = evidence, opts) do
    cursor = if evidence.state == "catchup_in_progress", do: evidence.next_cursor, else: nil
    client = catchup_client(opts)

    case safe_apply(client, :fetch_catchup_page, [
           evidence.boundary_token,
           cursor,
           catchup_client_opts(opts)
         ]) do
      {:ok, page} when is_map(page) -> {:ok, page}
      {:error, %WooOrderIndexError{reason: reason}} -> {:error, reason}
      {:error, reason} when is_atom(reason) -> {:error, reason}
      _other -> {:error, :invalid_catchup_page_response}
    end
  end

  defp resolve_page(run, event, source, page, opts) do
    with {:ok, orders} <- fetch_page_orders(page_value(page, :items, "items"), opts) do
      reconcile_page_orders(run, event, source, orders, opts)
    end
  end

  defp fetch_page_orders(items, opts) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, orders} ->
      source_order_id = page_value(item, :source_order_id, "source_order_id")

      case fetch_page_order(source_order_id, opts) do
        {:ok, order} -> {:cont, {:ok, [{source_order_id, order} | orders]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_result()
  end

  defp fetch_page_order(source_order_id, opts) do
    case fetch_order(source_order_id, opts) do
      {:ok, order} ->
        case validate_returned_order_id(source_order_id, order) do
          :ok -> {:ok, order}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, normalize_order_fetch_error(reason)}
    end
  end

  defp reconcile_page_orders(run, event, source, orders, opts) do
    Enum.reduce_while(orders, :ok, fn {source_order_id, order}, :ok ->
      case resolve_order(run, event, source, source_order_id, order, opts) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp resolve_order(run, event, source, source_order_id, order, opts) do
    with :ok <- validate_returned_order_id(source_order_id, order),
         {:ok, raw_lines} <- select_event_lines(event, source, order, opts),
         result <- reconcile_order(run, event, source_order_id, order, raw_lines, opts),
         :ok <- normalize_reconcile_result(result),
         :ok <- sync_refunds(run, source, source_order_id, opts) do
      :ok
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_reconcile_result({:ok, %Order{}}), do: :ok
  defp normalize_reconcile_result({:ok, :stale_noop}), do: :ok
  defp normalize_reconcile_result({:error, reason}), do: {:error, reason}
  defp normalize_reconcile_result(_result), do: {:error, :order_reconcile_failed}

  defp reverse_result({:ok, values}), do: {:ok, Enum.reverse(values)}
  defp reverse_result({:error, _reason} = error), do: error

  defp fetch_order(source_order_id, opts) do
    client = order_client(opts)

    case safe_apply(client, :fetch_order, [source_order_id, woocommerce_client_opts(opts)]) do
      {:ok, order} when is_map(order) -> {:ok, order}
      {:ok, _other} -> {:error, :invalid_source_order_response}
      {:error, %WooCommerceError{reason: reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :source_order_fetch_failed}
    end
  end

  defp validate_returned_order_id(source_order_id, order) when is_map(order) do
    with {:ok, expected_id} <- positive_id(source_order_id),
         {:ok, returned_id} <- positive_id(map_value(order, :id, "id")),
         true <- expected_id == returned_id do
      :ok
    else
      _error -> {:error, :source_order_id_mismatch}
    end
  end

  defp select_event_lines(event, source, order, opts) do
    selector = Keyword.get(opts, :event_line_selector, @line_selector)

    case safe_apply(selector, :select, [event, source, order]) do
      {:ok, raw_lines} when is_list(raw_lines) -> {:ok, raw_lines}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :historical_event_line_selection_failed}
    end
  end

  defp reconcile_order(run, event, source_order_id, order, raw_lines, opts) do
    upserter = Keyword.get(opts, :order_upserter, @order_upserter)
    args = [run.source_system_id, event.id, order, raw_lines]
    upserter_opts = Keyword.get(opts, :order_upserter_opts, [])

    cond do
      module_exports?(upserter, :reconcile_event_order, 5) ->
        safe_apply(upserter, :reconcile_event_order, args ++ [upserter_opts])

      module_exports?(upserter, :reconcile_event_order, 4) ->
        safe_apply(upserter, :reconcile_event_order, args)

      is_function(upserter, 5) ->
        safe_apply_function(upserter, args ++ [upserter_opts])

      is_function(upserter, 4) ->
        safe_apply_function(upserter, args)

      true ->
        {:error, {:order_reconcile_failed, source_order_id}}
    end
  end

  defp sync_refunds(run, source, source_order_id, opts) do
    refund_sync = Keyword.get(opts, :order_refund_sync, @order_refund_sync)

    refund_sync.sync_order(
      run.source_system_id,
      source_order_id,
      refund_sync_opts(run, source, opts)
    )
  end

  defp refund_sync_opts(run, source, opts) do
    refund_opts = Keyword.get(opts, :order_refund_sync_opts, [])

    Keyword.merge(refund_opts,
      woocommerce_client: Keyword.get(opts, :woocommerce_client, @woocommerce_client),
      woocommerce_client_opts: woocommerce_client_opts(opts),
      source_system_loader: source_system_loader(run, source)
    )
  end

  defp source_system_loader(run, source) do
    fn source_system_id ->
      if source_system_id == run.source_system_id do
        {:ok, source}
      else
        {:error, :source_system_mismatch}
      end
    end
  end

  defp before_checkpoint(opts) do
    case Keyword.get(opts, :before_checkpoint) do
      nil -> :ok
      callback when is_function(callback, 0) -> callback.()
      _other -> {:error, :invalid_checkpoint_callback}
    end
  end

  defp checkpoint_page(run, cursor, parent, evidence, page, opts) do
    with {:ok, next_metadata, result_kind} <- next_metadata(cursor.metadata, evidence, page),
         {:ok, result} <-
           checkpoint_transaction_result(
             run,
             cursor,
             parent,
             evidence,
             next_metadata,
             result_kind,
             opts
           ) do
      {:ok, notify_checkpoint(result)}
    end
  end

  defp next_metadata(metadata, evidence, page) do
    case {page_value(page, :has_more, "has_more"), page_value(page, :next_cursor, "next_cursor"),
          page_value(page, :terminal_evidence, "terminal_evidence")} do
      {true, next_cursor, nil} when is_binary(next_cursor) ->
        next_metadata =
          metadata
          |> Map.merge(HistoricalCatchupEvidence.in_progress_metadata(evidence, next_cursor))

        checkpoint_metadata(next_metadata, :continue)

      {false, nil, terminal_evidence} when is_binary(terminal_evidence) ->
        next_metadata =
          metadata
          |> Map.merge(HistoricalCatchupEvidence.terminal_metadata(evidence, terminal_evidence))

        checkpoint_metadata(next_metadata, :complete)

      _invalid ->
        {:error, :invalid_catchup_page}
    end
  end

  defp checkpoint_metadata(metadata, result_kind) do
    with {:ok, evidence} <- HistoricalCatchupEvidence.from_metadata(metadata),
         {:ok, size} <- HistoricalCatchupEvidence.encoded_size(metadata),
         true <- size <= HistoricalCatchupEvidence.metadata_max_bytes(),
         true <- evidence.state in ["catchup_in_progress", "catchup_terminal"] do
      {:ok, metadata, result_kind}
    else
      false -> {:error, :metadata_too_large}
      _error -> {:error, :invalid_catchup_evidence}
    end
  end

  defp checkpoint_transaction_result(run, cursor, parent, evidence, metadata, :continue, opts) do
    Repo.transaction(fn ->
      progress_transaction(run, cursor, parent, evidence, metadata, opts)
    end)
  end

  defp checkpoint_transaction_result(run, cursor, parent, evidence, metadata, :complete, opts) do
    Repo.transaction(fn ->
      complete_transaction(run, cursor, parent, evidence, metadata, opts)
    end)
  end

  defp progress_transaction(run, cursor, parent, evidence, metadata, opts) do
    with {:ok, current_cursor} <- locked_current_cursor(cursor),
         :ok <- verify_cursor_authority(current_cursor, cursor),
         {:ok, current_run} <- locked_current_run(run),
         :ok <- verify_run_authority(current_run, run),
         {:ok, current_event} <- current_event(current_run),
         :ok <- validate_event(current_event, current_run),
         {:ok, current_source} <- current_source_system(current_run),
         :ok <- validate_source_system(current_source, current_run),
         {:ok, current_parent} <- load_parent(current_cursor, opts),
         :ok <- same_parent_scope(parent, current_parent),
         {:ok, current_evidence} <- load_catchup(current_cursor, current_parent, opts),
         :ok <- same_child_scope(evidence, current_evidence),
         {:ok, updated_cursor, notifications} <- record_progress(current_cursor, metadata) do
      {:continue, current_run, updated_cursor, notifications}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp complete_transaction(run, cursor, parent, evidence, metadata, opts) do
    with {:ok, current_cursor} <- locked_current_cursor(cursor),
         :ok <- verify_cursor_authority(current_cursor, cursor),
         {:ok, current_run} <- locked_current_run(run),
         :ok <- verify_run_authority(current_run, run),
         {:ok, current_event} <- lock_and_current_event(current_run),
         :ok <- validate_event(current_event, current_run),
         {:ok, current_source} <- current_source_system(current_run),
         :ok <- validate_source_system(current_source, current_run),
         {:ok, current_parent} <- load_parent(current_cursor, opts),
         :ok <- same_parent_scope(parent, current_parent),
         {:ok, current_evidence} <- load_catchup(current_cursor, current_parent, opts),
         :ok <- same_child_scope(evidence, current_evidence),
         :ok <-
           validate_terminal_metadata(
             metadata,
             current_evidence,
             current_parent,
             current_run,
             current_cursor,
             opts
           ),
         {:ok, updated_cursor, cursor_notifications} <- complete_cursor(current_cursor, metadata),
         {:ok, updated_run, run_notifications} <- complete_run(current_run) do
      {:completed, updated_run, updated_cursor, cursor_notifications ++ run_notifications}
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp validate_terminal_metadata(metadata, current_evidence, parent, run, cursor, opts) do
    with {:ok, terminal} <- HistoricalCatchupEvidence.from_metadata(metadata),
         true <- terminal.state == "catchup_terminal",
         :ok <- HistoricalCatchupEvidence.validate_unexpired(terminal, now(opts)),
         :ok <- HistoricalCatchupEvidence.validate_parent_binding(terminal, parent),
         :ok <- HistoricalCatchupEvidence.validate_parent_binding(current_evidence, parent),
         true <- terminal.schema_version == current_evidence.schema_version,
         true <- terminal.phase == current_evidence.phase,
         true <- terminal.boundary_token == current_evidence.boundary_token,
         true <- terminal.manifest_hash == current_evidence.manifest_hash,
         true <-
           DateTime.compare(terminal.source_observed_at, parent.source_observed_at) in [:eq, :gt],
         true <- run.orders_failed_count == 0,
         true <- run.errors_count == 0,
         false <- Map.has_key?(cursor.metadata, "failure") do
      :ok
    else
      {:error, :catchup_manifest_expired} -> {:error, :catchup_manifest_expired}
      {:error, reason} -> {:error, reason}
      false -> {:error, :historical_completion_authority_invalid}
      _error -> {:error, :historical_completion_authority_invalid}
    end
  end

  defp complete_cursor(cursor, metadata) do
    case Ash.update(cursor, %{page: cursor.page + 1, metadata: metadata},
           action: :complete_historical,
           domain: EventSales.Ingestion,
           return_notifications?: true
         ) do
      {:ok, %SyncCursor{} = updated, notifications} -> {:ok, updated, notifications}
      {:ok, %SyncCursor{} = updated} -> {:ok, updated, []}
      {:error, _reason} -> {:error, :checkpoint_failed}
    end
  end

  defp complete_run(run) do
    case Ash.update(run, %{},
           action: :complete,
           domain: EventSales.Ingestion,
           return_notifications?: true
         ) do
      {:ok, %SyncRun{} = updated, notifications} -> {:ok, updated, notifications}
      {:ok, %SyncRun{} = updated} -> {:ok, updated, []}
      {:error, _reason} -> {:error, :completion_failed}
    end
  end

  defp record_progress(cursor, metadata) do
    case Ash.update(cursor, %{page: cursor.page + 1, metadata: metadata},
           action: :record_catchup_progress,
           domain: EventSales.Ingestion,
           return_notifications?: true
         ) do
      {:ok, %SyncCursor{} = updated, notifications} -> {:ok, updated, notifications}
      {:ok, %SyncCursor{} = updated} -> {:ok, updated, []}
      {:error, _reason} -> {:error, :checkpoint_failed}
    end
  end

  defp notify_checkpoint({:continue, updated_run, updated_cursor, []}),
    do: {:continue, updated_run, updated_cursor}

  defp notify_checkpoint({:continue, updated_run, updated_cursor, notifications}) do
    Ash.Notifier.notify(notifications)
    {:continue, updated_run, updated_cursor}
  end

  defp notify_checkpoint({:completed, _updated_run, _updated_cursor, []}), do: :ok

  defp notify_checkpoint({:completed, _updated_run, _updated_cursor, notifications}) do
    Ash.Notifier.notify(notifications)
    :ok
  end

  defp locked_current_cursor(%SyncCursor{id: cursor_id}) do
    query =
      from cursor in "ingestion_sync_cursors",
        where: cursor.id == type(^cursor_id, Ecto.UUID),
        select: cursor.id,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      nil -> {:error, :checkpoint_conflict}
      _id -> Ash.get(SyncCursor, cursor_id, domain: EventSales.Ingestion)
    end
  end

  defp verify_cursor_authority(current, expected) do
    if current.sync_run_id == expected.sync_run_id and
         current.status == :active and
         current.page == expected.page and
         same_datetime?(current.modified_after, expected.modified_after) and
         same_datetime?(current.modified_before, expected.modified_before) and
         is_nil(current.last_seen_order_id) and
         current.metadata[HistoricalManifestEvidence.metadata_key()] ==
           expected.metadata[HistoricalManifestEvidence.metadata_key()] and
         current.metadata[HistoricalCatchupEvidence.metadata_key()] ==
           expected.metadata[HistoricalCatchupEvidence.metadata_key()] do
      :ok
    else
      {:error, :checkpoint_conflict}
    end
  end

  defp verify_run_authority(current, expected) do
    if same_run_scope?(current, expected) and same_run_counters?(current, expected) do
      :ok
    else
      {:error, :checkpoint_conflict}
    end
  end

  defp same_run_scope?(current, expected) do
    current.id == expected.id and current.status == :running and
      current.sync_type == :historical_backfill and
      current.source_system_id == expected.source_system_id and
      current.event_id == expected.event_id and
      same_datetime?(current.date_from, expected.date_from) and
      same_datetime?(current.date_to, expected.date_to)
  end

  defp same_run_counters?(current, expected) do
    current.orders_seen_count == expected.orders_seen_count and
      current.orders_matched_count == expected.orders_matched_count and
      current.orders_upserted_count == expected.orders_upserted_count and
      current.orders_stale_count == expected.orders_stale_count
  end

  defp same_parent_scope(expected, current) do
    if HistoricalManifestEvidence.metadata(expected) ==
         HistoricalManifestEvidence.metadata(current),
       do: :ok,
       else: {:error, :historical_manifest_changed}
  end

  defp same_child_scope(expected, current) do
    if expected.state == current.state and
         expected.schema_version == current.schema_version and
         expected.phase == current.phase and
         expected.boundary_token == current.boundary_token and
         expected.manifest_hash == current.manifest_hash and
         DateTime.compare(expected.manifest_expires_at, current.manifest_expires_at) == :eq and
         DateTime.compare(expected.source_observed_at, current.source_observed_at) == :eq do
      :ok
    else
      {:error, :catchup_continuity_mismatch}
    end
  end

  defp current_run(%SyncRun{id: run_id}),
    do: Ash.get(SyncRun, run_id, domain: EventSales.Ingestion)

  defp current_cursor(%SyncCursor{id: cursor_id}),
    do: Ash.get(SyncCursor, cursor_id, domain: EventSales.Ingestion)

  defp locked_current_run(%SyncRun{id: run_id}) do
    query =
      from run in "ingestion_sync_runs",
        where: run.id == type(^run_id, Ecto.UUID),
        select: run.id,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      nil -> {:error, :checkpoint_conflict}
      _id -> current_run(%SyncRun{id: run_id})
    end
  end

  defp current_event(%SyncRun{event_id: event_id}) do
    case Ash.get(Event, event_id, domain: Catalog) do
      {:ok, %Event{} = event} -> {:ok, event}
      {:ok, nil} -> {:error, :historical_event_missing}
      _error -> {:error, :historical_event_missing}
    end
  end

  defp lock_and_current_event(%SyncRun{event_id: event_id}) do
    query =
      from event in "catalog_events",
        where: event.id == type(^event_id, Ecto.UUID),
        select: event.id,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      nil -> {:error, :historical_event_missing}
      _id -> current_event(%SyncRun{event_id: event_id})
    end
  end

  defp current_source_system(%SyncRun{source_system_id: source_system_id}) do
    case Ash.get(SourceSystem, source_system_id, domain: Catalog) do
      {:ok, %SourceSystem{} = source} -> {:ok, source}
      {:ok, nil} -> {:error, :source_system_not_found}
      _error -> {:error, :source_system_not_found}
    end
  end

  defp configured_base_url(client, opts) when is_atom(client) do
    if module_exports?(client, :configured_base_url, 1) do
      case safe_apply(client, :configured_base_url, [opts]) do
        {:ok, base_url} when is_binary(base_url) -> {:ok, base_url}
        {:error, %WooOrderIndexError{} = error} -> {:error, error}
        _other -> {:error, :source_endpoint_misconfigured}
      end
    else
      {:error, :source_endpoint_misconfigured}
    end
  end

  defp configured_base_url(_client, _opts), do: {:error, :source_endpoint_misconfigured}

  defp catchup_client(opts),
    do: Keyword.get(opts, :catchup_client, Keyword.get(opts, :manifest_client, @catchup_client))

  defp order_client(opts),
    do: Keyword.get(opts, :woocommerce_client, @woocommerce_client)

  defp catchup_client_opts(opts),
    do:
      Keyword.get(
        opts,
        :catchup_client_opts,
        Keyword.get(opts, :manifest_client_opts, Keyword.get(opts, :client_opts, []))
      )

  defp woocommerce_client_opts(opts),
    do: Keyword.get(opts, :woocommerce_client_opts, Keyword.get(opts, :client_opts, []))

  defp normalize_order_fetch_error(:not_found), do: :source_order_not_found
  defp normalize_order_fetch_error(:invalid_json), do: :invalid_source_order_response
  defp normalize_order_fetch_error(reason) when is_atom(reason), do: reason
  defp normalize_order_fetch_error(_reason), do: :source_order_fetch_failed

  defp positive_id?(value), do: match?({:ok, _}, positive_id(value))
  defp positive_id(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 ->
        if Integer.to_string(id) == value, do: {:ok, id}, else: {:error, :invalid_positive_id}

      _other ->
        {:error, :invalid_positive_id}
    end
  end

  defp positive_id(_value), do: {:error, :invalid_positive_id}

  defp map_value(map, atom_key, string_key) when is_map(map) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, string_key)
    end
  end

  defp map_value(_map, _atom_key, _string_key), do: nil
  defp page_value(map, atom_key, string_key), do: map_value(map, atom_key, string_key)

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))

  defp utc_datetime?(%DateTime{} = value),
    do: value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0

  defp utc_datetime?(_value), do: false

  defp valid_base_url?(value) when is_binary(value) do
    uri = URI.parse(value)
    uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.host != ""
  rescue
    _error -> false
  end

  defp valid_base_url?(_value), do: false

  defp module_exports?(module, function, arity) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end

  defp module_exports?(_module, _function, _arity), do: false

  defp safe_apply(module, function, args) when is_atom(module) do
    apply(module, function, args)
  rescue
    _error -> {:error, :callback_failed}
  catch
    :exit, _reason -> {:error, :callback_failed}
    :throw, _value -> {:error, :callback_failed}
  end

  defp safe_apply_function(fun, args) do
    apply(fun, args)
  rescue
    _error -> {:error, :callback_failed}
  catch
    :exit, _reason -> {:error, :callback_failed}
    :throw, _value -> {:error, :callback_failed}
  end

  defp safe_loader_call(fun, value), do: safe_apply_function(fun, [value])
end
