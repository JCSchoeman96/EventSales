defmodule EventSales.Analytics.EventDetail do
  @moduledoc """
  Admin-only read facade for Slice 12 event list and event detail pages.

  The event list uses hot/snapshot summaries only. Event detail financial and
  ticket-type breakdowns read canonical v2 projections inside one coherent
  database transaction. `status_breakdown` remains a separate operational query
  over current order status (mapped ticket lines); it is not canonical financial
  or dimensional truth.
  """

  import Ecto.Query

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.AdminRead.Pagination, as: AdminReadPagination

  alias EventSales.Analytics.{
    DimensionSnapshotReader,
    EventSnapshotRefreshFence,
    HotStateAggregator,
    SnapshotReader
  }

  alias EventSales.Catalog
  alias EventSales.Catalog.EventLifecycle
  alias EventSales.Catalog.Resources.{Event, TicketType}
  alias EventSales.Ingestion.AnalyticsReadinessResolver
  alias EventSales.Repo

  @default_per_page 25
  @max_per_page 50
  @zero Decimal.new("0")

  @type page :: %{
          page: pos_integer(),
          per_page: pos_integer(),
          has_next?: boolean(),
          has_previous?: boolean()
        }

  @type event_list_row :: %{
          event_id: Ecto.UUID.t(),
          event_name: String.t(),
          slug: String.t(),
          status: atom(),
          venue_name: String.t() | nil,
          starts_at: DateTime.t() | nil,
          ends_at: DateTime.t() | nil,
          lifecycle: EventLifecycle.lifecycle(),
          capacity: non_neg_integer() | nil,
          sold: non_neg_integer(),
          remaining: non_neg_integer() | nil,
          revenue: Decimal.t(),
          currency: String.t(),
          refreshed_at: DateTime.t() | nil
        }

  @type ticket_type_row :: %{
          ticket_type_id: Ecto.UUID.t(),
          ticket_type_name: String.t(),
          capacity: non_neg_integer() | nil,
          sold: non_neg_integer(),
          remaining: non_neg_integer() | nil,
          revenue: Decimal.t()
        }

  @type recent_order_row :: %{
          order_id: Ecto.UUID.t(),
          order_number: String.t() | nil,
          status: atom(),
          currency: String.t(),
          raw_total: Decimal.t(),
          customer_name: String.t() | nil,
          customer_email: String.t() | nil,
          completed_at: DateTime.t() | nil,
          updated_at_source: DateTime.t()
        }

  @type unmapped_item_row :: %{
          order_item_id: Ecto.UUID.t(),
          order_number: String.t() | nil,
          name: String.t() | nil,
          woo_product_id: integer(),
          woo_variation_id: integer() | nil,
          quantity: pos_integer(),
          mapping_status: atom(),
          updated_at: DateTime.t()
        }

  @type event_detail :: %{
          event_id: Ecto.UUID.t(),
          event_name: String.t(),
          slug: String.t(),
          status: atom(),
          capacity: non_neg_integer() | nil,
          sold: non_neg_integer(),
          remaining: non_neg_integer() | nil,
          revenue: Decimal.t(),
          currency: String.t(),
          refreshed_at: DateTime.t() | nil,
          status_breakdown: %{String.t() => non_neg_integer()},
          ticket_types: [ticket_type_row()]
        }

  @spec list_events(keyword()) ::
          {:ok, %{rows: [event_list_row()], page: page()}} | {:error, term()}
  def list_events(opts \\ []) do
    with :ok <- authorize(opts),
         %{page: page, per_page: per_page, offset: offset} <-
           AdminReadPagination.pagination(opts, @default_per_page, @max_per_page),
         {:ok, events} <- read_events(per_page + 1, offset, opts) do
      {visible_events, has_next?} = AdminReadPagination.split_page(events, per_page)

      {:ok,
       %{
         rows: Enum.map(visible_events, &event_list_row(&1, opts)),
         page: AdminReadPagination.page_info(page, per_page, has_next?)
       }}
    end
  end

  @spec get_event_detail(Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, event_detail()} | :not_found | {:error, term()}
  def get_event_detail(event_id, opts \\ []) when is_binary(event_id) do
    with :ok <- authorize(opts),
         {:ok, event_id} <- cast_uuid(event_id),
         transaction_result <- run_coherent_detail_transaction(event_id, opts) do
      normalize_detail_transaction_result(transaction_result)
    end
  end

  @spec recent_orders(Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, %{rows: [recent_order_row()], page: page()}} | {:error, term()}
  def recent_orders(event_id, opts \\ []) when is_binary(event_id) do
    with :ok <- authorize(opts),
         {:ok, event_id} <- cast_uuid(event_id),
         %{page: page, per_page: per_page, offset: offset} <-
           AdminReadPagination.pagination(opts, @default_per_page, @max_per_page),
         rows <- recent_order_rows(event_id, per_page + 1, offset) do
      {visible_rows, has_next?} = AdminReadPagination.split_page(rows, per_page)

      {:ok,
       %{
         rows: Enum.map(visible_rows, &normalize_recent_order/1),
         page: AdminReadPagination.page_info(page, per_page, has_next?)
       }}
    end
  end

  @spec unmapped_items(Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, %{rows: [unmapped_item_row()], page: page()}} | {:error, term()}
  def unmapped_items(event_id, opts \\ []) when is_binary(event_id) do
    with :ok <- authorize(opts),
         {:ok, event_id} <- cast_uuid(event_id),
         %{page: page, per_page: per_page, offset: offset} <-
           AdminReadPagination.pagination(opts, @default_per_page, @max_per_page),
         rows <- unmapped_item_rows(event_id, per_page + 1, offset) do
      {visible_rows, has_next?} = AdminReadPagination.split_page(rows, per_page)

      {:ok,
       %{
         rows: Enum.map(visible_rows, &normalize_unmapped_item/1),
         page: AdminReadPagination.page_info(page, per_page, has_next?)
       }}
    end
  end

  defp run_coherent_detail_transaction(event_id, opts) do
    actor = Keyword.get(opts, :actor)
    transaction_opts = EventSnapshotRefreshFence.coherent_transaction_opts()

    Repo.transaction(
      fn ->
        case build_coherent_event_detail(event_id, actor) do
          {:ok, detail} -> detail
          :not_found -> Repo.rollback(:not_found)
          {:error, reason} -> Repo.rollback(reason)
        end
      end,
      transaction_opts
    )
  end

  defp normalize_detail_transaction_result({:ok, detail}) when is_map(detail), do: {:ok, detail}
  defp normalize_detail_transaction_result({:error, :not_found}), do: :not_found
  defp normalize_detail_transaction_result({:error, reason}), do: {:error, reason}

  defp build_coherent_event_detail(event_id, actor) do
    with {:ok, %Event{} = event} <- fetch_event_result(event_id),
         :ok <- require_analytics_ready(event_id),
         {:ok, financial_scalar} <- scalar_from_financial_summaries(event_id),
         {:ok, ticket_types} <-
           ticket_type_rows_from_projection(event, financial_scalar.currency, actor),
         status_breakdown <- operational_status_breakdown_map(event_id) do
      {:ok,
       %{
         event_id: event.id,
         event_name: event.name,
         slug: event.slug,
         status: event.status,
         capacity: event.capacity,
         sold: financial_scalar.sold,
         remaining: remaining(event.capacity, financial_scalar.sold),
         revenue: financial_scalar.revenue,
         currency: financial_scalar.currency,
         refreshed_at: nil,
         status_breakdown: status_breakdown,
         ticket_types: ticket_types
       }}
    end
  end

  defp fetch_event_result(event_id) do
    case fetch_event(event_id) do
      {:ok, %Event{} = event} -> {:ok, event}
      {:ok, nil} -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  defp require_analytics_ready(event_id) do
    case AnalyticsReadinessResolver.resolve(event_id) do
      {:ok, %{analytics_ready?: true}} ->
        :ok

      {:ok, %{blocking_reason: reason}} ->
        {:error, {:analytics_not_ready, reason}}

      {:error, :invalid_event_id} ->
        {:error, :not_found}
    end
  end

  defp scalar_from_financial_summaries(event_id) do
    case SnapshotReader.financial_summaries_for_event(event_id) do
      :miss ->
        {:error, :snapshot_not_ready}

      {:ok, summaries} when map_size(summaries) == 0 ->
        {:error, :snapshot_not_ready}

      {:ok, summaries} when map_size(summaries) > 1 ->
        {:error, :mixed_currency}

      {:ok, summaries} ->
        [{currency, summary}] = Map.to_list(summaries)

        with {:ok, sold} <- quantity_from_gross(summary.gross_ticket_quantity) do
          {:ok,
           %{
             sold: sold,
             revenue: summary.gross_ticket_value || @zero,
             currency: currency
           }}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp quantity_from_gross(%Decimal{} = quantity) do
    if Decimal.integer?(quantity) do
      {:ok, Decimal.to_integer(quantity)}
    else
      {:error, :snapshot_not_ready}
    end
  end

  defp quantity_from_gross(quantity) when is_integer(quantity) and quantity >= 0,
    do: {:ok, quantity}

  defp quantity_from_gross(_), do: {:error, :snapshot_not_ready}

  defp ticket_type_rows_from_projection(%Event{} = event, currency, actor) do
    with {:ok, dimension_result} <-
           read_ticket_dimension_snapshot(event.id, actor),
         {:ok, ticket_rows} <- ticket_rows_for_currency(dimension_result, currency),
         {:ok, catalogue_ticket_types} <- read_ticket_types(event.id) do
      sold_by_ticket_type =
        Map.new(ticket_rows, fn row ->
          {row.ticket_type_id,
           %{
             sold: row.gross_ticket_quantity,
             revenue: row.gross_ticket_value || @zero
           }}
        end)

      {:ok,
       Enum.map(catalogue_ticket_types, fn ticket_type ->
         aggregate = Map.get(sold_by_ticket_type, ticket_type.id, %{sold: 0, revenue: @zero})

         %{
           ticket_type_id: ticket_type.id,
           ticket_type_name: ticket_type.name,
           capacity: ticket_type.capacity,
           sold: aggregate.sold,
           remaining: remaining(ticket_type.capacity, aggregate.sold),
           revenue: aggregate.revenue
         }
       end)}
    end
  end

  defp read_ticket_dimension_snapshot(event_id, actor) do
    case DimensionSnapshotReader.list_for_event(event_id,
           actor: actor,
           dimension_kind: :ticket_type
         ) do
      {:ok, result} -> {:ok, result}
      :miss -> {:error, :snapshot_not_ready}
      :not_found -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end

  defp ticket_rows_for_currency(%{currencies: currencies}, currency) do
    currency_codes = Enum.map(currencies, & &1.currency)

    cond do
      length(currency_codes) > 1 ->
        {:error, :mixed_currency}

      currency_codes != [] and currency_codes != [currency] ->
        {:error, :snapshot_not_ready}

      true ->
        bucket = Enum.find(currencies, &(&1.currency == currency))

        if is_nil(bucket) and currency_codes == [] do
          {:error, :snapshot_not_ready}
        else
          {:ok, (bucket && bucket.dimensions.ticket_type) || []}
        end
    end
  end

  defp authorize(opts) do
    if opts |> Keyword.get(:actor) |> Policies.global_admin?() do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp read_events(limit, offset, opts) do
    Event
    |> lifecycle_filter(
      Keyword.get(opts, :lifecycle, :current),
      Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    )
    |> Ash.Query.sort(name: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.offset(offset)
    |> Ash.read(domain: Catalog)
  end

  defp fetch_event(event_id) do
    Event
    |> Ash.Query.filter(id == ^event_id)
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Catalog)
  end

  defp event_list_row(%Event{} = event, opts) do
    summary = summary_for_list_event(event.id)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    %{
      event_id: event.id,
      event_name: event.name,
      slug: event.slug,
      status: event.status,
      venue_name: event.venue_name,
      starts_at: event.starts_at,
      ends_at: event.ends_at,
      lifecycle: EventLifecycle.classify(event, now),
      capacity: event.capacity,
      sold: summary.sold,
      remaining: remaining(event.capacity, summary.sold),
      revenue: summary.revenue,
      currency: summary.currency,
      refreshed_at: summary.refreshed_at
    }
  end

  defp summary_for_list_event(event_id) do
    case HotStateAggregator.summary_for_event(event_id) do
      {:ok, summary} ->
        normalize_summary(summary)

      :miss ->
        case SnapshotReader.summary_for_event(event_id) do
          {:ok, summary} -> normalize_summary(summary)
          _other -> empty_summary()
        end
    end
  end

  defp operational_status_breakdown_map(event_id) do
    rows =
      Repo.all(
        from item in "sales_order_items",
          join: order in "sales_orders",
          on: field(order, :id) == field(item, :order_id),
          where:
            field(item, :event_id) == type(^event_id, :binary_id) and
              field(item, :mapping_status) == "mapped" and
              field(item, :item_kind) == "ticket",
          group_by: field(order, :status),
          select: %{status: field(order, :status), count: sum(field(item, :quantity))}
      )

    Map.new(rows, &{to_string(&1.status), count_value(&1.count)})
  end

  defp read_ticket_types(event_id) do
    TicketType
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read(domain: Catalog)
  end

  defp recent_order_rows(event_id, limit, offset) do
    Repo.all(
      from item in "sales_order_items",
        join: order in "sales_orders",
        on: field(order, :id) == field(item, :order_id),
        where: field(item, :event_id) == type(^event_id, :binary_id),
        group_by: [
          field(order, :id),
          field(order, :order_number),
          field(order, :status),
          field(order, :currency),
          field(order, :raw_total),
          field(order, :customer_name),
          field(order, :customer_email),
          field(order, :completed_at),
          field(order, :updated_at_source)
        ],
        order_by: [desc: field(order, :updated_at_source), desc: field(order, :id)],
        limit: ^limit,
        offset: ^offset,
        select: %{
          order_id: type(field(order, :id), :binary_id),
          order_number: field(order, :order_number),
          status: field(order, :status),
          currency: field(order, :currency),
          raw_total: field(order, :raw_total),
          customer_name: field(order, :customer_name),
          customer_email: field(order, :customer_email),
          completed_at: field(order, :completed_at),
          updated_at_source: field(order, :updated_at_source)
        }
    )
  end

  defp unmapped_item_rows(event_id, limit, offset) do
    Repo.all(
      from item in "sales_order_items",
        join: order in "sales_orders",
        on: field(order, :id) == field(item, :order_id),
        where:
          field(item, :event_id) == type(^event_id, :binary_id) and
            field(item, :mapping_status) in ["pending_mapping_resolution", "unmapped"],
        order_by: [desc: field(item, :updated_at), desc: field(item, :id)],
        limit: ^limit,
        offset: ^offset,
        select: %{
          order_item_id: type(field(item, :id), :binary_id),
          order_number: field(order, :order_number),
          name: field(item, :name),
          woo_product_id: field(item, :woo_product_id),
          woo_variation_id: field(item, :woo_variation_id),
          quantity: field(item, :quantity),
          mapping_status: field(item, :mapping_status),
          updated_at: field(item, :updated_at)
        }
    )
  end

  defp normalize_summary(summary) when is_map(summary) do
    %{
      sold: Map.get(summary, :total_sold, Map.get(summary, "total_sold", 0)) || 0,
      revenue:
        Map.get(summary, :total_revenue, Map.get(summary, "total_revenue", @zero)) || @zero,
      currency:
        Map.get(summary, :currency, Map.get(summary, "currency")) ||
          Application.fetch_env!(:event_sales, :default_currency),
      refreshed_at:
        Map.get(summary, :refreshed_at, Map.get(summary, "refreshed_at")) ||
          Map.get(summary, :updated_at, Map.get(summary, "updated_at"))
    }
  end

  defp empty_summary do
    %{
      sold: 0,
      revenue: @zero,
      currency: Application.fetch_env!(:event_sales, :default_currency),
      refreshed_at: nil
    }
  end

  defp normalize_recent_order(row) do
    row
    |> Map.put(:status, status_atom(row.status))
    |> Map.put(:completed_at, utc_datetime(row.completed_at))
    |> Map.put(:updated_at_source, utc_datetime(row.updated_at_source))
  end

  defp normalize_unmapped_item(row) do
    %{
      row
      | mapping_status: status_atom(row.mapping_status),
        updated_at: utc_datetime(row.updated_at)
    }
  end

  defp status_atom(value) when is_atom(value), do: value
  defp status_atom(value) when is_binary(value), do: String.to_existing_atom(value)

  defp utc_datetime(nil), do: nil
  defp utc_datetime(%DateTime{} = datetime), do: datetime
  defp utc_datetime(%NaiveDateTime{} = datetime), do: DateTime.from_naive!(datetime, "Etc/UTC")

  defp count_value(nil), do: 0
  defp count_value(%Decimal{} = value), do: Decimal.to_integer(value)
  defp count_value(value) when is_integer(value), do: value

  defp remaining(nil, _sold), do: nil
  defp remaining(capacity, sold), do: max(capacity - sold, 0)

  defp lifecycle_filter(query, :past, %DateTime{} = now) do
    Ash.Query.filter(query, not is_nil(starts_at) and not is_nil(ends_at) and ends_at < ^now)
  end

  defp lifecycle_filter(query, _current, %DateTime{} = now) do
    Ash.Query.filter(query, is_nil(starts_at) or is_nil(ends_at) or ends_at >= ^now)
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end
end
