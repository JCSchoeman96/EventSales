defmodule EventSales.Catalog.MissingCatalogResolver do
  @moduledoc """
  Retries local mapping for order items affected by missing catalog metadata.

  This resolver never calls WooCommerce REST and never creates product mappings.
  Product metadata is informational only; EventSales mapping remains a local
  `ProductMapping` decision.
  """

  require Ash.Query

  alias EventSales.Sales
  alias EventSales.Sales.OrderItemMapper
  alias EventSales.Sales.Resources.OrderItem

  @type recovery_result :: %{
          mapped: non_neg_integer(),
          marked_unmapped: non_neg_integer(),
          unchanged: non_neg_integer()
        }

  @doc """
  Retries mapping for pending order items matching source/product/variation.

  On-hold order items are intentionally deferred and remain pending. Other
  matching rows that remain pending after local mapping is retried are marked
  `:unmapped` through the existing Ash action.
  """
  @spec recover_product(Ecto.UUID.t(), integer(), integer() | nil, keyword()) ::
          {:ok, recovery_result()} | {:error, term()}
  def recover_product(source_system_id, woo_product_id, woo_variation_id, _opts \\ [])
      when is_binary(source_system_id) and is_integer(woo_product_id) do
    with {:ok, items} <- pending_items(source_system_id, woo_product_id, woo_variation_id) do
      recover_items(items)
    end
  end

  defp pending_items(source_system_id, woo_product_id, woo_variation_id) do
    base_pending_query(source_system_id, woo_product_id)
    |> variation_filter(woo_variation_id)
    |> Ash.Query.load(:order)
    |> Ash.read(domain: Sales)
  end

  defp base_pending_query(source_system_id, woo_product_id) do
    Ash.Query.filter(
      OrderItem,
      order.source_system_id == ^source_system_id and
        woo_product_id == ^woo_product_id and
        mapping_status == :pending_mapping_resolution
    )
  end

  defp variation_filter(query, nil), do: Ash.Query.filter(query, is_nil(woo_variation_id))

  defp variation_filter(query, woo_variation_id),
    do: Ash.Query.filter(query, woo_variation_id == ^woo_variation_id)

  defp recover_items(items) do
    Enum.reduce_while(items, {:ok, %{mapped: 0, marked_unmapped: 0, unchanged: 0}}, fn item,
                                                                                       {:ok, acc} ->
      case recover_item(item) do
        {:ok, :mapped} -> {:cont, {:ok, Map.update!(acc, :mapped, &(&1 + 1))}}
        {:ok, :marked_unmapped} -> {:cont, {:ok, Map.update!(acc, :marked_unmapped, &(&1 + 1))}}
        {:ok, :unchanged} -> {:cont, {:ok, Map.update!(acc, :unchanged, &(&1 + 1))}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp recover_item(%OrderItem{} = item) do
    case OrderItemMapper.automatic_mapping_eligibility(item) do
      :deferred ->
        {:ok, :unchanged}

      :eligible ->
        recover_eligible_item(item)
    end
  end

  defp recover_eligible_item(%OrderItem{} = item) do
    case OrderItemMapper.map_item(item) do
      {:ok, %OrderItem{mapping_status: :mapped}} ->
        {:ok, :mapped}

      {:ok, %OrderItem{mapping_status: :pending_mapping_resolution} = pending} ->
        case Ash.update(pending, %{}, action: :mark_unmapped, domain: Sales) do
          {:ok, %OrderItem{}} -> {:ok, :marked_unmapped}
          {:error, reason} -> {:error, reason}
        end

      {:ok, %OrderItem{}} ->
        {:ok, :unchanged}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
