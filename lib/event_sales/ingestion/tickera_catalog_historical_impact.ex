defmodule EventSales.Ingestion.TickeraCatalogHistoricalImpact do
  @moduledoc "Builds a read-only, discovery-time forecast of pair-scoped recovery impact."

  import Ecto.Query
  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Repo
  alias EventSales.Sales.AutomaticMappingPolicy

  # Each aggregate query is limited to the production-validated 25 exact-pair shape.
  @max_supported_batch_pairs 25
  @default_max_batch_pairs @max_supported_batch_pairs

  # This is an application-level safety ceiling for one complete forecast. It is not
  # derived from feed pagination configuration. Aggregate batches run sequentially.
  @default_max_total_pairs 5_000
  @notice "Discovery-time forecast. Order and mapping state is re-evaluated during recovery; actual outcomes may differ due to order updates."

  @spec forecast(Ecto.UUID.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def forecast(source_system_id, context, opts \\ [])

  def forecast(source_system_id, context, opts) when is_binary(source_system_id) do
    max_batch_pairs = Keyword.get(opts, :max_batch_pairs, @default_max_batch_pairs)
    max_total_pairs = Keyword.get(opts, :max_total_pairs, @default_max_total_pairs)
    now = Keyword.get(opts, :now, DateTime.utc_now())

    with :ok <- validate_limits(max_batch_pairs, max_total_pairs),
         {:ok, keys} <- normalize_keys(Map.get(context, :touched_product_keys, [])),
         :ok <- enforce_total_limit(keys, max_total_pairs),
         indexed_context <- index_context(context, keys),
         {:ok, destinations} <- destinations(source_system_id, keys, indexed_context),
         {:ok, rows} <- aggregate(source_system_id, keys, max_batch_pairs),
         {:ok, impact} <- build(rows, destinations) do
      timestamp = DateTime.to_iso8601(now)

      {:ok,
       Map.merge(impact, %{
         "generated_at" => timestamp,
         "source_snapshot_at" => iso8601(Map.get(context, :source_snapshot_at)),
         "order_state_observed_at" => timestamp,
         "source_system_id" => source_system_id,
         "forecast_notice" => @notice,
         "proposed_destinations" => destinations
       })}
    end
  rescue
    error -> {:error, {:historical_impact_query_failed, error}}
  end

  def forecast(_source_system_id, _context, _opts), do: {:error, :invalid_source_system_id}

  defp normalize_keys(keys) when is_list(keys) do
    keys
    |> Enum.reduce_while({:ok, []}, fn
      {product, variation}, {:ok, acc}
      when is_integer(product) and (is_integer(variation) or is_nil(variation)) ->
        {:cont, {:ok, [{product, variation} | acc]}}

      [product, variation], {:ok, acc}
      when is_integer(product) and (is_integer(variation) or is_nil(variation)) ->
        {:cont, {:ok, [{product, variation} | acc]}}

      _, _ ->
        {:halt, {:error, :invalid_touched_product_key}}
    end)
    |> case do
      {:ok, normalized} -> {:ok, normalized |> Enum.uniq() |> Enum.sort_by(&pair_sort_key/1)}
      error -> error
    end
  end

  defp normalize_keys(_), do: {:error, :invalid_touched_product_key}

  defp validate_limits(max_batch_pairs, max_total_pairs)
       when is_integer(max_batch_pairs) and max_batch_pairs > 0 and
              is_integer(max_total_pairs) and max_total_pairs > 0 and
              max_batch_pairs <= @max_supported_batch_pairs,
       do: :ok

  defp validate_limits(max_batch_pairs, max_total_pairs) do
    {:error,
     {:invalid_historical_impact_limits,
      %{
        max_batch_pairs: max_batch_pairs,
        max_total_pairs: max_total_pairs,
        max_supported_batch_pairs: @max_supported_batch_pairs
      }}}
  end

  defp enforce_total_limit(keys, limit) when length(keys) <= limit, do: :ok

  defp enforce_total_limit(keys, limit),
    do:
      {:error,
       {:historical_impact_scope_too_large,
        %{observed_pairs: length(keys), max_total_pairs: limit}}}

  defp aggregate(_source_system_id, [], _max_batch_pairs), do: {:ok, []}

  defp aggregate(source_system_id, keys, max_batch_pairs) do
    keys
    |> Enum.chunk_every(max_batch_pairs)
    |> Enum.reduce({:ok, []}, fn batch, {:ok, rows} ->
      {:ok, [Repo.all(aggregate_query(source_system_id, batch)) | rows]}
    end)
    |> case do
      {:ok, batches} -> {:ok, batches |> Enum.reverse() |> List.flatten()}
      error -> error
    end
  end

  defp aggregate_query(source_system_id, keys) do
    pair_filter =
      Enum.reduce(keys, dynamic(false), fn {product, variation}, expression ->
        pair =
          if is_nil(variation) do
            dynamic(
              [item, _order],
              item.woo_product_id == ^product and is_nil(item.woo_variation_id)
            )
          else
            dynamic(
              [item, _order],
              item.woo_product_id == ^product and item.woo_variation_id == ^variation
            )
          end

        dynamic([item, order], ^expression or ^pair)
      end)

    query =
      from item in "sales_order_items",
        join: order in "sales_orders",
        on: order.id == item.order_id,
        where: order.source_system_id == type(^source_system_id, :binary_id),
        where: item.mapping_status in ["pending_mapping_resolution", "mapped"],
        where: ^pair_filter,
        group_by: [
          item.woo_product_id,
          item.woo_variation_id,
          item.mapping_status,
          order.status,
          item.source_tickera_event_id
        ],
        order_by: [
          asc: item.woo_product_id,
          asc: item.woo_variation_id,
          asc: item.mapping_status,
          asc: order.status,
          asc: item.source_tickera_event_id
        ],
        select: %{
          product_id: item.woo_product_id,
          variation_id: item.woo_variation_id,
          mapping_status: item.mapping_status,
          order_status: order.status,
          source_event_id: item.source_tickera_event_id,
          lines: count(item.id),
          quantity: sum(item.quantity)
        }

    query
  end

  defp destinations(source_system_id, keys, context) do
    with {:ok, mappings} <- existing_mappings(source_system_id, keys, context.touched_keys_set) do
      build_destinations(keys, context, mappings)
    end
  end

  defp build_destinations(keys, context, mappings) do
    keys
    |> Enum.reduce_while({:ok, []}, fn key, {:ok, destinations} ->
      append_destination(key, context, mappings, destinations)
    end)
    |> case do
      {:ok, destinations} -> {:ok, Enum.sort_by(destinations, &pair_sort_key/1)}
      error -> error
    end
  end

  defp append_destination(key, context, mappings, destinations) do
    case destination(key, context, mappings) do
      {:ok, destination} -> {:cont, {:ok, [destination | destinations]}}
      {:warning, warning} -> {:cont, {:ok, [unresolved_destination(key, warning) | destinations]}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp destination({product, variation}, context, mappings) do
    changes = Map.get(context.mapping_changes_by_pair, {product, variation}, [])

    case changes do
      [change] ->
        proposed_destination(change, context)

      [] ->
        existing_destination(
          Map.get(mappings, {product, variation}, []),
          product,
          variation,
          context
        )

      _ ->
        {:error, :ambiguous_planned_destination}
    end
  end

  defp proposed_destination(change, context) do
    event_ref = value(change, :event_ref)
    ticket_ref = value(change, :ticket_type_ref)
    event = Map.get(context.event_changes_by_ref, event_ref)
    ticket = Map.get(context.ticket_changes_by_ref, ticket_ref)

    with true <- not is_nil(event) and not is_nil(ticket),
         {:ok, event_external_id, event_id} <- planned_event_identity(event),
         {:ok, ticket_external_id, ticket_event_id} <- planned_ticket_identity(ticket),
         :ok <- validate_planned_membership(event_id, ticket_event_id) do
      {:ok,
       destination_map(
         value(change, :woo_product_id),
         value(change, :woo_variation_id),
         event_external_id,
         ticket_external_id,
         "proposed"
       )}
    else
      false ->
        {:warning, warning("missing_proposed_destination", change)}

      {:error, :ticket_type_event_mismatch} ->
        {:warning, warning("ticket_type_event_mismatch", change)}

      {:error, _reason} ->
        {:warning, warning("missing_proposed_destination", change)}
    end
  end

  defp planned_event_identity(change) do
    case {value(change, :external_event_id), value(change, :event_id)} do
      {external_id, event_id} when is_integer(external_id) ->
        {:ok, external_id, event_id}

      {nil, event_id} when is_binary(event_id) ->
        case Ash.get(EventSales.Catalog.Resources.Event, event_id, domain: Catalog) do
          {:ok, event} when not is_nil(event) -> {:ok, event.external_event_id, event.id}
          _ -> {:error, :missing_event}
        end

      _ ->
        {:error, :missing_event}
    end
  end

  defp planned_ticket_identity(change) do
    case {value(change, :external_ticket_type_id), value(change, :ticket_type_id),
          value(change, :event_id)} do
      {external_id, _ticket_id, event_id} when is_integer(external_id) ->
        {:ok, external_id, event_id}

      {nil, ticket_id, _event_id} when is_binary(ticket_id) ->
        case Ash.get(EventSales.Catalog.Resources.TicketType, ticket_id, domain: Catalog) do
          {:ok, ticket} when not is_nil(ticket) ->
            {:ok, ticket.external_ticket_type_id, ticket.event_id}

          _ ->
            {:error, :missing_ticket_type}
        end

      _ ->
        {:error, :missing_ticket_type}
    end
  end

  defp validate_planned_membership(nil, _ticket_event_id), do: :ok
  defp validate_planned_membership(_event_id, nil), do: :ok
  defp validate_planned_membership(event_id, event_id), do: :ok

  defp validate_planned_membership(_event_id, _ticket_event_id),
    do: {:error, :ticket_type_event_mismatch}

  defp existing_mappings(source_system_id, keys, touched_keys_set) do
    products = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    ProductMapping
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and active == true and woo_product_id in ^products
    )
    |> Ash.Query.load([:event, :ticket_type])
    |> Ash.read(domain: Catalog)
    |> case do
      {:ok, mappings} ->
        {:ok,
         mappings
         |> Enum.filter(
           &MapSet.member?(touched_keys_set, {&1.woo_product_id, &1.woo_variation_id})
         )
         |> Enum.group_by(&{&1.woo_product_id, &1.woo_variation_id})}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp existing_destination([mapping], product, variation, context)
       when mapping.ticket_type.event_id == mapping.event_id do
    {event_external_id, ticket_external_id} = adopted_identities(mapping, context)

    {:ok,
     destination_map(
       product,
       variation,
       event_external_id,
       ticket_external_id,
       "existing_active_mapping"
     )}
  end

  defp existing_destination([mapping], _product, _variation, _context),
    do: {:warning, warning("ticket_type_event_mismatch", mapping)}

  defp existing_destination([], product, variation, _context) do
    {:warning,
     warning("missing_proposed_destination", %{
       woo_product_id: product,
       woo_variation_id: variation
     })}
  end

  defp existing_destination(_mappings, product, variation, _context),
    do:
      {:warning,
       warning("active_mapping_conflict", %{woo_product_id: product, woo_variation_id: variation})}

  defp build(rows, destinations) do
    with {:ok, classified} <- classify(rows, destinations) do
      historical_rows_by_pair = Enum.group_by(classified, &{&1.product_id, &1.variation_id})
      pending = Enum.filter(classified, &(&1.mapping_status == "pending_mapping_resolution"))
      mapped = Enum.filter(classified, &(&1.mapping_status == "mapped"))
      eligible = Enum.filter(pending, &(&1.eligibility == :eligible))
      deferred = Enum.filter(pending, &(&1.eligibility == :deferred))
      conflicting = Enum.filter(pending, &(&1.eligibility == :conflict))

      mapped_warnings =
        Enum.map(mapped, fn row ->
          warning("existing_mapped_history", %{
            woo_product_id: row.product_id,
            woo_variation_id: row.variation_id,
            metadata: %{"lines" => row.lines, "quantity" => row.quantity}
          })
        end)

      {:ok,
       %{
         "totals" => %{
           "affected_pending_lines" => sum(pending, :lines),
           "affected_quantity" => sum(pending, :quantity),
           "eligible_lines" => sum(eligible, :lines),
           "eligible_quantity" => sum(eligible, :quantity),
           "deferred_lines" => sum(deferred, :lines),
           "deferred_quantity" => sum(deferred, :quantity),
           "conflicting_lines" => sum(conflicting, :lines),
           "conflicting_quantity" => sum(conflicting, :quantity),
           "already_mapped_lines" => sum(mapped, :lines),
           "already_mapped_quantity" => sum(mapped, :quantity)
         },
         "by_product_variation" => by_pair(historical_rows_by_pair, destinations),
         "by_order_status" => grouped(classified, :order_status),
         "by_mapping_status" => grouped(classified, :mapping_status),
         "by_source_event_identity" => grouped(classified, :source_event_id),
         "eligibility" => grouped(classified, :eligibility),
         "warnings" =>
           (destination_warnings(destinations) ++ mapped_warnings)
           |> Enum.sort_by(&warning_sort_key/1)
       }}
    end
  end

  defp classify(rows, destinations) do
    destination_by_pair =
      Map.new(destinations, &{{&1["woo_product_id"], &1["woo_variation_id"]}, &1})

    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      destination = Map.fetch!(destination_by_pair, {row.product_id, row.variation_id})

      case classify_row(row, destination) do
        {:ok, eligibility} ->
          {:cont, {:ok, [Map.put(row, :eligibility, eligibility) | acc]}}

        {:error, _} ->
          {:halt, {:error, {:unsupported_order_status, row.order_status}}}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  rescue
    ArgumentError -> {:error, :unsupported_order_status}
  end

  defp classify_row(%{mapping_status: "mapped"}, _destination), do: {:ok, :ignored_already_mapped}

  defp classify_row(_row, %{"resolution" => resolution})
       when resolution in ["missing_destination", "conflict"],
       do: {:ok, :conflict}

  defp classify_row(_row, %{"proposed_event_external_id" => nil}), do: {:ok, :conflict}

  defp classify_row(%{source_event_id: source_event_id}, %{
         "proposed_event_external_id" => event_id
       })
       when is_integer(source_event_id) and source_event_id != event_id,
       do: {:ok, :conflict}

  defp classify_row(row, _destination) do
    row.order_status
    |> String.to_existing_atom()
    |> AutomaticMappingPolicy.classify_order_status()
  end

  defp by_pair(historical_rows_by_pair, destinations) do
    destinations
    |> Enum.map(fn destination ->
      pair_rows =
        Map.get(
          historical_rows_by_pair,
          {destination["woo_product_id"], destination["woo_variation_id"]},
          []
        )

      pending = Enum.filter(pair_rows, &(&1.mapping_status == "pending_mapping_resolution"))

      Map.merge(destination, %{
        "pending_line_count" => sum(pending, :lines),
        "quantity" => sum(pending, :quantity),
        "eligible_line_count" =>
          sum(Enum.filter(pending, &(&1.eligibility == :eligible)), :lines),
        "deferred_line_count" =>
          sum(Enum.filter(pending, &(&1.eligibility == :deferred)), :lines),
        "conflicting_line_count" =>
          sum(Enum.filter(pending, &(&1.eligibility == :conflict)), :lines),
        "conflicting_quantity" =>
          sum(Enum.filter(pending, &(&1.eligibility == :conflict)), :quantity),
        "already_mapped_line_count" =>
          sum(Enum.filter(pair_rows, &(&1.eligibility == :ignored_already_mapped)), :lines),
        "already_mapped_quantity" =>
          sum(Enum.filter(pair_rows, &(&1.eligibility == :ignored_already_mapped)), :quantity),
        "order_status_counts" => grouped(pending, :order_status),
        "source_tickera_event_id_distribution" => grouped(pending, :source_event_id)
      })
    end)
  end

  defp grouped(rows, field) do
    rows
    |> Enum.group_by(&Map.get(&1, field))
    |> Map.new(fn {key, values} ->
      {to_string(key || "null"),
       %{"lines" => sum(values, :lines), "quantity" => sum(values, :quantity)}}
    end)
  end

  defp sum(rows, field), do: Enum.reduce(rows, 0, &(number(Map.get(&1, field, 0)) + &2))

  defp number(%Decimal{} = value), do: Decimal.to_integer(value)
  defp number(value), do: value

  defp destination_map(product, variation, event, ticket, resolution) do
    %{
      "woo_product_id" => product,
      "woo_variation_id" => variation,
      "proposed_event_external_id" => event,
      "proposed_ticket_type_external_id" => ticket,
      "resolution" => resolution
    }
  end

  defp unresolved_destination({product, variation}, warning) do
    destination_map(product, variation, nil, nil, resolution_for_warning(warning["code"]))
    |> Map.put("warning", warning)
  end

  defp resolution_for_warning("active_mapping_conflict"), do: "conflict"
  defp resolution_for_warning("ticket_type_event_mismatch"), do: "conflict"
  defp resolution_for_warning(_code), do: "missing_destination"

  defp destination_warnings(destinations) do
    destinations
    |> Enum.flat_map(fn destination ->
      if warning = destination["warning"], do: [warning], else: []
    end)
  end

  defp adopted_identities(mapping, context) do
    event_change = Map.get(context.adopted_events_by_id, mapping.event_id)
    ticket_change = Map.get(context.adopted_tickets_by_id, mapping.ticket_type_id)

    {value(event_change || %{}, :external_event_id) || mapping.event.external_event_id,
     value(ticket_change || %{}, :external_ticket_type_id) ||
       mapping.ticket_type.external_ticket_type_id}
  end

  defp pair_sort_key({product, variation}), do: {product, nil_first(variation)}
  defp pair_sort_key(map), do: pair_sort_key({map["woo_product_id"], map["woo_variation_id"]})
  defp nil_first(nil), do: {0, 0}
  defp nil_first(variation), do: {1, variation}

  defp warning_sort_key(warning),
    do: {pair_sort_key(warning), warning["code"], warning["metadata"] |> inspect()}

  defp warning(code, value) do
    %{
      "code" => code,
      "severity" => "warning",
      "woo_product_id" => value(value, :woo_product_id),
      "woo_variation_id" => value(value, :woo_variation_id),
      "metadata" => value(value, :metadata) || %{}
    }
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))
  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(nil), do: nil

  defp index_context(context, keys) do
    event_changes = Map.get(context, :event_changes, [])
    ticket_type_changes = Map.get(context, :ticket_type_changes, [])

    %{
      mapping_changes_by_pair:
        context
        |> Map.get(:product_mapping_changes, [])
        |> Enum.group_by(&{value(&1, :woo_product_id), value(&1, :woo_variation_id)}),
      event_changes_by_ref: index_by_first(event_changes, &value(&1, :ref)),
      ticket_changes_by_ref: index_by_first(ticket_type_changes, &value(&1, :ref)),
      adopted_events_by_id:
        event_changes
        |> Enum.filter(&(value(&1, :action) in [:adopt_existing, "adopt_existing"]))
        |> index_by_first(&value(&1, :event_id)),
      adopted_tickets_by_id:
        ticket_type_changes
        |> Enum.filter(&(value(&1, :action) in [:adopt_existing, "adopt_existing"]))
        |> index_by_first(&value(&1, :ticket_type_id)),
      touched_keys_set: MapSet.new(keys)
    }
  end

  defp index_by_first(values, key_fun) do
    Enum.reduce(values, %{}, fn value, index ->
      Map.put_new(index, key_fun.(value), value)
    end)
  end
end
