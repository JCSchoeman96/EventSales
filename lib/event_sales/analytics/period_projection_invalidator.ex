defmodule EventSales.Analytics.PeriodProjectionInvalidator do
  @moduledoc false

  alias EventSales.Analytics.EventSnapshotRefreshFence
  alias EventSales.Analytics.PeriodBucketRules
  alias EventSales.Ingestion.HistoricalOrderMutationDetector
  alias EventSales.Repo
  alias EventSales.Sales.FinancialPrimitives

  @period_snapshots "analytics_event_period_aggregate_snapshots"
  @coverage_identity "m5_04d:event_period_bucket_v1"
  @semantic_version 1
  @zero Decimal.new("0")

  @type snapshot :: HistoricalOrderMutationDetector.snapshot() | map()

  @doc false
  @spec invalidate_order_change(nil | snapshot(), snapshot()) :: :ok | {:error, term()}
  def invalidate_order_change(before_snapshot, after_snapshot) do
    with true <- Repo.in_transaction?(),
         {:ok, before} <- order_contributions(before_snapshot),
         {:ok, after_contributions} <- order_contributions(after_snapshot),
         {:ok, buckets} <- changed_bucket_identities(before, after_contributions),
         :ok <- persist_refresh_intent(buckets) do
      :ok
    else
      false -> {:error, :period_projection_invalidation_requires_transaction}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec invalidate_refund_change(nil | map(), map()) :: :ok | {:error, term()}
  def invalidate_refund_change(before_snapshot, after_snapshot) do
    with true <- Repo.in_transaction?(),
         {:ok, before} <- refund_contributions(before_snapshot),
         {:ok, after_contributions} <- refund_contributions(after_snapshot),
         {:ok, buckets} <- changed_bucket_identities(before, after_contributions),
         :ok <- persist_refresh_intent(buckets) do
      :ok
    else
      false -> {:error, :period_projection_invalidation_requires_transaction}
      {:error, _reason} = error -> error
    end
  end

  defp order_contributions(nil), do: {:ok, %{}}

  defp order_contributions(%{header: header, order_items: items} = snapshot)
       when is_map(header) and is_list(items) do
    effective_at = sale_effective_at(header)

    if historically_recognised?(header) do
      with {:ok, sales} <- order_sale_contributions(items, header, effective_at),
           {:ok, refunds} <-
             order_refund_contributions(header, items, Map.get(snapshot, :refunds, [])) do
        {:ok, Map.merge(sales, refunds)}
      end
    else
      {:ok, %{}}
    end
  end

  defp order_contributions(_snapshot), do: {:error, :invalid_order_period_snapshot}

  defp order_sale_contributions(_items, _header, nil), do: {:ok, %{}}

  defp order_sale_contributions(items, header, %DateTime{} = effective_at) do
    Enum.reduce_while(items, {:ok, %{}}, fn item, {:ok, acc} ->
      case sale_contribution(item, header, effective_at) do
        :not_qualifying ->
          {:cont, {:ok, acc}}

        {:ok, contribution} ->
          {:cont, {:ok, Map.put(acc, {:sale, contribution.id}, contribution)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp order_refund_contributions(_header, _items, []), do: {:ok, %{}}

  defp order_refund_contributions(header, items, refunds) when is_list(refunds) do
    items_by_id = Map.new(items, &{Map.get(&1, :id), &1})

    Enum.reduce_while(refunds, {:ok, %{}}, fn refund, {:ok, acc} ->
      case order_refund_lines(refund, header, items_by_id) do
        {:ok, contributions} -> {:cont, {:ok, Map.merge(acc, contributions)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp order_refund_contributions(_header, _items, _refunds),
    do: {:error, :invalid_order_period_snapshot}

  defp order_refund_lines(%{header: refund, lines: lines}, order, items_by_id)
       when is_map(refund) and is_list(lines) do
    if qualifies_parent_refund?(order, refund),
      do: reduce_order_refund_lines(lines, refund, order, items_by_id),
      else: {:ok, %{}}
  end

  defp order_refund_lines(_refund, _order, _items_by_id),
    do: {:error, :invalid_order_period_snapshot}

  defp reduce_order_refund_lines(lines, refund, order, items_by_id) do
    Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, acc} ->
      case order_refund_contribution(line, refund, order, items_by_id) do
        :not_qualifying ->
          {:cont, {:ok, acc}}

        {:ok, contribution} ->
          {:cont, {:ok, Map.put(acc, {:refund, contribution.id}, contribution)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp qualifies_parent_refund?(order, refund) do
    Map.get(refund, :source_state) == :active and
      Map.get(refund, :detail_status) == :complete and
      Map.get(refund, :currency) == Map.get(order, :currency) and
      is_binary(Map.get(order, :currency)) and
      match?(%DateTime{}, Map.get(refund, :source_created_at)) and
      historically_recognised?(order)
  end

  defp order_refund_contribution(
         %{
           id: id,
           order_item_id: order_item_id,
           woo_refunded_item_id: refunded_item_id,
           refunded_quantity: quantity,
           refund_total_amount: %Decimal{} = amount,
           refund_total_tax: %Decimal{} = tax,
           binding_reason: nil,
           validation_reason: nil
         },
         refund,
         order,
         items_by_id
       )
       when is_integer(quantity) and quantity >= 0 do
    item = Map.get(items_by_id, order_item_id)

    with {:ok, id} <- canonical_uuid(id),
         {:ok, identity} <- exact_order_refund_item(item, refunded_item_id),
         {:ok, source_system_id} <- canonical_uuid(Map.get(order, :source_system_id)),
         {:ok, effective_at} <- utc_instant(Map.get(refund, :source_created_at)),
         :ok <- valid_currency(Map.get(refund, :currency)) do
      refund_quantity = FinancialPrimitives.refund_ticket_quantity(quantity)
      refund_value = FinancialPrimitives.refund_ticket_value(amount, tax)

      if Decimal.compare(refund_quantity, @zero) == :gt or
           Decimal.compare(refund_value, @zero) == :gt do
        {:ok,
         Map.merge(identity, %{
           id: id,
           source_system_id: source_system_id,
           currency: refund.currency,
           effective_at: effective_at,
           gross_ticket_quantity: 0,
           gross_ticket_value: @zero,
           refund_ticket_quantity: Decimal.to_integer(refund_quantity),
           refund_ticket_value: refund_value
         })}
      else
        :not_qualifying
      end
    else
      :not_qualifying -> :not_qualifying
      {:error, reason} -> {:error, reason}
    end
  end

  defp order_refund_contribution(_line, _refund, _order, _items_by_id),
    do: :not_qualifying

  defp exact_order_refund_item(
         %{
           id: item_id,
           woo_line_item_id: line_item_id,
           event_id: event_id,
           ticket_type_id: ticket_type_id,
           woo_product_id: product_id,
           woo_variation_id: variation_id,
           item_kind: :ticket,
           mapping_status: :mapped
         },
         refunded_item_id
       )
       when line_item_id == refunded_item_id do
    with {:ok, _item_id} <- canonical_uuid(item_id),
         {:ok, event_id} <- canonical_uuid(event_id),
         {:ok, ticket_type_id} <- canonical_uuid(ticket_type_id),
         :ok <- valid_product_identity(product_id, variation_id) do
      {:ok,
       %{
         event_id: event_id,
         ticket_type_id: ticket_type_id,
         woo_product_id: product_id,
         woo_variation_id: variation_id
       }}
    else
      _ -> :not_qualifying
    end
  end

  defp exact_order_refund_item(_item, _refunded_item_id), do: :not_qualifying

  defp sale_contribution(
         %{
           id: id,
           event_id: event_id,
           ticket_type_id: ticket_type_id,
           woo_product_id: product_id,
           woo_variation_id: variation_id,
           quantity: quantity,
           line_total: line_total,
           line_total_tax: line_total_tax,
           mapping_status: :mapped,
           item_kind: :ticket
         },
         header,
         %DateTime{} = effective_at
       )
       when is_integer(quantity) and quantity > 0 do
    with {:ok, id} <- canonical_uuid(id),
         {:ok, event_id} <- canonical_uuid(event_id),
         {:ok, ticket_type_id} <- canonical_uuid(ticket_type_id),
         {:ok, source_system_id} <- canonical_uuid(Map.get(header, :source_system_id)),
         :ok <- valid_currency(Map.get(header, :currency)),
         :ok <- valid_product_identity(product_id, variation_id) do
      {:ok,
       %{
         id: id,
         event_id: event_id,
         currency: header.currency,
         effective_at: effective_at,
         ticket_type_id: ticket_type_id,
         source_system_id: source_system_id,
         woo_product_id: product_id,
         woo_variation_id: variation_id,
         gross_ticket_quantity: quantity,
         gross_ticket_value: gross_value_truth(line_total, line_total_tax),
         financial_primitives: {line_total, line_total_tax},
         refund_ticket_quantity: 0,
         refund_ticket_value: @zero
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp sale_contribution(_item, _header, _effective_at), do: :not_qualifying

  defp gross_value_truth(%Decimal{} = line_total, %Decimal{} = line_total_tax),
    do: FinancialPrimitives.gross_ticket_value(line_total, line_total_tax)

  defp gross_value_truth(_line_total, _line_total_tax), do: nil

  defp refund_contributions(nil), do: {:ok, %{}}

  defp refund_contributions(%{
         refund_truth: refund,
         refund_line_truth: lines,
         parent_order_evidence: parent,
         parent_order_item_evidence: parent_items
       })
       when is_map(refund) and is_list(lines) and is_list(parent_items) do
    if qualifying_refund_header?(refund, parent) do
      parent_items_by_id = Map.new(parent_items, &{Map.get(&1, :id), &1})
      reduce_refund_lines(lines, refund, parent, parent_items_by_id)
    else
      {:ok, %{}}
    end
  end

  defp refund_contributions(_snapshot), do: {:error, :invalid_refund_period_snapshot}

  defp reduce_refund_lines(lines, refund, parent, parent_items_by_id) do
    Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, acc} ->
      case refund_contribution(line, refund, parent, parent_items_by_id) do
        :not_qualifying ->
          {:cont, {:ok, acc}}

        {:ok, contribution} ->
          {:cont, {:ok, Map.put(acc, {:refund, contribution.id}, contribution)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp qualifying_refund_header?(refund, parent) when is_map(parent) do
    Map.get(refund, :source_state) == :active and
      Map.get(refund, :detail_status) == :complete and
      historically_recognised?(parent) and
      is_binary(Map.get(refund, :currency)) and
      Map.get(refund, :currency) == Map.get(parent, :currency) and
      match?(%DateTime{}, Map.get(refund, :source_created_at))
  end

  defp qualifying_refund_header?(_refund, _parent), do: false

  defp refund_contribution(
         %{
           id: id,
           order_item_id: order_item_id,
           woo_refunded_item_id: refunded_item_id,
           refunded_quantity: quantity,
           refund_total_amount: amount,
           refund_total_tax: tax,
           binding_reason: nil,
           validation_reason: nil
         },
         refund,
         parent,
         parent_items_by_id
       )
       when is_integer(quantity) and is_struct(amount, Decimal) and is_struct(tax, Decimal) do
    parent_item = Map.get(parent_items_by_id, order_item_id)

    with {:ok, id} <- canonical_uuid(id),
         {:ok, parent_identity} <- exact_parent_identity(parent_item, refunded_item_id),
         {:ok, source_system_id} <- canonical_uuid(Map.get(parent, :source_system_id)),
         {:ok, effective_at} <- utc_instant(Map.get(refund, :source_created_at)) do
      refund_value = FinancialPrimitives.refund_ticket_value(amount, tax)
      refund_quantity = FinancialPrimitives.refund_ticket_quantity(quantity)

      if Decimal.compare(refund_value, @zero) == :gt or
           Decimal.compare(refund_quantity, @zero) == :gt do
        {:ok,
         Map.merge(parent_identity, %{
           id: id,
           currency: refund.currency,
           effective_at: effective_at,
           source_system_id: source_system_id,
           gross_ticket_quantity: 0,
           gross_ticket_value: @zero,
           refund_ticket_quantity: Decimal.to_integer(refund_quantity),
           refund_ticket_value: refund_value
         })}
      else
        :not_qualifying
      end
    else
      :not_qualifying -> :not_qualifying
      {:error, reason} -> {:error, reason}
    end
  end

  defp refund_contribution(_line, _refund, _parent, _parent_items_by_id),
    do: :not_qualifying

  defp exact_parent_identity(
         %{
           id: order_item_id,
           woo_line_item_id: line_item_id,
           event_id: event_id,
           ticket_type_id: ticket_type_id,
           woo_product_id: product_id,
           woo_variation_id: variation_id,
           item_kind: :ticket,
           mapping_status: :mapped
         },
         refunded_item_id
       )
       when line_item_id == refunded_item_id do
    with {:ok, _order_item_id} <- canonical_uuid(order_item_id),
         {:ok, event_id} <- canonical_uuid(event_id),
         {:ok, ticket_type_id} <- canonical_uuid(ticket_type_id),
         :ok <- valid_product_identity(product_id, variation_id) do
      {:ok,
       %{
         event_id: event_id,
         ticket_type_id: ticket_type_id,
         woo_product_id: product_id,
         woo_variation_id: variation_id
       }}
    else
      _ -> :not_qualifying
    end
  end

  defp exact_parent_identity(_parent_item, _refunded_item_id), do: :not_qualifying

  defp changed_bucket_identities(before, after_contributions) do
    keys = (Map.keys(before) ++ Map.keys(after_contributions)) |> Enum.uniq()

    keys
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, acc} ->
      old_contribution = Map.get(before, key)
      new_contribution = Map.get(after_contributions, key)

      case changed_contribution_buckets(old_contribution, new_contribution) do
        {:ok, buckets} -> {:cont, {:ok, buckets ++ acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, buckets} -> {:ok, unique_buckets(buckets)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp changed_contribution_buckets(contribution, contribution), do: {:ok, []}

  defp changed_contribution_buckets(old_contribution, new_contribution) do
    with {:ok, old_buckets} <- contribution_buckets(old_contribution),
         {:ok, new_buckets} <- contribution_buckets(new_contribution) do
      {:ok, old_buckets ++ new_buckets}
    end
  end

  defp contribution_buckets(nil), do: {:ok, []}

  defp contribution_buckets(%{event_id: event_id, currency: currency, effective_at: effective_at}) do
    with :ok <- valid_currency(currency),
         {:ok, buckets} <- PeriodBucketRules.for_instant(effective_at) do
      {:ok,
       Enum.map(buckets, fn bucket ->
         Map.merge(bucket, %{event_id: event_id, currency: currency})
       end)}
    end
  end

  defp unique_buckets(buckets) do
    buckets
    |> Enum.uniq_by(&bucket_key/1)
    |> Enum.sort_by(&bucket_sort_key/1)
  end

  defp bucket_key(bucket) do
    {bucket.event_id, bucket.currency, bucket.bucket_kind, bucket.bucket_start_utc,
     bucket.bucket_end_utc}
  end

  defp bucket_sort_key(bucket) do
    {bucket.event_id, bucket.currency, Atom.to_string(bucket.bucket_kind),
     DateTime.to_unix(bucket.bucket_start_utc, :microsecond)}
  end

  defp persist_refresh_intent([]), do: :ok

  defp persist_refresh_intent(buckets) do
    event_ids = Enum.map(buckets, & &1.event_id) |> Enum.uniq()

    with :ok <- EventSnapshotRefreshFence.lock_events_in_transaction(event_ids) do
      now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

      rows = Enum.map(buckets, &pending_bucket_row(&1, now))

      try do
        Repo.insert_all(@period_snapshots, rows,
          on_conflict: [set: [projection_state: "refresh_pending", updated_at: now]],
          conflict_target: [
            :event_id,
            :currency,
            :bucket_kind,
            :bucket_start_utc,
            :bucket_end_utc
          ]
        )

        :ok
      rescue
        _error -> {:error, :period_projection_invalidation_failed}
      end
    end
  end

  defp pending_bucket_row(bucket, now) do
    %{
      id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
      event_id: Ecto.UUID.dump!(bucket.event_id),
      currency: bucket.currency,
      bucket_kind: Atom.to_string(bucket.bucket_kind),
      bucket_start_utc: bucket.bucket_start_utc,
      bucket_end_utc: bucket.bucket_end_utc,
      bucket_timezone: bucket.bucket_timezone,
      gross_ticket_quantity: 0,
      gross_ticket_value: @zero,
      refund_ticket_quantity: 0,
      refund_ticket_value: @zero,
      generation_id: Ecto.UUID.generate() |> Ecto.UUID.dump!(),
      semantic_version: @semantic_version,
      coverage_identity: @coverage_identity,
      projection_state: "refresh_pending",
      refreshed_at: now,
      source_watermark_at: nil,
      inserted_at: now,
      updated_at: now
    }
  end

  defp historically_recognised?(header) do
    FinancialPrimitives.historically_recognised_order?(
      Map.get(header, :status),
      Map.get(header, :completed_at)
    )
  end

  defp sale_effective_at(header) do
    Map.get(header, :paid_at) || Map.get(header, :completed_at)
  end

  defp valid_product_identity(product_id, variation_id) do
    if is_integer(product_id) and product_id > 0 and
         (is_nil(variation_id) or (is_integer(variation_id) and variation_id > 0)) do
      :ok
    else
      {:error, :invalid_period_source_identity}
    end
  end

  defp valid_currency(currency) when is_binary(currency) and byte_size(currency) > 0, do: :ok
  defp valid_currency(_currency), do: {:error, :invalid_period_source_identity}

  defp canonical_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :invalid_period_source_identity}
    end
  end

  defp canonical_uuid(_value), do: {:error, :invalid_period_source_identity}

  defp utc_instant(%DateTime{time_zone: "Etc/UTC", utc_offset: 0, std_offset: 0} = instant),
    do: {:ok, instant}

  defp utc_instant(_instant), do: {:error, :invalid_period_source_identity}
end
