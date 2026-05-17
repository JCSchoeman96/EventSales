defmodule EventSales.Catalog.MappingResolver do
  @moduledoc """
  Resolves WooCommerce product identifiers to local EventSales mappings.

  This resolver is intentionally local-only. It reads durable
  `ProductMapping` records and never calls WooCommerce REST or external HTTP
  clients.
  """

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping

  @type resolution :: {:mapped, ProductMapping.t()} | :pending_mapping_resolution

  @doc """
  Resolves a WooCommerce product/variation pair against active local mappings.

  Variation-specific mappings win over product-level mappings. Unknown products
  remain pending so Slice 8.5 can own missing-catalog recovery and final
  fallback behavior.
  """
  @spec resolve(Ecto.UUID.t(), integer(), integer() | nil) ::
          {:ok, resolution()} | {:error, term()}
  def resolve(source_system_id, woo_product_id, woo_variation_id)
      when is_binary(source_system_id) and is_integer(woo_product_id) do
    with {:ok, nil} <- maybe_exact_variation(source_system_id, woo_product_id, woo_variation_id),
         {:ok, nil} <- product_level(source_system_id, woo_product_id) do
      {:ok, :pending_mapping_resolution}
    else
      {:ok, %ProductMapping{} = mapping} -> {:ok, {:mapped, mapping}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_exact_variation(_source_system_id, _woo_product_id, nil), do: {:ok, nil}

  defp maybe_exact_variation(source_system_id, woo_product_id, woo_variation_id) do
    ProductMapping
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and
        woo_product_id == ^woo_product_id and
        woo_variation_id == ^woo_variation_id and
        active == true
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Catalog)
  end

  defp product_level(source_system_id, woo_product_id) do
    ProductMapping
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and
        woo_product_id == ^woo_product_id and
        is_nil(woo_variation_id) and
        active == true
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Catalog)
  end
end
