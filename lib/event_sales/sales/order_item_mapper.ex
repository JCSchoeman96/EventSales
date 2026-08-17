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
  Re-evaluates one exact order item through canonical attribution authority.

  Unlike normal automatic mapping, this operation also re-evaluates mapped
  rows. The target event is a scoping expectation and is never used to set
  attribution directly.
  """
  @spec reconcile_item(OrderItem.t(), Ecto.UUID.t()) ::
          {:ok, OrderItem.t()} | {:ok, :deferred} | {:error, term()}
  def reconcile_item(%OrderItem{} = item, target_event_id) when is_binary(target_event_id) do
    with {:ok, loaded} <- Ash.load(item, :order, domain: Sales),
         %Order{source_system_id: source_system_id} <- loaded.order do
      case automatic_mapping_eligibility(loaded) do
        :eligible -> reconcile_eligible_item(loaded, source_system_id, target_event_id)
        :deferred -> {:ok, :deferred}
      end
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :order_not_loaded}
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
    apply_normal_resolution(item, {
      :event_first,
      %{
        status: :pending,
        source_tickera_event_id: item.source_tickera_event_id,
        attribution_status_reason: :invalid_source_tickera_event_id
      }
    })
  end

  defp map_loaded_item(%OrderItem{} = item, source_system_id) do
    with {:ok, resolution} <- canonical_resolution(item, source_system_id) do
      apply_normal_resolution(item, resolution)
    end
  end

  defp canonical_resolution(
         %OrderItem{attribution_status_reason: :invalid_source_tickera_event_id} = item,
         _source_system_id
       ) do
    {:ok,
     {
       :event_first,
       %{
         status: :pending,
         source_tickera_event_id: item.source_tickera_event_id,
         attribution_status_reason: :invalid_source_tickera_event_id
       }
     }}
  end

  defp canonical_resolution(
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
      {:ok, {:event_first, resolution}}
    end
  end

  defp canonical_resolution(%OrderItem{} = item, source_system_id) do
    with {:ok, resolution} <-
           MappingResolver.resolve(
             source_system_id,
             item.woo_product_id,
             item.woo_variation_id
           ) do
      {:ok, {:product_mapping, normalize_mapping_resolution(resolution)}}
    end
  end

  defp normalize_mapping_resolution({:mapped, %ProductMapping{} = mapping}) do
    %{
      status: :mapped,
      event_id: mapping.event_id,
      ticket_type_id: mapping.ticket_type_id,
      source_tickera_event_id: nil,
      attribution_status_reason: nil
    }
  end

  defp normalize_mapping_resolution(:pending_mapping_resolution) do
    %{
      status: :pending,
      event_id: nil,
      ticket_type_id: nil,
      source_tickera_event_id: nil,
      attribution_status_reason: :pending_mapping_resolution
    }
  end

  defp apply_normal_resolution(item, {:event_first, resolution}),
    do: apply_event_first_resolution(item, resolution)

  defp apply_normal_resolution(item, {:product_mapping, resolution}),
    do: apply_product_mapping_resolution(item, resolution)

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

  defp apply_product_mapping_resolution(%OrderItem{} = item, %{status: :mapped} = resolution) do
    Ash.update(
      item,
      %{
        event_id: resolution.event_id,
        ticket_type_id: resolution.ticket_type_id,
        woo_product_id: item.woo_product_id,
        woo_variation_id: item.woo_variation_id,
        name: item.name
      },
      action: :apply_mapping,
      domain: Sales
    )
  end

  defp apply_product_mapping_resolution(%OrderItem{} = item, %{status: :pending}),
    do: {:ok, item}

  defp reconcile_eligible_item(%OrderItem{} = item, source_system_id, target_event_id) do
    with {:ok, resolution} <- canonical_resolution(item, source_system_id),
         :ok <- ensure_target_event(item, target_event_id, resolution),
         {:ok, reconciled} <- apply_reconciliation_resolution(item, resolution) do
      case resolution do
        {_origin, %{status: :mapped}} ->
          {:ok, reconciled}

        {_origin, %{status: :pending, attribution_status_reason: reason}} ->
          {:error, attribution_failure(item, reason)}
      end
    end
  end

  defp ensure_target_event(
         %OrderItem{} = item,
         target_event_id,
         {_origin, %{status: :mapped, event_id: resolved_event_id}}
       ) do
    if target_event_id == resolved_event_id do
      :ok
    else
      {:error, attribution_failure(item, {:target_event_mismatch, resolved_event_id})}
    end
  end

  defp ensure_target_event(_item, _target_event_id, {_origin, %{status: :pending}}), do: :ok

  defp apply_reconciliation_resolution(
         %OrderItem{} = item,
         {_origin, %{status: :mapped} = resolution}
       ) do
    attrs =
      resolution
      |> Map.take([
        :event_id,
        :ticket_type_id,
        :source_tickera_event_id,
        :attribution_status_reason
      ])

    Ash.update(item, attrs, action: :sync_from_mapped_import, domain: Sales)
  end

  defp apply_reconciliation_resolution(
         %OrderItem{} = item,
         {_origin, %{status: :pending} = resolution}
       ) do
    attrs =
      resolution
      |> Map.take([:source_tickera_event_id, :attribution_status_reason])

    set_attribution_status_reason(item, attrs)
  end

  defp attribution_failure(%OrderItem{woo_line_item_id: line_item_id}, reason) do
    {:event_line_attribution_mismatch, line_item_id, reason}
  end
end
