defmodule EventSales.Analytics.SnapshotRefresh do
  @moduledoc """
  Refreshes durable historical reporting snapshots from scoped sales rows.

  Snapshot rows are derived read models. Event refresh uses bounded canonical
  aggregation; daily refresh may still scan scoped durable sales data during
  refresh. Dashboard/reporting reads should use `EventSales.Analytics.SnapshotReader`.
  """

  import Ecto.Query

  require Ash.Query

  alias EventSales.Analytics
  alias EventSales.Analytics.Aggregators.DimensionAggregator
  alias EventSales.Analytics.Aggregators.EventAggregator
  alias EventSales.Analytics.DashboardCache
  alias EventSales.Analytics.EventSnapshotRefreshFence
  alias EventSales.Analytics.MetricRules
  alias EventSales.Analytics.Resources.{DailySalesAggregateSnapshot, EventAggregateSnapshot}
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.OrderItem

  @event_snapshot_version 2
  @daily_snapshot_version 1
  @zero Decimal.new("0")
  @dimension_snapshots_table "analytics_event_dimension_aggregate_snapshots"
  @product_dimension_kinds [:source_product, :source_variation]

  @doc "Refreshes the canonical event financial projection set for one event."
  @spec refresh_event(Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, [EventAggregateSnapshot.t()]} | {:error, term()}
  def refresh_event(event_id, opts \\ []) when is_binary(event_id) do
    with {:ok, event_id} <- cast_uuid(event_id, :event_id),
         {:ok, _event} <- fetch_event(event_id) do
      timezone = Keyword.get_lazy(opts, :business_timezone, &MetricRules.business_timezone/0)
      now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
      refreshed_at = Keyword.get_lazy(opts, :refreshed_at, &DateTime.utc_now/0)

      case refresh_event_transaction(event_id, timezone, now, refreshed_at) do
        {:ok, snapshots} ->
          DashboardCache.invalidate_event(event_id, :snapshot_refresh)
          {:ok, snapshots}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Refreshes the durable daily sales snapshot for one event and business date."
  @spec refresh_daily(Ecto.UUID.t() | String.t(), Date.t() | String.t(), keyword()) ::
          {:ok, DailySalesAggregateSnapshot.t()} | {:error, term()}
  def refresh_daily(event_id, business_date, opts \\ [])

  def refresh_daily(event_id, business_date, opts) when is_binary(event_id) do
    with {:ok, event_id} <- cast_uuid(event_id, :event_id),
         {:ok, business_date} <- cast_date(business_date),
         {:ok, _event} <- fetch_event(event_id),
         {:ok, rows} <- event_rows(event_id) do
      timezone = Keyword.get_lazy(opts, :business_timezone, &MetricRules.business_timezone/0)
      now = Keyword.get_lazy(opts, :now, fn -> snapshot_now(business_date) end)
      refreshed_at = Keyword.get_lazy(opts, :refreshed_at, &DateTime.utc_now/0)

      daily_rows =
        Enum.filter(rows, fn row ->
          row
          |> row_completed_at()
          |> same_business_date?(business_date, timezone)
        end)

      attrs =
        event_id
        |> snapshot_attrs(daily_rows, timezone, now, refreshed_at)
        |> Map.put(:business_date, business_date)

      with {:ok, snapshot} <- upsert_daily_snapshot(event_id, business_date, timezone, attrs) do
        DashboardCache.invalidate_event(event_id, :snapshot_refresh)
        {:ok, snapshot}
      end
    end
  end

  def refresh_daily(_event_id, _business_date, _opts), do: {:error, :invalid_event_id}

  defp refresh_event_transaction(event_id, timezone, now, refreshed_at) do
    EventSnapshotRefreshFence.with_serial_event_refresh(event_id, fn ->
      refresh_event_in_coherent_transaction(event_id, timezone, now, refreshed_at)
    end)
  end

  defp refresh_event_in_coherent_transaction(event_id, timezone, now, refreshed_at) do
    transaction_opts =
      [timeout: 120_000] ++ EventSnapshotRefreshFence.coherent_transaction_opts()

    Repo.transaction(
      fn -> refresh_event_projection_or_rollback(event_id, timezone, now, refreshed_at) end,
      transaction_opts
    )
  end

  defp refresh_event_projection_or_rollback(event_id, timezone, now, refreshed_at) do
    case refresh_event_projection_set!(event_id, timezone, now, refreshed_at) do
      {:ok, snapshots} -> snapshots
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp refresh_event_projection_set!(event_id, timezone, now, refreshed_at) do
    projection_refreshed_at = DateTime.truncate(refreshed_at, :microsecond)
    persisted_at = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    with {:ok, summaries} <- EventAggregator.financial_summaries_for_event(event_id),
         {:ok, dimension_rows} <- DimensionAggregator.gross_rows_for_event(event_id),
         {:ok, legacy_summary} <- legacy_summary_for_refresh(event_id, timezone, now),
         {:ok, event} <- fetch_event(event_id),
         :ok <- validate_dimension_rows_for_persist!(event, dimension_rows) do
      {source_row_count, source_watermark_at} = event_source_metadata(event_id)

      persist_event_projection_set!(%{
        event_id: event_id,
        summaries: summaries,
        legacy_summary: legacy_summary,
        dimension_rows: dimension_rows,
        timezone: timezone,
        projection_refreshed_at: projection_refreshed_at,
        persisted_at: persisted_at,
        source_row_count: source_row_count,
        source_watermark_at: source_watermark_at
      })
    end
  end

  defp legacy_summary_for_refresh(event_id, timezone, now) do
    opts = [timezone: timezone, now: now]

    case EventAggregator.summary_for_event(event_id, opts) do
      {:ok, summary} ->
        {:ok, summary}

      {:error, :mixed_currency} ->
        with {:ok, status_breakdown} <-
               EventAggregator.operational_status_breakdown_for_event(event_id, opts) do
          {:ok,
           %{
             total_sold: 0,
             total_revenue: @zero,
             today_sold: 0,
             today_revenue: @zero,
             status_breakdown: status_breakdown
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp persist_event_projection_set!(%{} = context) do
    canonical_currencies = context.summaries |> Map.keys() |> Enum.sort()

    persist_context = %{
      event_id: context.event_id,
      summaries: context.summaries,
      legacy_summary: context.legacy_summary,
      canonical_currencies: canonical_currencies,
      timezone: context.timezone,
      refreshed_at: context.projection_refreshed_at,
      source_row_count: context.source_row_count,
      source_watermark_at: context.source_watermark_at
    }

    dimension_context = %{
      event_id: context.event_id,
      dimension_rows: context.dimension_rows,
      projection_refreshed_at: context.projection_refreshed_at,
      persisted_at: context.persisted_at
    }

    with :ok <- persist_canonical_currencies!(persist_context),
         :ok <-
           purge_obsolete_event_projections!(context.event_id, MapSet.new(canonical_currencies)),
         :ok <- replace_event_dimension_projection_set!(dimension_context) do
      {:ok, read_event_snapshots(context.event_id, @event_snapshot_version)}
    end
  end

  defp validate_dimension_rows_for_persist!(%Event{} = event, dimension_rows) do
    case validate_dimension_source_system_ids!(event, dimension_rows) do
      :ok -> validate_dimension_ticket_type_event_membership!(event.id, dimension_rows)
      error -> error
    end
  end

  defp validate_dimension_source_system_ids!(%Event{} = event, dimension_rows) do
    invalid? =
      Enum.any?(dimension_rows, fn row ->
        row.dimension_kind in @product_dimension_kinds and
          row.source_system_id != event.source_system_id
      end)

    if invalid?, do: {:error, :dimension_source_event_mismatch}, else: :ok
  end

  defp validate_dimension_ticket_type_event_membership!(event_id, dimension_rows) do
    ticket_type_ids =
      dimension_rows
      |> Enum.filter(&(&1.dimension_kind == :ticket_type))
      |> Enum.map(& &1.ticket_type_id)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if ticket_type_ids == [],
      do: :ok,
      else: verify_ticket_type_ids_for_event(event_id, ticket_type_ids)
  end

  defp verify_ticket_type_ids_for_event(event_id, ticket_type_ids) do
    case load_ticket_type_ids_for_event(event_id, ticket_type_ids) do
      {:ok, found_ids} -> compare_ticket_type_id_sets(found_ids, ticket_type_ids)
      error -> error
    end
  end

  defp compare_ticket_type_id_sets(found_ids, ticket_type_ids) do
    if MapSet.new(found_ids) == MapSet.new(ticket_type_ids) do
      :ok
    else
      {:error, :dimension_ticket_type_event_mismatch}
    end
  end

  defp load_ticket_type_ids_for_event(event_id, ticket_type_ids) do
    case repo_dimension_persist_step(fn ->
           dumped_event_id = Ecto.UUID.dump!(event_id)
           dumped_ticket_type_ids = Enum.map(ticket_type_ids, &Ecto.UUID.dump!/1)

           found_ids =
             from(tt in "catalog_ticket_types",
               where: tt.event_id == ^dumped_event_id and tt.id in ^dumped_ticket_type_ids,
               select: tt.id
             )
             |> Repo.all()
             |> Enum.map(&uuid_from_repo/1)

           {:ok, found_ids}
         end) do
      {:ok, found_ids} -> {:ok, found_ids}
      {:error, reason} -> {:error, reason}
    end
  end

  defp replace_event_dimension_projection_set!(%{} = context) do
    case delete_dimension_rows_for_event!(context.event_id) do
      :ok ->
        bulk_insert_dimension_rows!(
          context.event_id,
          context.dimension_rows,
          context.projection_refreshed_at,
          context.persisted_at
        )

      error ->
        error
    end
  end

  defp delete_dimension_rows_for_event!(event_id) do
    case repo_dimension_persist_step(fn ->
           dumped_event_id = Ecto.UUID.dump!(event_id)

           {_count, _} =
             from(d in @dimension_snapshots_table, where: d.event_id == ^dumped_event_id)
             |> Repo.delete_all()

           :ok
         end) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp bulk_insert_dimension_rows!(_event_id, [], _projection_refreshed_at, _persisted_at),
    do: :ok

  defp bulk_insert_dimension_rows!(
         event_id,
         dimension_rows,
         projection_refreshed_at,
         persisted_at
       ) do
    insert_rows =
      Enum.map(dimension_rows, fn row ->
        dimension_row_to_insert_map(event_id, row, projection_refreshed_at, persisted_at)
      end)

    repo_dimension_persist_step(fn ->
      {inserted_count, _} = Repo.insert_all(@dimension_snapshots_table, insert_rows)
      dimension_insert_result(inserted_count, length(dimension_rows))
    end)
    |> normalize_dimension_persist_result()
  end

  defp dimension_insert_result(inserted_count, expected_count)
       when inserted_count == expected_count,
       do: :ok

  defp dimension_insert_result(_inserted_count, _expected_count),
    do: {:error, :dimension_snapshot_insert_count_mismatch}

  defp normalize_dimension_persist_result(:ok), do: :ok
  defp normalize_dimension_persist_result({:error, reason}), do: {:error, reason}

  defp dimension_row_to_insert_map(event_id, row, projection_refreshed_at, persisted_at) do
    %{
      id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
      event_id: Ecto.UUID.dump!(event_id),
      currency: row.currency,
      dimension_kind: Atom.to_string(row.dimension_kind),
      ticket_type_id: dump_optional_uuid(row.ticket_type_id),
      source_system_id: dump_optional_uuid(row.source_system_id),
      woo_product_id: row.woo_product_id,
      woo_variation_id: row.woo_variation_id,
      gross_ticket_quantity: row.gross_ticket_quantity,
      gross_ticket_value: row.gross_ticket_value,
      refreshed_at: projection_refreshed_at,
      inserted_at: persisted_at,
      updated_at: persisted_at
    }
  end

  defp repo_dimension_persist_step(fun) when is_function(fun, 0) do
    fun.()
  rescue
    e in Postgrex.Error -> {:error, {:dimension_snapshot_persist_failed, e}}
    e in DBConnection.ConnectionError -> {:error, {:dimension_snapshot_persist_failed, e}}
  end

  defp uuid_from_repo(id) when is_binary(id) do
    case Ecto.UUID.load(id) do
      {:ok, uuid} -> uuid
      :error -> id
    end
  end

  defp dump_optional_uuid(nil), do: nil
  defp dump_optional_uuid(id), do: Ecto.UUID.dump!(id)

  defp persist_canonical_currencies!(context) do
    Enum.reduce_while(context.canonical_currencies, :ok, fn currency, :ok ->
      financial = Map.fetch!(context.summaries, currency)

      attrs =
        event_snapshot_attrs(%{
          event_id: context.event_id,
          currency: currency,
          financial: financial,
          legacy_summary: context.legacy_summary,
          canonical_currencies: context.canonical_currencies,
          timezone: context.timezone,
          refreshed_at: context.refreshed_at,
          source_row_count: context.source_row_count,
          source_watermark_at: context.source_watermark_at
        })

      persist_currency_snapshot!(context.event_id, currency, attrs)
    end)
  end

  defp persist_currency_snapshot!(event_id, currency, attrs) do
    case upsert_event_snapshot(event_id, currency, attrs) do
      {:ok, _snapshot} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp event_snapshot_attrs(%{} = context) do
    legacy_fields =
      legacy_compatibility_fields(
        context.currency,
        context.legacy_summary,
        context.canonical_currencies
      )

    financial = context.financial

    %{
      event_id: context.event_id,
      total_sold: legacy_fields.total_sold,
      total_revenue: legacy_fields.total_revenue,
      today_sold: legacy_fields.today_sold,
      today_revenue: legacy_fields.today_revenue,
      gross_ticket_quantity: decimal_quantity_to_int!(financial.gross_ticket_quantity),
      refund_ticket_quantity: decimal_quantity_to_int!(financial.refund_ticket_quantity),
      gross_ticket_value: financial.gross_ticket_value,
      refund_ticket_value: financial.refund_ticket_value,
      recognised_order_count: financial.recognised_order_count,
      status_breakdown: legacy_fields.status_breakdown,
      currency: context.currency,
      business_timezone: context.timezone,
      refreshed_at: context.refreshed_at,
      source_watermark_at: context.source_watermark_at,
      source_row_count: context.source_row_count,
      snapshot_version: @event_snapshot_version
    }
  end

  defp legacy_compatibility_fields(currency, legacy_summary, canonical_currencies) do
    status_breakdown = stringify_status_breakdown(legacy_summary.status_breakdown)

    cond do
      length(canonical_currencies) > 1 ->
        %{
          total_sold: 0,
          total_revenue: @zero,
          today_sold: legacy_summary.today_sold,
          today_revenue: @zero,
          status_breakdown: status_breakdown
        }

      length(canonical_currencies) == 1 and currency == hd(canonical_currencies) ->
        %{
          total_sold: legacy_summary.total_sold,
          total_revenue: legacy_summary.total_revenue,
          today_sold: legacy_summary.today_sold,
          today_revenue: legacy_summary.today_revenue,
          status_breakdown: status_breakdown
        }

      true ->
        %{
          total_sold: 0,
          total_revenue: @zero,
          today_sold: 0,
          today_revenue: @zero,
          status_breakdown: status_breakdown
        }
    end
  end

  defp purge_obsolete_event_projections!(event_id, canonical_currencies) do
    event_id
    |> read_all_event_snapshots()
    |> Enum.reduce_while(:ok, fn snapshot, :ok ->
      if obsolete_event_snapshot?(snapshot, canonical_currencies) do
        purge_snapshot(snapshot)
      else
        {:cont, :ok}
      end
    end)
  end

  defp obsolete_event_snapshot?(snapshot, canonical_currencies) do
    snapshot.snapshot_version == 1 or
      (snapshot.snapshot_version == @event_snapshot_version and
         not MapSet.member?(canonical_currencies, snapshot.currency))
  end

  defp purge_snapshot(snapshot) do
    case destroy_snapshot(snapshot) do
      :ok -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp destroy_snapshot(snapshot) do
    case Ash.destroy(snapshot, action: :destroy_snapshot, domain: Analytics) do
      :ok -> :ok
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp upsert_event_snapshot(event_id, currency, attrs) do
    case read_event_snapshot(event_id, currency) do
      {:ok, nil} ->
        Ash.create(EventAggregateSnapshot, attrs, action: :create_snapshot, domain: Analytics)

      {:ok, %EventAggregateSnapshot{} = snapshot} ->
        Ash.update(snapshot, Map.delete(attrs, :event_id),
          action: :update_snapshot,
          domain: Analytics
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_event_snapshot(event_id, currency) do
    EventAggregateSnapshot
    |> Ash.Query.filter(event_id == ^event_id and currency == ^currency)
    |> Ash.read_one(domain: Analytics)
  end

  defp read_event_snapshots(event_id, snapshot_version) do
    EventAggregateSnapshot
    |> Ash.Query.filter(event_id == ^event_id and snapshot_version == ^snapshot_version)
    |> Ash.Query.sort(currency: :asc)
    |> Ash.read!(domain: Analytics)
  end

  defp read_all_event_snapshots(event_id) do
    EventAggregateSnapshot
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.read!(domain: Analytics)
  end

  defp event_source_metadata(event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, event_id} ->
        event_id = Ecto.UUID.dump!(event_id)

        count_query =
          from oi in "sales_order_items",
            where: oi.event_id == ^event_id,
            select: count(oi.id)

        watermark_query =
          from oi in "sales_order_items",
            join: o in "sales_orders",
            on: oi.order_id == o.id,
            where: oi.event_id == ^event_id,
            select: max(o.updated_at_source)

        {Repo.one!(count_query) || 0, Repo.one!(watermark_query)}

      :error ->
        {0, nil}
    end
  end

  defp decimal_quantity_to_int!(%Decimal{} = quantity) do
    quantity
    |> Decimal.round(0)
    |> Decimal.to_integer()
  end

  defp fetch_event(event_id) do
    case Ash.get(Event, event_id, domain: Catalog) do
      {:ok, %Event{} = event} -> {:ok, event}
      {:ok, nil} -> {:error, :event_not_found}
      {:error, _reason} -> {:error, :event_not_found}
    end
  end

  defp event_rows(event_id) do
    OrderItem
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.Query.sort(woo_line_item_id: :asc)
    |> Ash.Query.load(:order)
    |> Ash.read(domain: Sales)
  end

  defp snapshot_attrs(event_id, rows, timezone, now, refreshed_at) do
    summary = MetricRules.summarize(rows, timezone: timezone, now: now)

    %{
      event_id: event_id,
      total_sold: summary.total_sold,
      total_revenue: summary.total_revenue,
      today_sold: summary.today_sold,
      today_revenue: summary.today_revenue,
      status_breakdown: stringify_status_breakdown(summary.status_breakdown),
      currency: currency(rows),
      business_timezone: timezone,
      refreshed_at: DateTime.truncate(refreshed_at, :microsecond),
      source_watermark_at: source_watermark_at(rows),
      source_row_count: length(rows),
      snapshot_version: @daily_snapshot_version
    }
  end

  defp upsert_daily_snapshot(event_id, business_date, timezone, attrs) do
    case read_daily_snapshot(event_id, business_date, timezone) do
      {:ok, nil} ->
        Ash.create(DailySalesAggregateSnapshot, attrs,
          action: :create_snapshot,
          domain: Analytics
        )

      {:ok, %DailySalesAggregateSnapshot{} = snapshot} ->
        Ash.update(snapshot, attrs |> Map.delete(:event_id) |> Map.delete(:business_date),
          action: :update_snapshot,
          domain: Analytics
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_daily_snapshot(event_id, business_date, timezone) do
    DailySalesAggregateSnapshot
    |> Ash.Query.filter(
      event_id == ^event_id and business_date == ^business_date and business_timezone == ^timezone
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Analytics)
  end

  defp stringify_status_breakdown(status_breakdown) do
    Map.new(status_breakdown, fn {key, value} -> {to_string(key), value} end)
  end

  defp currency([%OrderItem{order: %{currency: currency}} | _rest]) when is_binary(currency),
    do: currency

  defp currency([_row | rest]), do: currency(rest)
  defp currency([]), do: Application.fetch_env!(:event_sales, :default_currency)

  defp source_watermark_at(rows) do
    rows
    |> Enum.map(&row_source_updated_at/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&DateTime.to_unix(&1, :microsecond), fn -> nil end)
  end

  defp row_source_updated_at(%OrderItem{order: %{updated_at_source: %DateTime{} = updated_at}}),
    do: updated_at

  defp row_source_updated_at(_row), do: nil

  defp row_completed_at(%OrderItem{order: %{completed_at: %DateTime{} = completed_at}}),
    do: completed_at

  defp row_completed_at(_row), do: nil

  defp same_business_date?(nil, _business_date, _timezone), do: false

  defp same_business_date?(%DateTime{} = completed_at, business_date, timezone) do
    case MetricRules.business_date(completed_at, timezone) do
      {:ok, ^business_date} -> true
      {:ok, _other_date} -> false
      {:error, :invalid_timezone} -> false
    end
  end

  defp snapshot_now(%Date{} = business_date) do
    business_date
    |> DateTime.new!(~T[12:00:00.000000], "Etc/UTC")
    |> DateTime.truncate(:microsecond)
  end

  defp cast_uuid(value, field) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, {:invalid_uuid, field}}
    end
  end

  defp cast_date(%Date{} = date), do: {:ok, date}

  defp cast_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, :invalid_business_date}
    end
  end

  defp cast_date(_value), do: {:error, :invalid_business_date}
end
