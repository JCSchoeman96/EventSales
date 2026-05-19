defmodule EventSales.Ingestion.TickeraReconciliation do
  @moduledoc """
  Local Tickera/Woo reconciliation engine.
  """

  import Ecto.Query

  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{TickeraEventSource, TickeraReconciliationRun}
  alias EventSales.Ingestion.{TickeraReconciliationFindings, TickeraReconciliationRuns}
  alias EventSales.Repo

  @version "tickera_reconciliation_v1"
  @paid_woo_statuses ["completed"]
  @refunded_cancelled_woo_statuses ["refunded", "cancelled"]
  @paid_tickera_statuses ["completed", "paid"]
  @refunded_cancelled_tickera_statuses ["refunded", "cancelled", "canceled"]

  @spec run(TickeraReconciliationRun.t(), keyword()) ::
          {:ok, TickeraReconciliationRun.t()} | {:error, term()}
  def run(%TickeraReconciliationRun{} = run, opts \\ []) do
    case maybe_start(run) do
      {:ok, run} ->
        case load_source(run) do
          {:ok, source} ->
            try do
              maybe_test_raise!()
              reconcile_loaded(run, source, opts)
            rescue
              exception ->
                mark_failed(run, Exception.message(exception), :exception)
            end

          {:fail, reason} ->
            mark_failed(run, reason, :source_invalid)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_test_raise! do
    case Application.get_env(:event_sales, :tickera_reconciliation_test_raise) do
      nil -> :ok
      message -> raise(to_string(message))
    end
  end

  defp maybe_start(%TickeraReconciliationRun{status: :queued} = run) do
    TickeraReconciliationRuns.mark_started(run, internal?: true)
  end

  defp maybe_start(%TickeraReconciliationRun{} = run), do: {:ok, run}

  defp load_source(%TickeraReconciliationRun{tickera_event_source_id: nil}), do: {:ok, nil}

  defp load_source(%TickeraReconciliationRun{tickera_event_source_id: source_id}) do
    case Ash.get(TickeraEventSource, source_id, domain: Ingestion) do
      {:ok, %TickeraEventSource{active: true} = source} -> {:ok, source}
      {:ok, %TickeraEventSource{active: false}} -> {:fail, "tickera_source_inactive"}
      {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Query.NotFound{} | _]}} -> {:ok, nil}
      {:error, reason} -> {:error, reason}
    end
  end

  defp reconcile_loaded(run, nil, opts) do
    woo = woo_summary(run.event_id)
    now = now(opts)

    findings =
      if woo.total_paid + woo.total_refunded_cancelled + woo.unmapped_count > 0 do
        [
          finding_attrs(run, nil, :no_tickera_source, :info, %{
            ticket_type_scope: "event",
            payment_bucket: "none",
            details: %{woo_quantity: woo.total_paid}
          })
        ]
      else
        []
      end

    complete_with_findings(run, findings, woo, %{snapshot_count: 0}, now)
  end

  defp reconcile_loaded(run, %TickeraEventSource{} = source, opts) do
    now = now(opts)
    woo = woo_summary(run.event_id)
    tickera = tickera_summary(run.event_id, source.id)
    ticket_types = ticket_types(run.event_id)
    label_map = label_map(ticket_types)

    findings =
      []
      |> maybe_no_snapshots(run, source, tickera)
      |> maybe_stale_snapshot(run, source, tickera, opts)
      |> add_unmapped_finding(run, source, woo)
      |> add_ticket_type_mismatch_findings(run, source, tickera, label_map)
      |> add_aggregate_findings(run, source, woo, tickera, label_map)

    complete_with_findings(run, findings, woo, tickera, now)
  end

  defp complete_with_findings(run, finding_attrs, woo, tickera, now) do
    findings =
      Enum.map(finding_attrs, fn attrs ->
        attrs =
          attrs
          |> Map.put(:first_seen_at, now)
          |> Map.put(:last_seen_at, now)

        {:ok, finding} = TickeraReconciliationFindings.upsert_open(attrs, internal?: true)
        finding
      end)

    counts = run_counts(woo, tickera, findings)

    with {:ok, counted} <- TickeraReconciliationRuns.record_counts(run, counts, internal?: true) do
      TickeraReconciliationRuns.mark_completed(counted, counts, internal?: true)
    end
  end

  defp mark_failed(%TickeraReconciliationRun{} = run, message, reason) do
    last_error =
      message
      |> to_string()
      |> String.slice(0, 500)

    case TickeraReconciliationRuns.mark_failed(run, %{last_error: last_error}, internal?: true) do
      {:ok, failed} -> {:error, {:failed, failed, reason}}
      {:error, error} -> {:error, error}
    end
  end

  defp woo_summary(event_id) do
    mapped_rows =
      Repo.all(
        from item in "sales_order_items",
          join: order in "sales_orders",
          on: order.id == item.order_id,
          where:
            item.event_id == type(^event_id, :binary_id) and item.item_kind == "ticket" and
              item.mapping_status == "mapped" and not is_nil(item.ticket_type_id),
          group_by: [item.ticket_type_id, order.status],
          select: %{
            ticket_type_id: type(item.ticket_type_id, :string),
            order_status: order.status,
            quantity: coalesce(sum(item.quantity), 0),
            orders_count: count(order.id, :distinct),
            items_count: count(item.id)
          }
      )

    unmapped_count =
      Repo.one(
        from item in "sales_order_items",
          where:
            item.event_id == type(^event_id, :binary_id) and item.item_kind == "ticket" and
              item.mapping_status != "mapped",
          select: count(item.id)
      ) || 0

    aggregates =
      Enum.reduce(mapped_rows, %{}, fn row, acc ->
        bucket = woo_bucket(row.order_status)

        row = %{row | quantity: int_value(row.quantity)}

        Map.update(acc, row.ticket_type_id, new_woo_bucket(bucket, row), fn current ->
          %{
            current
            | bucket => Map.fetch!(current, bucket) + row.quantity,
              orders_count: current.orders_count + row.orders_count,
              items_count: current.items_count + row.items_count
          }
        end)
      end)

    %{
      aggregates: aggregates,
      orders_count: mapped_rows |> Enum.map(& &1.orders_count) |> Enum.sum(),
      items_count: mapped_rows |> Enum.map(& &1.items_count) |> Enum.sum(),
      unmapped_count: unmapped_count,
      total_paid: sum_bucket(aggregates, :paid),
      total_refunded_cancelled: sum_bucket(aggregates, :refunded_cancelled)
    }
  end

  defp tickera_summary(event_id, source_id) do
    rows =
      Repo.all(
        from snapshot in "ingestion_tickera_attendee_snapshots",
          where:
            snapshot.event_id == type(^event_id, :binary_id) and
              snapshot.tickera_event_source_id == type(^source_id, :binary_id),
          group_by: [snapshot.ticket_type, snapshot.ticket_type_id, snapshot.payment_status],
          select: %{
            ticket_type: snapshot.ticket_type,
            tickera_ticket_type_id: snapshot.ticket_type_id,
            payment_status: snapshot.payment_status,
            count: count(snapshot.id),
            latest_seen_at: max(snapshot.last_seen_at)
          }
      )

    latest_seen_at =
      rows
      |> Enum.map(& &1.latest_seen_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()
      |> List.last()
      |> to_utc_datetime()

    %{
      rows: rows,
      snapshot_count: Enum.reduce(rows, 0, &(&1.count + &2)),
      latest_seen_at: latest_seen_at,
      latest_completed_sync_run: latest_completed_sync_run(source_id)
    }
  end

  defp ticket_types(event_id) do
    Repo.all(
      from ticket_type in "catalog_ticket_types",
        where: ticket_type.event_id == type(^event_id, :binary_id),
        select: %{id: type(ticket_type.id, :string), name: ticket_type.name}
    )
  end

  defp latest_completed_sync_run(source_id) do
    Repo.one(
      from run in "ingestion_tickera_attendee_sync_runs",
        where:
          run.tickera_event_source_id == type(^source_id, :binary_id) and
            run.status == "completed",
        order_by: [desc_nulls_last: run.finished_at, desc: run.inserted_at],
        limit: 1,
        select: %{id: type(run.id, :string), finished_at: run.finished_at}
    )
  end

  defp maybe_no_snapshots(findings, run, source, %{snapshot_count: 0}) do
    [
      finding_attrs(run, source, :no_tickera_snapshots, :info, %{
        ticket_type_scope: "event",
        payment_bucket: "none",
        details: %{}
      })
      | findings
    ]
  end

  defp maybe_no_snapshots(findings, _run, _source, _tickera), do: findings

  defp maybe_stale_snapshot(findings, run, source, tickera, opts) do
    stale_after_hours = Keyword.get(opts, :stale_snapshot_after_hours, stale_after_hours())
    cutoff = DateTime.add(now(opts), -stale_after_hours, :hour)

    stale? =
      is_nil(tickera.latest_completed_sync_run) or
        (not is_nil(tickera.latest_seen_at) and
           DateTime.compare(tickera.latest_seen_at, cutoff) == :lt)

    if tickera.snapshot_count > 0 and stale? do
      [
        finding_attrs(run, source, :stale_tickera_snapshot, :warning, %{
          ticket_type_scope: "event",
          payment_bucket: "none",
          details: %{
            latest_seen_at: tickera.latest_seen_at,
            stale_after_hours: stale_after_hours,
            latest_completed_sync_run_id:
              tickera.latest_completed_sync_run && tickera.latest_completed_sync_run.id
          }
        })
        | findings
      ]
    else
      findings
    end
  end

  defp add_unmapped_finding(findings, run, source, %{unmapped_count: count}) when count > 0 do
    [
      finding_attrs(run, source, :unmapped_woo_order_item, :info, %{
        ticket_type_scope: "unmapped",
        payment_bucket: "none",
        woo_quantity: count,
        details: %{unmapped_count: count}
      })
      | findings
    ]
  end

  defp add_unmapped_finding(findings, _run, _source, _woo), do: findings

  defp add_ticket_type_mismatch_findings(findings, run, source, tickera, label_map) do
    tickera.rows
    |> Enum.filter(fn row ->
      tickera_bucket(row.payment_status) == :paid and
        not match?({:ok, _ticket_type}, match_label(row.ticket_type, label_map))
    end)
    |> Enum.reduce(findings, fn row, findings ->
      [
        finding_attrs(run, source, :ticket_type_mismatch, :warning, %{
          ticket_type_scope: "tickera_label:" <> normalize_label(row.ticket_type),
          payment_bucket: "paid",
          tickera_quantity: row.count,
          tickera_payment_status: row.payment_status,
          details: %{
            tickera_ticket_type: row.ticket_type,
            tickera_ticket_type_id: row.tickera_ticket_type_id,
            reason: mismatch_reason(row.ticket_type, label_map)
          }
        })
        | findings
      ]
    end)
  end

  defp add_aggregate_findings(findings, run, source, woo, tickera, label_map) do
    tickera_by_ticket =
      Enum.reduce(tickera.rows, %{}, &add_tickera_row_to_map(&1, &2, label_map))

    ticket_type_ids =
      (Map.keys(woo.aggregates) ++ Map.keys(tickera_by_ticket))
      |> Enum.uniq()

    Enum.reduce(ticket_type_ids, findings, fn ticket_type_id, findings ->
      woo_row = Map.get(woo.aggregates, ticket_type_id, empty_woo_bucket())
      tickera_row = Map.get(tickera_by_ticket, ticket_type_id, empty_tickera_bucket())
      add_ticket_type_findings(findings, run, source, ticket_type_id, woo_row, tickera_row)
    end)
  end

  defp add_tickera_row_to_map(row, acc, label_map) do
    case match_label(row.ticket_type, label_map) do
      {:ok, ticket_type} ->
        bucket = tickera_bucket(row.payment_status)

        Map.update(acc, ticket_type.id, new_tickera_bucket(bucket, row), fn current ->
          %{current | bucket => Map.fetch!(current, bucket) + row.count}
        end)

      _other ->
        acc
    end
  end

  defp add_ticket_type_findings(findings, run, source, ticket_type_id, woo_row, tickera_row) do
    findings =
      cond do
        woo_row.paid > tickera_row.paid ->
          [
            finding_attrs(run, source, :woo_paid_missing_tickera, :critical, %{
              ticket_type_id: ticket_type_id,
              ticket_type_scope: "ticket_type:" <> ticket_type_id,
              payment_bucket: "paid",
              woo_quantity: woo_row.paid,
              tickera_quantity: tickera_row.paid,
              details: %{delta: woo_row.paid - tickera_row.paid}
            })
            | findings
          ]

        tickera_row.paid > woo_row.paid ->
          [
            finding_attrs(run, source, :tickera_paid_extra, :warning, %{
              ticket_type_id: ticket_type_id,
              ticket_type_scope: "ticket_type:" <> ticket_type_id,
              payment_bucket: "paid",
              woo_quantity: woo_row.paid,
              tickera_quantity: tickera_row.paid,
              details: %{delta: tickera_row.paid - woo_row.paid}
            })
            | findings
          ]

        true ->
          findings
      end

    findings =
      if woo_row.paid != tickera_row.paid do
        [
          finding_attrs(run, source, :quantity_mismatch, :critical, %{
            ticket_type_id: ticket_type_id,
            ticket_type_scope: "ticket_type:" <> ticket_type_id,
            payment_bucket: "paid",
            woo_quantity: woo_row.paid,
            tickera_quantity: tickera_row.paid,
            details: %{delta: woo_row.paid - tickera_row.paid}
          })
          | findings
        ]
      else
        findings
      end

    if woo_row.refunded_cancelled > 0 and tickera_row.paid > 0 do
      [
        finding_attrs(run, source, :payment_status_mismatch, :warning, %{
          ticket_type_id: ticket_type_id,
          ticket_type_scope: "ticket_type:" <> ticket_type_id,
          payment_bucket: "refunded_cancelled_vs_paid",
          woo_order_status: "refunded_cancelled",
          tickera_payment_status: "paid",
          woo_quantity: woo_row.refunded_cancelled,
          tickera_quantity: tickera_row.paid,
          details: %{}
        })
        | findings
      ]
    else
      findings
    end
  end

  defp finding_attrs(run, source, type, severity, opts) do
    source_id = source && source.id

    source_scope_key =
      TickeraReconciliationFindings.source_scope_key(%{
        event_id: run.event_id,
        tickera_event_source_id: source_id
      })

    ticket_type_scope = Map.fetch!(opts, :ticket_type_scope)
    payment_bucket = Map.fetch!(opts, :payment_bucket)

    %{
      tickera_reconciliation_run_id: run.id,
      tickera_event_source_id: source_id,
      source_scope_key: source_scope_key,
      source_system_id: run.source_system_id,
      event_id: run.event_id,
      finding_type: type,
      severity: severity,
      status: :open,
      ticket_type_id: Map.get(opts, :ticket_type_id),
      woo_order_status: Map.get(opts, :woo_order_status),
      tickera_payment_status: Map.get(opts, :tickera_payment_status),
      woo_quantity: Map.get(opts, :woo_quantity),
      tickera_quantity: Map.get(opts, :tickera_quantity),
      details: Map.get(opts, :details, %{}),
      fingerprint:
        TickeraReconciliationFindings.fingerprint([
          @version,
          run.event_id,
          source_scope_key,
          type,
          ticket_type_scope,
          payment_bucket,
          Map.get(opts, :order_id, "aggregate"),
          Map.get(opts, :order_item_id, "aggregate"),
          Map.get(opts, :ticket_code, "none")
        ])
    }
  end

  defp run_counts(woo, tickera, findings) do
    %{
      woo_orders_scanned_count: woo.orders_count,
      woo_items_scanned_count: woo.items_count + woo.unmapped_count,
      tickera_snapshots_scanned_count: tickera.snapshot_count,
      findings_created_count: length(findings),
      findings_open_count: length(findings),
      findings_resolved_count: 0,
      critical_count: Enum.count(findings, &(&1.severity == :critical)),
      warning_count: Enum.count(findings, &(&1.severity == :warning)),
      info_count: Enum.count(findings, &(&1.severity == :info))
    }
  end

  defp new_woo_bucket(bucket, row),
    do:
      Map.put(empty_woo_bucket(), bucket, row.quantity)
      |> Map.merge(%{orders_count: row.orders_count, items_count: row.items_count})

  defp empty_woo_bucket,
    do: %{paid: 0, refunded_cancelled: 0, other: 0, orders_count: 0, items_count: 0}

  defp new_tickera_bucket(bucket, row), do: Map.put(empty_tickera_bucket(), bucket, row.count)
  defp empty_tickera_bucket, do: %{paid: 0, refunded_cancelled: 0, other: 0}

  defp sum_bucket(aggregates, bucket) do
    aggregates
    |> Map.values()
    |> Enum.reduce(0, &(Map.fetch!(&1, bucket) + &2))
  end

  defp woo_bucket(status) when status in @paid_woo_statuses, do: :paid
  defp woo_bucket(status) when status in @refunded_cancelled_woo_statuses, do: :refunded_cancelled
  defp woo_bucket(_status), do: :other

  defp tickera_bucket(status) when is_binary(status) do
    status = normalize_label(status)

    cond do
      status in @paid_tickera_statuses -> :paid
      status in @refunded_cancelled_tickera_statuses -> :refunded_cancelled
      true -> :other
    end
  end

  defp tickera_bucket(_status), do: :other

  defp label_map(ticket_types) do
    ticket_types
    |> Enum.group_by(&normalize_label(&1.name))
    |> Map.new(fn
      {label, [ticket_type]} -> {label, {:ok, ticket_type}}
      {label, _many} -> {label, :ambiguous}
    end)
  end

  defp match_label(label, label_map) do
    Map.get(label_map, normalize_label(label), :missing)
  end

  defp mismatch_reason(nil, _label_map), do: "missing_label"
  defp mismatch_reason("", _label_map), do: "missing_label"

  defp mismatch_reason(label, label_map) do
    case match_label(label, label_map) do
      :ambiguous -> "ambiguous_label"
      :missing -> "unknown_label"
      {:ok, _ticket_type} -> "matched"
    end
  end

  defp normalize_label(nil), do: ""

  defp normalize_label(value) do
    value
    |> to_string()
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end

  defp stale_after_hours do
    :event_sales
    |> Application.get_env(:tickera_reconciliation, [])
    |> Keyword.get(:stale_snapshot_after_hours, 24)
  end

  defp now(opts), do: Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

  defp int_value(%Decimal{} = value), do: Decimal.to_integer(value)
  defp int_value(value), do: value || 0

  defp to_utc_datetime(nil), do: nil
  defp to_utc_datetime(%DateTime{} = value), do: value
  defp to_utc_datetime(%NaiveDateTime{} = value), do: DateTime.from_naive!(value, "Etc/UTC")
end
