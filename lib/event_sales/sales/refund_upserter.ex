defmodule EventSales.Sales.RefundUpserter do
  @moduledoc """
  Persists source-scoped WooCommerce refund facts.

  This module is the only durable writer for Refund and RefundLine records.
  Parsing happens before the transaction; parent and line binding happen only
  inside the transaction.
  """

  require Ash.Query
  import Ecto.Query

  alias EventSales.Ingestion.Parsers.WoocommerceRefundParser
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.Resources.{Order, OrderItem, Refund, RefundLine}

  @parent_order_not_found "parent_order_not_found"
  @malformed_detail "malformed_refund_detail"
  @source_detail_conflict "source_detail_conflict"
  @refund_identity_constraint "sales_refunds_unique_source_order_refund_index"
  @validation_tokens [
    "product_id_mismatch",
    "variation_id_mismatch",
    "refunded_quantity_exceeds_original"
  ]

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
        opts,
        0
      )
    end
  end

  def upsert_reference(_source_system_id, _woo_order_id, _normalized_reference, _opts),
    do: {:error, {:invalid_refund_identity, :reference}}

  @spec upsert_refund(Ecto.UUID.t(), pos_integer(), map(), keyword()) :: result()
  def upsert_refund(source_system_id, woo_order_id, raw_refund_payload, opts \\ []) do
    case validate_identity(source_system_id, woo_order_id) do
      :ok -> persist_raw_refund(source_system_id, woo_order_id, raw_refund_payload, opts)
      {:error, _reason} = error -> error
    end
  end

  @spec upsert_normalized_refund(Ecto.UUID.t(), pos_integer(), map(), keyword()) :: result()
  def upsert_normalized_refund(source_system_id, woo_order_id, normalized_refund, opts \\ [])

  def upsert_normalized_refund(source_system_id, woo_order_id, normalized_refund, opts)
      when is_map(normalized_refund) do
    with :ok <- validate_identity(source_system_id, woo_order_id),
         {:ok, woo_refund_id} <-
           positive_identity(normalized_refund, :woo_refund_id) do
      persist_normalized(
        source_system_id,
        woo_order_id,
        woo_refund_id,
        normalized_refund,
        opts,
        0
      )
    end
  end

  def upsert_normalized_refund(_source_system_id, _woo_order_id, _normalized_refund, _opts),
    do: {:error, {:invalid_refund_identity, :normalized_refund}}

  defp persist_raw_refund(source_system_id, woo_order_id, raw_refund_payload, opts) do
    case WoocommerceRefundParser.parse(raw_refund_payload) do
      {:ok, normalized} ->
        upsert_normalized_refund(source_system_id, woo_order_id, normalized, opts)

      {:error, reason} ->
        case raw_refund_id(raw_refund_payload) do
          {:ok, woo_refund_id} ->
            persist_malformed(
              source_system_id,
              woo_order_id,
              woo_refund_id,
              reason,
              opts,
              0
            )

          {:error, _reason} ->
            {:error, {:invalid_refund_identity, :woo_refund_id}}
        end
    end
  end

  defp persist_normalized(
         source_system_id,
         woo_order_id,
         woo_refund_id,
         normalized_refund,
         opts,
         attempt
       ) do
    result =
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

    case result do
      {:error, reason} = error ->
        if attempt == 0 and unique_refund_identity_error?(reason) do
          persist_normalized(
            source_system_id,
            woo_order_id,
            woo_refund_id,
            normalized_refund,
            opts,
            1
          )
        else
          error
        end

      other ->
        other
    end
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
         {:ok, validated_lines} <-
           validate_refund_quantities(refund.id, resolved_lines, order_items),
         {:ok, _persisted_lines} <- persist_refund_lines(refund, validated_lines) do
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
          unresolved_reason: normalized_unresolved_reason(existing, parent_order)
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
      |> Ash.Query.filter(order_id == ^parent_order.id and woo_line_item_id in ^line_ids)
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

  defp validate_refund_quantities(_refund_id, lines, []), do: {:ok, lines}

  defp validate_refund_quantities(refund_id, lines, order_items) do
    bound_item_ids =
      lines
      |> Enum.map(&Map.get(&1, :order_item_id))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if bound_item_ids == [] do
      {:ok, lines}
    else
      historical_quantities =
        active_refunded_quantities(refund_id, bound_item_ids)
        |> Map.new(fn {order_item_id, quantity} ->
          {normalize_uuid_key(order_item_id), normalize_quantity(quantity)}
        end)

      item_by_id = Map.new(order_items, &{&1.id, &1})

      incoming_quantities = Enum.reduce(lines, %{}, &accumulate_incoming_quantity/2)

      over_refunded_item_ids =
        incoming_quantities
        |> Enum.filter(&over_refunded_item?(&1, item_by_id, historical_quantities))
        |> MapSet.new(fn {order_item_id, _quantity} -> order_item_id end)

      {:ok,
       Enum.map(lines, fn line ->
         if MapSet.member?(over_refunded_item_ids, Map.get(line, :order_item_id)) do
           Map.put(
             line,
             :validation_reason,
             add_validation_token(
               Map.get(line, :validation_reason),
               "refunded_quantity_exceeds_original"
             )
           )
         else
           line
         end
       end)}
    end
  end

  defp over_refunded_item?(
         {order_item_id, incoming_quantity},
         item_by_id,
         historical_quantities
       ) do
    case Map.get(item_by_id, order_item_id) do
      %{item_kind: :ticket, quantity: original_quantity} ->
        historical_quantity = Map.get(historical_quantities, order_item_id, 0)
        historical_quantity + incoming_quantity > original_quantity

      _other ->
        false
    end
  end

  defp accumulate_incoming_quantity(line, quantities) do
    order_item_id = Map.get(line, :order_item_id)
    quantity = Map.get(line, :refunded_quantity)

    if is_nil(order_item_id) or not positive_integer?(quantity) do
      quantities
    else
      Map.update(quantities, order_item_id, quantity, &(&1 + quantity))
    end
  end

  defp active_refunded_quantities(refund_id, order_item_ids) do
    Repo.all(
      from line in "sales_refund_lines",
        join: refund in "sales_refunds",
        on: refund.id == line.refund_id,
        where:
          line.order_item_id in type(^order_item_ids, {:array, :binary_id}) and
            refund.source_state == "active" and
            refund.id != type(^refund_id, :binary_id),
        group_by: line.order_item_id,
        select: {line.order_item_id, coalesce(sum(line.refunded_quantity), 0)}
    )
  end

  defp normalize_uuid_key(value) when is_binary(value) do
    case Ecto.UUID.load(value) do
      {:ok, uuid} -> uuid
      :error -> value
    end
  end

  defp normalize_uuid_key(value), do: value

  defp normalize_quantity(value) when is_integer(value), do: value
  defp normalize_quantity(%Decimal{} = value), do: Decimal.to_integer(value)

  defp add_validation_token(nil, token), do: token

  defp add_validation_token(reason, token) do
    reason
    |> String.split("|", trim: true)
    |> Kernel.++([token])
    |> Enum.uniq()
    |> sort_validation_tokens()
    |> Enum.join("|")
  end

  defp sort_validation_tokens(tokens) do
    Enum.sort_by(tokens, fn token ->
      Enum.find_index(@validation_tokens, &(&1 == token)) || length(@validation_tokens)
    end)
  end

  defp persist_refund_lines(%Refund{} = refund, resolved_lines) do
    with {:ok, existing_lines} <- existing_refund_lines(refund.id) do
      existing_by_line_id =
        Map.new(existing_lines, &{&1.woo_refund_line_item_id, &1})

      Enum.reduce_while(
        resolved_lines,
        {:ok, []},
        &persist_refund_line_accumulator(&1, &2, refund, existing_by_line_id)
      )
      |> reverse_persisted_lines()
    end
  end

  defp persist_refund_line_accumulator(
         line,
         {:ok, persisted},
         %Refund{} = refund,
         existing_by_line_id
       ) do
    case persist_refund_line(refund, line, existing_by_line_id) do
      {:ok, persisted_line} ->
        {:cont, {:ok, [persisted_line | persisted]}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp persist_refund_line(%Refund{} = refund, line, existing_by_line_id) do
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

    case Map.get(existing_by_line_id, line.woo_refund_line_item_id) do
      nil ->
        ash_create(RefundLine, attrs, :create_normalized)

      existing ->
        attrs
        |> Map.drop([:refund_id, :woo_refund_line_item_id])
        |> then(&ash_update(existing, &1, :sync_normalized))
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
      |> then(&incoming_lines_source_conflict?(&1, normalized_refund.line_items))

    line_set_changed? or refund_source_changed? or line_source_changed?
  end

  defp incoming_lines_source_conflict?(existing_by_id, incoming_lines) do
    Enum.any?(incoming_lines, &incoming_line_source_conflict?(&1, existing_by_id))
  end

  defp incoming_line_source_conflict?(incoming, existing_by_id) do
    case Map.get(existing_by_id, Map.get(incoming, :woo_refund_line_item_id)) do
      nil ->
        false

      existing ->
        Enum.any?(
          [
            :woo_refunded_item_id,
            :woo_product_id,
            :woo_variation_id,
            :refunded_quantity,
            :refund_subtotal_amount,
            :refund_total_amount,
            :refund_total_tax
          ],
          &incoming_source_field_conflict?(existing, incoming, &1)
        )
    end
  end

  defp incoming_source_field_conflict?(existing, incoming, field) do
    Map.has_key?(incoming, field) and
      match?(
        {:conflict, _},
        merge_source_field(Map.get(existing, field), Map.get(incoming, field))
      )
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
         opts,
         attempt
       ) do
    result =
      Repo.transaction(fn ->
        with {:ok, parent_order} <- lock_parent_order(source_system_id, woo_order_id),
             {:ok, existing} <-
               lock_refund(source_system_id, woo_order_id, woo_refund_id),
             {:ok, existing_lines} <- existing_lines_for(existing),
             {:ok, refund} <-
               persist_malformed_transaction(
                 source_system_id,
                 woo_order_id,
                 woo_refund_id,
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

    case result do
      {:error, reason} = error ->
        if attempt == 0 and unique_refund_identity_error?(reason) do
          persist_malformed(
            source_system_id,
            woo_order_id,
            woo_refund_id,
            nil,
            opts,
            1
          )
        else
          error
        end

      other ->
        other
    end
  end

  defp persist_malformed_transaction(
         source_system_id,
         woo_order_id,
         woo_refund_id,
         parent_order,
         existing,
         existing_lines
       ) do
    unresolved_reason = malformed_unresolved_reason(existing, existing_lines)

    attrs = %{
      source_system_id: source_system_id,
      order_id: parent_id(parent_order),
      woo_order_id: woo_order_id,
      woo_refund_id: woo_refund_id,
      currency: parent_currency(parent_order),
      detail_status: :unresolved,
      unresolved_reason: unresolved_reason
    }

    case existing do
      nil ->
        ash_create(Refund, attrs, :create_normalized)

      %Refund{} = refund ->
        attrs
        |> Map.take([:order_id, :currency, :detail_status, :unresolved_reason])
        |> then(&ash_update(refund, &1, :sync_normalized))
    end
  end

  defp malformed_unresolved_reason(nil, _existing_lines), do: @malformed_detail

  defp malformed_unresolved_reason(
         %Refund{unresolved_reason: @source_detail_conflict},
         _existing_lines
       ),
       do: @source_detail_conflict

  defp malformed_unresolved_reason(%Refund{detail_status: :complete}, _existing_lines),
    do: @source_detail_conflict

  defp malformed_unresolved_reason(_existing, existing_lines) when existing_lines != [],
    do: @source_detail_conflict

  defp malformed_unresolved_reason(_existing, _existing_lines), do: @malformed_detail

  defp persist_reference(
         source_system_id,
         woo_order_id,
         woo_refund_id,
         normalized_reference,
         opts,
         attempt
       ) do
    result =
      Repo.transaction(fn ->
        with {:ok, parent_order} <- lock_parent_order(source_system_id, woo_order_id),
             {:ok, existing} <-
               lock_refund(source_system_id, woo_order_id, woo_refund_id),
             {:ok, refund} <-
               persist_reference_transaction(
                 source_system_id,
                 woo_order_id,
                 woo_refund_id,
                 normalized_reference,
                 parent_order,
                 existing
               ) do
          refund
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
      |> normalize_transaction_result()

    case result do
      {:error, reason} = error ->
        if attempt == 0 and unique_refund_identity_error?(reason) do
          persist_reference(
            source_system_id,
            woo_order_id,
            woo_refund_id,
            normalized_reference,
            opts,
            1
          )
        else
          error
        end

      other ->
        other
    end
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

    ash_update(existing, attrs, :sync_normalized)
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
      value when is_integer(value) and value > 0 ->
        {:ok, value}

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

  defp normalized_unresolved_reason(
         %Refund{unresolved_reason: @source_detail_conflict},
         _parent_order
       ),
       do: @source_detail_conflict

  defp normalized_unresolved_reason(_existing, nil), do: @parent_order_not_found

  defp normalized_unresolved_reason(%Refund{unresolved_reason: @malformed_detail}, _parent_order),
    do: nil

  defp normalized_unresolved_reason(
         %Refund{unresolved_reason: @parent_order_not_found},
         _parent_order
       ),
       do: nil

  defp normalized_unresolved_reason(%Refund{unresolved_reason: reason}, _parent_order),
    do: reason

  defp merged_unresolved_reason(%Refund{unresolved_reason: @parent_order_not_found}, nil),
    do: @parent_order_not_found

  defp merged_unresolved_reason(
         %Refund{unresolved_reason: @parent_order_not_found},
         _parent_order
       ),
       do: nil

  defp merged_unresolved_reason(%Refund{unresolved_reason: @malformed_detail}, _parent_order),
    do: @malformed_detail

  defp merged_unresolved_reason(%Refund{unresolved_reason: nil}, nil),
    do: @parent_order_not_found

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

  defp unique_refund_identity_error?(error) do
    error
    |> Ash.Error.to_error_class()
    |> case do
      %Ash.Error.Invalid{errors: errors} ->
        Enum.any?(errors, &unique_refund_identity_constraint?/1)

      %Ash.Error.Unknown{errors: errors} ->
        Enum.any?(errors, &unique_refund_identity_constraint?/1)

      _other ->
        String.contains?(inspect(error), @refund_identity_constraint)
    end
  end

  defp unique_refund_identity_constraint?(%Ash.Error.Changes.InvalidAttribute{
         private_vars: private_vars
       }) do
    private_vars[:constraint] == @refund_identity_constraint
  end

  defp unique_refund_identity_constraint?(%Ash.Error.Unknown.UnknownError{error: message})
       when is_binary(message) do
    String.contains?(message, @refund_identity_constraint)
  end

  defp unique_refund_identity_constraint?(_error), do: false

  defp normalize_transaction_result({:ok, {:ok, %Refund{} = refund}}), do: {:ok, refund}
  defp normalize_transaction_result({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize_transaction_result({:ok, %Refund{} = refund}), do: {:ok, refund}
  defp normalize_transaction_result({:error, reason}), do: {:error, reason}
end
