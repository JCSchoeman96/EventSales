defmodule EventSales.Sales.OrderUpserter do
  @moduledoc """
  Persists normalized WooCommerce order payloads into durable Sales resources.
  """

  require Ash.Query

  alias EventSales.Ingestion.Parsers.WoocommerceOrderParser
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{CouponSnapshot, Order, OrderItem}
  alias EventSales.Sales.SourceVersionGuard

  @type upsert_result :: {:ok, Order.t()} | {:ok, :stale_noop} | {:error, term()}

  @doc """
  Parses and persists a WooCommerce order payload for a source system.
  """
  @spec upsert_order(Ecto.UUID.t(), map()) :: upsert_result()
  def upsert_order(source_system_id, payload)
      when is_binary(source_system_id) and is_map(payload) do
    with {:ok, normalized} <- WoocommerceOrderParser.parse(payload) do
      upsert_normalized_order(source_system_id, normalized)
    end
  end

  @doc """
  Persists an already parsed WooCommerce order for a source system.
  """
  @spec upsert_normalized_order(Ecto.UUID.t(), map()) :: upsert_result()
  def upsert_normalized_order(source_system_id, normalized)
      when is_binary(source_system_id) and is_map(normalized) do
    case find_order(source_system_id, normalized.woo_order_id) do
      {:ok, nil} ->
        create_order_with_children(source_system_id, normalized)

      {:ok, %Order{} = existing} ->
        update_order_with_children(existing, source_system_id, normalized)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Persists the order payload stored on a queued WooCommerce webhook event.
  """
  @spec upsert_from_webhook_event(WebhookEvent.t()) :: upsert_result()
  def upsert_from_webhook_event(%WebhookEvent{
        source_system_id: source_system_id,
        payload: payload
      }) do
    upsert_order(source_system_id, payload)
  end

  defp create_order_with_children(source_system_id, normalized) do
    attrs = order_attrs(source_system_id, normalized)

    with {:ok, order} <- Ash.create(Order, attrs, action: :create_normalized, domain: Sales),
         :ok <- upsert_child_rows(order, normalized) do
      {:ok, order}
    end
  end

  defp update_order_with_children(%Order{} = existing, source_system_id, normalized) do
    cond do
      DateTime.compare(existing.updated_at_source, normalized.updated_at_source) == :gt ->
        {:ok, :stale_noop}

      SourceVersionGuard.allows_update?(existing.updated_at_source, normalized.updated_at_source) ->
        with {:ok, order} <-
               Ash.update(existing, order_attrs(source_system_id, normalized),
                 action: :sync_from_normalized,
                 domain: Sales
               ),
             :ok <- upsert_child_rows(order, normalized) do
          {:ok, order}
        end

      DateTime.compare(existing.updated_at_source, normalized.updated_at_source) == :eq ->
        with :ok <- upsert_child_rows(existing, normalized) do
          {:ok, existing}
        end

      true ->
        {:ok, :stale_noop}
    end
  end

  defp upsert_child_rows(%Order{} = order, normalized) do
    with :ok <- upsert_order_items(order, normalized.line_items),
         :ok <- upsert_coupons(order, normalized.coupons) do
      :ok
    end
  end

  defp upsert_order_items(%Order{} = order, line_items) do
    Enum.reduce_while(line_items, :ok, fn line_item, :ok ->
      case upsert_order_item(order, line_item) do
        {:ok, _item} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp upsert_order_item(%Order{} = order, line_item) do
    case find_order_item(order.id, line_item.woo_line_item_id) do
      {:ok, nil} ->
        attrs =
          line_item
          |> Map.take([
            :woo_line_item_id,
            :woo_product_id,
            :woo_variation_id,
            :name,
            :quantity,
            :line_subtotal,
            :line_total,
            :discount_total,
            :item_kind,
            :mapping_status
          ])
          |> Map.put(:order_id, order.id)

        Ash.create(OrderItem, attrs, action: :create_normalized, domain: Sales)

      {:ok, %OrderItem{} = existing} ->
        attrs =
          Map.take(line_item, [
            :woo_product_id,
            :woo_variation_id,
            :name,
            :quantity,
            :line_subtotal,
            :line_total,
            :discount_total
          ])

        Ash.update(existing, attrs, action: :sync_from_order, domain: Sales)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upsert_coupons(%Order{} = order, coupons) do
    Enum.reduce_while(coupons, :ok, fn coupon, :ok ->
      case upsert_coupon(order, coupon) do
        {:ok, _coupon} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp upsert_coupon(%Order{} = order, coupon) do
    case find_coupon(order.id, coupon.code) do
      {:ok, nil} ->
        attrs =
          coupon
          |> Map.take([:code, :discount_amount, :discount_tax])
          |> Map.put(:order_id, order.id)

        Ash.create(CouponSnapshot, attrs, action: :create_snapshot, domain: Sales)

      {:ok, %CouponSnapshot{} = existing} ->
        attrs = Map.take(coupon, [:discount_amount, :discount_tax])
        Ash.update(existing, attrs, action: :sync_from_order, domain: Sales)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_order(source_system_id, woo_order_id) do
    Order
    |> Ash.Query.filter(source_system_id == ^source_system_id and woo_order_id == ^woo_order_id)
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Sales)
  end

  defp find_order_item(order_id, woo_line_item_id) do
    OrderItem
    |> Ash.Query.filter(order_id == ^order_id and woo_line_item_id == ^woo_line_item_id)
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Sales)
  end

  defp find_coupon(order_id, code) do
    CouponSnapshot
    |> Ash.Query.filter(order_id == ^order_id and code == ^code)
    |> Ash.Query.limit(1)
    |> Ash.read_one(domain: Sales)
  end

  defp order_attrs(source_system_id, normalized) do
    normalized
    |> Map.take([
      :woo_order_id,
      :order_number,
      :status,
      :currency,
      :completed_at,
      :created_at_source,
      :updated_at_source,
      :customer_name,
      :customer_email,
      :raw_total,
      :raw_discount_total,
      :raw_tax_total,
      :payment_method,
      :payment_method_title,
      :payment_gateway_transaction_id
    ])
    |> Map.put(:source_system_id, source_system_id)
  end
end
