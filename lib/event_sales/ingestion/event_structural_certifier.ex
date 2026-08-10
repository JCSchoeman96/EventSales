defmodule EventSales.Ingestion.EventStructuralCertifier do
  @moduledoc """
  Certifies the durable catalogue structure for one exact Tickera Event.

  The certifier trusts only the persisted, event-scoped dry-run snapshot identified
  by the caller. It never accepts live discovery rows, calls the source system, or
  mutates catalogue structure.
  """

  require Ash.Query

  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.{Event, ProductMapping, SourceSystem, TicketType}
  alias EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizer
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.TickeraCatalogSyncRun
  alias EventSales.Repo

  @event_lock_query "SELECT id FROM catalog_events WHERE id = $1 FOR UPDATE"
  @run_lock_query "SELECT id FROM ingestion_tickera_catalog_sync_runs WHERE id = $1 FOR UPDATE"
  @scope %{"kind" => "wordpress_feed"}

  @type reason ::
          :event_not_found
          | :invalid_event_identity
          | :run_not_found
          | :run_not_ready
          | :run_source_mismatch
          | :run_scope_mismatch
          | :missing_plan_snapshot
          | :snapshot_hash_mismatch
          | :blocking_discovery_findings
          | :invalid_source_membership
          | :mapping_source_mismatch
          | :missing_mapping
          | :extra_mapping
          | :foreign_event_mapping
          | :variation_set_mismatch
          | :ticket_type_event_mismatch
          | :ticket_type_inactive
          | :ticket_type_product_mismatch
          | :ticket_type_variation_mismatch
          | :certification_failed

  @spec certify(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, %{event: Event.t(), run: TickeraCatalogSyncRun.t()}}
          | {:error, reason()}
  def certify(local_event_id, sync_run_id, opts \\ [])

  def certify(local_event_id, sync_run_id, opts)
      when is_binary(local_event_id) and is_binary(sync_run_id) and is_list(opts) do
    transaction_result =
      Repo.transaction(fn ->
        with :ok <- lock_uuid(@event_lock_query, local_event_id, :event_not_found),
             {:ok, event} <- load_event(local_event_id),
             :ok <- validate_event(event),
             :ok <- run_hook(opts, :after_certification_locks),
             :ok <- lock_uuid(@run_lock_query, sync_run_id, :run_not_found),
             {:ok, run} <- load_run(sync_run_id),
             :ok <- validate_run_binding(event, run),
             {:ok, snapshot} <- trusted_snapshot(run),
             {:ok, source_membership} <- source_membership(snapshot),
             :ok <- reject_blocking_findings(snapshot),
             {:ok, local_mappings} <- active_event_mappings(event),
             :ok <- validate_event_mapping_sources(event, local_mappings),
             {:ok, owned_mappings} <- active_source_mappings(event, source_membership),
             :ok <- reject_foreign_event_mapping(event, source_membership, owned_mappings),
             :ok <- validate_mapping_sets(source_membership, local_mappings),
             :ok <- validate_mapping_bindings(event, local_mappings),
             :ok <- run_hook(opts, :before_certification_transition),
             {:ok, certified_event} <- transition_event(event) do
          {:ok, %{event: certified_event, run: run}}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case transaction_result do
      {:ok, result} -> result
      {:error, reason} when is_atom(reason) -> {:error, reason}
      {:error, _reason} -> {:error, :certification_failed}
    end
  rescue
    _error -> {:error, :certification_failed}
  end

  def certify(_local_event_id, _sync_run_id, _opts), do: {:error, :certification_failed}

  defp load_event(local_event_id) do
    case Ash.get(Event, local_event_id, domain: Catalog) do
      {:ok, %Event{} = event} -> {:ok, event}
      {:ok, nil} -> {:error, :event_not_found}
      {:error, _reason} -> {:error, :event_not_found}
    end
  end

  defp validate_event(%Event{
         source_system_id: source_system_id,
         external_event_kind: :tickera_event,
         external_event_id: external_event_id
       })
       when is_binary(source_system_id) and is_integer(external_event_id) and
              external_event_id > 0 do
    case Ash.get(SourceSystem, source_system_id, domain: Catalog) do
      {:ok, %SourceSystem{}} -> :ok
      _other -> {:error, :invalid_event_identity}
    end
  end

  defp validate_event(_event), do: {:error, :invalid_event_identity}

  defp load_run(sync_run_id) do
    case Ash.get(TickeraCatalogSyncRun, sync_run_id, domain: Ingestion) do
      {:ok, %TickeraCatalogSyncRun{} = run} -> {:ok, run}
      {:ok, nil} -> {:error, :run_not_found}
      {:error, _reason} -> {:error, :run_not_found}
    end
  end

  defp validate_run_binding(
         %Event{source_system_id: source_system_id, external_event_id: external_event_id},
         %TickeraCatalogSyncRun{
           status: :dry_run_ready,
           source_system_id: source_system_id,
           scope: scope
         }
       ) do
    if scope == Map.put(@scope, "event_id", external_event_id) do
      :ok
    else
      {:error, :run_scope_mismatch}
    end
  end

  defp validate_run_binding(%Event{}, %TickeraCatalogSyncRun{status: :dry_run_ready}),
    do: {:error, :run_source_mismatch}

  defp validate_run_binding(%Event{}, %TickeraCatalogSyncRun{}),
    do: {:error, :run_not_ready}

  defp trusted_snapshot(%TickeraCatalogSyncRun{plan_snapshot: nil}),
    do: {:error, :missing_plan_snapshot}

  defp trusted_snapshot(%TickeraCatalogSyncRun{plan_snapshot: snapshot})
       when not is_map(snapshot),
       do: {:error, :missing_plan_snapshot}

  defp trusted_snapshot(%TickeraCatalogSyncRun{
         plan_snapshot: snapshot,
         dry_run_hash: dry_run_hash
       })
       when is_map(snapshot) and is_binary(dry_run_hash) and dry_run_hash != "" do
    case SnapshotCanonicalizer.canonicalize(snapshot) do
      {:ok, _bytes, ^dry_run_hash} -> {:ok, snapshot}
      _other -> {:error, :snapshot_hash_mismatch}
    end
  end

  defp trusted_snapshot(_run), do: {:error, :snapshot_hash_mismatch}

  defp reject_blocking_findings(snapshot) do
    finding_lists = [
      map_value(snapshot, "findings"),
      map_value(snapshot, "canonical_source_risk_findings")
    ]

    if Enum.any?(finding_lists, fn findings ->
         is_list(findings) and Enum.any?(findings, &blocking_finding?/1)
       end) do
      {:error, :blocking_discovery_findings}
    else
      :ok
    end
  end

  defp blocking_finding?(finding),
    do: map_value(finding, "severity") in [:blocking, "blocking"]

  defp source_membership(snapshot) do
    with touched when is_map(touched) <- map_value(snapshot, "touched_identifiers"),
         product_keys when is_list(product_keys) <- map_value(touched, "product_keys"),
         {:ok, full_keys} <- normalize_product_keys(product_keys) do
      product_ids = MapSet.new(full_keys, &elem(&1, 0))
      variations = MapSet.new(Enum.reject(full_keys, &is_nil(elem(&1, 1))))

      {:ok,
       %{
         full_keys: MapSet.new(full_keys),
         product_ids: product_ids,
         variations: variations
       }}
    else
      _other -> {:error, :invalid_source_membership}
    end
  end

  defp normalize_product_keys(product_keys) do
    Enum.reduce_while(product_keys, {:ok, []}, fn product_key, {:ok, keys} ->
      product_id = map_value(product_key, "woo_product_id")
      variation_id = map_value(product_key, "woo_variation_id")

      if positive_integer?(product_id) and
           (is_nil(variation_id) or positive_integer?(variation_id)) do
        {:cont, {:ok, [{product_id, variation_id} | keys]}}
      else
        {:halt, {:error, :invalid_source_membership}}
      end
    end)
    |> case do
      {:ok, keys} -> {:ok, Enum.reverse(keys)}
      error -> error
    end
  end

  defp active_event_mappings(%Event{id: event_id}) do
    ProductMapping
    |> Ash.Query.filter(event_id == ^event_id and active == true)
    |> Ash.read(domain: Catalog)
    |> normalize_read_result()
  end

  defp validate_event_mapping_sources(%Event{source_system_id: source_system_id}, mappings) do
    if Enum.all?(mappings, &(&1.source_system_id == source_system_id)) do
      :ok
    else
      {:error, :mapping_source_mismatch}
    end
  end

  defp active_source_mappings(
         %Event{source_system_id: source_system_id},
         %{product_ids: product_ids}
       ) do
    product_ids = product_ids |> MapSet.to_list() |> Enum.sort()

    if product_ids == [] do
      {:ok, []}
    else
      ProductMapping
      |> Ash.Query.filter(source_system_id == ^source_system_id and active == true)
      |> Ash.Query.filter(woo_product_id in ^product_ids)
      |> Ash.read(domain: Catalog)
      |> normalize_read_result()
    end
  end

  defp normalize_read_result({:ok, records}) when is_list(records), do: {:ok, records}
  defp normalize_read_result(_result), do: {:error, :certification_failed}

  defp reject_foreign_event_mapping(
         %Event{id: event_id},
         %{full_keys: source_full_keys},
         mappings
       ) do
    foreign? =
      Enum.any?(mappings, fn mapping ->
        mapping.event_id != event_id and mapping_key(mapping) in source_full_keys
      end)

    if foreign?, do: {:error, :foreign_event_mapping}, else: :ok
  end

  defp validate_mapping_sets(source_membership, mappings) do
    local_full_keys = MapSet.new(mappings, &mapping_key/1)
    local_product_ids = MapSet.new(local_full_keys, &elem(&1, 0))
    local_variations = MapSet.new(Enum.reject(local_full_keys, &is_nil(elem(&1, 1))))

    local = %{
      full_keys: local_full_keys,
      product_ids: local_product_ids,
      variations: local_variations
    }

    cond do
      membership_sets_equal?(source_membership, local) ->
        :ok

      same_products_with_different_variations?(source_membership, local) ->
        {:error, :variation_set_mismatch}

      not empty_difference?(source_membership.product_ids, local.product_ids) ->
        {:error, :missing_mapping}

      not empty_difference?(local.product_ids, source_membership.product_ids) ->
        {:error, :extra_mapping}

      not MapSet.equal?(source_membership.variations, local.variations) ->
        {:error, :variation_set_mismatch}

      not empty_difference?(source_membership.full_keys, local.full_keys) ->
        {:error, :missing_mapping}

      not empty_difference?(local.full_keys, source_membership.full_keys) ->
        {:error, :extra_mapping}

      true ->
        {:error, :certification_failed}
    end
  end

  defp membership_sets_equal?(left, right) do
    MapSet.equal?(left.full_keys, right.full_keys) and
      MapSet.equal?(left.product_ids, right.product_ids) and
      MapSet.equal?(left.variations, right.variations)
  end

  defp same_products_with_different_variations?(left, right) do
    MapSet.equal?(left.product_ids, right.product_ids) and
      not MapSet.equal?(left.variations, right.variations)
  end

  defp empty_difference?(left, right) do
    MapSet.equal?(MapSet.difference(left, right), MapSet.new())
  end

  defp validate_mapping_bindings(%Event{} = event, mappings) do
    ticket_ids = mappings |> Enum.map(& &1.ticket_type_id) |> Enum.uniq()

    case load_ticket_types(ticket_ids) do
      {:ok, tickets} -> validate_loaded_mapping_bindings(event, mappings, tickets)
      error -> error
    end
  end

  defp validate_loaded_mapping_bindings(event, mappings, tickets) do
    tickets_by_id = Map.new(tickets, &{&1.id, &1})

    Enum.reduce_while(mappings, :ok, fn mapping, :ok ->
      validate_one_mapping_binding(event, mapping, tickets_by_id)
    end)
  end

  defp validate_one_mapping_binding(event, mapping, tickets_by_id) do
    case Map.get(tickets_by_id, mapping.ticket_type_id) do
      nil -> {:halt, {:error, :ticket_type_event_mismatch}}
      ticket -> normalize_mapping_binding_result(validate_mapping_binding(mapping, ticket, event))
    end
  end

  defp normalize_mapping_binding_result(:ok), do: {:cont, :ok}
  defp normalize_mapping_binding_result({:halt, result}), do: {:halt, result}

  defp load_ticket_types([]), do: {:ok, []}

  defp load_ticket_types(ticket_ids) do
    TicketType
    |> Ash.Query.filter(id in ^ticket_ids)
    |> Ash.read(domain: Catalog)
    |> normalize_read_result()
  end

  defp validate_mapping_binding(
         %ProductMapping{
           source_system_id: source_system_id,
           event_id: event_id,
           active: active
         } = mapping,
         %TicketType{} = ticket,
         %Event{source_system_id: source_system_id, id: event_id}
       )
       when active == true do
    cond do
      ticket.event_id != event_id -> {:halt, {:error, :ticket_type_event_mismatch}}
      ticket.active != true -> {:halt, {:error, :ticket_type_inactive}}
      true -> validate_ticket_identity(ticket, mapping_key(mapping))
    end
  end

  defp validate_mapping_binding(%ProductMapping{}, %TicketType{event_id: _}, %Event{}),
    do: {:halt, {:error, :foreign_event_mapping}}

  defp validate_ticket_identity(
         %TicketType{
           external_ticket_type_kind: :woo_product,
           external_ticket_type_id: product_id,
           external_product_id: parent_id,
           external_variation_id: nil
         },
         {product_id, nil}
       )
       when is_integer(product_id) and product_id > 0 and
              (is_nil(parent_id) or parent_id == product_id),
       do: :ok

  defp validate_ticket_identity(
         %TicketType{
           external_ticket_type_kind: :woo_variation,
           external_ticket_type_id: variation_id,
           external_product_id: parent_id,
           external_variation_id: mirror_id
         },
         {product_id, variation_id}
       )
       when is_integer(variation_id) and variation_id > 0 and
              (is_nil(parent_id) or parent_id == product_id) and
              (is_nil(mirror_id) or mirror_id == variation_id),
       do: :ok

  defp validate_ticket_identity(
         %TicketType{external_ticket_type_kind: :woo_variation, external_product_id: parent_id},
         {product_id, _variation_id}
       )
       when is_integer(parent_id) and parent_id != product_id,
       do: {:halt, {:error, :ticket_type_product_mismatch}}

  defp validate_ticket_identity(%TicketType{}, {_product_id, nil}),
    do: {:halt, {:error, :ticket_type_product_mismatch}}

  defp validate_ticket_identity(%TicketType{}, {_product_id, _variation_id}),
    do: {:halt, {:error, :ticket_type_variation_mismatch}}

  defp transition_event(%Event{analytics_onboarding_state: :backfill_pending} = event),
    do: {:ok, event}

  defp transition_event(%Event{analytics_onboarding_state: :unverified} = event) do
    case Ash.update(event, %{},
           action: :mark_backfill_pending,
           domain: Catalog,
           context: %{warn_on_transaction_hooks?: false},
           return_notifications?: true
         ) do
      {:ok, %Event{} = transitioned} -> {:ok, transitioned}
      {:ok, %Event{} = transitioned, _notifications} -> {:ok, transitioned}
      _other -> {:error, :certification_failed}
    end
  end

  defp transition_event(%Event{}), do: {:error, :certification_failed}

  defp lock_uuid(query, id, not_found_reason) do
    case Ecto.UUID.cast(id) do
      {:ok, cast_id} ->
        case Repo.query(query, [Ecto.UUID.dump!(cast_id)]) do
          {:ok, %{num_rows: 1}} -> :ok
          {:ok, %{num_rows: 0}} -> {:error, not_found_reason}
          {:error, _reason} -> {:error, :certification_failed}
        end

      :error ->
        {:error, not_found_reason}
    end
  end

  defp run_hook(opts, key) do
    case Keyword.get(opts, key) do
      nil -> :ok
      hook when is_function(hook, 0) -> normalize_hook_result(hook.())
      _other -> {:error, :certification_failed}
    end
  rescue
    _error -> {:error, :certification_failed}
  end

  defp normalize_hook_result(:ok), do: :ok
  defp normalize_hook_result({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize_hook_result(_other), do: {:error, :certification_failed}

  defp mapping_key(%ProductMapping{woo_product_id: product_id, woo_variation_id: variation_id}),
    do: {product_id, variation_id}

  defp positive_integer?(value), do: is_integer(value) and value > 0

  defp map_value(value, key) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, result} -> result
      :error -> fetch_atom_key(value, key)
    end
  end

  defp map_value(_value, _key), do: nil

  defp fetch_atom_key(value, key) do
    atom_key = String.to_existing_atom(key)
    Map.get(value, atom_key)
  rescue
    ArgumentError -> nil
  end
end
