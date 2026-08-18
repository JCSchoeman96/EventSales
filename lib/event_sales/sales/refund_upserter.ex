defmodule EventSales.Sales.RefundUpserter do
  @moduledoc """
  Persists source-scoped WooCommerce refund facts.

  This module is the only durable writer for Refund and RefundLine records.
  Parsing happens before the transaction; parent and line binding happen only
  inside the transaction.
  """

  require Ash.Query

  alias EventSales.Ingestion.Parsers.WoocommerceRefundParser
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem, Refund, RefundLine}

  @parent_order_not_found "parent_order_not_found"
  @malformed_detail "malformed_refund_detail"
  @source_detail_conflict "source_detail_conflict"

  @type result :: {:ok, Refund.t()} | {:error, term()}

  @spec upsert_reference(Ecto.UUID.t(), pos_integer(), map(), keyword()) :: result()
  def upsert_reference(source_system_id, woo_order_id, normalized_reference, opts \\ [])

  def upsert_reference(source_system_id, woo_order_id, normalized_reference, opts)
      when is_map(normalized_reference) do
    with :ok <- validate_identity(source_system_id, woo_order_id),
         {:ok, woo_refund_id} <-
           positive_identity(normalized_reference, :woo_refund_id) do
      persist_reference(
        source_system_id,
        woo_order_id,
        woo_refund_id,
        normalized_reference,
        opts
      )
    end
  end

  def upsert_reference(_source_system_id, _woo_order_id, _normalized_reference, _opts),
    do: {:error, {:invalid_refund_identity, :reference}}

  @spec upsert_refund(Ecto.UUID.t(), pos_integer(), map(), keyword()) :: result()
  def upsert_refund(source_system_id, woo_order_id, raw_refund_payload, opts \\ []) do
    with :ok <- validate_identity(source_system_id, woo_order_id) do
      case WoocommerceRefundParser.parse(raw_refund_payload) do
        {:ok, normalized} ->
          upsert_normalized_refund(source_system_id, woo_order_id, normalized, opts)

        {:error, reason} ->
          with {:ok, woo_refund_id} <- raw_refund_id(raw_refund_payload) do
            persist_malformed(
              source_system_id,
              woo_order_id,
              woo_refund_id,
              reason,
              opts
            )
          else
            {:error, _reason} -> {:error, {:invalid_refund_identity, :woo_refund_id}}
          end
      end
    end
  end

  @spec upsert_normalized_refund(Ecto.UUID.t(), pos_integer(), map(), keyword()) :: result()
  def upsert_normalized_refund(source_system_id, woo_order_id, normalized_refund, opts \\ [])

  def upsert_normalized_refund(source_system_id, woo_order_id, normalized_refund, _opts)
      when is_map(normalized_refund) do
    with :ok <- validate_identity(source_system_id, woo_order_id),
         {:ok, woo_refund_id} <-
           positive_identity(normalized_refund, :woo_refund_id) do
      persist_normalized(
        source_system_id,
        woo_order_id,
        woo_refund_id,
        normalized_refund,
        []
      )
    end
  end

  def upsert_normalized_refund(_source_system_id, _woo_order_id, _normalized_refund, _opts),
    do: {:error, {:invalid_refund_identity, :normalized_refund}}

  defp persist_normalized(
         source_system_id,
         woo_order_id,
         woo_refund_id,
         normalized_refund,
         _opts
       ) do
    Repo.transaction(fn ->
      with {:ok, parent_order} <- lock_parent_order(source_system_id, woo_order_id),
           {:ok, existing} <-
             lock_refund(source_system_id, woo_order_id, woo_refund_id),
           {:ok, existing_lines} <- existing_lines_for(existing),
           conflict? <-
             source_detail_conflict?(existing, normalized_refund, existing_lines),
           {:ok, refund} <-
             persist_normalized_transaction(
               conflict?,
               source_system_id,
               woo_order_id,
               woo_refund_id,
               normalized_refund,
               parent_order,
               existing,
               existing_lines
             ) do
        refund
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  end

  defp persist_normalized_transaction(
         true,
         _source_system_id,
         _woo_order_id,
         _woo_refund_id,
         _normalized_refund,
         parent_order,
         %Refund{} = existing,
         _existing_lines
       ) do
    ash_update(
      existing,
      %{
        order_id: parent_id(parent_order),
        currency: parent_currency(parent_order),
        detail_status: :unresolved,
        unresolved_reason: @source_detail_conflict
      },
      :sync_normalized
    )
  end

  defp persist_normalized_transaction(
         false,
         source_system_id,
         woo_order_id,
         woo_refund_id,
         normalized_refund,
         parent_order,
         existing,
         _existing_lines
       ) do
    with {:ok, refund} <-
           persist_normalized_refund(
             source_system_id,
             woo_order_id,
             woo_refund_id,
             normalized_refund,
             parent_order,
             existing
           ),
         {:ok, order_items} <-
           lock_order_items(parent_order, normalized_refund.line_items),
         {:ok, resolved_lines} <-
           resolve_line_bindings(parent_order, normalized_refund.line_items, order_items),
         {:ok, _persisted_lines} <- persist_refund_lines(refund, resolved_lines) do
      {:ok, refund}
    end
  end

  defp persist_normalized_refund(
         source_system_id,
         woo_order_id,
         woo_refund_id,
         normalized_refund,
         parent_order,
         nil
       ) do
    ash_create(
      Refund,
      normalized_refund_attrs(
        source_system_id,
        woo_order_id,
        woo_refund_id,
        normalized_refund,
        parent_order
      ),
      :create_normalized
    )
  end

  defp persist_normalized_refund(
         _source_system_id,
         _woo_order_id,
         _woo_refund_id,
         normalized_refund,
         parent_order,
         %Refund{} = existing
       ) do
    with {:ok, source_attrs} <- merge_refund_source_attrs(existing, normalized_refund) do
      attrs =
        Map.merge(source_attrs, %{
          order_id: parent_id(parent_order),
          currency: parent_currency(parent_order),
          detail_status: :complete,
          unresolved_reason: merged_unresolved_reason(existing, parent_order)
        })

      ash_update(existing, attrs, :sync_normalized)
    end
  end

  defp normalized_refund_attrs(
         source_system_id,
         woo_order_id,
         woo_refund_id,
         normalized_refund,
         parent_order
       ) do
    normalized_refund
    |> normalized_source_attrs()
    |> Map.merge(%{
      source_system_id: source_system_id,
      order_id: parent_id(parent_order),
      woo_order_id: woo_order_id,
      woo_refund_id: woo_refund_id,
      currency: parent_currency(parent_order),
      source_state: :active,
      detail_status: :complete,
      unresolved_reason: unresolved_reason(parent_order)
    })
  end

  defp normalized_source_attrs(normalized_refund) do
    normalized_refund
    |> Map.take([
      :summary_total_amount,
      :header_amount,
      :shipping_refund_amount,
      :shipping_refund_tax,
      :fee_refund_amount,
      :fee_refund_tax,
      :unallocated_header_amount,
      :reason,
      :source_created_at
    ])
  end

  defp lock_order_items(nil, _line_items), do: {:ok, []}

  defp lock_order_items(parent_order, line_items) do
    line_ids =
      line_items
      |> Enum.map(&Map.get(&1, :woo_refunded_item_id))
      |> Enum.filter(&positive_integer?/1)
      |> Enum.uniq()

    if line_ids == [] do
      {:ok, []}
    else
      OrderItem
      |> Ash.Query.filter(
        order_id == ^parent_order.id and woo_line_item_id in ^line_ids
      )
      |> Ash.Query.sort(woo_line_item_id: :asc)
      |> Ash.Query.lock(:for_update)
      |> Ash.read(domain: Sales)
    end
  end

  defp resolve_line_bindings(parent_order, line_items, order_items) do
    items_by_line_id = Map.new(order_items, &{&1.woo_line_item_id, &1})

    resolved =
      Enum.map(line_items, fn line ->
        binder = Map.get(line, :woo_refunded_item_id)
        order_item = if positive_integer?(binder), do: Map.get(items_by_line_id, binder)

        {order_item_id, binding_reason} =
          cond do
            not is_nil(Map.get(line, :binding_reason)) ->
              {nil, Map.get(line, :binding_reason)}

            is_nil(parent_order) and positive_integer?(binder) ->
              {nil, @parent_order_not_found}

            not positive_integer?(binder) ->
              {nil, Map.get(line, :binding_reason) || "missing_refunded_item_id"}

            is_nil(order_item) ->
              {nil, "order_item_not_found"}

            true ->
              {order_item.id, nil}
          end

        validation_reason = validation_reason(line, order_item)

        line
        |> Map.put(:order_item_id, order_item_id)
        |> Map.put(:binding_reason, binding_reason)
        |> Map.put(:validation_reason, validation_reason)
      end)

    {:ok, resolved}
  end

  defp validation_reason(_line, nil), do: nil

  defp validation_reason(line, order_item) do
    tokens =
      []
      |> maybe_add_token(
        :product_id_mismatch,
        source_value_differs?(Map.get(line, :woo_product_id), order_item.woo_product_id)
      )
      |> maybe_add_token(
        :variation_id_mismatch,
        source_value_differs?(Map.get(line, :woo_variation_id), order_item.woo_variation_id)
      )

    case tokens do
      [] -> nil
      tokens -> Enum.join(tokens, "|")
    end
  end

  defp maybe_add_token(tokens, token, true), do: tokens ++ [Atom.to_string(token)]
  defp maybe_add_token(tokens, _token, false), do: tokens

  defp source_value_differs?(nil, _historical), do: false
  defp source_value_differs?(source, historical), do: source != historical

  defp persist_refund_lines(%Refund{} = refund, resolved_lines) do
    with {:ok, existing_lines} <- existing_refund_lines(refund.id) do
      existing_by_line_id =
        Map.new(existing_lines, &{&1.woo_refund_line_item_id, &1})

      Enum.reduce_while(resolved_lines, {:ok, []}, fn line, {:ok, persisted} ->
        attrs =
          line
          |> Map.take([
            :refund_id,
            :order_item_id,
            :woo_refund_line_item_id,
            :woo_refunded_item_id,
            :woo_product_id,
            :woo_variation_id,
            :refunded_quantity,
            :refund_subtotal_amount,
            :refund_total_amount,
            :refund_total_tax,
            :binding_reason,
            :validation_reason
          ])
          |> Map.put(:refund_id, refund.id)

        action_and_record =
          case Map.get(existing_by_line_id, line.woo_refund_line_item_id) do
            nil -> {:create_normalized, RefundLine}
            existing -> {:sync_normalized, existing}
          end

        result =
          case action_and_record do
            {:create_normalized, RefundLine} ->
              ash_create(RefundLine, attrs, :create_normalized)

            {:sync_normalized, existing} ->
              attrs
              |> Map.drop([:refund_id, :woo_refund_line_item_id])
              |> then(&ash_update(existing, &1, :sync_normalized))
          end

        case result do
          {:ok, persisted_line} ->
            {:cont, {:ok, [persisted_line | persisted]}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
      |> reverse_persisted_lines()
    end
  end

  defp reverse_persisted_lines({:ok, lines}), do: {:ok, Enum.reverse(lines)}
  defp reverse_persisted_lines({:error, reason}), do: {:error, reason}

  defp existing_refund_lines(refund_id) do
    RefundLine
    |> Ash.Query.filter(refund_id == ^refund_id)
    |> Ash.read(domain: Sales)
  end

  defp existing_lines_for(nil), do: {:ok, []}
  defp existing_lines_for(%Refund{id: refund_id}), do: existing_refund_lines(refund_id)

  defp merge_refund_source_attrs(existing, normalized_refund) do
    normalized_source_attrs(normalized_refund)
    |> Enum.reduce_while({:ok, %{}}, fn {field, incoming}, {:ok, attrs} ->
      case merge_source_field(Map.get(existing, field), incoming) do
        {:ok, value} -> {:cont, {:ok, Map.put(attrs, field, value)}}
        {:conflict, _existing_value} -> {:halt, {:error, @source_detail_conflict}}
      end
    end)
  end

  defp source_detail_conflict?(nil, _normalized_refund, _existing_lines), do: false

  defp source_detail_conflict?(
         %Refund{unresolved_reason: @source_detail_conflict},
         _normalized_refund,
         _existing_lines
       ),
       do: true

  defp source_detail_conflict?(existing, normalized_refund, existing_lines) do
    exact_detail_established? =
      existing.detail_status == :complete or existing_lines != []

    line_set_changed? =
      exact_detail_established? and
        line_identity_set(existing_lines) != line_identity_set(normalized_refund.line_items)

    refund_source_changed? =
      normalized_source_attrs(normalized_refund)
      |> Enum.any?(fn {field, incoming} ->
        match?({:conflict, _}, merge_source_field(Map.get(existing, field), incoming))
      end)

    line_source_changed? =
      existing_lines
      |> Map.new(&{&1.woo_refund_line_item_id, &1})
      |> then(&incoming_line_source_conflict?(&1, normalized_refund.line_items))

    line_set_changed? or refund_source_changed? or line_source_changed?
  end

  defp incoming_line_source_conflict?(existing_by_id, incoming_lines) do
    Enum.any?(incoming_lines, fn incoming ->
      case Map.get(existing_by_id, Map.get(incoming, :woo_refund_line_item_id)) do
        nil ->
          false

        existing ->
          [
            :woo_refunded_item_id,
            :woo_product_id,
            :woo_variation_id,
            :refunded_quantity,
            :refund_subtotal_amount,
            :refund_total_amount,
            :refund_total_tax
          ]
          |> Enum.any?(fn field ->
            Map.has_key?(incoming, field) and
              match?(
                {:conflict, _},
                merge_source_field(Map.get(existing, field), Map.get(incoming, field))
              )
          end)
      end
    end)
  end

  defp line_identity_set(lines) do
    lines
    |> Enum.map(&Map.get(&1, :woo_refund_line_item_id))
    |> MapSet.new()
  end

  defp merge_source_field(existing, incoming) do
    cond do
      is_nil(existing) -> {:ok, incoming}
      is_nil(incoming) -> {:conflict, existing}
      source_values_equal?(existing, incoming) -> {:ok, existing}
      true -> {:conflict, existing}
    end
  end

  defp source_values_equal?(%Decimal{} = left, %Decimal{} = right),
    do: Decimal.equal?(left, right)

  defp source_values_equal?(%DateTime{} = left, %DateTime{} = right),
    do: DateTime.compare(left, right) == :eq

  defp source_values_equal?(left, right), do: left == right

  defp persist_malformed(
         source_system_id,
         woo_order_id,
         woo_refund_id,
         _parse_reason,
         _opts
       ) do
    Repo.transaction(fn ->
      with {:ok, parent_order} <- lock_parent_order(source_system_id, woo_order_id),
           {:ok, existing} <-
             lock_refund(source_system_id, woo_order_id, woo_refund_id) do
        attrs = %{
          source_system_id: source_system_id,
          order_id: parent_id(parent_order),
          woo_order_id: woo_order_id,
          woo_refund_id: woo_refund_id,
          currency: parent_currency(parent_order),
          detail_status: :unresolved,
          unresolved_reason: "malformed_refund_detail"
        }

        case existing do
          nil -> ash_create(Refund, attrs, :create_normalized)
          %Refund{} = refund ->
            attrs
            |> Map.take([:order_id, :currency, :detail_status, :unresolved_reason])
            |> then(&ash_update(refund, &1, :sync_normalized))
        end
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  end

  defp persist_reference(
         source_system_id,
         woo_order_id,
         woo_refund_id,
         normalized_reference,
         _opts
       ) do
    Repo.transaction(fn ->
      with {:ok, parent_order} <- lock_parent_order(source_system_id, woo_order_id),
           {:ok, existing} <-
             lock_refund(source_system_id, woo_order_id, woo_refund_id) do
        persist_reference_transaction(
          source_system_id,
          woo_order_id,
          woo_refund_id,
          normalized_reference,
          parent_order,
          existing
        )
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> normalize_transaction_result()
  end

  defp persist_reference_transaction(
         source_system_id,
         woo_order_id,
         woo_refund_id,
         normalized_reference,
         parent_order,
         nil
       ) do
    ash_create(
      Refund,
      %{
        source_system_id: source_system_id,
        order_id: parent_id(parent_order),
        woo_order_id: woo_order_id,
        woo_refund_id: woo_refund_id,
        currency: parent_currency(parent_order),
        summary_total_amount: Map.get(normalized_reference, :summary_total_amount),
        reason: Map.get(normalized_reference, :reason),
        unresolved_reason: unresolved_reason(parent_order)
      },
      :create_reference
    )
  end

  defp persist_reference_transaction(
         _source_system_id,
         _woo_order_id,
         _woo_refund_id,
         normalized_reference,
         parent_order,
         %Refund{} = existing
       ) do
    attrs =
      %{
        order_id: parent_id(parent_order),
        currency: parent_currency(parent_order),
        unresolved_reason: merged_unresolved_reason(existing, parent_order)
      }
      |> maybe_hydrate(existing, :summary_total_amount, normalized_reference)
      |> maybe_hydrate(existing, :reason, normalized_reference)

    if attrs == %{} do
      {:ok, existing}
    else
      ash_update(existing, attrs, :sync_normalized)
    end
  end

  defp lock_parent_order(source_system_id, woo_order_id) do
    Order
    |> Ash.Query.filter(source_system_id == ^source_system_id and woo_order_id == ^woo_order_id)
    |> Ash.Query.limit(1)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(domain: Sales)
  end

  defp lock_refund(source_system_id, woo_order_id, woo_refund_id) do
    Refund
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and
        woo_order_id == ^woo_order_id and
        woo_refund_id == ^woo_refund_id
    )
    |> Ash.Query.limit(1)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(domain: Sales)
  end

  defp validate_identity(source_system_id, woo_order_id) do
    cond do
      not valid_uuid?(source_system_id) ->
        {:error, {:invalid_refund_identity, :source_system_id}}

      not positive_integer?(woo_order_id) ->
        {:error, {:invalid_refund_identity, :woo_order_id}}

      true ->
        :ok
    end
  end

  defp positive_identity(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value > 0 -> {:ok, value}
      value when is_binary(value) ->
        case Integer.parse(String.trim(value)) do
          {integer, ""} when integer > 0 -> {:ok, integer}
          _other -> {:error, {:invalid_refund_identity, key}}
        end

      _value ->
        {:error, {:invalid_refund_identity, key}}
    end
  end

  defp raw_refund_id(payload) when is_map(payload) do
    positive_identity(%{woo_refund_id: Map.get(payload, "id")}, :woo_refund_id)
  end

  defp raw_refund_id(_payload), do: {:error, :invalid_payload}

  defp positive_integer?(value) when is_integer(value), do: value > 0

  defp positive_integer?(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer > 0
      _other -> false
    end
  end

  defp positive_integer?(_value), do: false

  defp valid_uuid?(value) when is_binary(value) do
    match?({:ok, _uuid}, Ecto.UUID.cast(value))
  end

  defp valid_uuid?(_value), do: false

  defp parent_id(nil), do: nil
  defp parent_id(parent_order), do: parent_order.id

  defp parent_currency(nil), do: nil
  defp parent_currency(parent_order), do: parent_order.currency

  defp unresolved_reason(nil), do: @parent_order_not_found
  defp unresolved_reason(_parent_order), do: nil

  defp merged_unresolved_reason(%Refund{unresolved_reason: @parent_order_not_found}, nil),
    do: @parent_order_not_found

  defp merged_unresolved_reason(%Refund{unresolved_reason: @parent_order_not_found}, _parent_order),
    do: nil

  defp merged_unresolved_reason(%Refund{unresolved_reason: @malformed_detail}, nil),
    do: @parent_order_not_found

  defp merged_unresolved_reason(%Refund{unresolved_reason: @malformed_detail}, _parent_order),
    do: nil

  defp merged_unresolved_reason(%Refund{unresolved_reason: reason}, _parent_order), do: reason

  defp maybe_hydrate(attrs, %Refund{} = existing, key, incoming) do
    incoming_value = Map.get(incoming, key)

    if is_nil(Map.get(existing, key)) and not is_nil(incoming_value) do
      Map.put(attrs, key, incoming_value)
    else
      attrs
    end
  end

  defp ash_create(resource, attrs, action) do
    case Ash.create(resource, attrs,
           action: action,
           domain: Sales,
           return_notifications?: true
         ) do
      {:ok, record, _notifications} -> {:ok, record}
      {:ok, record} -> {:ok, record}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ash_update(record, attrs, action) do
    case Ash.update(record, attrs,
           action: action,
           domain: Sales,
           return_notifications?: true
         ) do
      {:ok, updated, _notifications} -> {:ok, updated}
      {:ok, updated} -> {:ok, updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_transaction_result({:ok, {:ok, %Refund{} = refund}}), do: {:ok, refund}
  defp normalize_transaction_result({:ok, %Refund{} = refund}), do: {:ok, refund}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}
end
