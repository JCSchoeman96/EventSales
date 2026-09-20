defmodule EventSales.Ingestion.FinancialReconciliation.LocalTotals do
  @moduledoc """
  Independent Postgres local-side financial totals for one exact M3 certificate.

  Reads durable Sales facts through bounded aggregate queries. It never calls
  WooCommerce or mutates state.
  """

  import Ecto.Query

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, SourceSystem}
  alias EventSales.Ingestion.HistoricalCoverageResolver
  alias EventSales.Ingestion.Resources.SyncRun
  alias EventSales.Repo
  alias EventSales.Sales.FinancialPrimitives

  @type structural_category ::
          :invalid_scope
          | :missing_local_fact
          | :financial_primitive_incomplete
          | :currency_conflict
          | :timestamp_incomplete
          | :unresolved_attribution
          | :historical_recognition_unproven

  @type structural_error :: {structural_category(), map()}

  @type currency_totals :: %{FinancialPrimitives.primitive() => Decimal.t()}

  @type result :: %{
          sync_run_id: String.t(),
          event_id: String.t(),
          source_system_id: String.t(),
          coverage_start: DateTime.t(),
          sales_covered_through: DateTime.t(),
          refunds_covered_through: DateTime.t(),
          currencies: %{String.t() => currency_totals()}
        }

  @type scope :: %{
          run_id: binary(),
          source_system_id: binary(),
          event_id: binary(),
          refunds_covered_through: DateTime.t()
        }

  @doc """
  Extracts local financial totals for the current M3 certificate of one Event.
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
  Extracts local financial totals for one exact certified historical SyncRun.
  """
  @spec extract_for_run(SyncRun.t(), Event.t(), SourceSystem.t(), keyword()) ::
          {:ok, result()} | {:error, structural_error()}
  def extract_for_run(%SyncRun{} = run, %Event{} = event, %SourceSystem{} = source, opts \\ [])
      when is_list(opts) do
    scope = build_scope(run, event.id)

    with :ok <- validate_run_scope(run, event, source),
         :ok <- assert_current_certificate(run, event),
         :ok <- validate_membership_integrity(scope),
         :ok <- validate_financial_integrity(scope),
         {:ok, scope_currencies} <- list_scope_currencies(scope),
         {:ok, gross_by_currency} <- aggregate_gross_totals(scope),
         {:ok, refund_by_currency} <- aggregate_refund_totals(scope) do
      {:ok, build_result(run, scope_currencies, gross_by_currency, refund_by_currency)}
    end
  end

  defp build_scope(%SyncRun{} = run, event_id) do
    %{
      run_id: Ecto.UUID.dump!(run.id),
      source_system_id: Ecto.UUID.dump!(run.source_system_id),
      event_id: Ecto.UUID.dump!(event_id),
      refunds_covered_through: run.refunds_covered_through
    }
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

  defp assert_current_certificate(%SyncRun{id: run_id}, %Event{id: event_id}) do
    case HistoricalCoverageResolver.resolve_current(event_id) do
      {:ok, %SyncRun{id: ^run_id}} ->
        :ok

      {:ok, %SyncRun{}} ->
        {:error, {:invalid_scope, %{reason: :historical_certificate_not_current}}}

      {:error, :historical_coverage_not_current} ->
        {:error, {:invalid_scope, %{reason: :historical_certificate_not_current}}}

      {:error, reason} ->
        {:error, {:invalid_scope, %{reason: reason}}}
    end
  end

  defp validate_membership_integrity(scope) do
    case first_violation(membership_integrity_queries(scope)) do
      nil -> :ok
      violation -> membership_violation_to_error(violation)
    end
  end

  defp validate_financial_integrity(scope) do
    case first_violation(financial_integrity_queries(scope)) do
      nil -> :ok
      violation -> financial_violation_to_error(violation, scope.refunds_covered_through)
    end
  end

  defp first_violation(queries) do
    Enum.find_value(queries, fn query ->
      case Repo.one(query) do
        nil -> nil
        violation -> violation
      end
    end)
  end

  defp membership_integrity_queries(scope) do
    memberships = target_memberships_subquery(scope)

    [
      missing_order_query(scope, memberships),
      missing_observation_query(memberships),
      reference_mismatch_query(memberships),
      historical_recognition_unproven_query(scope, memberships),
      missing_order_currency_query(scope, memberships)
    ]
  end

  defp financial_integrity_queries(scope) do
    present_refunds = present_refund_refs_subquery(scope)
    present_lines = present_refund_lines_subquery(scope, present_refunds)

    [
      incomplete_gross_line_query(scope),
      missing_refund_query(scope, present_refunds),
      inactive_refund_query(scope, present_refunds),
      incomplete_refund_query(scope, present_refunds),
      missing_refund_effective_time_query(scope, present_refunds),
      refund_after_boundary_query(scope, present_refunds),
      refund_currency_invalid_query(scope, present_refunds),
      refund_parent_nil_query(scope, present_refunds),
      refund_parent_wrong_query(scope, present_refunds),
      unresolved_refund_line_query(scope, present_lines),
      incomplete_refund_line_query(scope, present_lines)
    ]
  end

  defp target_memberships_subquery(scope) do
    from hom in "ingestion_historical_order_memberships",
      where: hom.sync_run_id == ^scope.run_id and hom.event_match_state == "target",
      select: %{
        membership_id: hom.id,
        source_order_id: hom.source_order_id
      }
  end

  defp member_order_on(scope) do
    dynamic(
      [row, o],
      o.source_system_id == ^scope.source_system_id and o.woo_order_id == row.source_order_id
    )
  end

  defp refund_identity_on(scope) do
    dynamic(
      [row, r],
      r.source_system_id == ^scope.source_system_id and r.woo_order_id == row.source_order_id and
        r.woo_refund_id == row.woo_refund_id
    )
  end

  defp refund_identity_after_order_on(scope) do
    dynamic(
      [row, _o, r],
      r.source_system_id == ^scope.source_system_id and r.woo_order_id == row.source_order_id and
        r.woo_refund_id == row.woo_refund_id
    )
  end

  defp member_refund_on(scope) do
    dynamic(
      [row, o, r],
      o.source_system_id == ^scope.source_system_id and o.woo_order_id == row.source_order_id and
        r.source_system_id == ^scope.source_system_id and r.woo_order_id == row.source_order_id and
        r.woo_refund_id == row.woo_refund_id and r.order_id == o.id
    )
  end

  defp missing_order_query(scope, memberships) do
    from row in subquery(memberships),
      left_join: o in "sales_orders",
      on: ^member_order_on(scope),
      where: is_nil(o.id),
      select: {:missing_order, row.source_order_id},
      limit: 1
  end

  defp missing_observation_query(memberships) do
    from row in subquery(memberships),
      left_join: obs in "ingestion_historical_refund_observations",
      on: obs.historical_order_membership_id == row.membership_id,
      where: is_nil(obs.id),
      select: {:missing_refund_observation, row.source_order_id},
      limit: 1
  end

  defp present_ref_counts_subquery do
    from ref in "ingestion_historical_refund_references",
      where: ref.source_state == "present",
      group_by: ref.historical_refund_observation_id,
      select: %{
        observation_id: ref.historical_refund_observation_id,
        present_count: count(ref.id)
      }
  end

  defp reference_mismatch_query(memberships) do
    from row in subquery(memberships),
      join: obs in "ingestion_historical_refund_observations",
      on: obs.historical_order_membership_id == row.membership_id,
      left_join: counts in subquery(present_ref_counts_subquery()),
      on: counts.observation_id == obs.id,
      where: obs.reference_count != coalesce(counts.present_count, 0),
      select:
        {:refund_reference_count_mismatch, row.source_order_id, obs.reference_count,
         coalesce(counts.present_count, 0)},
      limit: 1
  end

  defp historical_recognition_unproven_query(scope, memberships) do
    from row in subquery(memberships),
      join: o in "sales_orders",
      on: ^member_order_on(scope),
      join: obs in "ingestion_historical_refund_observations",
      on: obs.historical_order_membership_id == row.membership_id,
      join: ref in "ingestion_historical_refund_references",
      on: ref.historical_refund_observation_id == obs.id and ref.source_state == "present",
      where: o.status != "completed" and is_nil(o.completed_at),
      select: {:historical_recognition_unproven, row.source_order_id},
      limit: 1
  end

  defp missing_order_currency_query(scope, memberships) do
    from row in subquery(memberships),
      join: o in "sales_orders",
      on: ^member_order_on(scope),
      where: is_nil(o.currency) or fragment("btrim(?) = ''", o.currency),
      select: {:missing_currency, row.source_order_id},
      limit: 1
  end

  defp present_refund_refs_subquery(scope) do
    from hom in "ingestion_historical_order_memberships",
      join: obs in "ingestion_historical_refund_observations",
      on: obs.historical_order_membership_id == hom.id,
      join: ref in "ingestion_historical_refund_references",
      on: ref.historical_refund_observation_id == obs.id and ref.source_state == "present",
      where: hom.sync_run_id == ^scope.run_id and hom.event_match_state == "target",
      select: %{
        source_order_id: hom.source_order_id,
        woo_refund_id: ref.woo_refund_id
      }
  end

  defp historically_recognised_order do
    dynamic([_hom, o, _oi], o.status == "completed" or not is_nil(o.completed_at))
  end

  defp gross_target_ticket_where(scope) do
    dynamic(
      [hom, o, oi],
      hom.sync_run_id == ^scope.run_id and hom.event_match_state == "target" and
        ^historically_recognised_order() and oi.event_id == ^scope.event_id and
        oi.mapping_status == "mapped" and oi.item_kind == "ticket" and oi.quantity > 0
    )
  end

  defp incomplete_gross_line_fields do
    dynamic([_hom, _o, oi], is_nil(oi.line_total) or is_nil(oi.line_total_tax))
  end

  defp incomplete_gross_line_where(scope) do
    dynamic(
      [hom, o, oi],
      hom.sync_run_id == ^scope.run_id and hom.event_match_state == "target" and
        ^historically_recognised_order() and oi.event_id == ^scope.event_id and
        oi.mapping_status == "mapped" and oi.item_kind == "ticket" and oi.quantity > 0 and
        ^incomplete_gross_line_fields()
    )
  end

  defp incomplete_gross_line_query(scope) do
    from hom in "ingestion_historical_order_memberships",
      join: o in "sales_orders",
      on: o.source_system_id == ^scope.source_system_id and o.woo_order_id == hom.source_order_id,
      join: oi in "sales_order_items",
      on: oi.order_id == o.id,
      where: ^incomplete_gross_line_where(scope),
      select:
        {:incomplete_gross_line, hom.source_order_id, oi.woo_line_item_id,
         fragment(
           "CASE WHEN ? IS NULL THEN 'line_total' ELSE 'line_total_tax' END",
           oi.line_total
         )},
      limit: 1
  end

  defp missing_refund_query(scope, present_refunds) do
    from row in subquery(present_refunds),
      left_join: r in "sales_refunds",
      on: ^refund_identity_on(scope),
      where: is_nil(r.id),
      select: {:missing_refund, row.source_order_id, row.woo_refund_id},
      limit: 1
  end

  defp inactive_refund_query(scope, present_refunds) do
    from row in subquery(present_refunds),
      join: r in "sales_refunds",
      on: ^refund_identity_on(scope),
      where: r.source_state != "active",
      select: {:inactive_refund, row.source_order_id, row.woo_refund_id},
      limit: 1
  end

  defp incomplete_refund_query(scope, present_refunds) do
    from row in subquery(present_refunds),
      join: r in "sales_refunds",
      on: ^refund_identity_on(scope),
      where: r.detail_status != "complete",
      select: {:incomplete_refund, row.source_order_id, row.woo_refund_id},
      limit: 1
  end

  defp missing_refund_effective_time_query(scope, present_refunds) do
    from row in subquery(present_refunds),
      join: r in "sales_refunds",
      on: ^refund_identity_on(scope),
      where: is_nil(r.source_created_at),
      select: {:missing_refund_effective_time, row.source_order_id, row.woo_refund_id},
      limit: 1
  end

  defp refund_after_boundary_query(scope, present_refunds) do
    from row in subquery(present_refunds),
      join: r in "sales_refunds",
      on: ^refund_identity_on(scope),
      where: r.source_created_at > ^scope.refunds_covered_through,
      select: {:refund_after_boundary, row.source_order_id, row.woo_refund_id},
      limit: 1
  end

  defp refund_currency_invalid_query(scope, present_refunds) do
    from row in subquery(present_refunds),
      join: o in "sales_orders",
      on: ^member_order_on(scope),
      join: r in "sales_refunds",
      on: ^refund_identity_after_order_on(scope),
      where:
        is_nil(r.currency) or fragment("btrim(?) = ''", r.currency) or
          fragment("? IS DISTINCT FROM ?", r.currency, o.currency),
      select: {:refund_currency_mismatch, row.source_order_id, row.woo_refund_id},
      limit: 1
  end

  defp refund_parent_nil_query(scope, present_refunds) do
    from row in subquery(present_refunds),
      join: o in "sales_orders",
      on: ^member_order_on(scope),
      join: r in "sales_refunds",
      on: ^refund_identity_after_order_on(scope),
      where: is_nil(r.order_id),
      select: {:refund_parent_nil, row.source_order_id, row.woo_refund_id},
      limit: 1
  end

  defp refund_parent_wrong_query(scope, present_refunds) do
    from row in subquery(present_refunds),
      join: o in "sales_orders",
      on: ^member_order_on(scope),
      join: r in "sales_refunds",
      on: ^refund_identity_after_order_on(scope),
      where: not is_nil(r.order_id) and r.order_id != o.id,
      select: {:refund_parent_wrong, row.source_order_id, row.woo_refund_id},
      limit: 1
  end

  defp event_ticket_items_subquery(scope) do
    from oi in "sales_order_items",
      where:
        oi.event_id == ^scope.event_id and oi.mapping_status == "mapped" and
          oi.item_kind == "ticket",
      select: %{
        id: oi.id,
        order_id: oi.order_id,
        woo_line_item_id: oi.woo_line_item_id
      }
  end

  defp present_refund_lines_subquery(scope, present_refunds) do
    from row in subquery(present_refunds),
      join: o in "sales_orders",
      on: ^member_order_on(scope),
      join: r in "sales_refunds",
      on: ^member_refund_on(scope),
      join: rl in "sales_refund_lines",
      on: rl.refund_id == r.id,
      select: %{
        source_order_id: row.source_order_id,
        woo_refund_id: row.woo_refund_id,
        member_order_id: o.id,
        woo_refunded_item_id: rl.woo_refunded_item_id,
        order_item_id: rl.order_item_id,
        binding_reason: rl.binding_reason,
        validation_reason: rl.validation_reason,
        refund_total_amount: rl.refund_total_amount,
        refund_total_tax: rl.refund_total_tax
      }
  end

  defp unresolved_refund_line_binder_violation do
    dynamic(
      [row, parent, bound],
      is_nil(row.woo_refunded_item_id) or is_nil(parent.id) or is_nil(row.order_item_id) or
        row.order_item_id != parent.id or
        (not is_nil(row.order_item_id) and
           (is_nil(bound.id) or bound.order_id != row.member_order_id))
    )
  end

  defp unresolved_refund_line_attribution_violation do
    dynamic(
      [row, ticket],
      not is_nil(ticket.id) and
        (not is_nil(row.binding_reason) or not is_nil(row.validation_reason))
    )
  end

  defp unresolved_refund_line_where do
    dynamic(
      [row, parent, bound, ticket],
      ^unresolved_refund_line_binder_violation() or
        ^unresolved_refund_line_attribution_violation()
    )
  end

  defp unresolved_refund_line_query(scope, present_lines) do
    tickets = event_ticket_items_subquery(scope)

    from row in subquery(present_lines),
      left_join: parent in "sales_order_items",
      on:
        parent.order_id == row.member_order_id and
          parent.woo_line_item_id == row.woo_refunded_item_id,
      left_join: bound in "sales_order_items",
      on: bound.id == row.order_item_id,
      left_join: ticket in subquery(tickets),
      on: ticket.id == parent.id,
      where: ^unresolved_refund_line_where(),
      select:
        {:unresolved_refund_line, row.source_order_id, row.woo_refund_id,
         fragment(
           "CASE
              WHEN ? IS NULL THEN 'missing_refunded_item_id'
              WHEN ? IS NULL THEN 'unknown_parent_line_binder'
              WHEN ? IS NOT NULL AND ? IS NOT NULL THEN 'binding_reason'
              WHEN ? IS NOT NULL AND ? IS NOT NULL THEN 'validation_reason'
              WHEN ? IS NOT NULL AND ? IS NOT NULL AND ? != ? THEN 'cross_order_binder'
              WHEN ? IS NULL THEN 'binder_mismatch'
              WHEN ? != ? THEN 'binder_mismatch'
              ELSE 'binder_mismatch'
            END",
           row.woo_refunded_item_id,
           parent.id,
           ticket.id,
           row.binding_reason,
           ticket.id,
           row.validation_reason,
           row.order_item_id,
           bound.id,
           bound.order_id,
           row.member_order_id,
           row.order_item_id,
           row.order_item_id,
           parent.id
         )},
      limit: 1
  end

  defp incomplete_refund_line_query(scope, present_lines) do
    tickets = event_ticket_items_subquery(scope)

    from row in subquery(present_lines),
      join: parent in "sales_order_items",
      on:
        parent.order_id == row.member_order_id and
          parent.woo_line_item_id == row.woo_refunded_item_id and
          parent.id == row.order_item_id,
      join: ticket in subquery(tickets),
      on: ticket.id == parent.id,
      where: is_nil(row.refund_total_amount) or is_nil(row.refund_total_tax),
      select:
        {:incomplete_refund_line, row.source_order_id, row.woo_refund_id,
         fragment(
           "CASE WHEN ? IS NULL THEN 'refund_total_amount' ELSE 'refund_total_tax' END",
           row.refund_total_amount
         )},
      limit: 1
  end

  defp membership_violation_to_error({:missing_order, source_order_id}) do
    {:error, {:missing_local_fact, %{kind: :order, source_order_id: source_order_id}}}
  end

  defp membership_violation_to_error({:missing_refund_observation, source_order_id}) do
    {:error,
     {:missing_local_fact, %{kind: :refund_observation, source_order_id: source_order_id}}}
  end

  defp membership_violation_to_error(
         {:refund_reference_count_mismatch, source_order_id, reference_count, present_count}
       ) do
    {:error,
     {:missing_local_fact,
      %{
        kind: :refund_reference_inconsistent,
        source_order_id: source_order_id,
        reference_count: reference_count,
        present_reference_count: present_count
      }}}
  end

  defp membership_violation_to_error({:historical_recognition_unproven, source_order_id}) do
    {:error, {:historical_recognition_unproven, %{source_order_id: source_order_id}}}
  end

  defp membership_violation_to_error({:missing_currency, source_order_id}) do
    {:error, {:currency_conflict, %{source_order_id: source_order_id, field: :currency}}}
  end

  defp membership_violation_to_error(other) do
    {:error, {:missing_local_fact, %{kind: other}}}
  end

  defp financial_violation_to_error(
         {:incomplete_gross_line, source_order_id, line_id, field},
         _boundary
       ) do
    {:error,
     {:financial_primitive_incomplete,
      %{
        field: normalize_field(field),
        woo_line_item_id: line_id,
        source_order_id: source_order_id,
        reason: :missing
      }}}
  end

  defp financial_violation_to_error({:missing_refund, source_order_id, woo_refund_id}, _boundary) do
    {:error,
     {:missing_local_fact,
      %{kind: :refund, source_order_id: source_order_id, woo_refund_id: woo_refund_id}}}
  end

  defp financial_violation_to_error({:inactive_refund, source_order_id, woo_refund_id}, _boundary) do
    {:error,
     {:missing_local_fact,
      %{
        kind: :refund_not_active,
        source_order_id: source_order_id,
        woo_refund_id: woo_refund_id
      }}}
  end

  defp financial_violation_to_error(
         {:incomplete_refund, source_order_id, woo_refund_id},
         _boundary
       ) do
    {:error,
     {:missing_local_fact,
      %{
        kind: :refund_not_complete,
        source_order_id: source_order_id,
        woo_refund_id: woo_refund_id
      }}}
  end

  defp financial_violation_to_error(
         {:missing_refund_effective_time, source_order_id, woo_refund_id},
         _boundary
       ) do
    {:error,
     {:timestamp_incomplete,
      %{
        field: :source_created_at,
        source_order_id: source_order_id,
        woo_refund_id: woo_refund_id
      }}}
  end

  defp financial_violation_to_error(
         {:refund_after_boundary, source_order_id, woo_refund_id},
         boundary
       ) do
    {:error,
     {:timestamp_incomplete,
      %{
        field: :source_created_at,
        source_order_id: source_order_id,
        woo_refund_id: woo_refund_id,
        boundary: boundary
      }}}
  end

  defp financial_violation_to_error(
         {:refund_currency_mismatch, source_order_id, woo_refund_id},
         _boundary
       ) do
    {:error,
     {:currency_conflict, %{source_order_id: source_order_id, woo_refund_id: woo_refund_id}}}
  end

  defp financial_violation_to_error(
         {:refund_parent_nil, source_order_id, woo_refund_id},
         _boundary
       ) do
    {:error,
     {:missing_local_fact,
      %{
        kind: :refund_parent_binding,
        source_order_id: source_order_id,
        woo_refund_id: woo_refund_id
      }}}
  end

  defp financial_violation_to_error(
         {:refund_parent_wrong, source_order_id, woo_refund_id},
         _boundary
       ) do
    {:error,
     {:missing_local_fact,
      %{
        kind: :refund_parent_binding,
        source_order_id: source_order_id,
        woo_refund_id: woo_refund_id
      }}}
  end

  defp financial_violation_to_error(
         {:unresolved_refund_line, source_order_id, woo_refund_id, reason},
         _boundary
       ) do
    {:error,
     {:unresolved_attribution,
      %{
        source_order_id: source_order_id,
        woo_refund_id: woo_refund_id,
        reason: reason
      }}}
  end

  defp financial_violation_to_error(
         {:incomplete_refund_line, source_order_id, woo_refund_id, field},
         _boundary
       ) do
    {:error,
     {:financial_primitive_incomplete,
      %{
        field: normalize_field(field),
        source_order_id: source_order_id,
        woo_refund_id: woo_refund_id,
        reason: :missing
      }}}
  end

  defp list_scope_currencies(scope) do
    memberships = target_memberships_subquery(scope)

    query =
      from row in subquery(memberships),
        join: o in "sales_orders",
        on: ^member_order_on(scope),
        distinct: o.currency,
        select: o.currency,
        order_by: o.currency

    currencies = Repo.all(query)

    {:ok, currencies}
  end

  defp aggregate_gross_totals(scope) do
    {:ok, map_gross_currency_totals(Repo.all(gross_totals_aggregate_query(scope)))}
  end

  defp gross_totals_aggregate_query(scope) do
    from hom in "ingestion_historical_order_memberships",
      join: o in "sales_orders",
      on: o.source_system_id == ^scope.source_system_id and o.woo_order_id == hom.source_order_id,
      join: oi in "sales_order_items",
      on: oi.order_id == o.id,
      where: ^gross_target_ticket_where(scope),
      group_by: o.currency,
      select:
        {o.currency, sum(oi.quantity), sum(fragment("? + ?", oi.line_total, oi.line_total_tax))}
  end

  defp aggregate_refund_totals(scope) do
    {:ok, map_refund_currency_totals(Repo.all(refund_totals_aggregate_query(scope)))}
  end

  defp member_refund_aggregate_on(scope) do
    dynamic(
      [hom, _obs, href, o, r],
      r.source_system_id == ^scope.source_system_id and r.woo_order_id == hom.source_order_id and
        r.woo_refund_id == href.woo_refund_id and r.order_id == o.id
    )
  end

  defp refund_totals_aggregate_query(scope) do
    tickets = event_ticket_items_subquery(scope)

    from hom in "ingestion_historical_order_memberships",
      join: obs in "ingestion_historical_refund_observations",
      on: obs.historical_order_membership_id == hom.id,
      join: href in "ingestion_historical_refund_references",
      on: href.historical_refund_observation_id == obs.id and href.source_state == "present",
      join: o in "sales_orders",
      on: o.source_system_id == ^scope.source_system_id and o.woo_order_id == hom.source_order_id,
      join: r in "sales_refunds",
      on: ^member_refund_aggregate_on(scope),
      join: rl in "sales_refund_lines",
      on: rl.refund_id == r.id,
      join: parent in "sales_order_items",
      on:
        parent.order_id == o.id and parent.woo_line_item_id == rl.woo_refunded_item_id and
          parent.id == rl.order_item_id,
      join: ticket in subquery(tickets),
      on: ticket.id == parent.id,
      where:
        hom.sync_run_id == ^scope.run_id and hom.event_match_state == "target" and
          is_nil(rl.binding_reason) and is_nil(rl.validation_reason),
      group_by: o.currency,
      select:
        {o.currency,
         sum(
           fragment(
             "CASE WHEN ? > 0 THEN ? ELSE 0 END",
             rl.refunded_quantity,
             rl.refunded_quantity
           )
         ), sum(fragment("? + ?", rl.refund_total_amount, rl.refund_total_tax))}
  end

  defp map_gross_currency_totals(rows) do
    Enum.reduce(rows, %{}, fn {currency, quantity, value}, acc ->
      totals =
        FinancialPrimitives.empty_totals()
        |> Map.put(:gross_ticket_quantity, decimal!(quantity))
        |> Map.put(:gross_ticket_value, decimal!(value))

      Map.update(acc, currency, totals, &FinancialPrimitives.add_totals(&1, totals))
    end)
  end

  defp map_refund_currency_totals(rows) do
    Enum.reduce(rows, %{}, fn {currency, quantity, value}, acc ->
      totals =
        FinancialPrimitives.empty_totals()
        |> Map.put(:refund_ticket_quantity, decimal!(quantity))
        |> Map.put(:refund_ticket_value, decimal!(value))

      Map.update(acc, currency, totals, &FinancialPrimitives.add_totals(&1, totals))
    end)
  end

  defp build_result(run, scope_currencies, gross_by_currency, refund_by_currency) do
    currencies =
      Enum.reduce(scope_currencies, %{}, fn currency, acc ->
        combined =
          FinancialPrimitives.add_totals(
            Map.get(gross_by_currency, currency, FinancialPrimitives.empty_totals()),
            Map.get(refund_by_currency, currency, FinancialPrimitives.empty_totals())
          )

        Map.put(acc, currency, FinancialPrimitives.derive_net_totals(combined))
      end)

    %{
      sync_run_id: run.id,
      event_id: run.event_id,
      source_system_id: run.source_system_id,
      coverage_start: run.coverage_start,
      sales_covered_through: run.sales_covered_through,
      refunds_covered_through: run.refunds_covered_through,
      currencies: currencies
    }
  end

  defp decimal!(%Decimal{} = value), do: value
  defp decimal!(value) when is_integer(value), do: Decimal.new(value)
  defp decimal!(nil), do: Decimal.new(0)

  defp normalize_field(field) when is_atom(field), do: field
  defp normalize_field(field) when is_binary(field), do: String.to_existing_atom(field)

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
