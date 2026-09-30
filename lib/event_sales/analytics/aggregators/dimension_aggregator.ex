defmodule EventSales.Analytics.Aggregators.DimensionAggregator do
  @moduledoc """
  Builds event-scoped dimensional gross ticket rows from recognised sales.

  Each call uses one grouped query per dimension family and returns only
  aggregate rows. M5-02D owns persistence of those rows.
  """

  import Ecto.Query

  alias EventSales.Analytics.Aggregators.EventAggregator
  alias EventSales.Repo

  @dimension_order %{ticket_type: 0, source_product: 1, source_variation: 2}

  @type dimension_kind :: :ticket_type | :source_product | :source_variation
  @type dimension_row :: %{
          required(:event_id) => Ecto.UUID.t(),
          required(:currency) => String.t(),
          required(:dimension_kind) => dimension_kind(),
          required(:ticket_type_id) => Ecto.UUID.t() | nil,
          required(:source_system_id) => Ecto.UUID.t() | nil,
          required(:woo_product_id) => pos_integer() | nil,
          required(:woo_variation_id) => pos_integer() | nil,
          required(:gross_ticket_quantity) => non_neg_integer(),
          required(:gross_ticket_value) => Decimal.t()
        }

  @type aggregation_error ::
          :invalid_event_id | :incomplete_financial_primitives | :invalid_dimension_identity

  @doc "Returns normalized dimensional gross rows for one event."
  @spec gross_rows_for_event(Ecto.UUID.t()) ::
          {:ok, [dimension_row()]} | {:error, aggregation_error()}
  def gross_rows_for_event(event_id) do
    case cast_event_id(event_id) do
      {:ok, event_id} -> aggregate_for_event(event_id)
      error -> error
    end
  end

  defp aggregate_for_event(event_id) do
    dumped_event_id = Ecto.UUID.dump!(event_id)

    ticket_type_rows = Repo.all(ticket_type_query(dumped_event_id))
    source_product_rows = Repo.all(source_product_query(dumped_event_id))
    source_variation_rows = Repo.all(source_variation_query(dumped_event_id))

    raw_rows = ticket_type_rows ++ source_product_rows ++ source_variation_rows

    if Enum.any?(raw_rows, &(&1.incomplete_count > 0)) do
      {:error, :incomplete_financial_primitives}
    else
      normalize_and_sort(ticket_type_rows, source_product_rows, source_variation_rows, event_id)
    end
  end

  defp normalize_and_sort(ticket_type_rows, source_product_rows, source_variation_rows, event_id) do
    with {:ok, ticket_rows} <- normalize_ticket_type_rows(ticket_type_rows, event_id),
         {:ok, product_rows} <- normalize_source_product_rows(source_product_rows, event_id),
         {:ok, variation_rows} <- normalize_source_variation_rows(source_variation_rows, event_id) do
      {:ok, sort_rows(ticket_rows ++ product_rows ++ variation_rows)}
    end
  end

  defp cast_event_id(event_id) do
    case Ecto.UUID.cast(event_id) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :invalid_event_id}
    end
  end

  defp ticket_type_query(event_id) do
    recognised_filters = EventAggregator.recognised_sale_item_filters(event_id)

    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where: ^recognised_filters,
      group_by: [o.currency, oi.ticket_type_id],
      select: %{
        currency: o.currency,
        ticket_type_id: oi.ticket_type_id,
        gross_ticket_quantity: sum(oi.quantity),
        gross_ticket_value: sum(fragment("? + ?", oi.line_total, oi.line_total_tax)),
        incomplete_count:
          count(
            fragment(
              "CASE WHEN ? IS NULL OR ? IS NULL THEN 1 END",
              oi.line_total,
              oi.line_total_tax
            )
          )
      }
  end

  defp source_product_query(event_id) do
    recognised_filters = EventAggregator.recognised_sale_item_filters(event_id)

    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where: ^recognised_filters,
      group_by: [o.currency, o.source_system_id, oi.woo_product_id],
      select: %{
        currency: o.currency,
        source_system_id: o.source_system_id,
        woo_product_id: oi.woo_product_id,
        gross_ticket_quantity: sum(oi.quantity),
        gross_ticket_value: sum(fragment("? + ?", oi.line_total, oi.line_total_tax)),
        incomplete_count:
          count(
            fragment(
              "CASE WHEN ? IS NULL OR ? IS NULL THEN 1 END",
              oi.line_total,
              oi.line_total_tax
            )
          )
      }
  end

  defp source_variation_query(event_id) do
    recognised_filters = EventAggregator.recognised_sale_item_filters(event_id)

    from oi in "sales_order_items",
      join: o in "sales_orders",
      on: oi.order_id == o.id,
      where: ^recognised_filters,
      where: not is_nil(oi.woo_variation_id),
      group_by: [o.currency, o.source_system_id, oi.woo_product_id, oi.woo_variation_id],
      select: %{
        currency: o.currency,
        source_system_id: o.source_system_id,
        woo_product_id: oi.woo_product_id,
        woo_variation_id: oi.woo_variation_id,
        gross_ticket_quantity: sum(oi.quantity),
        gross_ticket_value: sum(fragment("? + ?", oi.line_total, oi.line_total_tax)),
        incomplete_count:
          count(
            fragment(
              "CASE WHEN ? IS NULL OR ? IS NULL THEN 1 END",
              oi.line_total,
              oi.line_total_tax
            )
          )
      }
  end

  defp normalize_ticket_type_rows(rows, event_id) do
    normalize_rows(rows, fn row ->
      with {:ok, ticket_type_id} <- load_uuid(row.ticket_type_id) do
        {:ok,
         build_row(event_id, row.currency, :ticket_type, %{
           ticket_type_id: ticket_type_id,
           source_system_id: nil,
           woo_product_id: nil,
           woo_variation_id: nil,
           gross_ticket_quantity: quantity_as_integer(row.gross_ticket_quantity),
           gross_ticket_value: row.gross_ticket_value
         })}
      end
    end)
  end

  defp normalize_source_product_rows(rows, event_id) do
    normalize_rows(rows, fn row ->
      with {:ok, source_system_id} <- load_uuid(row.source_system_id),
           true <- is_integer(row.woo_product_id) do
        {:ok,
         build_row(event_id, row.currency, :source_product, %{
           ticket_type_id: nil,
           source_system_id: source_system_id,
           woo_product_id: row.woo_product_id,
           woo_variation_id: nil,
           gross_ticket_quantity: quantity_as_integer(row.gross_ticket_quantity),
           gross_ticket_value: row.gross_ticket_value
         })}
      else
        _ -> {:error, :invalid_dimension_identity}
      end
    end)
  end

  defp normalize_source_variation_rows(rows, event_id) do
    normalize_rows(rows, fn row ->
      with {:ok, source_system_id} <- load_uuid(row.source_system_id),
           true <- is_integer(row.woo_product_id),
           true <- is_integer(row.woo_variation_id) do
        {:ok,
         build_row(event_id, row.currency, :source_variation, %{
           ticket_type_id: nil,
           source_system_id: source_system_id,
           woo_product_id: row.woo_product_id,
           woo_variation_id: row.woo_variation_id,
           gross_ticket_quantity: quantity_as_integer(row.gross_ticket_quantity),
           gross_ticket_value: row.gross_ticket_value
         })}
      else
        _ -> {:error, :invalid_dimension_identity}
      end
    end)
  end

  defp normalize_rows(rows, normalize_row) do
    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case normalize_row.(row) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, :invalid_dimension_identity} -> {:halt, {:error, :invalid_dimension_identity}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp build_row(event_id, currency, dimension_kind, values) do
    Map.merge(
      %{
        event_id: event_id,
        currency: currency,
        dimension_kind: dimension_kind
      },
      values
    )
  end

  defp load_uuid(nil), do: {:error, :invalid_dimension_identity}

  defp load_uuid(value) when is_binary(value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} ->
        {:ok, uuid}

      :error ->
        case Ecto.UUID.cast(value) do
          {:ok, uuid} -> {:ok, uuid}
          :error -> {:error, :invalid_dimension_identity}
        end
    end
  end

  defp load_uuid(_value), do: {:error, :invalid_dimension_identity}

  defp quantity_as_integer(%Decimal{} = quantity), do: Decimal.to_integer(quantity)
  defp quantity_as_integer(quantity) when is_integer(quantity), do: quantity

  defp sort_rows(rows) do
    Enum.sort_by(rows, fn row ->
      {row.currency, @dimension_order[row.dimension_kind], identity_sort_key(row)}
    end)
  end

  defp identity_sort_key(%{dimension_kind: :ticket_type, ticket_type_id: ticket_type_id}),
    do: {ticket_type_id}

  defp identity_sort_key(%{
         dimension_kind: :source_product,
         source_system_id: source_system_id,
         woo_product_id: woo_product_id
       }),
       do: {source_system_id, woo_product_id}

  defp identity_sort_key(%{
         dimension_kind: :source_variation,
         source_system_id: source_system_id,
         woo_product_id: woo_product_id,
         woo_variation_id: woo_variation_id
       }),
       do: {source_system_id, woo_product_id, woo_variation_id}
end
