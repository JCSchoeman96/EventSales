defmodule EventSales.Ingestion.HistoricalManifestExecution do
  @moduledoc """
  Executes exactly one immutable historical manifest page for a SyncRun.

  The manifest is the sole historical membership authority. This module never
  uses WooCommerce collection paging and never completes the historical run;
  catch-up remains a later phase.
  """

  import Ecto.Query
  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Changes.NormalizeBaseUrl
  alias EventSales.Catalog.Resources.{ProductMapping, SourceSystem}

  alias EventSales.Ingestion.Clients.{
    WooCommerceClient,
    WooCommerceError,
    WooOrderIndexClient,
    WooOrderIndexError
  }

  alias EventSales.Ingestion.HistoricalManifestEvidence
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.Repo
  alias EventSales.Sales.OrderUpserter

  @type result ::
          {:continue, SyncRun.t(), SyncCursor.t()}
          | {:manifest_terminal, SyncRun.t(), SyncCursor.t()}
          | {:error, atom()}

  @manifest_client WooOrderIndexClient
  @woocommerce_client WooCommerceClient
  @order_upserter OrderUpserter

  @doc "Processes exactly one manifest page and checkpoints it after resolution."
  @spec run_step(SyncRun.t(), SyncCursor.t(), keyword()) :: result()
  def run_step(run, cursor, opts \\ [])

  def run_step(%SyncRun{} = run, %SyncCursor{} = cursor, opts) do
    with :ok <- validate_run(run),
         :ok <- validate_cursor(run, cursor),
         {:ok, evidence} <- load_evidence(cursor),
         {:ok, source} <- load_source_system(run, opts),
         :ok <- validate_source_system(source, run),
         :ok <- validate_client_bindings(source, opts) do
      execute_state(run, cursor, evidence, opts)
    end
  end

  def run_step(%SyncRun{}, nil, _opts), do: {:error, :historical_cursor_required}
  def run_step(_run, _cursor, _opts), do: {:error, :invalid_historical_execution_input}

  defp execute_state(run, cursor, %HistoricalManifestEvidence{state: "manifest_terminal"}, _opts),
    do: {:manifest_terminal, run, cursor}

  defp execute_state(run, cursor, evidence, opts) do
    with :ok <- HistoricalManifestEvidence.validate_unexpired(evidence, now(opts)),
         {:ok, page} <- fetch_one_page(evidence, opts),
         :ok <- HistoricalManifestEvidence.validate_continuity(evidence, page),
         :ok <- HistoricalManifestEvidence.validate_unexpired(evidence, now(opts)),
         {:ok, mappings} <- load_mappings(run, opts),
         {:ok, counts} <- resolve_page(run, page, mappings, opts),
         :ok <- before_checkpoint(opts),
         {:ok, result} <- checkpoint_page(run, cursor, evidence, page, counts, opts) do
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
         source_system_id: source_system_id,
         event_id: event_id,
         date_from: %DateTime{} = date_from,
         date_to: %DateTime{} = date_to
       })
       when is_binary(source_system_id) and is_binary(event_id) do
    if DateTime.compare(date_from, date_to) in [:lt, :eq],
      do: :ok,
      else: {:error, :invalid_historical_bounds}
  end

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

  defp load_evidence(%SyncCursor{metadata: metadata}) do
    case HistoricalManifestEvidence.state(metadata) do
      :missing -> {:error, :manifest_evidence_missing}
      :create_claimed -> {:error, :manifest_create_in_doubt}
      :corrupt -> {:error, :corrupt_manifest_evidence}
      _state -> HistoricalManifestEvidence.from_metadata(metadata)
    end
  end

  defp load_source_system(run, opts) do
    loader = Keyword.get(opts, :test_source_system_loader, &default_source_system_loader/1)

    case loader.(run.source_system_id) do
      {:ok, %SourceSystem{} = source} -> {:ok, source}
      %SourceSystem{} = source -> {:ok, source}
      {:ok, nil} -> {:error, :source_system_not_found}
      {:error, _reason} -> {:error, :source_system_not_found}
      _other -> {:error, :source_system_not_found}
    end
  end

  defp default_source_system_loader(source_system_id),
    do: Ash.get(SourceSystem, source_system_id, domain: Catalog)

  defp validate_source_system(%SourceSystem{} = source, run) do
    cond do
      source.id != run.source_system_id -> {:error, :source_system_mismatch}
      source.kind != :woocommerce -> {:error, :source_system_kind_mismatch}
      source.active != true -> {:error, :source_system_inactive}
      not is_binary(source.base_url) or source.base_url == "" -> {:error, :source_system_invalid}
      true -> :ok
    end
  end

  defp validate_client_bindings(%SourceSystem{} = source, opts) do
    source_url = NormalizeBaseUrl.normalize(source.base_url)
    manifest_client = Keyword.get(opts, :manifest_client, @manifest_client)
    woocommerce_client = Keyword.get(opts, :woocommerce_client, @woocommerce_client)

    with {:ok, manifest_url} <- configured_base_url(manifest_client, manifest_client_opts(opts)),
         {:ok, woocommerce_url} <-
           configured_base_url(woocommerce_client, woocommerce_client_opts(opts)),
         true <- NormalizeBaseUrl.normalize(manifest_url) == source_url,
         true <- NormalizeBaseUrl.normalize(woocommerce_url) == source_url do
      :ok
    else
      false -> {:error, :source_endpoint_mismatch}
      {:error, _reason} -> {:error, :source_client_misconfigured}
      _other -> {:error, :source_client_misconfigured}
    end
  end

  defp configured_base_url(client, opts) do
    if function_exported?(client, :configured_base_url, 1) do
      case client.configured_base_url(opts) do
        {:ok, url} when is_binary(url) and url != "" -> {:ok, url}
        {:error, reason} -> {:error, reason}
        _other -> {:error, :invalid_configured_base_url}
      end
    else
      {:error, :missing_configured_base_url}
    end
  end

  defp fetch_one_page(%HistoricalManifestEvidence{state: state} = evidence, opts) do
    cursor =
      case state do
        "pending_first_page" -> nil
        "manifest_in_progress" -> evidence.next_cursor
        _other -> nil
      end

    client = Keyword.get(opts, :manifest_client, @manifest_client)
    client_opts = manifest_client_opts(opts)

    case client.fetch_manifest_page(evidence.boundary_token, cursor, client_opts) do
      {:ok, page} when is_map(page) -> {:ok, page}
      {:error, %WooOrderIndexError{reason: reason}} -> {:error, reason}
      {:error, _reason} -> {:error, :manifest_source_error}
      _other -> {:error, :invalid_manifest_page_response}
    end
  end

  defp load_mappings(run, opts) do
    case Keyword.fetch(opts, :mappings) do
      {:ok, mappings} when is_list(mappings) ->
        {:ok, Enum.filter(mappings, &active_mapping_for_run?(&1, run))}

      {:ok, _other} ->
        {:error, :invalid_product_mappings}

      :error ->
        ProductMapping
        |> Ash.Query.filter(
          source_system_id == ^run.source_system_id and event_id == ^run.event_id and
            active == true
        )
        |> Ash.read(domain: Catalog)
        |> case do
          {:ok, mappings} -> {:ok, mappings}
          {:error, _reason} -> {:error, :product_mappings_unavailable}
        end
    end
  end

  defp active_mapping_for_run?(mapping, run) when is_map(mapping) do
    mapping_value(mapping, :source_system_id, "source_system_id") == run.source_system_id and
      mapping_value(mapping, :event_id, "event_id") == run.event_id and
      mapping_value(mapping, :active, "active") == true and
      is_integer(mapping_value(mapping, :woo_product_id, "woo_product_id"))
  end

  defp active_mapping_for_run?(_mapping, _run), do: false

  defp resolve_page(run, page, mappings, opts) do
    page
    |> page_value(:items, "items")
    |> Enum.reduce_while({:ok, zero_counts()}, fn item, {:ok, counts} ->
      source_order_id = page_value(item, :source_order_id, "source_order_id")

      case fetch_order(source_order_id, opts) do
        {:ok, order} ->
          with :ok <- validate_returned_order_id(source_order_id, order),
               {:ok, filtered_line_items} <- matching_line_items(order, mappings) do
            next_counts = Map.update!(counts, :orders_seen_count, &(&1 + 1))

            if filtered_line_items == [] do
              {:cont, {:ok, next_counts}}
            else
              filtered_order = put_line_items(order, filtered_line_items)

              case upsert_order(run.source_system_id, filtered_order, opts) do
                {:ok, :stale_noop} ->
                  {:cont,
                   {:ok,
                    next_counts
                    |> Map.update!(:orders_matched_count, &(&1 + 1))
                    |> Map.update!(:orders_stale_count, &(&1 + 1))}}

                {:ok, _persisted_order} ->
                  {:cont,
                   {:ok,
                    next_counts
                    |> Map.update!(:orders_matched_count, &(&1 + 1))
                    |> Map.update!(:orders_upserted_count, &(&1 + 1))}}

                {:error, _reason} ->
                  {:halt, {:error, :order_upsert_failed}}

                _other ->
                  {:halt, {:error, :order_upsert_failed}}
              end
            end
          else
            {:error, reason} -> {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, normalize_order_fetch_error(reason)}}

        _other ->
          {:halt, {:error, :source_order_fetch_failed}}
      end
    end)
  end

  defp fetch_order(source_order_id, opts) do
    client = Keyword.get(opts, :woocommerce_client, @woocommerce_client)

    case client.fetch_order(source_order_id, woocommerce_client_opts(opts)) do
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

  defp validate_returned_order_id(_source_order_id, _order),
    do: {:error, :invalid_source_order_response}

  defp matching_line_items(order, mappings) do
    case map_value(order, :line_items, "line_items") do
      line_items when is_list(line_items) ->
        {:ok,
         Enum.filter(line_items, fn line_item ->
           is_map(line_item) and
             Enum.any?(mappings, &mapping_matches_line_item?(&1, line_item))
         end)}

      nil ->
        {:ok, []}

      _other ->
        {:error, :invalid_source_order_line_items}
    end
  end

  defp mapping_matches_line_item?(mapping, line_item) do
    product_id = positive_or_nil_id(map_value(line_item, :product_id, "product_id"))
    variation_id = positive_or_nil_id(map_value(line_item, :variation_id, "variation_id"))
    mapped_product_id = mapping_value(mapping, :woo_product_id, "woo_product_id")
    mapped_variation_id = mapping_value(mapping, :woo_variation_id, "woo_variation_id")

    mapped_product_id == product_id and mapped_variation_id == variation_id
  end

  defp put_line_items(order, line_items), do: Map.put(order, "line_items", line_items)

  defp upsert_order(source_system_id, payload, opts) do
    upserter = Keyword.get(opts, :order_upserter, @order_upserter)
    upserter.upsert_order(source_system_id, payload, Keyword.get(opts, :order_upserter_opts, []))
  end

  defp zero_counts do
    %{
      orders_seen_count: 0,
      orders_matched_count: 0,
      orders_upserted_count: 0,
      orders_stale_count: 0
    }
  end

  defp before_checkpoint(opts) do
    case Keyword.get(opts, :before_checkpoint) do
      nil -> :ok
      callback when is_function(callback, 0) -> callback.()
      _other -> {:error, :invalid_checkpoint_callback}
    end
  end

  defp checkpoint_page(run, cursor, evidence, page, counts, _opts) do
    with {:ok, next_metadata, result_kind} <- next_metadata(cursor.metadata, evidence, page) do
      case Repo.transaction(fn ->
             with {:ok, current_cursor} <- locked_current_cursor(cursor),
                  :ok <- verify_cursor_authority(current_cursor, cursor),
                  {:ok, current_run} <- current_run(run),
                  :ok <- verify_run_authority(current_run, run),
                  {:ok, updated_run, run_notifications} <- record_counts(current_run, counts),
                  {:ok, updated_cursor, cursor_notifications} <-
                    record_progress(current_cursor, next_metadata) do
               {result_kind, updated_run, updated_cursor,
                run_notifications ++ cursor_notifications}
             else
               {:error, reason} -> Repo.rollback(reason)
               _other -> Repo.rollback(:checkpoint_conflict)
             end
           end) do
        {:ok, {result_kind, updated_run, updated_cursor, notifications}} ->
          if notifications != [], do: Ash.Notifier.notify(notifications)
          {:ok, {result_kind, updated_run, updated_cursor}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp next_metadata(metadata, evidence, page) do
    case {page_value(page, :has_more, "has_more"), page_value(page, :next_cursor, "next_cursor"),
          page_value(page, :terminal_evidence, "terminal_evidence")} do
      {true, next_cursor, nil} when is_binary(next_cursor) ->
        state_metadata = HistoricalManifestEvidence.in_progress_metadata(evidence, next_cursor)
        checkpoint_metadata(Map.merge(metadata, state_metadata), :continue)

      {false, nil, terminal_evidence}
      when is_binary(terminal_evidence) and terminal_evidence != "" ->
        state_metadata = HistoricalManifestEvidence.terminal_metadata(evidence, terminal_evidence)
        checkpoint_metadata(Map.merge(metadata, state_metadata), :manifest_terminal)

      _invalid ->
        {:error, :invalid_manifest_page}
    end
  end

  defp checkpoint_metadata(metadata, result_kind) do
    with {:ok, _evidence} <- HistoricalManifestEvidence.from_metadata(metadata),
         {:ok, size} <- HistoricalManifestEvidence.encoded_size(metadata),
         true <- size <= HistoricalManifestEvidence.metadata_max_bytes() do
      {:ok, metadata, result_kind}
    else
      {:ok, _size} -> {:error, :metadata_too_large}
      _error -> {:error, :invalid_manifest_evidence}
    end
  end

  defp locked_current_cursor(%SyncCursor{id: cursor_id}) do
    query =
      from cursor in "ingestion_sync_cursors",
        where: cursor.id == type(^cursor_id, Ecto.UUID),
        select: cursor.id,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      nil -> {:error, :checkpoint_conflict}
      _id -> Ash.get(SyncCursor, cursor_id, domain: Ingestion)
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
           expected.metadata[HistoricalManifestEvidence.metadata_key()] do
      :ok
    else
      {:error, :checkpoint_conflict}
    end
  end

  defp current_run(%SyncRun{id: run_id}), do: Ash.get(SyncRun, run_id, domain: Ingestion)

  defp verify_run_authority(current, expected) do
    if current.id == expected.id and current.sync_type == :historical_backfill and
         current.source_system_id == expected.source_system_id and
         current.event_id == expected.event_id and
         same_datetime?(current.date_from, expected.date_from) and
         same_datetime?(current.date_to, expected.date_to) and
         current.status in [:queued, :running, :paused] do
      :ok
    else
      {:error, :checkpoint_conflict}
    end
  end

  defp record_counts(run, counts) do
    attrs = %{
      orders_seen_count: run.orders_seen_count + counts.orders_seen_count,
      orders_matched_count: run.orders_matched_count + counts.orders_matched_count,
      orders_upserted_count: run.orders_upserted_count + counts.orders_upserted_count,
      orders_stale_count: run.orders_stale_count + counts.orders_stale_count
    }

    case Ash.update(run, attrs,
           action: :record_counts,
           domain: Ingestion,
           return_notifications?: true
         ) do
      {:ok, updated} -> {:ok, updated, []}
      {:ok, updated, notifications} -> {:ok, updated, notifications}
      {:error, _reason} -> {:error, :checkpoint_failed}
      _other -> {:error, :checkpoint_failed}
    end
  end

  defp record_progress(cursor, metadata) do
    attrs = %{page: cursor.page + 1, metadata: metadata}

    case Ash.update(cursor, attrs,
           action: :record_manifest_progress,
           domain: Ingestion,
           return_notifications?: true
         ) do
      {:ok, updated} -> {:ok, updated, []}
      {:ok, updated, notifications} -> {:ok, updated, notifications}
      {:error, _reason} -> {:error, :checkpoint_failed}
      _other -> {:error, :checkpoint_failed}
    end
  end

  defp normalize_order_fetch_error(:not_found), do: :source_order_not_found
  defp normalize_order_fetch_error(:invalid_json), do: :invalid_source_order_response
  defp normalize_order_fetch_error(reason) when is_atom(reason), do: reason
  defp normalize_order_fetch_error(_reason), do: :source_order_fetch_failed

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

  defp positive_or_nil_id(value) do
    case positive_id(value) do
      {:ok, id} -> id
      _error when value in [nil, 0, "0"] -> nil
      _error -> :invalid
    end
  end

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false

  defp mapping_value(mapping, atom_key, string_key), do: map_value(mapping, atom_key, string_key)

  defp map_value(map, atom_key, string_key) when is_map(map) do
    case Map.fetch(map, atom_key) do
      {:ok, value} -> value
      :error -> Map.get(map, string_key)
    end
  end

  defp map_value(_map, _atom_key, _string_key), do: nil

  defp page_value(map, atom_key, string_key), do: map_value(map, atom_key, string_key)

  defp manifest_client_opts(opts),
    do: Keyword.get(opts, :manifest_client_opts, Keyword.get(opts, :client_opts, []))

  defp woocommerce_client_opts(opts),
    do: Keyword.get(opts, :woocommerce_client_opts, Keyword.get(opts, :client_opts, []))
end
