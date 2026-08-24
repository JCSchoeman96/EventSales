defmodule EventSales.Catalog.MissingCatalogResolver do
  @moduledoc """
  Retries local mapping for order items affected by missing catalog metadata.

  This resolver never calls WooCommerce REST and never creates product mappings.
  Product metadata is informational only; EventSales mapping remains a local
  `ProductMapping` decision.
  """

  import Ecto.Query

  require Ash.Query

  alias EventSales.Ingestion.HistoricalCoverageInvalidator
  alias EventSales.Ingestion.HistoricalOrderMutationDetector
  alias EventSales.Repo
  alias EventSales.Sales
  alias EventSales.Sales.OrderItemMapper
  alias EventSales.Sales.Resources.{Order, OrderItem}

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
  def recover_product(source_system_id, woo_product_id, woo_variation_id, opts \\ [])
      when is_binary(source_system_id) and is_integer(woo_product_id) do
    with {:ok, items} <- pending_items(source_system_id, woo_product_id, woo_variation_id) do
      recover_orders(items, source_system_id, woo_product_id, woo_variation_id, opts)
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

  defp recover_orders(items, source_system_id, woo_product_id, woo_variation_id, opts) do
    items
    |> Enum.group_by(& &1.order.id)
    |> Enum.sort_by(fn {order_id, _items} -> order_id end)
    |> Enum.reduce_while({:ok, empty_result()}, fn {order_id, _items}, {:ok, totals} ->
      case recover_order(
             order_id,
             source_system_id,
             woo_product_id,
             woo_variation_id,
             opts
           ) do
        {:ok, order_result} ->
          {:cont, {:ok, add_results(totals, order_result)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp recover_order(order_id, source_system_id, woo_product_id, woo_variation_id, opts) do
    Repo.transaction(fn ->
      with {:ok, order} <- lock_order(order_id, source_system_id),
           {:ok, items} <- lock_pending_items(order.id, woo_product_id, woo_variation_id),
           {:ok, before_snapshot} <- capture_order(order, opts),
           {:ok, result} <- recover_items(items),
           {:ok, after_snapshot} <- capture_order(order, opts),
           :ok <- invalidate_changed_order(order, before_snapshot, after_snapshot, opts) do
        result
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp lock_order(order_id, source_system_id) do
    query =
      from order in "sales_orders",
        where:
          order.id == type(^order_id, Ecto.UUID) and
            order.source_system_id == type(^source_system_id, Ecto.UUID),
        select: order.id,
        lock: "FOR UPDATE"

    case Repo.one(query) do
      nil ->
        {:error, :order_not_found}

      locked_order_id ->
        case Ash.get(Order, locked_order_id, domain: Sales) do
          {:ok, %Order{} = order} -> {:ok, order}
          {:ok, nil} -> {:error, :order_not_found}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp lock_pending_items(order_id, woo_product_id, woo_variation_id) do
    query =
      from item in "sales_order_items",
        where:
          item.order_id == type(^order_id, Ecto.UUID) and
            item.woo_product_id == ^woo_product_id and
            item.mapping_status == "pending_mapping_resolution",
        order_by: [asc: item.woo_line_item_id, asc: item.id],
        select: item.id,
        lock: "FOR UPDATE"

    query
    |> locked_variation_filter(woo_variation_id)
    |> Repo.all()
    |> load_locked_items()
  end

  defp locked_variation_filter(query, nil),
    do: where(query, [item], is_nil(item.woo_variation_id))

  defp locked_variation_filter(query, woo_variation_id),
    do: where(query, [item], item.woo_variation_id == ^woo_variation_id)

  defp load_locked_items([]), do: {:ok, []}

  defp load_locked_items(item_ids) do
    item_ids
    |> Enum.reduce_while({:ok, []}, fn item_id, {:ok, items} ->
      case Ash.get(OrderItem, item_id, domain: Sales) do
        {:ok, %OrderItem{} = item} -> {:cont, {:ok, [item | items]}}
        {:ok, nil} -> {:halt, {:error, :order_item_not_found}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, items} -> Ash.load(Enum.reverse(items), :order, domain: Sales)
      {:error, reason} -> {:error, reason}
    end
  end

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

  defp capture_order(order, opts) do
    detector =
      Keyword.get(opts, :historical_order_mutation_detector, HistoricalOrderMutationDetector)

    detector.capture(order)
  end

  defp invalidate_changed_order(order, before_snapshot, after_snapshot, opts) do
    detector =
      Keyword.get(opts, :historical_order_mutation_detector, HistoricalOrderMutationDetector)

    case detector.compare(before_snapshot, after_snapshot) do
      %{changed?: false, candidate_event_ids: []} ->
        :ok

      %{changed?: true, candidate_event_ids: []} ->
        :ok

      %{changed?: true, candidate_event_ids: candidate_event_ids}
      when is_list(candidate_event_ids) ->
        call_coverage_invalidator(order, candidate_event_ids, opts)

      _other ->
        {:error, :invalid_historical_order_mutation_comparison}
    end
  end

  defp call_coverage_invalidator(order, event_ids, opts) do
    invalidator =
      Keyword.get(
        opts,
        :historical_coverage_invalidator,
        &HistoricalCoverageInvalidator.invalidate_order_change/2
      )

    case invalidator.(order, event_ids) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_historical_coverage_invalidator_result, other}}
    end
  end

  defp empty_result do
    %{mapped: 0, marked_unmapped: 0, unchanged: 0}
  end

  defp add_results(left, right) do
    %{
      mapped: left.mapped + right.mapped,
      marked_unmapped: left.marked_unmapped + right.marked_unmapped,
      unchanged: left.unchanged + right.unchanged
    }
  end
end
