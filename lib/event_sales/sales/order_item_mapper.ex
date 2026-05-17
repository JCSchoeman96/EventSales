defmodule EventSales.Sales.OrderItemMapper do
  @moduledoc """
  Applies local catalog mappings to normalized order items.

  Only pending rows are mutated by normal mapping. Manual corrections and
  terminal mapping states are preserved unless a later explicit remap action is
  introduced and tested.
  """

  require Ash.Query

  alias EventSales.Catalog.MappingResolver
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem}

  @default_queue_limit 50

  @doc """
  Maps one pending order item through local ProductMapping data.

  Non-pending items are returned unchanged.
  """
  @spec map_item(OrderItem.t()) :: {:ok, OrderItem.t()} | {:error, term()}
  def map_item(%OrderItem{mapping_status: status} = item)
      when status != :pending_mapping_resolution do
    {:ok, item}
  end

  def map_item(%OrderItem{} = item) do
    with {:ok, loaded} <- Ash.load(item, :order, domain: Sales),
         %Order{source_system_id: source_system_id} <- loaded.order,
         {:ok, resolution} <-
           MappingResolver.resolve(
             source_system_id,
             loaded.woo_product_id,
             loaded.woo_variation_id
           ) do
      apply_resolution(loaded, resolution)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Maps pending items for an order and leaves all other mapping states unchanged.
  """
  @spec map_pending_items_for_order(Order.t()) :: {:ok, [OrderItem.t()]} | {:error, term()}
  def map_pending_items_for_order(%Order{id: order_id}) do
    with {:ok, items} <- pending_items(order_id),
         {:ok, mapped_items} <- map_pending_items(items) do
      {:ok, Enum.reverse(mapped_items)}
    end
  end

  @doc """
  Lists rows that need mapping attention for the internal admin queue.
  """
  @spec list_unmapped_queue(keyword()) :: {:ok, [OrderItem.t()]} | {:error, term()}
  def list_unmapped_queue(opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_queue_limit)

    OrderItem
    |> Ash.Query.filter(
      mapping_status == :pending_mapping_resolution or mapping_status == :unmapped
    )
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.Query.load(:order)
    |> Ash.read(domain: Sales)
  end

  defp pending_items(order_id) do
    OrderItem
    |> Ash.Query.filter(order_id == ^order_id and mapping_status == :pending_mapping_resolution)
    |> Ash.Query.sort(woo_line_item_id: :asc)
    |> Ash.read(domain: Sales)
  end

  defp map_pending_items(items) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, mapped_items} ->
      map_pending_item(item, mapped_items)
    end)
  end

  defp map_pending_item(item, mapped_items) do
    case map_item(item) do
      {:ok, %OrderItem{mapping_status: :mapped} = mapped} ->
        {:cont, {:ok, [mapped | mapped_items]}}

      {:ok, %OrderItem{}} ->
        {:cont, {:ok, mapped_items}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp apply_resolution(%OrderItem{} = item, {:mapped, %ProductMapping{} = mapping}) do
    Ash.update(
      item,
      %{
        event_id: mapping.event_id,
        ticket_type_id: mapping.ticket_type_id,
        woo_product_id: item.woo_product_id,
        woo_variation_id: item.woo_variation_id,
        name: item.name
      },
      action: :apply_mapping,
      domain: Sales
    )
  end

  defp apply_resolution(%OrderItem{} = item, :pending_mapping_resolution), do: {:ok, item}
end
