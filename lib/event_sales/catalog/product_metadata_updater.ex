defmodule EventSales.Catalog.ProductMetadataUpdater do
  @moduledoc """
  Applies WooCommerce product.updated metadata to local product mappings.

  Product updates are informational metadata. They can refresh
  `ProductMapping.current_label`, but they must never create mappings, remap
  products, mutate order items, or call WooCommerce REST.
  """

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.ProductMetadataCache
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Telemetry

  @type update_result ::
          {:ok,
           %{
             status: :updated,
             mapping: ProductMapping.t(),
             previous_label: String.t() | nil,
             current_label: String.t()
           }}
          | {:ok,
             %{
               status: :unchanged,
               mapping: ProductMapping.t(),
               current_label: String.t() | nil
             }}
          | {:ignored, :unknown_product,
             %{woo_product_id: pos_integer(), current_label: String.t()}}
          | {:error, {:invalid_product_payload, atom(), atom()}}
          | {:error, term()}

  @doc """
  Refreshes `ProductMapping.current_label` from a WooCommerce product payload.
  """
  @spec update_from_payload(Ecto.UUID.t(), map()) :: update_result()
  def update_from_payload(source_system_id, payload)
      when is_binary(source_system_id) and is_map(payload) do
    with {:ok, woo_product_id} <- parse_product_id(payload),
         {:ok, label} <- parse_product_name(payload),
         {:ok, mapping} <- active_product_mapping(source_system_id, woo_product_id) do
      case mapping do
        %ProductMapping{} ->
          apply_label_update(source_system_id, woo_product_id, mapping, label)

        nil ->
          ProductMetadataCache.invalidate(source_system_id, woo_product_id, nil)
          emit_update(:unknown_product)
          {:ignored, :unknown_product, %{woo_product_id: woo_product_id, current_label: label}}
      end
    else
      {:error, {:invalid_product_payload, _field, _reason} = reason} ->
        emit_update(:invalid_payload)
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def update_from_payload(_source_system_id, _payload) do
    emit_update(:invalid_payload)
    {:error, {:invalid_product_payload, :payload, :invalid}}
  end

  defp apply_label_update(source_system_id, woo_product_id, %ProductMapping{} = mapping, label) do
    if mapping.current_label == label do
      emit_update(:unchanged)
      {:ok, %{status: :unchanged, mapping: mapping, current_label: mapping.current_label}}
    else
      case Ash.update(mapping, %{current_label: label},
             action: :update_current_label,
             domain: Catalog
           ) do
        {:ok, %ProductMapping{} = updated} ->
          ProductMetadataCache.invalidate(source_system_id, woo_product_id, nil)
          emit_update(:updated)

          {:ok,
           %{
             status: :updated,
             mapping: updated,
             previous_label: mapping.current_label,
             current_label: updated.current_label
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp active_product_mapping(source_system_id, woo_product_id) do
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

  defp parse_product_id(payload) do
    case Map.fetch(payload, "id") do
      {:ok, value} -> normalize_positive_integer(value, :id)
      :error -> {:error, {:invalid_product_payload, :id, :missing}}
    end
  end

  defp parse_product_name(payload) do
    case Map.fetch(payload, "name") do
      {:ok, value} when is_binary(value) ->
        label = String.trim(value)

        if label == "" do
          {:error, {:invalid_product_payload, :name, :blank}}
        else
          {:ok, label}
        end

      {:ok, _value} ->
        {:error, {:invalid_product_payload, :name, :invalid}}

      :error ->
        {:error, {:invalid_product_payload, :name, :missing}}
    end
  end

  defp normalize_positive_integer(value, _field) when is_integer(value) and value > 0,
    do: {:ok, value}

  defp normalize_positive_integer(value, field) when is_integer(value) and value <= 0,
    do: {:error, {:invalid_product_payload, field, :invalid}}

  defp normalize_positive_integer(value, field) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> {:ok, parsed}
      _ -> {:error, {:invalid_product_payload, field, :invalid}}
    end
  end

  defp normalize_positive_integer(_value, field),
    do: {:error, {:invalid_product_payload, field, :invalid}}

  defp emit_update(result) do
    Telemetry.emit(Telemetry.product_metadata_update(), %{count: 1}, %{
      result: result,
      source: :woocommerce
    })
  end
end
