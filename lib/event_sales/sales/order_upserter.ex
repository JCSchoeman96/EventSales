defmodule EventSales.Sales.OrderUpserter do
  @moduledoc """
  Persists normalized WooCommerce order payloads into durable Sales resources.
  """

  require Ash.Query

  alias EventSales.Ingestion.Parsers.WoocommerceOrderParser
  alias EventSales.Ingestion.Resources.WebhookEvent
  alias EventSales.Sales
  alias EventSales.Sales.OrderItemMapper
  alias EventSales.Sales.Resources.{CouponSnapshot, Order, OrderItem}
  alias EventSales.Sales.SourceVersionGuard

  @type upsert_result :: {:ok, Order.t()} | {:ok, :stale_noop} | {:error, term()}
  @type reconcile_result :: upsert_result()

  @doc """
  Parses and persists a WooCommerce order payload for a source system.
  """
  @spec upsert_order(Ecto.UUID.t(), map()) :: upsert_result()
  @spec upsert_order(Ecto.UUID.t(), map(), keyword()) :: upsert_result()
  def upsert_order(source_system_id, payload, opts \\ [])
      when is_binary(source_system_id) and is_map(payload) do
    with {:ok, normalized} <- WoocommerceOrderParser.parse(payload) do
      upsert_normalized_order(source_system_id, normalized, opts)
    end
  end

  @doc """
  Reconciles the exact current line-item subset for one historical event.

  The full source order remains authoritative for the order header and coupons;
  only its line_items field is replaced with the supplied event subset before
  the existing WooCommerce parser and source-version guard are used.
  """
  @spec reconcile_event_order(Ecto.UUID.t(), Ecto.UUID.t(), map(), list()) :: reconcile_result()
  @spec reconcile_event_order(Ecto.UUID.t(), Ecto.UUID.t(), map(), list(), keyword()) ::
          reconcile_result()
  def reconcile_event_order(
        source_system_id,
        event_id,
        full_order_payload,
        event_line_items,
        opts \\ []
      ) do
    with :ok <- validate_reconciliation_ids(source_system_id, event_id),
         {:ok, full_source_lines} <- validate_full_order_payload(full_order_payload),
         {:ok, current_event_line_ids} <-
           validate_event_line_subset(full_source_lines, event_line_items),
         {:ok, normalized} <-
           WoocommerceOrderParser.parse(
             Map.put(full_order_payload, "line_items", event_line_items)
           ) do
      normalized = put_event_id_on_lines(normalized, event_id)

      reconciliation_opts =
        opts
        |> Keyword.put(:event_reconciliation?, true)
        |> Keyword.put(:map_pending_items?, false)

      case upsert_normalized_order(source_system_id, normalized, reconciliation_opts) do
        {:ok, :stale_noop} = stale ->
          stale

        {:ok, %Order{} = order} ->
          reconcile_accepted_order(
            order,
            event_id,
            current_event_line_ids,
            normalized.coupons,
            opts
          )

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc """
  Persists an already parsed WooCommerce order for a source system.
  """
  @spec upsert_normalized_order(Ecto.UUID.t(), map()) :: upsert_result()
  @spec upsert_normalized_order(Ecto.UUID.t(), map(), keyword()) :: upsert_result()
  def upsert_normalized_order(source_system_id, normalized, opts \\ [])
      when is_binary(source_system_id) and is_map(normalized) do
    case find_order(source_system_id, normalized.woo_order_id) do
      {:ok, nil} ->
        create_order_with_children(source_system_id, normalized, opts)

      {:ok, %Order{} = existing} ->
        update_order_with_children(existing, source_system_id, normalized, opts)

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

  defp create_order_with_children(source_system_id, normalized, opts) do
    attrs = order_attrs(source_system_id, normalized)

    with {:ok, order} <- ash_create(Order, attrs, :create_normalized, opts),
         :ok <- upsert_child_rows(order, normalized, opts) do
      {:ok, order}
    end
  end

  defp update_order_with_children(%Order{} = existing, source_system_id, normalized, opts) do
    cond do
      DateTime.compare(existing.updated_at_source, normalized.updated_at_source) == :gt ->
        {:ok, :stale_noop}

      SourceVersionGuard.allows_update?(existing.updated_at_source, normalized.updated_at_source) ->
        with {:ok, order} <-
               ash_update(
                 existing,
                 order_attrs(source_system_id, normalized),
                 :sync_from_normalized,
                 opts
               ),
             :ok <- upsert_child_rows(order, normalized, opts) do
          {:ok, order}
        end

      DateTime.compare(existing.updated_at_source, normalized.updated_at_source) == :eq ->
        with :ok <- upsert_child_rows(existing, normalized, opts) do
          {:ok, existing}
        end

      true ->
        {:ok, :stale_noop}
    end
  end

  defp upsert_child_rows(%Order{} = order, normalized, opts) do
    with :ok <- upsert_order_items(order, normalized.line_items, opts),
         :ok <- upsert_coupons(order, normalized.coupons, opts) do
      maybe_map_pending_items(order, opts)
    end
  end

  defp maybe_map_pending_items(%Order{} = order, opts) do
    if Keyword.get(opts, :map_pending_items?, true) do
      case OrderItemMapper.map_pending_items_for_order(order) do
        {:ok, _mapped_items} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp upsert_order_items(%Order{} = order, line_items, opts) do
    Enum.reduce_while(line_items, :ok, fn line_item, :ok ->
      case upsert_order_item(order, line_item, opts) do
        {:ok, _item} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp upsert_order_item(%Order{} = order, line_item, opts) do
    case find_order_item(order.id, line_item.woo_line_item_id) do
      {:ok, nil} ->
        attrs =
          line_item
          |> Map.take([
            :event_id,
            :ticket_type_id,
            :woo_line_item_id,
            :woo_product_id,
            :woo_variation_id,
            :name,
            :quantity,
            :line_subtotal,
            :line_total,
            :discount_total,
            :item_kind,
            :mapping_status,
            :source_tickera_event_id,
            :attribution_status_reason
          ])
          |> Map.put(:order_id, order.id)

        ash_create(OrderItem, attrs, :create_normalized, opts)

      {:ok, %OrderItem{} = existing} ->
        action =
          cond do
            Keyword.get(opts, :event_reconciliation?, false) ->
              :sync_from_event_reconciliation

            mapped_import_line?(line_item) ->
              :sync_from_mapped_import

            true ->
              :sync_from_order
          end

        attrs = order_item_update_attrs(existing, line_item, action)

        ash_update(existing, attrs, action, opts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp mapped_import_line?(line_item) do
    Map.has_key?(line_item, :event_id) and
      Map.has_key?(line_item, :ticket_type_id) and
      not is_nil(Map.get(line_item, :event_id)) and
      not is_nil(Map.get(line_item, :ticket_type_id))
  end

  defp order_item_update_attrs(%OrderItem{} = existing, line_item, :sync_from_mapped_import) do
    line_item
    |> Map.take([
      :event_id,
      :ticket_type_id,
      :woo_product_id,
      :woo_variation_id,
      :name,
      :quantity,
      :line_subtotal,
      :line_total,
      :discount_total,
      :source_tickera_event_id,
      :attribution_status_reason
    ])
    |> protect_mapped_source_identity(existing, line_item)
  end

  defp order_item_update_attrs(%OrderItem{} = existing, line_item, :sync_from_order) do
    line_item
    |> Map.take([
      :woo_product_id,
      :woo_variation_id,
      :name,
      :quantity,
      :line_subtotal,
      :line_total,
      :discount_total,
      :source_tickera_event_id,
      :attribution_status_reason
    ])
    |> protect_mapped_source_identity(existing, line_item)
  end

  defp order_item_update_attrs(
         %OrderItem{} = existing,
         line_item,
         :sync_from_event_reconciliation
       ) do
    line_item
    |> Map.take([
      :event_id,
      :woo_product_id,
      :woo_variation_id,
      :name,
      :quantity,
      :line_subtotal,
      :line_total,
      :discount_total,
      :source_tickera_event_id,
      :attribution_status_reason
    ])
    |> protect_mapped_source_identity(existing, line_item)
  end

  defp validate_reconciliation_ids(source_system_id, event_id) do
    if valid_uuid?(source_system_id) and valid_uuid?(event_id) do
      :ok
    else
      {:error, {:invalid_order_reconciliation, :identifiers}}
    end
  end

  defp valid_uuid?(value) when is_binary(value) do
    match?({:ok, _uuid}, Ecto.UUID.cast(value))
  end

  defp valid_uuid?(_value), do: false

  defp validate_full_order_payload(full_order_payload) when is_map(full_order_payload) do
    with :ok <- validate_positive_order_id(full_order_payload),
         {:ok, full_source_lines} <- fetch_source_lines(full_order_payload),
         :ok <- validate_source_lines(full_source_lines) do
      {:ok, full_source_lines}
    end
  end

  defp validate_full_order_payload(_full_order_payload),
    do: {:error, {:invalid_order_reconciliation, :full_order_payload}}

  defp validate_positive_order_id(%{"id" => order_id}) when is_integer(order_id) and order_id > 0,
    do: :ok

  defp validate_positive_order_id(_payload),
    do: {:error, {:invalid_order_reconciliation, :order_id}}

  defp fetch_source_lines(%{"line_items" => line_items}) when is_list(line_items),
    do: {:ok, line_items}

  defp fetch_source_lines(_payload),
    do: {:error, {:invalid_order_reconciliation, :line_items}}

  defp validate_source_lines(lines) do
    with :ok <- validate_line_shapes(lines) do
      validate_unique_line_ids(lines)
    end
  end

  defp validate_line_shapes(lines) do
    Enum.reduce_while(lines, :ok, fn line, :ok ->
      if valid_source_line?(line) do
        {:cont, :ok}
      else
        {:halt, {:error, {:invalid_order_reconciliation, :line_item_identity}}}
      end
    end)
  end

  defp valid_source_line?(line) when is_map(line) do
    positive_integer?(Map.get(line, "id")) and
      positive_integer?(Map.get(line, "product_id")) and
      valid_variation_id?(Map.get(line, "variation_id"))
  end

  defp valid_source_line?(_line), do: false

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp valid_variation_id?(nil), do: true
  defp valid_variation_id?(value), do: is_integer(value) and value >= 0

  defp validate_unique_line_ids(lines) do
    ids = Enum.map(lines, &Map.get(&1, "id"))

    if length(ids) == length(Enum.uniq(ids)) do
      :ok
    else
      {:error, {:invalid_order_reconciliation, :duplicate_line_item_id}}
    end
  end

  defp validate_event_line_subset(full_source_lines, event_line_items)
       when is_list(event_line_items) do
    with :ok <- validate_source_lines(event_line_items),
         :ok <- validate_subset_membership(full_source_lines, event_line_items) do
      {:ok, Enum.map(event_line_items, &Map.get(&1, "id"))}
    end
  end

  defp validate_event_line_subset(_full_source_lines, _event_line_items),
    do: {:error, {:invalid_order_reconciliation, :event_line_items}}

  defp validate_subset_membership(full_source_lines, event_line_items) do
    Enum.reduce_while(event_line_items, :ok, fn event_line, :ok ->
      if Enum.any?(full_source_lines, &same_source_line?(&1, event_line)) do
        {:cont, :ok}
      else
        {:halt, {:error, {:invalid_order_reconciliation, :event_line_membership}}}
      end
    end)
  end

  defp same_source_line?(left, right) when left == right, do: true

  defp same_source_line?(left, right) do
    source_line_identity(left) == source_line_identity(right)
  end

  defp source_line_identity(line) do
    {Map.get(line, "id"), Map.get(line, "product_id"), Map.get(line, "variation_id")}
  end

  defp put_event_id_on_lines(normalized, event_id) do
    Map.update!(normalized, :line_items, fn lines ->
      Enum.map(lines, &Map.put(&1, :event_id, event_id))
    end)
  end

  defp reconcile_accepted_order(order, event_id, current_event_line_ids, current_coupons, opts) do
    with :ok <- remove_absent_event_items(order, event_id, current_event_line_ids, opts),
         :ok <- remove_absent_coupons(order, current_coupons, opts) do
      {:ok, order}
    end
  end

  defp protect_mapped_source_identity(
         attrs,
         %OrderItem{mapping_status: :mapped} = existing,
         line_item
       ) do
    incoming_event_id = Map.get(line_item, :source_tickera_event_id)
    incoming_reason = Map.get(line_item, :attribution_status_reason)
    existing_event_id = existing.source_tickera_event_id
    mapped_external_event_id = mapped_external_event_id(existing)

    cond do
      incoming_reason == :invalid_source_tickera_event_id ->
        attrs
        |> Map.delete(:source_tickera_event_id)
        |> Map.put(:attribution_status_reason, incoming_reason)

      is_nil(incoming_event_id) ->
        attrs
        |> Map.delete(:source_tickera_event_id)
        |> Map.delete(:attribution_status_reason)

      is_integer(existing_event_id) and incoming_event_id != existing_event_id ->
        attrs
        |> Map.put(:source_tickera_event_id, existing_event_id)
        |> Map.put(:attribution_status_reason, :source_event_identity_conflict)

      is_integer(mapped_external_event_id) and incoming_event_id != mapped_external_event_id ->
        attrs
        |> maybe_put_source_event_id(existing_event_id, incoming_event_id)
        |> Map.put(:attribution_status_reason, :source_event_identity_conflict)

      true ->
        attrs
    end
  end

  defp protect_mapped_source_identity(attrs, _existing, _line_item), do: attrs

  defp maybe_put_source_event_id(attrs, nil, incoming_event_id),
    do: Map.put(attrs, :source_tickera_event_id, incoming_event_id)

  defp maybe_put_source_event_id(attrs, existing_event_id, _incoming_event_id),
    do: Map.put(attrs, :source_tickera_event_id, existing_event_id)

  defp mapped_external_event_id(%OrderItem{event_id: nil}), do: nil

  defp mapped_external_event_id(%OrderItem{} = item) do
    item
    |> Ash.load!(:event, domain: Sales)
    |> Map.get(:event)
    |> case do
      %{external_event_id: external_event_id} -> external_event_id
      _other -> nil
    end
  end

  defp upsert_coupons(%Order{} = order, coupons, opts) do
    Enum.reduce_while(coupons, :ok, fn coupon, :ok ->
      case upsert_coupon(order, coupon, opts) do
        {:ok, _coupon} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp upsert_coupon(%Order{} = order, coupon, opts) do
    case find_coupon(order.id, coupon.code) do
      {:ok, nil} ->
        attrs =
          coupon
          |> Map.take([:code, :discount_amount, :discount_tax])
          |> Map.put(:order_id, order.id)

        ash_create(CouponSnapshot, attrs, :create_snapshot, opts)

      {:ok, %CouponSnapshot{} = existing} ->
        attrs = Map.take(coupon, [:discount_amount, :discount_tax])
        ash_update(existing, attrs, :sync_from_order, opts)

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

  defp remove_absent_event_items(%Order{id: order_id}, event_id, current_line_ids, opts) do
    current_line_ids = MapSet.new(current_line_ids)

    OrderItem
    |> Ash.Query.filter(order_id == ^order_id and event_id == ^event_id)
    |> Ash.read(domain: Sales)
    |> handle_event_item_read(current_line_ids, opts)
  end

  defp handle_event_item_read({:ok, items}, current_line_ids, opts) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      item
      |> remove_event_item_if_absent(current_line_ids, opts)
      |> continue_or_halt()
    end)
  end

  defp handle_event_item_read({:error, reason}, _current_line_ids, _opts),
    do: {:error, reason}

  defp continue_or_halt(:ok), do: {:cont, :ok}
  defp continue_or_halt({:error, reason}), do: {:halt, {:error, reason}}
  defp continue_or_halt(other), do: {:halt, other}

  defp remove_event_item_if_absent(item, current_line_ids, opts) do
    if MapSet.member?(current_line_ids, item.woo_line_item_id) do
      :ok
    else
      ash_destroy(item, :destroy_source_absent, opts)
    end
  end

  defp remove_absent_coupons(%Order{id: order_id}, current_coupons, opts) do
    current_coupon_codes =
      current_coupons
      |> Enum.map(& &1.code)
      |> MapSet.new()

    CouponSnapshot
    |> Ash.Query.filter(order_id == ^order_id)
    |> Ash.read(domain: Sales)
    |> handle_coupon_read(current_coupon_codes, opts)
  end

  defp handle_coupon_read({:ok, coupons}, current_coupon_codes, opts) do
    Enum.reduce_while(coupons, :ok, fn coupon, :ok ->
      coupon
      |> remove_coupon_if_absent(current_coupon_codes, opts)
      |> continue_or_halt()
    end)
  end

  defp handle_coupon_read({:error, reason}, _current_coupon_codes, _opts),
    do: {:error, reason}

  defp remove_coupon_if_absent(coupon, current_coupon_codes, opts) do
    if MapSet.member?(current_coupon_codes, coupon.code) do
      :ok
    else
      ash_destroy(coupon, :destroy_source_absent, opts)
    end
  end

  defp ash_opts(opts, action) do
    opts
    |> Keyword.get(:ash_action_opts, [])
    |> Keyword.merge(action: action, domain: Sales)
  end

  defp ash_create(resource, attrs, action, opts) do
    case Ash.create(resource, attrs, ash_opts(opts, action)) do
      {:ok, record, _notifications} -> {:ok, record}
      other -> other
    end
  end

  defp ash_update(record, attrs, action, opts) do
    case Ash.update(record, attrs, ash_opts(opts, action)) do
      {:ok, record, _notifications} -> {:ok, record}
      other -> other
    end
  end

  defp ash_destroy(record, action, opts) do
    case Keyword.get(opts, :source_absent_destroyer) do
      destroyer when is_function(destroyer, 3) ->
        result = destroyer.(record, action, ash_opts(opts, action))
        normalize_destroy_result(result)

      _missing ->
        normalize_destroy_result(Ash.destroy(record, ash_opts(opts, action)))
    end
  end

  defp normalize_destroy_result({:ok, _record, _notifications}), do: :ok
  defp normalize_destroy_result({:ok, _record}), do: :ok
  defp normalize_destroy_result(:ok), do: :ok
  defp normalize_destroy_result(other), do: other

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
