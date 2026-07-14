defmodule EventSales.Sales.OrderItemMapper do
  @moduledoc """
  Applies local catalog mappings to normalized order items.

  Only eligible pending rows are mutated by normal mapping. On-hold orders are
  deferred until a later source update advances their status. Manual
  corrections and terminal mapping states are preserved unless a later
  explicit remap action is introduced and tested.
  """

  require Ash.Query

  alias EventSales.Catalog.{MappingResolver, OrderAttributionResolver}
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Sales
  alias EventSales.Sales.AutomaticMappingPolicy
  alias EventSales.Sales.Resources.{Order, OrderItem}

  @default_queue_limit 50

  @type automatic_mapping_eligibility :: :eligible | :deferred

  @doc """
  Returns whether an order item may be mapped automatically.

  The item must have its parent order loaded. On-hold WooCommerce orders are
  deferred until a later order update advances their status.
  """
  @spec automatic_mapping_eligibility(OrderItem.t()) :: automatic_mapping_eligibility()
  def automatic_mapping_eligibility(%OrderItem{order: %Order{status: status}}) do
    {:ok, eligibility} = AutomaticMappingPolicy.classify_order_status(status)
    eligibility
  end

  @doc """
  Maps one pending order item through local ProductMapping data.

  Non-pending items are returned unchanged.
  """
  @spec map_item(OrderItem.t()) :: {:ok, OrderItem.t()} | {:error, term()}
  def map_item(%OrderItem{mapping_status: status} = item)
      when status not in [:pending_mapping_resolution, :unmapped] do
    {:ok, item}
  end

  def map_item(%OrderItem{} = item) do
    with {:ok, loaded} <- Ash.load(item, :order, domain: Sales),
         %Order{source_system_id: source_system_id} <- loaded.order do
      case automatic_mapping_eligibility(loaded) do
        :eligible -> map_loaded_item(loaded, source_system_id)
        :deferred -> {:ok, loaded}
      end
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

  defp map_loaded_item(
         %OrderItem{attribution_status_reason: :invalid_source_tickera_event_id} = item,
         _source_system_id
       ) do
    set_attribution_status_reason(item, %{
      source_tickera_event_id: item.source_tickera_event_id,
      attribution_status_reason: :invalid_source_tickera_event_id
    })
  end

  defp map_loaded_item(
         %OrderItem{source_tickera_event_id: source_tickera_event_id} = item,
         source_system_id
       )
       when is_integer(source_tickera_event_id) do
    with {:ok, resolution} <-
           OrderAttributionResolver.resolve(
             source_system_id,
             source_tickera_event_id,
             item.woo_product_id,
             item.woo_variation_id
           ) do
      apply_event_first_resolution(item, resolution)
    end
  end

  defp map_loaded_item(%OrderItem{} = item, source_system_id) do
    with {:ok, resolution} <-
           MappingResolver.resolve(
             source_system_id,
             item.woo_product_id,
             item.woo_variation_id
           ) do
      apply_resolution(item, resolution)
    end
  end

  defp apply_event_first_resolution(%OrderItem{} = item, %{status: :mapped} = resolution) do
    Ash.update(
      item,
      %{
        event_id: resolution.event_id,
        ticket_type_id: resolution.ticket_type_id,
        source_tickera_event_id: resolution.source_tickera_event_id,
        attribution_status_reason: resolution.attribution_status_reason
      },
      action: :apply_event_first_mapping,
      domain: Sales
    )
  end

  defp apply_event_first_resolution(%OrderItem{} = item, %{status: :pending} = resolution) do
    set_attribution_status_reason(item, %{
      source_tickera_event_id: resolution.source_tickera_event_id,
      attribution_status_reason: resolution.attribution_status_reason
    })
  end

  defp set_attribution_status_reason(%OrderItem{} = item, attrs) do
    Ash.update(item, attrs, action: :set_attribution_status_reason, domain: Sales)
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
