defmodule EventSales.Ingestion.OrderReconciliation do
  @moduledoc """
  Scoped WooCommerce order reconciliation for a single `SyncRun`.

  Fetches one page of modified orders per `run_step/3`, filters line items against
  active catalog mappings, upserts matches, and updates per-run cursor progress.
  """

  require Ash.Query

  alias EventSales.Analytics.OrderProcessedNotifier
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Clients.{WooCommerceClient, WooCommerceError}
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.Sales.OrderUpserter
  alias EventSales.Telemetry

  @retryable_reasons MapSet.new([
                       :rate_limited,
                       :server_error,
                       :timeout,
                       :transport_error,
                       :queue_timeout,
                       :circuit_open
                     ])

  @pause_seconds %{
    rate_limited: 60,
    timeout: 30,
    server_error: 30,
    circuit_open: 30
  }

  @type step_result ::
          {:continue, SyncRun.t()}
          | {:complete, SyncRun.t()}
          | {:pause, SyncRun.t(), atom(), pos_integer()}
          | {:error, term()}

  @doc """
  Loads the cursor for a run or initializes one from the run date scope.
  """
  @spec load_or_init_cursor(SyncRun.t(), keyword()) ::
          {:ok, SyncCursor.t()} | {:error, term()}
  def load_or_init_cursor(%SyncRun{} = run, _opts \\ []) do
    ensure_cursor(run, nil)
  end

  @doc false
  @spec woo_params(SyncRun.t(), SyncCursor.t()) :: map()
  def woo_params(%SyncRun{} = run, %SyncCursor{} = cursor), do: build_woo_params(run, cursor)

  @doc false
  @spec matches_event_mapping?(map(), [ProductMapping.t()]) :: boolean()
  def matches_event_mapping?(line_item, mappings) when is_map(line_item) and is_list(mappings) do
    line_item_matches?(line_item, mappings)
  end

  @doc """
  Executes one reconciliation step for the given run and cursor.
  """
  @spec run_step(SyncRun.t(), SyncCursor.t() | nil, keyword()) :: step_result()
  def run_step(%SyncRun{} = run, cursor, opts \\ []) do
    emit_start(run)

    with {:ok, cursor} <- ensure_cursor(run, cursor),
         {:ok, orders, per_page} <- fetch_orders(run, cursor, opts),
         {:ok, run} <- process_orders(run, orders, opts),
         result <- finalize_step(run, cursor, orders, per_page) do
      emit_step_result(run, result)
      result
    else
      {:pause, run, pause_reason, seconds} ->
        emit_pause(run, pause_reason)
        {:pause, run, pause_reason, seconds}

      {:error, reason} = error ->
        emit_exception(run, reason)
        error
    end
  end

  defp ensure_cursor(%SyncRun{}, %SyncCursor{} = cursor), do: {:ok, cursor}

  defp ensure_cursor(%SyncRun{} = run, nil) do
    SyncCursor
    |> Ash.Changeset.for_create(:upsert_active, %{
      sync_run_id: run.id,
      page: 1,
      modified_after: run.date_from,
      modified_before: run.date_to,
      metadata: %{}
    })
    |> Ash.create(domain: Ingestion)
  end

  defp fetch_orders(%SyncRun{} = run, %SyncCursor{} = cursor, opts) do
    params = build_woo_params(run, cursor)
    client = Keyword.get(opts, :woocommerce_client, WooCommerceClient)
    per_page = per_page()

    client_opts =
      [max_pages: 1]
      |> maybe_put_client_opt(:transport, Keyword.get(opts, :transport))

    case client.list_orders(params, client_opts) do
      {:ok, orders} when is_list(orders) ->
        {:ok, orders, per_page}

      {:error, %WooCommerceError{} = error} ->
        handle_fetch_error(run, error)
    end
  end

  defp process_orders(%SyncRun{} = run, orders, opts) do
    mappings = active_mappings(run)
    notifier = notifier(opts)
    upserter = Keyword.get(opts, :order_upserter, OrderUpserter)

    counts =
      Enum.reduce(orders, initial_counts(), fn order, counts ->
        process_order(run, order, mappings, upserter, notifier, counts)
      end)

    record_counts(run, counts)
  end

  defp process_order(run, order, mappings, upserter, notifier, counts) do
    counts = %{counts | orders_seen_count: counts.orders_seen_count + 1}

    filtered = filter_matching_line_items(order, mappings)

    if filtered["line_items"] != [] do
      counts = %{counts | orders_matched_count: counts.orders_matched_count + 1}

      case upserter.upsert_order(run.source_system_id, filtered) do
        {:ok, %_{} = persisted} ->
          :ok = notifier.notify_order_reconciled(persisted, run, run.event_id)
          %{counts | orders_upserted_count: counts.orders_upserted_count + 1}

        {:ok, :stale_noop} ->
          %{counts | orders_stale_count: counts.orders_stale_count + 1}

        {:error, _reason} ->
          %{
            counts
            | orders_failed_count: counts.orders_failed_count + 1,
              errors_count: counts.errors_count + 1
          }
      end
    else
      counts
    end
  end

  defp finalize_step(%SyncRun{} = run, %SyncCursor{} = cursor, orders, per_page) do
    last_order_id = last_order_id(orders)

    if done_page?(run, cursor, orders, per_page) do
      with {:ok, _cursor} <- mark_cursor_done(cursor),
           {:ok, completed} <- complete_run(run) do
        {:complete, completed}
      end
    else
      next_page = (cursor.page || 1) + 1

      with {:ok, _cursor} <-
             upsert_cursor(cursor, %{page: next_page, last_seen_order_id: last_order_id}),
           {:ok, updated} <- reload_run(run) do
        {:continue, updated}
      end
    end
  end

  defp done_page?(%SyncRun{sync_mode: :shallow}, _cursor, _orders, _per_page), do: true

  defp done_page?(%SyncRun{} = run, cursor, orders, per_page) do
    page_limit = page_limit(run)
    current_page = cursor.page || 1
    current_page >= page_limit or length(orders) < per_page
  end

  defp handle_fetch_error(%SyncRun{} = run, %WooCommerceError{reason: reason}) do
    if MapSet.member?(@retryable_reasons, reason) do
      pause_reason = pause_reason_for(reason)
      seconds = Map.fetch!(@pause_seconds, pause_reason)
      paused_until = DateTime.add(DateTime.utc_now(), seconds, :second)

      with {:ok, paused} <-
             Ash.update(
               run,
               %{
                 paused_until: paused_until,
                 pause_reason: pause_reason,
                 last_error: "woocommerce_#{reason}"
               },
               action: :pause,
               domain: Ingestion
             ) do
        {:pause, paused, pause_reason, seconds}
      end
    else
      with {:ok, failed} <-
             Ash.update(run, %{last_error: "woocommerce_#{reason}"},
               action: :fail,
               domain: Ingestion
             ) do
        {:error, {:failed, failed, reason}}
      end
    end
  end

  defp filter_matching_line_items(order, mappings) do
    line_items =
      order
      |> Map.get("line_items", [])
      |> Enum.filter(&line_item_matches?(&1, mappings))

    Map.put(order, "line_items", line_items)
  end

  defp build_woo_params(%SyncRun{} = run, %SyncCursor{} = cursor) do
    %{
      "modified_after" => iso8601(cursor.modified_after || run.date_from),
      "modified_before" => iso8601(run.date_to),
      "orderby" => "modified",
      "order" => "asc",
      "page" => Integer.to_string(cursor.page || 1),
      "per_page" => Integer.to_string(per_page())
    }
  end

  defp line_item_matches?(line_item, mappings) do
    product_id = woo_id(line_item, "product_id")
    variation_id = normalize_variation_id(line_item)

    Enum.any?(mappings, fn mapping ->
      mapping.woo_product_id == product_id and variation_matches?(mapping, variation_id)
    end)
  end

  defp variation_matches?(%ProductMapping{woo_variation_id: nil}, nil), do: true
  defp variation_matches?(%ProductMapping{woo_variation_id: nil}, _variation_id), do: false

  defp variation_matches?(%ProductMapping{woo_variation_id: mapping_variation_id}, variation_id) do
    mapping_variation_id == variation_id
  end

  defp active_mappings(%SyncRun{event_id: event_id, source_system_id: source_system_id}) do
    ProductMapping
    |> Ash.Query.filter(
      event_id == ^event_id and source_system_id == ^source_system_id and active == true
    )
    |> Ash.read!(domain: Catalog)
  end

  defp record_counts(%SyncRun{} = run, counts) do
    attrs = %{
      orders_seen_count: run.orders_seen_count + counts.orders_seen_count,
      orders_matched_count: run.orders_matched_count + counts.orders_matched_count,
      orders_upserted_count: run.orders_upserted_count + counts.orders_upserted_count,
      orders_stale_count: run.orders_stale_count + counts.orders_stale_count,
      orders_failed_count: run.orders_failed_count + counts.orders_failed_count,
      errors_count: run.errors_count + counts.errors_count
    }

    Ash.update(run, attrs, action: :record_counts, domain: Ingestion)
  end

  defp complete_run(%SyncRun{} = run) do
    Ash.update(run, %{}, action: :complete, domain: Ingestion)
  end

  defp mark_cursor_done(%SyncCursor{} = cursor) do
    Ash.update(cursor, %{}, action: :mark_done, domain: Ingestion)
  end

  defp upsert_cursor(%SyncCursor{sync_run_id: sync_run_id} = cursor, attrs) do
    attrs =
      attrs
      |> Map.put(:sync_run_id, sync_run_id)
      |> Map.put_new(:modified_after, cursor.modified_after)
      |> Map.put_new(:modified_before, cursor.modified_before)
      |> Map.put_new(:metadata, cursor.metadata || %{})

    SyncCursor
    |> Ash.Changeset.for_create(:upsert_active, attrs)
    |> Ash.create(domain: Ingestion)
  end

  defp reload_run(%SyncRun{id: id}), do: Ash.get(SyncRun, id, domain: Ingestion)

  defp initial_counts do
    %{
      orders_seen_count: 0,
      orders_matched_count: 0,
      orders_upserted_count: 0,
      orders_stale_count: 0,
      orders_failed_count: 0,
      errors_count: 0
    }
  end

  defp last_order_id([]), do: nil

  defp last_order_id(orders) do
    orders
    |> List.last()
    |> woo_id("id")
  end

  defp woo_id(map, key) when is_map(map) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      id when is_integer(id) -> id
      id when is_binary(id) -> String.to_integer(id)
      _ -> nil
    end
  end

  defp normalize_variation_id(line_item) do
    case woo_id(line_item, "variation_id") do
      nil -> nil
      0 -> nil
      id -> id
    end
  end

  defp iso8601(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp per_page do
    Application.get_env(:event_sales, :woocommerce_rest, [])
    |> Keyword.get(:per_page, 100)
  end

  defp page_limit(%SyncRun{sync_mode: :shallow}), do: 1

  defp page_limit(%SyncRun{sync_mode: :deep}) do
    Application.get_env(:event_sales, :woocommerce_rest, [])
    |> Keyword.get(:max_pages, 50)
  end

  defp pause_reason_for(:rate_limited), do: :rate_limited
  defp pause_reason_for(:timeout), do: :timeout
  defp pause_reason_for(:server_error), do: :server_error
  defp pause_reason_for(:circuit_open), do: :circuit_open
  defp pause_reason_for(_reason), do: :server_error

  defp maybe_put_client_opt(opts, _key, nil), do: opts

  defp maybe_put_client_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp notifier(opts) do
    cond do
      Keyword.has_key?(opts, :notifier) ->
        Keyword.fetch!(opts, :notifier)

      Keyword.has_key?(opts, :order_processed_notifier) ->
        Keyword.fetch!(opts, :order_processed_notifier)

      true ->
        OrderProcessedNotifier
    end
  end

  defp emit_start(%SyncRun{} = run) do
    Telemetry.emit(Telemetry.reconciliation_start(), %{count: 1}, telemetry_metadata(run))
  end

  defp emit_step_result(run, {:complete, _}), do: emit_stop(run, :completed)
  defp emit_step_result(run, {:continue, _}), do: emit_stop(run, :continued)
  defp emit_step_result(_run, {:error, _}), do: :ok

  defp emit_stop(%SyncRun{} = run, result) do
    Telemetry.emit(
      Telemetry.reconciliation_stop(),
      %{count: 1},
      Map.put(telemetry_metadata(run), :result, result)
    )
  end

  defp emit_pause(%SyncRun{} = run, pause_reason) do
    Telemetry.emit(
      Telemetry.reconciliation_pause(),
      %{count: 1},
      Map.put(telemetry_metadata(run), :pause_reason, pause_reason)
    )
  end

  defp emit_exception(%SyncRun{} = run, reason) do
    Telemetry.emit(
      Telemetry.reconciliation_exception(),
      %{count: 1},
      Map.put(telemetry_metadata(run), :reason, reason)
    )
  end

  defp telemetry_metadata(%SyncRun{} = run) do
    %{
      sync_mode: run.sync_mode,
      requested_via: run.requested_via,
      source: :reconciliation
    }
  end
end
