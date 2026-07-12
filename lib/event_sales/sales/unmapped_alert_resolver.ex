defmodule EventSales.Sales.UnmappedAlertResolver do
  @moduledoc """
  Admin workflow for resolving a durable unmapped order-item alert.

  Submitted forms choose catalog records, while source and WooCommerce identity
  always come from the persisted order item and its order.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Catalog.{ManualMappingCreator, MissingCatalogResolver}
  alias EventSales.Sales
  alias EventSales.Sales.Resources.OrderItem

  @allowed_mapping_fields ~w(event_id ticket_type_mode ticket_type_id ticket_type_name source_status reason)

  @spec load(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, atom()}
  def load(order_item_id, opts) when is_binary(order_item_id) and is_list(opts) do
    with :ok <- authorize(Keyword.get(opts, :actor)),
         {:ok, item} <- fetch_item(order_item_id),
         :ok <- require_pending(item) do
      {:ok, safe_context(item)}
    end
  end

  def load(_order_item_id, opts) when is_list(opts) do
    with :ok <- authorize(Keyword.get(opts, :actor)), do: {:error, :not_found}
  end

  @spec resolve(Ecto.UUID.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve(order_item_id, params, opts)
      when is_binary(order_item_id) and is_map(params) and is_list(opts) do
    actor = Keyword.get(opts, :actor)

    with :ok <- authorize(actor),
         {:ok, item} <- fetch_item(order_item_id),
         :ok <- require_pending(item),
         {:ok, mapping_result} <-
           ManualMappingCreator.create(mapping_params(item, params), actor: actor) do
      recover_after_mapping(item, mapping_result)
    end
  end

  def resolve(_order_item_id, _params, opts) when is_list(opts) do
    with :ok <- authorize(Keyword.get(opts, :actor)), do: {:error, :not_found}
  end

  @spec retry_recovery(Ecto.UUID.t(), keyword()) ::
          {:ok, MissingCatalogResolver.recovery_result()} | {:error, atom()}
  def retry_recovery(order_item_id, opts) when is_binary(order_item_id) and is_list(opts) do
    with :ok <- authorize(Keyword.get(opts, :actor)),
         {:ok, item} <- fetch_item(order_item_id) do
      recover(item)
    end
  end

  def retry_recovery(_order_item_id, opts) when is_list(opts) do
    with :ok <- authorize(Keyword.get(opts, :actor)), do: {:error, :not_found}
  end

  defp authorize(actor),
    do: if(Policies.global_admin?(actor), do: :ok, else: {:error, :forbidden})

  defp fetch_item(order_item_id) do
    OrderItem
    |> Ash.Query.filter(id == ^order_item_id)
    |> Ash.Query.load(:order)
    |> Ash.read_one(domain: Sales)
    |> case do
      {:ok, %OrderItem{} = item} -> {:ok, item}
      {:ok, nil} -> {:error, :not_found}
      {:error, _reason} -> {:error, :not_found}
    end
  end

  defp require_pending(%OrderItem{mapping_status: :pending_mapping_resolution}), do: :ok
  defp require_pending(%OrderItem{}), do: {:error, :not_pending}

  defp safe_context(item) do
    %{
      order_item_id: item.id,
      source_system_id: item.order.source_system_id,
      order_number: item.order.order_number,
      name: item.name,
      woo_product_id: item.woo_product_id,
      woo_variation_id: item.woo_variation_id,
      mapping_status: item.mapping_status,
      quantity: item.quantity,
      updated_at: item.updated_at
    }
  end

  defp mapping_params(item, params) do
    params
    |> Map.take(@allowed_mapping_fields)
    |> Map.merge(%{
      "source_system_id" => item.order.source_system_id,
      "woo_product_id" => item.woo_product_id,
      "woo_variation_id" => item.woo_variation_id,
      "label" => item.name
    })
  end

  defp recover_after_mapping(item, mapping_result) do
    case recover(item) do
      {:ok, recovery} -> {:ok, Map.put(mapping_result, :recovery, recovery)}
      {:error, _reason} -> {:error, {:recovery_failed, :recovery_failed}}
    end
  end

  defp recover(item) do
    recovery_module().recover_product(
      item.order.source_system_id,
      item.woo_product_id,
      item.woo_variation_id,
      []
    )
  end

  defp recovery_module do
    Application.get_env(:event_sales, :unmapped_alert_recovery_module, MissingCatalogResolver)
  end
end
