defmodule EventSales.Ingestion.FinancialReconciliation.SourceExtractor do
  @moduledoc """
  Independent Woo source-side financial totals for one exact M3 certificate.

  The extractor reads certified target membership rows, performs bounded exact
  Woo Order and Refund GETs outside database transactions, and accumulates the
  locked M1-08 C17 primitives per currency.
  """

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, SourceSystem}
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Clients.WooCommerceClient
  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.HistoricalEventLineSelector
  alias EventSales.Ingestion.Parsers.WoocommerceRefundParser
  alias EventSales.Ingestion.Parsers.WoocommerceRefundReferenceParser

  alias EventSales.Ingestion.Resources.{
    HistoricalOrderMembership,
    HistoricalRefundObservation,
    HistoricalRefundReference,
    SyncRun
  }

  alias EventSales.Repo
  alias EventSales.Sales.FinancialPrimitives

  @default_batch_size 50

  @type structural_category ::
          :source_snapshot_stale
          | :refund_identity_drift
          | :missing_source_fact
          | :historical_recognition_unproven
          | :timestamp_incomplete
          | :currency_conflict
          | :unresolved_attribution
          | :invalid_currency
          | :http_under_lock
          | :invalid_scope

  @type structural_error :: {structural_category(), map()}

  @type currency_totals :: %{FinancialPrimitives.primitive() => Decimal.t()}

  @type result :: %{
          sync_run_id: String.t(),
          event_id: String.t(),
          source_system_id: String.t(),
          coverage_start: DateTime.t(),
          sales_covered_through: DateTime.t(),
          refunds_covered_through: DateTime.t(),
          currencies: %{String.t() => currency_totals()},
          source_orders_fetched: non_neg_integer(),
          source_refunds_fetched: non_neg_integer(),
          source_observed_at: DateTime.t() | nil
        }

  @doc """
  Extracts source financial totals for the current M3 certificate of one Event.
  """
  @spec extract(term(), keyword()) :: {:ok, result()} | {:error, structural_error()}
  def extract(event_id, opts \\ []) when is_list(opts) do
    with {:ok, %SyncRun{} = run} <- HistoricalCoverageResolver.resolve_current(event_id),
         {:ok, %Event{} = event} <- load_event(run.event_id),
         {:ok, %SourceSystem{} = source} <- load_source_system(run.source_system_id) do
      extract_for_run(run, event, source, opts)
    end
  end

  @doc """
  Extracts source financial totals for one exact certified historical SyncRun.
  """
  @spec extract_for_run(SyncRun.t(), Event.t(), SourceSystem.t(), keyword()) ::
          {:ok, result()} | {:error, structural_error()}
  def extract_for_run(%SyncRun{} = run, %Event{} = event, %SourceSystem{} = source, opts \\ [])
      when is_list(opts) do
    with :ok <- validate_run_scope(run, event, source) do
      process_memberships(run, event, source, opts)
    end
  end

  defp validate_run_scope(%SyncRun{} = run, %Event{} = event, %SourceSystem{} = source) do
    cond do
      run.sync_type != :historical_backfill ->
        {:error, {:invalid_scope, %{reason: :not_historical_backfill}}}

      run.event_id != event.id ->
        {:error, {:invalid_scope, %{reason: :event_mismatch}}}

      run.source_system_id != source.id ->
        {:error, {:invalid_scope, %{reason: :source_mismatch}}}

      is_nil(run.coverage_start) or is_nil(run.sales_covered_through) or
          is_nil(run.refunds_covered_through) ->
        {:error, {:invalid_scope, %{reason: :incomplete_coverage_boundaries}}}

      true ->
        :ok
    end
  end

  defp process_memberships(run, event, source, opts) do
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    woo_client = Keyword.get(opts, :woo_client, WooCommerceClient)
    line_selector = Keyword.get(opts, :line_selector, &HistoricalEventLineSelector.select/3)
    now = normalize_now(Keyword.get(opts, :now, DateTime.utc_now()))

    initial_acc = %{
      currencies: %{},
      source_orders_fetched: 0,
      source_refunds_fetched: 0,
      source_observed_at: nil
    }

    context = %{
      run: run,
      event: event,
      source: source,
      woo_client: woo_client,
      line_selector: line_selector,
      now: now
    }

    case stream_memberships(
           run.id,
           batch_size,
           initial_acc,
           nil,
           &reduce_membership_batch(&1, &2, context)
         ) do
      {:ok, acc} -> {:ok, finalize_acc(run, acc)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reduce_membership_batch(memberships, acc, context) do
    Enum.reduce_while(memberships, {:ok, acc}, fn membership, {:ok, acc} ->
      reduce_membership(membership, acc, context)
    end)
  end

  defp reduce_membership(membership, acc, context) do
    case process_membership(
           membership,
           context.run,
           context.event,
           context.source,
           context.woo_client,
           context.line_selector,
           context.now
         ) do
      {:ok, update} -> {:cont, {:ok, merge_acc(acc, update)}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp normalize_now(fun) when is_function(fun, 0), do: fun.()
  defp normalize_now(%DateTime{} = datetime), do: datetime

  defp stream_memberships(sync_run_id, batch_size, acc, after_source_order_id, reducer) do
    memberships = fetch_membership_batch(sync_run_id, batch_size, after_source_order_id)

    case memberships do
      [] ->
        {:ok, acc}

      batch ->
        case reducer.(batch, acc) do
          {:ok, updated_acc} ->
            stream_memberships(
              sync_run_id,
              batch_size,
              updated_acc,
              List.last(batch).source_order_id,
              reducer
            )

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  defp fetch_membership_batch(sync_run_id, batch_size, after_source_order_id) do
    query =
      HistoricalOrderMembership
      |> Ash.Query.filter(sync_run_id == ^sync_run_id and event_match_state == :target)
      |> Ash.Query.sort(source_order_id: :asc)
      |> Ash.Query.limit(batch_size)

    query =
      if is_integer(after_source_order_id) do
        Ash.Query.filter(query, source_order_id > ^after_source_order_id)
      else
        query
      end

    Ash.read!(query, domain: Ingestion)
  end

  defp process_membership(membership, run, event, source, woo_client, line_selector, now) do
    if Repo.in_transaction?() do
      {:error, {:http_under_lock, %{source_order_id: membership.source_order_id}}}
    else
      do_process_membership(membership, run, event, source, woo_client, line_selector, now)
    end
  end

  defp do_process_membership(membership, run, event, source, woo_client, line_selector, now) do
    with {:ok, order_payload} <- fetch_order_payload(woo_client, membership.source_order_id),
         :ok <- assert_source_snapshot(order_payload, membership),
         {:ok, currency} <- order_currency(order_payload),
         {:ok, selected_lines} <- select_event_lines(line_selector, event, source, order_payload),
         {:ok, gross_totals} <-
           gross_totals_for_order(order_payload, selected_lines, currency),
         {:ok, refund_totals, refunds_fetched} <-
           refund_totals_for_membership(
             membership,
             order_payload,
             selected_lines,
             run.refunds_covered_through,
             woo_client
           ) do
      combined =
        FinancialPrimitives.add_totals(gross_totals, refund_totals)
        |> FinancialPrimitives.derive_net_totals()

      {:ok,
       %{
         currencies: %{currency => combined},
         source_orders_fetched: 1,
         source_refunds_fetched: refunds_fetched,
         source_observed_at: now
       }}
    end
  end

  defp fetch_order_payload(woo_client, source_order_id) do
    case woo_client.fetch_order(source_order_id, []) do
      {:ok, payload} when is_map(payload) ->
        {:ok, payload}

      {:error, :not_found} ->
        {:error, {:missing_source_fact, %{source_order_id: source_order_id, kind: :order}}}

      {:error, %{reason: :not_found}} ->
        {:error, {:missing_source_fact, %{source_order_id: source_order_id, kind: :order}}}

      {:error, _reason} ->
        {:error,
         {:missing_source_fact, %{source_order_id: source_order_id, kind: :order_fetch_failed}}}
    end
  end

  defp assert_source_snapshot(order_payload, membership) do
    with {:ok, modified_at} <- parse_gmt_datetime(order_payload, "date_modified_gmt"),
         true <- DateTime.compare(modified_at, membership.last_source_modified_at) == :eq do
      :ok
    else
      false ->
        {:error,
         {:source_snapshot_stale,
          %{
            source_order_id: membership.source_order_id,
            expected: membership.last_source_modified_at,
            actual: modified_at_value(order_payload)
          }}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp modified_at_value(order_payload) do
    case parse_gmt_datetime(order_payload, "date_modified_gmt") do
      {:ok, value} -> value
      error -> error
    end
  end

  defp order_currency(order_payload) do
    case blank_to_nil(Map.get(order_payload, "currency")) do
      currency when is_binary(currency) and currency != "" -> {:ok, currency}
      _other -> {:error, {:invalid_currency, %{field: :currency}}}
    end
  end

  defp select_event_lines(line_selector, event, source, order_payload) do
    case line_selector.(event, source, order_payload) do
      {:ok, lines} ->
        {:ok, lines}

      {:error, {:historical_event_line_unresolved, line_id, reason}} ->
        {:error,
         {:unresolved_attribution,
          %{woo_line_item_id: line_id, reason: reason, woo_order_id: order_payload["id"]}}}

      {:error, reason} ->
        {:error, {:unresolved_attribution, %{reason: reason, woo_order_id: order_payload["id"]}}}
    end
  end

  defp gross_totals_for_order(order_payload, selected_lines, _currency) do
    status = Map.get(order_payload, "status", "")
    completed_at = completed_at_value(order_payload)
    has_refund_evidence? = refund_evidence?(order_payload)

    with :ok <-
           validate_historical_recognition(
             status,
             completed_at,
             has_refund_evidence?,
             order_payload
           ) do
      {:ok, accumulate_gross_lines(selected_lines, status, completed_at)}
    end
  end

  defp accumulate_gross_lines(selected_lines, status, completed_at) do
    if FinancialPrimitives.historically_recognised_source_order?(status, completed_at) do
      Enum.reduce(selected_lines, FinancialPrimitives.empty_totals(), fn line, acc ->
        add_gross_line(acc, line)
      end)
    else
      FinancialPrimitives.empty_totals()
    end
  end

  defp completed_at_value(order_payload) do
    case parse_gmt_datetime(order_payload, "date_completed_gmt") do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp validate_historical_recognition(status, completed_at, has_refund_evidence?, order_payload) do
    if FinancialPrimitives.historically_recognised_source_order?(status, completed_at) do
      :ok
    else
      if has_refund_evidence? or present_refund_references?(order_payload) do
        {:error,
         {:historical_recognition_unproven, %{woo_order_id: order_payload["id"], status: status}}}
      else
        :ok
      end
    end
  end

  defp present_refund_references?(order_payload) do
    case WoocommerceRefundReferenceParser.parse_historical(order_payload) do
      {:ok, []} -> false
      {:ok, _references} -> true
      {:error, _} -> false
    end
  end

  defp refund_evidence?(order_payload) do
    case Map.get(order_payload, "refunds") do
      references when is_list(references) and references != [] -> true
      _ -> false
    end
  end

  defp add_gross_line(acc, line) do
    quantity = positive_integer(Map.get(line, "quantity", 0))
    gross_qty = FinancialPrimitives.gross_ticket_quantity(quantity)

    gross_val =
      FinancialPrimitives.gross_ticket_value(
        parse_decimal(Map.get(line, "total")),
        parse_decimal(Map.get(line, "total_tax"))
      )

    acc
    |> Map.update!(:gross_ticket_quantity, &Decimal.add(&1, gross_qty))
    |> Map.update!(:gross_ticket_value, &Decimal.add(&1, gross_val))
  end

  defp refund_totals_for_membership(
         membership,
         order_payload,
         selected_lines,
         refunds_covered_through,
         woo_client
       ) do
    with {:ok, woo_refund_ids} <- parse_woo_refund_ids(order_payload),
         {:ok, expected_refund_ids} <- expected_present_refund_ids(membership),
         :ok <- assert_refund_identity_sets(woo_refund_ids, expected_refund_ids, membership) do
      selected_line_ids = MapSet.new(selected_lines, &Map.get(&1, "id"))

      accumulate_refund_totals(
        expected_refund_ids,
        membership.source_order_id,
        selected_line_ids,
        refunds_covered_through,
        woo_client
      )
    end
  end

  defp accumulate_refund_totals(
         refund_ids,
         source_order_id,
         selected_line_ids,
         refunds_covered_through,
         woo_client
       ) do
    refund_ids
    |> Enum.sort()
    |> Enum.reduce_while({:ok, {FinancialPrimitives.empty_totals(), 0}}, fn refund_id,
                                                                            {:ok, {totals, count}} ->
      accumulate_refund(
        refund_id,
        totals,
        count,
        source_order_id,
        selected_line_ids,
        refunds_covered_through,
        woo_client
      )
    end)
    |> case do
      {:ok, {totals, count}} -> {:ok, totals, count}
      {:error, reason} -> {:error, reason}
    end
  end

  defp accumulate_refund(
         refund_id,
         totals,
         count,
         source_order_id,
         selected_line_ids,
         refunds_covered_through,
         woo_client
       ) do
    case fetch_and_accumulate_refund(
           woo_client,
           source_order_id,
           refund_id,
           selected_line_ids,
           refunds_covered_through
         ) do
      {:ok, refund_totals} ->
        updated = FinancialPrimitives.add_totals(totals, refund_totals)
        {:cont, {:ok, {updated, count + 1}}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp parse_woo_refund_ids(order_payload) do
    case WoocommerceRefundReferenceParser.parse_historical(order_payload) do
      {:ok, references} ->
        {:ok, Enum.map(references, & &1.woo_refund_id) |> Enum.sort()}

      {:error, _reason} ->
        {:error, {:refund_identity_drift, %{reason: :invalid_refund_discovery}}}
    end
  end

  defp expected_present_refund_ids(membership) do
    case HistoricalRefundObservation
         |> Ash.Query.filter(historical_order_membership_id == ^membership.id)
         |> Ash.read_one(domain: Ingestion) do
      {:ok, nil} ->
        {:ok, []}

      {:ok, %HistoricalRefundObservation{} = observation} ->
        references =
          HistoricalRefundReference
          |> Ash.Query.filter(
            historical_refund_observation_id == ^observation.id and source_state == :present
          )
          |> Ash.read!(domain: Ingestion)

        {:ok, Enum.map(references, & &1.woo_refund_id) |> Enum.sort()}

      {:error, _reason} ->
        {:error, {:missing_source_fact, %{kind: :refund_reference_lookup}}}
    end
  end

  defp assert_refund_identity_sets(woo_ids, expected_ids, membership) do
    if woo_ids == expected_ids do
      :ok
    else
      {:error,
       {:refund_identity_drift,
        %{
          source_order_id: membership.source_order_id,
          woo_refund_ids: woo_ids,
          expected_refund_ids: expected_ids
        }}}
    end
  end

  defp fetch_and_accumulate_refund(
         woo_client,
         source_order_id,
         refund_id,
         selected_line_ids,
         refunds_covered_through
       ) do
    case woo_client.fetch_refund(source_order_id, refund_id, []) do
      {:ok, payload} when is_map(payload) ->
        with {:ok, normalized} <- WoocommerceRefundParser.parse(payload),
             :ok <-
               assert_refund_effective_time(normalized.source_created_at, refunds_covered_through) do
          {:ok, accumulate_refund_lines(normalized, selected_line_ids)}
        end

      {:error, :not_found} ->
        {:error,
         {:missing_source_fact,
          %{kind: :refund, source_order_id: source_order_id, woo_refund_id: refund_id}}}

      {:error, %{reason: :not_found}} ->
        {:error,
         {:missing_source_fact,
          %{kind: :refund, source_order_id: source_order_id, woo_refund_id: refund_id}}}

      {:error, _reason} ->
        {:error,
         {:missing_source_fact,
          %{
            kind: :refund_fetch_failed,
            source_order_id: source_order_id,
            woo_refund_id: refund_id
          }}}
    end
  end

  defp assert_refund_effective_time(nil, _boundary),
    do: {:error, {:timestamp_incomplete, %{field: :source_created_at}}}

  defp assert_refund_effective_time(%DateTime{} = created_at, %DateTime{} = boundary) do
    if DateTime.compare(created_at, boundary) in [:lt, :eq],
      do: :ok,
      else: {:error, {:timestamp_incomplete, %{field: :source_created_at, boundary: boundary}}}
  end

  defp accumulate_refund_lines(normalized, selected_line_ids) do
    Enum.reduce(normalized.line_items, FinancialPrimitives.empty_totals(), fn line, acc ->
      if refund_line_matches?(line, selected_line_ids) do
        add_refund_line(acc, line)
      else
        acc
      end
    end)
  end

  defp refund_line_matches?(line, selected_line_ids) do
    case Map.get(line, :woo_refunded_item_id) do
      id when is_integer(id) -> MapSet.member?(selected_line_ids, id)
      _ -> false
    end
  end

  defp add_refund_line(acc, line) do
    qty = FinancialPrimitives.refund_ticket_quantity(line.refunded_quantity || 0)

    value =
      FinancialPrimitives.refund_ticket_value(
        line.refund_total_amount,
        line.refund_total_tax
      )

    acc
    |> Map.update!(:refund_ticket_quantity, &Decimal.add(&1, qty))
    |> Map.update!(:refund_ticket_value, &Decimal.add(&1, value))
  end

  defp merge_acc(acc, update) do
    currencies =
      Enum.reduce(update.currencies, acc.currencies, fn {currency, totals}, merged ->
        Map.update(merged, currency, totals, &FinancialPrimitives.add_totals(&1, totals))
      end)

    %{
      currencies: currencies,
      source_orders_fetched: acc.source_orders_fetched + update.source_orders_fetched,
      source_refunds_fetched: acc.source_refunds_fetched + update.source_refunds_fetched,
      source_observed_at: later_datetime(acc.source_observed_at, update.source_observed_at)
    }
  end

  defp later_datetime(nil, %DateTime{} = right), do: right
  defp later_datetime(%DateTime{} = left, nil), do: left

  defp later_datetime(%DateTime{} = left, %DateTime{} = right) do
    if DateTime.compare(left, right) == :lt, do: right, else: left
  end

  defp finalize_acc(%SyncRun{} = run, acc) do
    currencies =
      Map.new(acc.currencies, fn {currency, totals} ->
        {currency, FinancialPrimitives.derive_net_totals(totals)}
      end)

    %{
      sync_run_id: run.id,
      event_id: run.event_id,
      source_system_id: run.source_system_id,
      coverage_start: run.coverage_start,
      sales_covered_through: run.sales_covered_through,
      refunds_covered_through: run.refunds_covered_through,
      currencies: currencies,
      source_orders_fetched: acc.source_orders_fetched,
      source_refunds_fetched: acc.source_refunds_fetched,
      source_observed_at: acc.source_observed_at
    }
  end

  defp parse_gmt_datetime(payload, key) do
    case blank_to_nil(Map.get(payload, key)) do
      nil ->
        {:ok, nil}

      value when is_binary(value) ->
        value
        |> NaiveDateTime.from_iso8601()
        |> case do
          {:ok, naive} -> {:ok, DateTime.from_naive!(naive, "Etc/UTC")}
          {:error, _} -> {:error, {:invalid_currency, %{field: key}}}
        end

      _other ->
        {:error, {:invalid_currency, %{field: key}}}
    end
  end

  defp parse_decimal(nil), do: Decimal.new("0")
  defp parse_decimal(%Decimal{} = value), do: value
  defp parse_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp parse_decimal(value) when is_binary(value), do: Decimal.new(value)

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _ -> 0
    end
  end

  defp positive_integer(_), do: 0

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp load_event(event_id) do
    case Ash.get(Event, event_id, domain: Catalog) do
      {:ok, %Event{} = event} -> {:ok, event}
      _ -> {:error, {:invalid_scope, %{reason: :event_missing}}}
    end
  end

  defp load_source_system(source_system_id) do
    case Ash.get(SourceSystem, source_system_id, domain: Catalog) do
      {:ok, %SourceSystem{} = source} -> {:ok, source}
      _ -> {:error, {:invalid_scope, %{reason: :source_missing}}}
    end
  end
end
