defmodule EventSales.Ingestion.HistoricalCoverageCertifier do
  @moduledoc """
  Evaluates durable authority for one historical SyncRun without performing writes.

  The evaluator combines terminal source evidence with aggregate local facts.
  It certifies the bounded M3 evidence contract only. It does not perform
  source HTTP, reconcile financial totals, or claim analytics readiness.
  """

  import Ecto.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Ingestion.HistoricalCatchupEvidence
  alias EventSales.Ingestion.HistoricalCoverageEvidence
  alias EventSales.Ingestion.HistoricalManifestEvidence
  alias EventSales.Ingestion.Resources.{SyncCursor, SyncRun}
  alias EventSales.Repo

  @type summary :: %{
          required(:coverage_start) => DateTime.t(),
          required(:sales_covered_through) => DateTime.t(),
          required(:refunds_covered_through) => DateTime.t(),
          required(:coverage_evidence) => HistoricalCoverageEvidence.t()
        }

  @type reason ::
          :invalid_input
          | :not_historical_backfill
          | :sync_run_not_running
          | :invalid_source_system_id
          | :missing_event_id
          | :invalid_backfill_start
          | :invalid_backfill_cutoff
          | :invalid_historical_bounds
          | :coverage_already_certified
          | :order_coverage_not_incomplete
          | :refund_coverage_not_incomplete
          | :orders_failed_count_nonzero
          | :errors_count_nonzero
          | :historical_event_missing
          | :historical_event_source_mismatch
          | :historical_event_not_backfill_pending
          | :missing_source_created_at
          | :historical_event_backfill_start_mismatch
          | :cursor_run_mismatch
          | :invalid_historical_cursor
          | :corrupt_cursor_metadata
          | :cursor_failure_metadata
          | :manifest_evidence_missing
          | :manifest_not_terminal
          | :corrupt_manifest_evidence
          | :catchup_evidence_missing
          | :catchup_not_terminal
          | :corrupt_catchup_evidence
          | :catchup_parent_binding_mismatch
          | :catchup_before_manifest
          | :historical_membership_incomplete
          | :historical_member_order_missing
          | :historical_member_attribution_incomplete
          | :nonmember_target_order_detected
          | :invalid_coverage_range
          | :coverage_evidence_invalid

  @spec evaluate(SyncRun.t(), SyncCursor.t(), keyword()) ::
          {:ok, summary()}
          | {:blocked, summary()}
          | {:retry, :coverage_evidence_read_failed}
          | {:error, reason()}
  def evaluate(run, cursor, opts \\ [])

  def evaluate(%SyncRun{} = run, %SyncCursor{} = cursor, opts) do
    with :ok <- validate_run(run),
         {:ok, event} <- load_event(run.event_id),
         :ok <- validate_event(event, run),
         :ok <- validate_cursor(cursor, run),
         {:ok, manifest} <- terminal_manifest(cursor.metadata),
         {:ok, catchup} <- terminal_catchup(cursor.metadata),
         :ok <- validate_parent_binding(catchup, manifest),
         :ok <- validate_coverage_range(event.source_created_at, run.date_to) do
      evaluate_durable_facts(run, event, manifest, catchup, opts)
    end
  end

  def evaluate(_run, _cursor, _opts), do: {:error, :invalid_input}

  defp evaluate_durable_facts(run, event, manifest, catchup, opts) do
    coverage_repo = Keyword.get(opts, :coverage_repo, Repo)

    try do
      case coverage_repo.transaction(fn ->
             order_facts =
               order_facts(run, event, event.source_created_at, run.date_to, coverage_repo)

             refund_facts =
               refund_facts(run, event, event.source_created_at, run.date_to, coverage_repo)

             build_summary(run, manifest, catchup, order_facts, refund_facts, opts)
           end) do
        {:ok, outcome} -> outcome
        {:error, _reason} -> {:retry, :coverage_evidence_read_failed}
      end
    rescue
      _error -> {:retry, :coverage_evidence_read_failed}
    catch
      :exit, _reason -> {:retry, :coverage_evidence_read_failed}
      :throw, _value -> {:retry, :coverage_evidence_read_failed}
    end
  end

  defp build_summary(run, manifest, catchup, order_facts, refund_facts, opts) do
    order_reasons = order_reason_counts(run, order_facts)
    refund_reasons = refund_reason_counts(refund_facts)

    result =
      if map_size(order_reasons) == 0 and map_size(refund_reasons) == 0,
        do: "certified",
        else: "blocked"

    evidence_attrs = %{
      manifest_hash: manifest.manifest_hash,
      manifest_terminal_evidence: manifest.terminal_evidence,
      catchup_hash: catchup.manifest_hash,
      catchup_terminal_evidence: catchup.terminal_evidence,
      orders: %{
        manifest_members_seen: run.orders_seen_count,
        orders_durable: order_facts.orders_durable,
        order_items_durable: order_facts.order_items_durable,
        blocking_unresolved_count: Enum.sum(Map.values(order_reasons)),
        blocking_reasons: order_reasons
      },
      refunds: %{
        references_seen: refund_facts.references_seen,
        details_complete: refund_facts.details_complete,
        refund_lines_durable: refund_facts.refund_lines_durable,
        blocking_unresolved_count: Enum.sum(Map.values(refund_reasons)),
        blocking_reasons: refund_reasons
      },
      result: result,
      evaluated_at: evaluation_now(opts)
    }

    case HistoricalCoverageEvidence.build(evidence_attrs) do
      {:ok, coverage_evidence} ->
        summary = %{
          coverage_start: event_source_created_at(manifest, run),
          sales_covered_through: run.date_to,
          refunds_covered_through: catchup.source_observed_at,
          coverage_evidence: coverage_evidence
        }

        if result == "certified", do: {:ok, summary}, else: {:blocked, summary}

      {:error, reason} ->
        {:error, {:coverage_evidence_invalid, reason}}
    end
  end

  defp event_source_created_at(_manifest, %SyncRun{date_from: date_from}), do: date_from

  defp evaluation_now(opts) do
    case Keyword.get(opts, :now) do
      now when is_function(now, 0) -> now.()
      %DateTime{} = now -> now
      _other -> DateTime.utc_now()
    end
  end

  defp order_facts(run, event, coverage_start, sales_covered_through, repo) do
    source_event_id = event.external_event_id || 0
    source_system_id = Ecto.UUID.dump!(run.source_system_id)
    event_id = Ecto.UUID.dump!(event.id)
    run_id = Ecto.UUID.dump!(run.id)

    query =
      from membership in "ingestion_historical_order_memberships",
        left_join: o in "sales_orders",
        on:
          o.source_system_id == ^source_system_id and
            o.woo_order_id == membership.source_order_id,
        left_join: oi in "sales_order_items",
        on:
          oi.order_id == o.id and
            (oi.event_id == ^event_id or oi.source_tickera_event_id == ^source_event_id),
        where: membership.sync_run_id == ^run_id,
        select: %{
          membership_count: fragment("COUNT(DISTINCT ?)", membership.id),
          member_order_missing:
            fragment("COUNT(DISTINCT ?) FILTER (WHERE ? IS NULL)", membership.id, o.id),
          historical_member_attribution_incomplete:
            fragment(
              "COUNT(DISTINCT ?) FILTER (WHERE (? = ? AND ? IS NULL) OR (? = ? AND ? IS NOT NULL))",
              membership.id,
              membership.event_match_state,
              ^"target",
              oi.id,
              membership.event_match_state,
              ^"non_target",
              oi.id
            ),
          orders_durable: fragment("COUNT(DISTINCT ?)", oi.order_id),
          order_items_durable: count(oi.id),
          pending_or_unmapped:
            fragment(
              "COUNT(*) FILTER (WHERE ? IN (?, ?))",
              oi.mapping_status,
              ^"pending_mapping_resolution",
              ^"unmapped"
            ),
          mapped_invalid:
            fragment(
              "COUNT(*) FILTER (WHERE ? = ? AND (? IS DISTINCT FROM ? OR ? IS NULL OR ? IS DISTINCT FROM ?))",
              oi.mapping_status,
              ^"mapped",
              oi.event_id,
              ^event_id,
              oi.ticket_type_id,
              oi.item_kind,
              ^"ticket"
            ),
          source_event_identity_conflict:
            fragment(
              "COUNT(*) FILTER (WHERE (? = ? AND ? IS NOT NULL AND ? IS DISTINCT FROM ?) OR (? = ? AND ? IS NOT NULL AND ? IS DISTINCT FROM ?))",
              oi.source_tickera_event_id,
              ^source_event_id,
              oi.event_id,
              oi.event_id,
              ^event_id,
              oi.event_id,
              ^event_id,
              oi.source_tickera_event_id,
              oi.source_tickera_event_id,
              ^source_event_id
            ),
          ticket_tax_missing:
            fragment(
              "COUNT(*) FILTER (WHERE ? = ? AND ? = ? AND ? = ? AND ? IS NULL)",
              oi.mapping_status,
              ^"mapped",
              oi.item_kind,
              ^"ticket",
              oi.event_id,
              ^event_id,
              oi.line_total_tax
            ),
          currency_missing:
            fragment(
              "COUNT(DISTINCT ?) FILTER (WHERE ? IS NULL OR btrim(?) = '')",
              o.id,
              o.currency,
              o.currency
            ),
          effective_time_missing:
            fragment(
              "COUNT(DISTINCT ?) FILTER (WHERE ? IN (?, ?) AND ? IS NULL AND ? IS NULL)",
              o.id,
              o.status,
              ^"completed",
              ^"refunded",
              o.paid_at,
              o.completed_at
            )
        }

    facts = repo.one!(query)

    Map.put(
      facts,
      :nonmember_target_orders,
      nonmember_target_order_count(
        run,
        event,
        coverage_start,
        sales_covered_through,
        source_system_id,
        event_id,
        source_event_id,
        repo
      )
    )
  end

  defp nonmember_target_order_count(
         run,
         _event,
         coverage_start,
         sales_covered_through,
         source_system_id,
         event_id,
         source_event_id,
         repo
       ) do
    run_id = Ecto.UUID.dump!(run.id)

    query =
      from oi in "sales_order_items",
        join: o in "sales_orders",
        on: o.id == oi.order_id,
        where:
          o.source_system_id == ^source_system_id and
            o.created_at_source >= ^coverage_start and
            o.created_at_source <= ^sales_covered_through and
            (oi.event_id == ^event_id or oi.source_tickera_event_id == ^source_event_id) and
            fragment(
              "NOT EXISTS (SELECT 1 FROM ingestion_historical_order_memberships AS m WHERE m.sync_run_id = ? AND m.source_order_id = ?)",
              ^run_id,
              o.woo_order_id
            ),
        select: fragment("COUNT(DISTINCT ?)", o.id)

    repo.one!(query)
  end

  defp order_reason_counts(run, facts) do
    facts
    |> Map.take([
      :pending_or_unmapped,
      :mapped_invalid,
      :source_event_identity_conflict,
      :ticket_tax_missing,
      :currency_missing,
      :effective_time_missing
    ])
    |> Map.merge(%{
      historical_membership_incomplete:
        if(facts.membership_count == run.orders_seen_count, do: 0, else: 1),
      historical_member_order_missing: facts.member_order_missing,
      historical_member_attribution_incomplete: facts.historical_member_attribution_incomplete,
      nonmember_target_order_detected: facts.nonmember_target_orders,
      order_history_incomplete: max(run.orders_matched_count - facts.orders_durable, 0),
      order_counter_inconsistent: if(counter_inconsistent?(run), do: 1, else: 0)
    })
    |> rename_order_reasons()
    |> nonzero_counts()
  end

  defp rename_order_reasons(counts) do
    %{
      "historical_membership_incomplete" => Map.get(counts, :historical_membership_incomplete, 0),
      "historical_member_order_missing" => Map.get(counts, :historical_member_order_missing, 0),
      "historical_member_attribution_incomplete" =>
        Map.get(counts, :historical_member_attribution_incomplete, 0),
      "nonmember_target_order_detected" => Map.get(counts, :nonmember_target_order_detected, 0),
      "attribution_incomplete" => Map.get(counts, :pending_or_unmapped, 0),
      "mapped_line_invalid" => Map.get(counts, :mapped_invalid, 0),
      "source_event_identity_conflict" => Map.get(counts, :source_event_identity_conflict, 0),
      "financial_primitive_incomplete" => Map.get(counts, :ticket_tax_missing, 0),
      "currency_incomplete" => Map.get(counts, :currency_missing, 0),
      "effective_time_incomplete" => Map.get(counts, :effective_time_missing, 0),
      "order_history_incomplete" => Map.get(counts, :order_history_incomplete, 0),
      "order_counter_inconsistent" => Map.get(counts, :order_counter_inconsistent, 0)
    }
  end

  defp counter_inconsistent?(run) do
    run.orders_matched_count > run.orders_seen_count or
      run.orders_matched_count != run.orders_upserted_count + run.orders_stale_count
  end

  defp refund_facts(run, event, coverage_start, sales_covered_through, repo) do
    source_event_id = event.external_event_id || 0
    source_system_id = Ecto.UUID.dump!(run.source_system_id)
    event_id = Ecto.UUID.dump!(event.id)
    run_id = Ecto.UUID.dump!(run.id)

    query =
      from membership in "ingestion_historical_order_memberships",
        join: o in "sales_orders",
        on:
          fragment(
            "? = ? AND ? = ?",
            o.source_system_id,
            ^source_system_id,
            o.woo_order_id,
            membership.source_order_id
          ),
        join: r in "sales_refunds",
        on:
          fragment(
            "? = ? AND ? = ?",
            r.source_system_id,
            o.source_system_id,
            r.woo_order_id,
            o.woo_order_id
          ),
        left_join: rl in "sales_refund_lines",
        on: rl.refund_id == r.id,
        left_join: oi in "sales_order_items",
        on: oi.id == rl.order_item_id,
        where:
          fragment("? = ?", membership.sync_run_id, ^run_id) and
            r.source_system_id == ^source_system_id and
            o.created_at_source >= ^coverage_start and
            o.created_at_source <= ^sales_covered_through and
            o.source_system_id == ^source_system_id and
            fragment(
              "EXISTS (SELECT 1 FROM sales_order_items AS target_oi WHERE target_oi.order_id = ? AND (target_oi.event_id = ? OR target_oi.source_tickera_event_id = ?))",
              o.id,
              ^event_id,
              ^source_event_id
            ),
        select: %{
          references_seen: fragment("COUNT(DISTINCT ?)", r.id),
          details_complete:
            fragment(
              "COUNT(DISTINCT ?) FILTER (WHERE ? = ? OR ? = ?)",
              r.id,
              r.source_state,
              ^"voided",
              r.detail_status,
              ^"complete"
            ),
          refund_lines_durable: fragment("COUNT(DISTINCT ?)", rl.id),
          detail_incomplete:
            fragment(
              "COUNT(DISTINCT ?) FILTER (WHERE ? = ? AND ? IS DISTINCT FROM ?)",
              r.id,
              r.source_state,
              ^"active",
              r.detail_status,
              ^"complete"
            ),
          effective_time_missing:
            fragment(
              "COUNT(DISTINCT ?) FILTER (WHERE ? = ? AND ? IS NULL)",
              r.id,
              r.source_state,
              ^"active",
              r.source_created_at
            ),
          parent_binding_incomplete:
            fragment(
              "COUNT(DISTINCT ?) FILTER (WHERE ? = ? AND (? IS NULL OR ? IS DISTINCT FROM ?))",
              r.id,
              r.source_state,
              ^"active",
              r.order_id,
              r.order_id,
              o.id
            ),
          line_binding_incomplete:
            fragment(
              "COUNT(DISTINCT ?) FILTER (WHERE ? = ? AND ? IS NOT NULL AND NOT (? IS NOT NULL AND (? IN (?, ?) OR ? = ? OR (? IS DISTINCT FROM ? AND ? IS DISTINCT FROM ?))) AND (? IS NULL OR ? IS NULL OR ? IS DISTINCT FROM ? OR ? IS DISTINCT FROM ? OR ? IS DISTINCT FROM ? OR ? IS DISTINCT FROM ? OR ? IS DISTINCT FROM ?))",
              r.id,
              r.source_state,
              ^"active",
              rl.id,
              oi.id,
              oi.mapping_status,
              ^"non_ticket",
              ^"ignored",
              oi.item_kind,
              ^"non_ticket",
              oi.event_id,
              ^event_id,
              oi.source_tickera_event_id,
              ^source_event_id,
              rl.woo_refunded_item_id,
              rl.order_item_id,
              oi.order_id,
              o.id,
              oi.event_id,
              ^event_id,
              oi.mapping_status,
              ^"mapped",
              oi.item_kind,
              ^"ticket",
              oi.woo_line_item_id,
              rl.woo_refunded_item_id
            ),
          line_validation_conflict:
            fragment(
              "COUNT(DISTINCT ?) FILTER (WHERE ? = ? AND ? IS NOT NULL AND (? = ? OR ? = ?) AND ? = ? AND ? = ? AND (? IS NOT NULL OR ? IS NOT NULL OR (? IS NOT NULL AND ? IS DISTINCT FROM ?) OR (? IS NOT NULL AND ? IS DISTINCT FROM ?)))",
              rl.id,
              r.source_state,
              ^"active",
              oi.id,
              oi.event_id,
              ^event_id,
              oi.source_tickera_event_id,
              ^source_event_id,
              oi.mapping_status,
              ^"mapped",
              oi.item_kind,
              ^"ticket",
              rl.binding_reason,
              rl.validation_reason,
              rl.woo_product_id,
              rl.woo_product_id,
              oi.woo_product_id,
              rl.woo_variation_id,
              rl.woo_variation_id,
              oi.woo_variation_id
            ),
          header_financial_missing:
            fragment(
              "COUNT(DISTINCT ?) FILTER (WHERE ? = ? AND ? = ? AND ? IS NULL)",
              r.id,
              r.source_state,
              ^"active",
              r.detail_status,
              ^"complete",
              r.header_amount
            ),
          currency_incomplete:
            fragment(
              "COUNT(DISTINCT ?) FILTER (WHERE ? IS NULL OR btrim(?) = '' OR ? IS DISTINCT FROM ?)",
              r.id,
              r.currency,
              r.currency,
              r.currency,
              o.currency
            )
        }

    base = repo.one!(query)

    line_financial_missing =
      refund_ticket_line_financial_count(
        run,
        event,
        coverage_start,
        sales_covered_through,
        repo
      )

    Map.put(base, :ticket_line_financial_missing, line_financial_missing)
  end

  defp refund_ticket_line_financial_count(
         run,
         event,
         coverage_start,
         sales_covered_through,
         repo
       ) do
    source_system_id = Ecto.UUID.dump!(run.source_system_id)
    event_id = Ecto.UUID.dump!(event.id)
    run_id = Ecto.UUID.dump!(run.id)

    query =
      from membership in "ingestion_historical_order_memberships",
        join: o in "sales_orders",
        on:
          fragment(
            "? = ? AND ? = ?",
            o.source_system_id,
            ^source_system_id,
            o.woo_order_id,
            membership.source_order_id
          ),
        join: r in "sales_refunds",
        on:
          fragment(
            "? = ? AND ? = ?",
            r.source_system_id,
            o.source_system_id,
            r.woo_order_id,
            o.woo_order_id
          ),
        join: rl in "sales_refund_lines",
        on: rl.refund_id == r.id,
        join: oi in "sales_order_items",
        on: oi.id == rl.order_item_id,
        where:
          fragment("? = ?", membership.sync_run_id, ^run_id) and
            r.source_system_id == ^source_system_id and
            o.created_at_source >= ^coverage_start and
            o.created_at_source <= ^sales_covered_through and
            r.source_state == ^"active" and
            r.detail_status == ^"complete" and
            oi.event_id == ^event_id and
            oi.item_kind == ^"ticket" and
            fragment("? IS NULL OR ? IS NULL", rl.refund_total_amount, rl.refund_total_tax),
        select: count(rl.id)

    repo.one!(query)
  end

  defp refund_reason_counts(facts) do
    %{
      "refund_detail_incomplete" => facts.detail_incomplete,
      "refund_effective_time_incomplete" => facts.effective_time_missing,
      "refund_parent_binding_incomplete" => facts.parent_binding_incomplete,
      "refund_line_binding_incomplete" => facts.line_binding_incomplete,
      "refund_line_validation_conflict" => facts.line_validation_conflict,
      "refund_financial_primitive_incomplete" =>
        facts.header_financial_missing + facts.ticket_line_financial_missing,
      "refund_currency_incomplete" => facts.currency_incomplete
    }
    |> nonzero_counts()
  end

  defp nonzero_counts(counts) do
    Map.reject(counts, fn {_key, count} -> count == 0 end)
  end

  defp validate_run(%SyncRun{sync_type: :historical_backfill, status: :running} = run) do
    with :ok <- validate_run_identity(run),
         :ok <- validate_run_bounds(run),
         :ok <- validate_run_coverage(run) do
      validate_run_failures(run)
    end
  end

  defp validate_run(%SyncRun{sync_type: :historical_backfill}),
    do: {:error, :sync_run_not_running}

  defp validate_run(%SyncRun{}), do: {:error, :not_historical_backfill}

  defp validate_run_identity(run) do
    cond do
      not valid_uuid?(run.source_system_id) -> {:error, :invalid_source_system_id}
      not valid_uuid?(run.event_id) -> {:error, :missing_event_id}
      true -> :ok
    end
  end

  defp validate_run_bounds(run) do
    cond do
      not utc_datetime?(run.date_from) ->
        {:error, :invalid_backfill_start}

      not utc_datetime?(run.date_to) ->
        {:error, :invalid_backfill_cutoff}

      DateTime.compare(run.date_from, run.date_to) == :gt ->
        {:error, :invalid_historical_bounds}

      true ->
        :ok
    end
  end

  defp validate_run_coverage(run) do
    cond do
      not is_nil(run.coverage_certified_at) ->
        {:error, :coverage_already_certified}

      run.order_coverage_status != :incomplete ->
        {:error, :order_coverage_not_incomplete}

      run.refund_coverage_status not in [:not_started, :incomplete] ->
        {:error, :refund_coverage_not_incomplete}

      true ->
        :ok
    end
  end

  defp validate_run_failures(run) do
    cond do
      run.orders_failed_count != 0 -> {:error, :orders_failed_count_nonzero}
      run.errors_count != 0 -> {:error, :errors_count_nonzero}
      true -> :ok
    end
  end

  defp load_event(event_id) do
    case Ash.get(Event, event_id, domain: Catalog) do
      {:ok, %Event{} = event} -> {:ok, event}
      _other -> {:error, :historical_event_missing}
    end
  end

  defp validate_event(%Event{} = event, %SyncRun{} = run) do
    cond do
      event.id != run.event_id ->
        {:error, :historical_event_missing}

      event.source_system_id != run.source_system_id ->
        {:error, :historical_event_source_mismatch}

      event.analytics_onboarding_state != :backfill_pending ->
        {:error, :historical_event_not_backfill_pending}

      not utc_datetime?(event.source_created_at) ->
        {:error, :missing_source_created_at}

      not same_datetime?(event.source_created_at, run.date_from) ->
        {:error, :historical_event_backfill_start_mismatch}

      true ->
        :ok
    end
  end

  defp validate_cursor(%SyncCursor{sync_run_id: sync_run_id}, %SyncRun{id: run_id})
       when sync_run_id != run_id,
       do: {:error, :cursor_run_mismatch}

  defp validate_cursor(%SyncCursor{status: status}, _run) when status != :active,
    do: {:error, :invalid_historical_cursor}

  defp validate_cursor(%SyncCursor{metadata: metadata}, _run) when not is_map(metadata),
    do: {:error, :corrupt_cursor_metadata}

  defp validate_cursor(%SyncCursor{metadata: metadata}, _run) do
    if Map.has_key?(metadata, "failure"),
      do: {:error, :cursor_failure_metadata},
      else: :ok
  end

  defp terminal_manifest(metadata) when is_map(metadata) do
    case HistoricalManifestEvidence.state(metadata) do
      :manifest_terminal ->
        case HistoricalManifestEvidence.from_metadata(metadata) do
          {:ok, manifest} -> {:ok, manifest}
          {:error, _reason} -> {:error, :corrupt_manifest_evidence}
        end

      :missing ->
        {:error, :manifest_evidence_missing}

      :corrupt ->
        {:error, :corrupt_manifest_evidence}

      _other ->
        {:error, :manifest_not_terminal}
    end
  end

  defp terminal_manifest(_metadata), do: {:error, :corrupt_manifest_evidence}

  defp terminal_catchup(metadata) when is_map(metadata) do
    case HistoricalCatchupEvidence.state(metadata) do
      :catchup_terminal ->
        case HistoricalCatchupEvidence.from_metadata(metadata) do
          {:ok, catchup} -> {:ok, catchup}
          {:error, _reason} -> {:error, :corrupt_catchup_evidence}
        end

      :missing ->
        {:error, :catchup_evidence_missing}

      :corrupt ->
        {:error, :corrupt_catchup_evidence}

      _other ->
        {:error, :catchup_not_terminal}
    end
  end

  defp terminal_catchup(_metadata), do: {:error, :corrupt_catchup_evidence}

  defp validate_parent_binding(catchup, manifest) do
    case HistoricalCatchupEvidence.validate_parent_binding(catchup, manifest) do
      :ok -> :ok
      {:error, :catchup_high_water_before_parent} -> {:error, :catchup_before_manifest}
      {:error, _reason} -> {:error, :catchup_parent_binding_mismatch}
    end
  end

  defp validate_coverage_range(%DateTime{} = coverage_start, %DateTime{} = sales_covered_through) do
    if DateTime.compare(coverage_start, sales_covered_through) in [:lt, :eq],
      do: :ok,
      else: {:error, :invalid_coverage_range}
  end

  defp validate_coverage_range(_coverage_start, _sales_covered_through),
    do: {:error, :invalid_coverage_range}

  defp same_datetime?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp same_datetime?(_left, _right), do: false

  defp valid_uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp valid_uuid?(_value), do: false

  defp utc_datetime?(%DateTime{} = value) do
    value.time_zone == "Etc/UTC" and value.utc_offset == 0 and value.std_offset == 0
  end

  defp utc_datetime?(_value), do: false
end
