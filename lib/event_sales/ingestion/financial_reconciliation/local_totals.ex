defmodule EventSales.Ingestion.FinancialReconciliation.LocalTotals do
  @moduledoc """
  Independent Postgres local-side financial totals for one exact M3 certificate.

  Reads durable Sales facts through bounded aggregate queries. It never calls
  WooCommerce, `SourceExtractor`, or mutates state.
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
    with :ok <- validate_run_scope(run, event, source),
         :ok <- assert_current_certificate(run, event),
         :ok <- validate_membership_integrity(run),
         :ok <- validate_financial_integrity(run, event.id, source.id),
         {:ok, gross_by_currency} <- aggregate_gross_totals(run, event.id, source.id),
         {:ok, refund_by_currency} <- aggregate_refund_totals(run, event.id, source.id) do
      {:ok, build_result(run, gross_by_currency, refund_by_currency)}
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

  defp validate_membership_integrity(%SyncRun{id: run_id, source_system_id: source_system_id}) do
    case find_membership_integrity_violation(run_id, source_system_id) do
      nil ->
        :ok

      {:missing_order, source_order_id} ->
        {:error, {:missing_local_fact, %{kind: :order, source_order_id: source_order_id}}}

      {:missing_refund_observation, source_order_id} ->
        {:error,
         {:missing_local_fact, %{kind: :refund_observation, source_order_id: source_order_id}}}

      {:refund_reference_count_mismatch, source_order_id, reference_count, present_count} ->
        {:error,
         {:missing_local_fact,
          %{
            kind: :refund_reference_inconsistent,
            source_order_id: source_order_id,
            reference_count: reference_count,
            present_reference_count: present_count
          }}}

      {:historical_recognition_unproven, source_order_id} ->
        {:error, {:historical_recognition_unproven, %{source_order_id: source_order_id}}}

      {:missing_currency, source_order_id} ->
        {:error, {:currency_conflict, %{source_order_id: source_order_id, field: :currency}}}

      other ->
        {:error, {:missing_local_fact, %{kind: other}}}
    end
  end

  defp find_membership_integrity_violation(run_id, source_system_id) do
    run_id = Ecto.UUID.dump!(run_id)
    source_system_id = Ecto.UUID.dump!(source_system_id)

    target_memberships =
      from hom in "ingestion_historical_order_memberships",
        where: hom.sync_run_id == ^run_id and hom.event_match_state == "target",
        select: %{
          membership_id: hom.id,
          source_order_id: hom.source_order_id
        }

    missing_order =
      from row in subquery(target_memberships),
        left_join: o in "sales_orders",
        on: o.source_system_id == ^source_system_id and o.woo_order_id == row.source_order_id,
        where: is_nil(o.id),
        select: {:missing_order, row.source_order_id},
        limit: 1

    missing_observation =
      from row in subquery(target_memberships),
        left_join: obs in "ingestion_historical_refund_observations",
        on: obs.historical_order_membership_id == row.membership_id,
        where: is_nil(obs.id),
        select: {:missing_refund_observation, row.source_order_id},
        limit: 1

    present_ref_counts =
      from ref in "ingestion_historical_refund_references",
        where: ref.source_state == "present",
        group_by: ref.historical_refund_observation_id,
        select: %{
          observation_id: ref.historical_refund_observation_id,
          present_count: count(ref.id)
        }

    reference_mismatch =
      from row in subquery(target_memberships),
        join: obs in "ingestion_historical_refund_observations",
        on: obs.historical_order_membership_id == row.membership_id,
        left_join: counts in subquery(present_ref_counts),
        on: counts.observation_id == obs.id,
        where: obs.reference_count != coalesce(counts.present_count, 0),
        select:
          {:refund_reference_count_mismatch, row.source_order_id, obs.reference_count,
           coalesce(counts.present_count, 0)},
        limit: 1

    historical_recognition_unproven =
      from row in subquery(target_memberships),
        join: o in "sales_orders",
        on: o.source_system_id == ^source_system_id and o.woo_order_id == row.source_order_id,
        join: obs in "ingestion_historical_refund_observations",
        on: obs.historical_order_membership_id == row.membership_id,
        join: ref in "ingestion_historical_refund_references",
        on: ref.historical_refund_observation_id == obs.id and ref.source_state == "present",
        where: o.status != "completed" and is_nil(o.completed_at),
        select: {:historical_recognition_unproven, row.source_order_id},
        limit: 1

    missing_currency =
      from row in subquery(target_memberships),
        join: o in "sales_orders",
        on: o.source_system_id == ^source_system_id and o.woo_order_id == row.source_order_id,
        where: is_nil(o.currency) or o.currency == "",
        select: {:missing_currency, row.source_order_id},
        limit: 1

    [
      missing_order,
      missing_observation,
      reference_mismatch,
      historical_recognition_unproven,
      missing_currency
    ]
    |> Enum.find_value(fn query ->
      case Repo.one(query) do
        nil -> nil
        violation -> violation
      end
    end)
  end

  defp validate_financial_integrity(%SyncRun{} = run, event_id, source_system_id) do
    boundary = run.refunds_covered_through

    case find_financial_integrity_violation(run, event_id, source_system_id, boundary) do
      nil ->
        :ok

      {:incomplete_gross_line, source_order_id, woo_line_item_id, field} ->
        {:error,
         {:financial_primitive_incomplete,
          %{
            field: normalize_field(field),
            woo_line_item_id: woo_line_item_id,
            source_order_id: source_order_id,
            reason: :missing
          }}}

      {:missing_refund, source_order_id, woo_refund_id} ->
        {:error,
         {:missing_local_fact,
          %{
            kind: :refund,
            source_order_id: source_order_id,
            woo_refund_id: woo_refund_id
          }}}

      {:inactive_refund, source_order_id, woo_refund_id} ->
        {:error,
         {:missing_local_fact,
          %{
            kind: :refund_not_active,
            source_order_id: source_order_id,
            woo_refund_id: woo_refund_id
          }}}

      {:incomplete_refund, source_order_id, woo_refund_id} ->
        {:error,
         {:missing_local_fact,
          %{
            kind: :refund_not_complete,
            source_order_id: source_order_id,
            woo_refund_id: woo_refund_id
          }}}

      {:missing_refund_effective_time, source_order_id, woo_refund_id} ->
        {:error,
         {:timestamp_incomplete,
          %{
            field: :source_created_at,
            source_order_id: source_order_id,
            woo_refund_id: woo_refund_id
          }}}

      {:refund_after_boundary, source_order_id, woo_refund_id} ->
        {:error,
         {:timestamp_incomplete,
          %{
            field: :source_created_at,
            source_order_id: source_order_id,
            woo_refund_id: woo_refund_id,
            boundary: boundary
          }}}

      {:refund_currency_mismatch, source_order_id, woo_refund_id} ->
        {:error,
         {:currency_conflict,
          %{
            source_order_id: source_order_id,
            woo_refund_id: woo_refund_id
          }}}

      {:unresolved_refund_line, source_order_id, woo_refund_id, reason} ->
        {:error,
         {:unresolved_attribution,
          %{
            source_order_id: source_order_id,
            woo_refund_id: woo_refund_id,
            reason: reason
          }}}

      {:incomplete_refund_line, source_order_id, woo_refund_id, field} ->
        {:error,
         {:financial_primitive_incomplete,
          %{
            field: normalize_field(field),
            source_order_id: source_order_id,
            woo_refund_id: woo_refund_id,
            reason: :missing
          }}}
    end
  end

  defp find_financial_integrity_violation(
         %SyncRun{id: run_id},
         event_id,
         source_system_id,
         refunds_covered_through
       ) do
    run_id = Ecto.UUID.dump!(run_id)
    event_id = Ecto.UUID.dump!(event_id)
    source_system_id = Ecto.UUID.dump!(source_system_id)

    incomplete_gross_line =
      from hom in "ingestion_historical_order_memberships",
        join: o in "sales_orders",
        on: o.source_system_id == ^source_system_id and o.woo_order_id == hom.source_order_id,
        join: oi in "sales_order_items",
        on: oi.order_id == o.id,
        where:
          hom.sync_run_id == ^run_id and hom.event_match_state == "target" and
            (o.status == "completed" or not is_nil(o.completed_at)) and
            oi.event_id == ^event_id and oi.mapping_status == "mapped" and
            oi.item_kind == "ticket" and oi.quantity > 0 and
            (is_nil(oi.line_total) or is_nil(oi.line_total_tax)),
        select:
          {:incomplete_gross_line, hom.source_order_id, oi.woo_line_item_id,
           fragment(
             "CASE WHEN ? IS NULL THEN 'line_total' ELSE 'line_total_tax' END",
             oi.line_total
           )},
        limit: 1

    present_refunds =
      from hom in "ingestion_historical_order_memberships",
        join: obs in "ingestion_historical_refund_observations",
        on: obs.historical_order_membership_id == hom.id,
        join: ref in "ingestion_historical_refund_references",
        on: ref.historical_refund_observation_id == obs.id and ref.source_state == "present",
        where: hom.sync_run_id == ^run_id and hom.event_match_state == "target",
        select: %{
          source_order_id: hom.source_order_id,
          woo_refund_id: ref.woo_refund_id
        }

    missing_refund =
      from row in subquery(present_refunds),
        left_join: r in "sales_refunds",
        on:
          r.source_system_id == ^source_system_id and r.woo_order_id == row.source_order_id and
            r.woo_refund_id == row.woo_refund_id,
        where: is_nil(r.id),
        select: {:missing_refund, row.source_order_id, row.woo_refund_id},
        limit: 1

    inactive_refund =
      from row in subquery(present_refunds),
        join: r in "sales_refunds",
        on:
          r.source_system_id == ^source_system_id and r.woo_order_id == row.source_order_id and
            r.woo_refund_id == row.woo_refund_id,
        where: r.source_state != "active",
        select: {:inactive_refund, row.source_order_id, row.woo_refund_id},
        limit: 1

    incomplete_refund =
      from row in subquery(present_refunds),
        join: r in "sales_refunds",
        on:
          r.source_system_id == ^source_system_id and r.woo_order_id == row.source_order_id and
            r.woo_refund_id == row.woo_refund_id,
        where: r.detail_status != "complete",
        select: {:incomplete_refund, row.source_order_id, row.woo_refund_id},
        limit: 1

    missing_refund_effective_time =
      from row in subquery(present_refunds),
        join: r in "sales_refunds",
        on:
          r.source_system_id == ^source_system_id and r.woo_order_id == row.source_order_id and
            r.woo_refund_id == row.woo_refund_id,
        where: is_nil(r.source_created_at),
        select: {:missing_refund_effective_time, row.source_order_id, row.woo_refund_id},
        limit: 1

    refund_after_boundary =
      from row in subquery(present_refunds),
        join: r in "sales_refunds",
        on:
          r.source_system_id == ^source_system_id and r.woo_order_id == row.source_order_id and
            r.woo_refund_id == row.woo_refund_id,
        where: r.source_created_at > ^refunds_covered_through,
        select: {:refund_after_boundary, row.source_order_id, row.woo_refund_id},
        limit: 1

    refund_currency_mismatch =
      from row in subquery(present_refunds),
        join: r in "sales_refunds",
        on:
          r.source_system_id == ^source_system_id and r.woo_order_id == row.source_order_id and
            r.woo_refund_id == row.woo_refund_id,
        join: o in "sales_orders",
        on: o.id == r.order_id,
        where: r.currency != o.currency,
        select: {:refund_currency_mismatch, row.source_order_id, row.woo_refund_id},
        limit: 1

    event_ticket_items =
      from oi in "sales_order_items",
        where:
          oi.event_id == ^event_id and oi.mapping_status == "mapped" and oi.item_kind == "ticket",
        select: %{
          id: oi.id,
          order_id: oi.order_id,
          woo_line_item_id: oi.woo_line_item_id
        }

    order_items =
      from oi in "sales_order_items",
        select: %{
          id: oi.id,
          order_id: oi.order_id,
          woo_line_item_id: oi.woo_line_item_id,
          item_kind: oi.item_kind,
          event_id: oi.event_id,
          mapping_status: oi.mapping_status
        }

    present_refund_lines =
      from row in subquery(present_refunds),
        join: r in "sales_refunds",
        on:
          r.source_system_id == ^source_system_id and r.woo_order_id == row.source_order_id and
            r.woo_refund_id == row.woo_refund_id,
        join: rl in "sales_refund_lines",
        on: rl.refund_id == r.id,
        select: %{
          source_order_id: row.source_order_id,
          woo_refund_id: row.woo_refund_id,
          refund_line_id: rl.id,
          order_item_id: rl.order_item_id,
          woo_refunded_item_id: rl.woo_refunded_item_id,
          binding_reason: rl.binding_reason,
          validation_reason: rl.validation_reason,
          refund_total_amount: rl.refund_total_amount,
          refund_total_tax: rl.refund_total_tax,
          order_id: r.order_id
        }

    unresolved_refund_line =
      from row in subquery(present_refund_lines),
        left_join: oi in subquery(order_items),
        on: oi.order_id == row.order_id and oi.woo_line_item_id == row.woo_refunded_item_id,
        left_join: ticket in subquery(event_ticket_items),
        on:
          ticket.order_id == row.order_id and
            ticket.woo_line_item_id == row.woo_refunded_item_id,
        where:
          is_nil(row.woo_refunded_item_id) or
            (not is_nil(ticket.id) and
               (not is_nil(row.binding_reason) or not is_nil(row.validation_reason) or
                  is_nil(row.order_item_id) or row.order_item_id != ticket.id)) or
            (is_nil(oi.id) and not is_nil(row.woo_refunded_item_id)),
        select:
          {:unresolved_refund_line, row.source_order_id, row.woo_refund_id,
           fragment(
             "CASE
                WHEN ? IS NULL THEN 'missing_refunded_item_id'
                WHEN ? IS NOT NULL AND ? IS NOT NULL THEN 'binding_reason'
                WHEN ? IS NOT NULL AND ? IS NOT NULL THEN 'validation_reason'
                WHEN ? IS NOT NULL AND (? IS NULL OR ? != ?) THEN 'binder_mismatch'
                ELSE 'unknown_parent_line_binder'
              END",
             row.woo_refunded_item_id,
             row.binding_reason,
             ticket.id,
             row.validation_reason,
             ticket.id,
             ticket.id,
             row.order_item_id,
             row.order_item_id,
             ticket.id
           )},
        limit: 1

    incomplete_refund_line =
      from row in subquery(present_refund_lines),
        join: ticket in subquery(event_ticket_items),
        on:
          ticket.id == row.order_item_id and
            ticket.woo_line_item_id == row.woo_refunded_item_id,
        where: is_nil(row.refund_total_amount) or is_nil(row.refund_total_tax),
        select:
          {:incomplete_refund_line, row.source_order_id, row.woo_refund_id,
           fragment(
             "CASE WHEN ? IS NULL THEN 'refund_total_amount' ELSE 'refund_total_tax' END",
             row.refund_total_amount
           )},
        limit: 1

    [
      incomplete_gross_line,
      missing_refund,
      inactive_refund,
      incomplete_refund,
      missing_refund_effective_time,
      refund_after_boundary,
      refund_currency_mismatch,
      unresolved_refund_line,
      incomplete_refund_line
    ]
    |> Enum.find_value(fn query ->
      case Repo.one(query) do
        nil -> nil
        violation -> violation
      end
    end)
  end

  defp aggregate_gross_totals(%SyncRun{id: run_id}, event_id, source_system_id) do
    run_id = Ecto.UUID.dump!(run_id)
    event_id = Ecto.UUID.dump!(event_id)
    source_system_id = Ecto.UUID.dump!(source_system_id)

    query =
      from hom in "ingestion_historical_order_memberships",
        join: o in "sales_orders",
        on: o.source_system_id == ^source_system_id and o.woo_order_id == hom.source_order_id,
        join: oi in "sales_order_items",
        on: oi.order_id == o.id,
        where:
          hom.sync_run_id == ^run_id and hom.event_match_state == "target" and
            (o.status == "completed" or not is_nil(o.completed_at)) and
            oi.event_id == ^event_id and oi.mapping_status == "mapped" and
            oi.item_kind == "ticket" and oi.quantity > 0,
        group_by: o.currency,
        select:
          {o.currency, sum(oi.quantity), sum(fragment("? + ?", oi.line_total, oi.line_total_tax))}

    rows = Repo.all(query)
    {:ok, map_gross_currency_totals(rows)}
  end

  defp aggregate_refund_totals(%SyncRun{id: run_id}, event_id, source_system_id) do
    run_id = Ecto.UUID.dump!(run_id)
    event_id = Ecto.UUID.dump!(event_id)
    source_system_id = Ecto.UUID.dump!(source_system_id)

    query =
      from hom in "ingestion_historical_order_memberships",
        join: obs in "ingestion_historical_refund_observations",
        on: obs.historical_order_membership_id == hom.id,
        join: href in "ingestion_historical_refund_references",
        on: href.historical_refund_observation_id == obs.id and href.source_state == "present",
        join: r in "sales_refunds",
        on:
          r.source_system_id == ^source_system_id and r.woo_order_id == hom.source_order_id and
            r.woo_refund_id == href.woo_refund_id,
        join: o in "sales_orders",
        on: o.id == r.order_id,
        join: rl in "sales_refund_lines",
        on: rl.refund_id == r.id,
        join: oi in "sales_order_items",
        on:
          oi.id == rl.order_item_id and oi.woo_line_item_id == rl.woo_refunded_item_id and
            oi.order_id == o.id,
        where:
          hom.sync_run_id == ^run_id and hom.event_match_state == "target" and
            oi.event_id == ^event_id and oi.mapping_status == "mapped" and
            oi.item_kind == "ticket" and is_nil(rl.binding_reason) and
            is_nil(rl.validation_reason),
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

    rows = Repo.all(query)
    {:ok, map_refund_currency_totals(rows)}
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

  defp build_result(run, gross_by_currency, refund_by_currency) do
    currencies =
      Map.keys(gross_by_currency)
      |> Kernel.++(Map.keys(refund_by_currency))
      |> Enum.uniq()
      |> Enum.reduce(%{}, fn currency, acc ->
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
