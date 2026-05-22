defmodule EventSales.Exports.EventSalesCsv do
  @moduledoc """
  Event-scoped CSV exports for Slice 18.

  Exports are admin-only, PII-free, and generated in bounded pages.
  """

  import Ecto.Query
  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.Event
  alias EventSales.Exports.CsvStream
  alias EventSales.Repo

  @summary_headers [
    "row_type",
    "event_id",
    "event_name",
    "ticket_type_id",
    "ticket_type_name",
    "capacity",
    "sold",
    "remaining",
    "revenue",
    "currency"
  ]

  @orders_headers [
    "event_id",
    "event_name",
    "order_id",
    "order_number",
    "order_status",
    "woo_line_item_id",
    "woo_product_id",
    "woo_variation_id",
    "item_name",
    "item_kind",
    "mapping_status",
    "ticket_type_id",
    "ticket_type_name",
    "quantity",
    "line_total",
    "currency",
    "completed_at",
    "updated_at_source"
  ]

  @default_max_rows 10_000
  @page_size 500
  @zero Decimal.new("0")

  @spec summary_csv(Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, Enumerable.t(), boolean()} | {:error, :forbidden | :not_found}
  def summary_csv(event_id, opts \\ []) do
    with :ok <- authorize(opts),
         {:ok, event} <- fetch_event(event_id) do
      max_rows = max_rows(opts)
      rows = summary_rows(event)
      visible_rows = Enum.take(rows, max_rows)
      truncated? = length(rows) > max_rows

      {:ok, CsvStream.encode_rows([@summary_headers | visible_rows]), truncated?}
    end
  end

  @spec orders_csv(Ecto.UUID.t() | String.t(), keyword()) ::
          {:ok, Enumerable.t(), boolean()} | {:error, :forbidden | :not_found}
  def orders_csv(event_id, opts \\ []) do
    with :ok <- authorize(opts),
         {:ok, event} <- fetch_event(event_id) do
      max_rows = max_rows(opts)
      truncated? = order_row_count(event.id) > max_rows

      stream =
        [@orders_headers]
        |> Stream.concat(order_row_stream(event, max_rows))
        |> CsvStream.encode_rows()

      {:ok, stream, truncated?}
    end
  end

  defp authorize(opts) do
    if opts |> Keyword.get(:actor) |> Policies.global_admin?() do
      :ok
    else
      {:error, :forbidden}
    end
  end

  defp fetch_event(event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, uuid} ->
        Event
        |> Ash.Query.filter(id == ^uuid)
        |> Ash.read_one(domain: Catalog)
        |> case do
          {:ok, %Event{} = event} -> {:ok, event}
          {:ok, nil} -> {:error, :not_found}
          {:error, _reason} -> {:error, :not_found}
        end

      :error ->
        {:error, :not_found}
    end
  end

  defp summary_rows(%Event{} = event) do
    ticket_rows =
      event.id
      |> ticket_type_summary_rows()
      |> Enum.map(&summary_ticket_row(event, &1))

    ticket_rows ++ [total_summary_row(event, ticket_rows)]
  end

  defp ticket_type_summary_rows(event_id) do
    Repo.all(
      from ticket in "catalog_ticket_types",
        left_join: item in "sales_order_items",
        on:
          field(item, :ticket_type_id) == field(ticket, :id) and
            field(item, :event_id) == type(^event_id, :binary_id) and
            field(item, :mapping_status) == "mapped" and
            field(item, :item_kind) == "ticket",
        left_join: order in "sales_orders",
        on: field(order, :id) == field(item, :order_id) and field(order, :status) == "completed",
        where: field(ticket, :event_id) == type(^event_id, :binary_id),
        group_by: [
          field(ticket, :id),
          field(ticket, :name),
          field(ticket, :capacity)
        ],
        order_by: [asc: field(ticket, :name), asc: field(ticket, :id)],
        select: %{
          ticket_type_id: type(field(ticket, :id), :binary_id),
          ticket_type_name: field(ticket, :name),
          capacity: field(ticket, :capacity),
          sold:
            fragment(
              "COALESCE(SUM(CASE WHEN ? IS NOT NULL THEN ? ELSE 0 END), 0)",
              field(order, :id),
              field(item, :quantity)
            ),
          revenue:
            fragment(
              "COALESCE(SUM(CASE WHEN ? IS NOT NULL THEN ? ELSE 0 END), 0)",
              field(order, :id),
              field(item, :line_total)
            ),
          currency: max(field(order, :currency))
        }
    )
  end

  defp summary_ticket_row(%Event{} = event, row) do
    sold = count_value(row.sold)

    [
      "ticket_type",
      event.id,
      event.name,
      row.ticket_type_id,
      row.ticket_type_name,
      row.capacity,
      sold,
      remaining(row.capacity, sold),
      row.revenue || @zero,
      row.currency || default_currency()
    ]
  end

  defp total_summary_row(%Event{} = event, ticket_rows) do
    sold =
      ticket_rows
      |> Enum.map(&Enum.at(&1, 6))
      |> Enum.sum()

    revenue =
      ticket_rows
      |> Enum.map(&Enum.at(&1, 8))
      |> Enum.reduce(@zero, &Decimal.add/2)

    currency =
      ticket_rows
      |> Enum.map(&Enum.at(&1, 9))
      |> Enum.find(default_currency(), &(&1 not in [nil, ""]))

    [
      "total",
      event.id,
      event.name,
      nil,
      "Total",
      event.capacity,
      sold,
      remaining(event.capacity, sold),
      revenue,
      currency
    ]
  end

  defp order_row_stream(%Event{} = event, max_rows) do
    Stream.resource(
      fn -> 0 end,
      fn
        :halt ->
          {:halt, :halt}

        offset when offset >= max_rows ->
          {:halt, :halt}

        offset ->
          rows = order_page(event, min(@page_size, max_rows - offset), offset)
          next_offset = offset + length(rows)

          cond do
            rows == [] -> {:halt, :halt}
            next_offset >= max_rows -> {rows, :halt}
            length(rows) < @page_size -> {rows, :halt}
            true -> {rows, next_offset}
          end
      end,
      fn _state -> :ok end
    )
  end

  defp order_page(%Event{} = event, limit, offset) do
    Repo.all(
      from item in "sales_order_items",
        join: order in "sales_orders",
        on: field(order, :id) == field(item, :order_id),
        left_join: ticket in "catalog_ticket_types",
        on: field(ticket, :id) == field(item, :ticket_type_id),
        where: field(item, :event_id) == type(^event.id, :binary_id),
        order_by: [
          desc: field(order, :updated_at_source),
          desc: field(order, :id),
          asc: field(item, :woo_line_item_id)
        ],
        limit: ^limit,
        offset: ^offset,
        select: [
          type(^event.id, :binary_id),
          ^event.name,
          type(field(order, :id), :binary_id),
          field(order, :order_number),
          field(order, :status),
          field(item, :woo_line_item_id),
          field(item, :woo_product_id),
          field(item, :woo_variation_id),
          field(item, :name),
          field(item, :item_kind),
          field(item, :mapping_status),
          type(field(item, :ticket_type_id), :binary_id),
          field(ticket, :name),
          field(item, :quantity),
          field(item, :line_total),
          field(order, :currency),
          field(order, :completed_at),
          field(order, :updated_at_source)
        ]
    )
  end

  defp order_row_count(event_id) do
    Repo.one(
      from item in "sales_order_items",
        where: field(item, :event_id) == type(^event_id, :binary_id),
        select: count()
    )
  end

  defp max_rows(opts) do
    opts
    |> Keyword.get(:max_rows, @default_max_rows)
    |> normalize_positive_integer(@default_max_rows)
    |> min(@default_max_rows)
  end

  defp normalize_positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp normalize_positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _other -> default
    end
  end

  defp normalize_positive_integer(_value, default), do: default

  defp count_value(nil), do: 0
  defp count_value(%Decimal{} = value), do: Decimal.to_integer(value)
  defp count_value(value) when is_integer(value), do: value

  defp remaining(nil, _sold), do: nil
  defp remaining(capacity, sold), do: max(capacity - sold, 0)

  defp default_currency, do: Application.fetch_env!(:event_sales, :default_currency)
end
