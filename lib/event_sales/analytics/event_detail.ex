defmodule EventSales.Analytics.EventDetail do
  @moduledoc """
  Admin-only read facade for Slice 12 event list and event detail pages.

  The event list uses hot/snapshot summaries only. Scoped detail aggregates are
  computed for exactly one event from durable EventSales state.
  """

  import Ecto.Query

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.AdminRead.Pagination, as: AdminReadPagination
  alias EventSales.Analytics.{HotStateAggregator, SnapshotReader}
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, TicketType}
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
         {:ok, events} <- read_events(per_page + 1, offset) do
      {visible_events, has_next?} = AdminReadPagination.split_page(events, per_page)

      {:ok,
       %{
         rows: Enum.map(visible_events, &event_list_row/1),
         page: AdminReadPagination.page_info(page, per_page, has_next?)
       }}
    end
  end

  @spec get_event_detail(Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, event_detail()} | :not_found | {:error, term()}
  def get_event_detail(event_id, opts \\ []) when is_binary(event_id) do
    with :ok <- authorize(opts),
         {:ok, event_id} <- cast_uuid(event_id),
         {:ok, %Event{} = event} <- fetch_event(event_id),
         {:ok, summary} <- scoped_summary(event_id),
         {:ok, status_breakdown} <- status_breakdown(event_id),
         {:ok, ticket_types} <- ticket_type_breakdown(event) do
      {:ok,
       %{
         event_id: event.id,
         event_name: event.name,
         slug: event.slug,
         status: event.status,
         capacity: event.capacity,
         sold: summary.sold,
         remaining: remaining(event.capacity, summary.sold),
         revenue: summary.revenue,
         currency: summary.currency,
         refreshed_at: nil,
         status_breakdown: status_breakdown,
         ticket_types: ticket_types
       }}
    else
      {:ok, nil} -> :not_found
      {:error, :not_found} -> :not_found
      {:error, reason} -> {:error, reason}
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

  defp authorize(opts) do
    if opts |> Keyword.get(:actor) |> Policies.global_admin?() do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp read_events(limit, offset) do
    Event
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

  defp event_list_row(%Event{} = event) do
    summary = summary_for_list_event(event.id)

    %{
      event_id: event.id,
      event_name: event.name,
      slug: event.slug,
      status: event.status,
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

  defp scoped_summary(event_id) do
    row =
      Repo.one(
        from item in "sales_order_items",
          join: order in "sales_orders",
          on: field(order, :id) == field(item, :order_id),
          where:
            field(item, :event_id) == type(^event_id, :binary_id) and
              field(item, :mapping_status) == "mapped" and
              field(item, :item_kind) == "ticket" and
              field(order, :status) == "completed",
          select: %{
            sold: sum(field(item, :quantity)),
            revenue: sum(field(item, :line_total)),
            currency: max(field(order, :currency))
          }
      )

    {:ok,
     %{
       sold: count_value(row.sold),
       revenue: row.revenue || @zero,
       currency: row.currency || Application.fetch_env!(:event_sales, :default_currency)
     }}
  end

  defp status_breakdown(event_id) do
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

    {:ok, Map.new(rows, &{to_string(&1.status), count_value(&1.count)})}
  end

  defp ticket_type_breakdown(%Event{} = event) do
    with {:ok, ticket_types} <- read_ticket_types(event.id) do
      sold_by_ticket_type =
        event.id
        |> ticket_type_aggregate_rows()
        |> Map.new(
          &{&1.ticket_type_id, %{sold: count_value(&1.sold), revenue: &1.revenue || @zero}}
        )

      {:ok,
       Enum.map(ticket_types, fn ticket_type ->
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

  defp read_ticket_types(event_id) do
    TicketType
    |> Ash.Query.filter(event_id == ^event_id)
    |> Ash.Query.sort(name: :asc)
    |> Ash.read(domain: Catalog)
  end

  defp ticket_type_aggregate_rows(event_id) do
    Repo.all(
      from item in "sales_order_items",
        join: order in "sales_orders",
        on: field(order, :id) == field(item, :order_id),
        where:
          field(item, :event_id) == type(^event_id, :binary_id) and
            field(item, :mapping_status) == "mapped" and
            field(item, :item_kind) == "ticket" and
            field(order, :status) == "completed",
        group_by: field(item, :ticket_type_id),
        select: %{
          ticket_type_id: type(field(item, :ticket_type_id), :binary_id),
          sold: sum(field(item, :quantity)),
          revenue: sum(field(item, :line_total))
        }
    )
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
    %{
      row
      | status: status_atom(row.status),
        completed_at: utc_datetime(row.completed_at),
        updated_at_source: utc_datetime(row.updated_at_source)
    }
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

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end
end
