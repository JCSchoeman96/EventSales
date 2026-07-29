defmodule EventSales.Catalog.VariationMappingReview do
  @moduledoc """
  Reconstructs an admin-only exact variation review from one catalog dry-run.

  Structural variable-product warnings provide context only. Classification is
  performed independently for every exact source/product/variation identity.
  """

  require Ash.Query

  alias EventSales.Accounts.Policies
  alias EventSales.Catalog
  alias EventSales.Catalog.Resources.ProductMapping
  alias EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizer
  alias EventSales.Ingestion
  alias EventSales.Ingestion.Resources.{TickeraCatalogSyncFinding, TickeraCatalogSyncRun}

  @reviewable_statuses [:dry_run_ready, :cancelled]
  @blocking_codes ~w(
    ambiguous_variation_ticket_type_name
    duplicate_ticket_type_name
    duplicate_ticket_name
  )

  @spec list(Ecto.UUID.t() | TickeraCatalogSyncRun.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def list(run_or_id, dry_run_hash, opts \\ []) do
    with :ok <- authorize(opts),
         {:ok, run} <- load_run(run_or_id),
         :ok <- validate_run(run, dry_run_hash),
         {:ok, findings} <- load_findings(run.id),
         {:ok, rows} <- build_rows(run, findings) do
      {:ok,
       %{
         run_id: run.id,
         dry_run_hash: run.dry_run_hash,
         source_system_id: run.source_system_id,
         run_status: run.status,
         structural_warning_count:
           Enum.count(
             findings,
             &(&1.code == "variation_mapping_required" and &1.severity == :warning)
           ),
         exact_variation_count: length(rows),
         classification_summary: Enum.frequencies_by(rows, & &1.classification),
         rows: rows
       }}
    end
  end

  defp authorize(opts) do
    if opts |> Keyword.get(:actor) |> Policies.global_admin?(),
      do: :ok,
      else: {:error, :forbidden}
  end

  defp load_run(%TickeraCatalogSyncRun{} = run), do: {:ok, run}

  defp load_run(run_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(run_id),
         {:ok, %TickeraCatalogSyncRun{} = run} <-
           Ash.get(TickeraCatalogSyncRun, uuid, domain: Ingestion) do
      {:ok, run}
    else
      _error -> {:error, :stale_preview}
    end
  end

  defp validate_run(run, expected_hash) do
    with true <- run.status in @reviewable_statuses,
         true <- is_binary(expected_hash) and expected_hash != "",
         true <- run.dry_run_hash == expected_hash,
         %{"snapshot_schema_version" => "tickera_catalog_plan.v2"} = snapshot <-
           run.plan_snapshot,
         true <- value(snapshot, "source_system_id") == run.source_system_id,
         {:ok, _bytes, ^expected_hash} <- SnapshotCanonicalizer.canonicalize(snapshot) do
      :ok
    else
      _other -> {:error, :stale_preview}
    end
  end

  defp load_findings(run_id) do
    TickeraCatalogSyncFinding
    |> Ash.Query.filter(run_id == ^run_id)
    |> Ash.Query.sort(
      tickera_event_id: :asc,
      woo_product_id: :asc,
      woo_variation_id: :asc,
      code: :asc,
      id: :asc
    )
    |> Ash.read(domain: Ingestion)
    |> case do
      {:ok, findings} -> {:ok, findings}
      {:error, _reason} -> {:error, :review_unavailable}
    end
  end

  defp build_rows(run, findings) do
    snapshot = run.plan_snapshot
    keys = exact_keys(snapshot)

    with {:ok, mappings} <- load_active_mappings(run.source_system_id, keys) do
      indexes = snapshot_indexes(snapshot, mappings, findings)

      rows =
        keys
        |> Enum.map(&build_row(run, &1, indexes))
        |> Enum.sort_by(&{&1.woo_product_id, &1.woo_variation_id})

      {:ok, rows}
    end
  end

  defp exact_keys(snapshot) do
    mapping_actions =
      snapshot
      |> snapshot_list("product_mapping_actions")
      |> Enum.map(&identity_from_mapping/1)

    ticket_actions =
      snapshot
      |> snapshot_list("ticket_type_actions")
      |> Enum.map(&identity_from_ticket/1)

    mapping_proof =
      snapshot
      |> get_in_list(["identity_membership_proof", "product_mappings"])
      |> Enum.map(&identity_from_mapping/1)

    ticket_proof =
      snapshot
      |> get_in_list(["identity_membership_proof", "ticket_types"])
      |> Enum.map(&identity_from_ticket/1)

    touched =
      snapshot
      |> get_in_list(["touched_identifiers", "product_keys"])
      |> Enum.map(&identity_from_mapping/1)

    [mapping_actions, ticket_actions, mapping_proof, ticket_proof, touched]
    |> List.flatten()
    |> Enum.filter(fn
      {product_id, variation_id}
      when is_integer(product_id) and product_id > 0 and is_integer(variation_id) and
             variation_id > 0 ->
        true

      _other ->
        false
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp identity_from_mapping(value),
    do: {value(value, "woo_product_id"), value(value, "woo_variation_id")}

  defp identity_from_ticket(value),
    do: {value(value, "external_product_id"), value(value, "external_variation_id")}

  defp load_active_mappings(_source_system_id, []), do: {:ok, []}

  defp load_active_mappings(source_system_id, keys) do
    product_ids = keys |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    ProductMapping
    |> Ash.Query.filter(
      source_system_id == ^source_system_id and woo_product_id in ^product_ids and
        active == true and not is_nil(woo_variation_id)
    )
    |> Ash.Query.load([:event, :ticket_type])
    |> Ash.read(domain: Catalog)
    |> case do
      {:ok, mappings} ->
        key_set = MapSet.new(keys)
        {:ok, Enum.filter(mappings, &MapSet.member?(key_set, mapping_key(&1)))}

      {:error, _reason} ->
        {:error, :review_unavailable}
    end
  end

  defp snapshot_indexes(snapshot, mappings, findings) do
    event_actions = snapshot_list(snapshot, "event_actions")
    ticket_actions = snapshot_list(snapshot, "ticket_type_actions")
    mapping_actions = snapshot_list(snapshot, "product_mapping_actions")

    %{
      event_by_ref: index_by(event_actions, &value(&1, "ref")),
      ticket_by_ref: index_by(ticket_actions, &value(&1, "ref")),
      ticket_by_identity: index_by(ticket_actions, &identity_from_ticket/1),
      mapping_by_identity: index_by(mapping_actions, &identity_from_mapping/1),
      mapping: Map.new(mappings, &{mapping_key(&1), &1}),
      findings: Enum.group_by(findings, &{&1.woo_product_id, &1.woo_variation_id}),
      structural_findings:
        findings
        |> Enum.filter(&(&1.code == "variation_mapping_required"))
        |> Enum.group_by(& &1.woo_product_id)
    }
  end

  defp build_row(run, {product_id, variation_id} = key, indexes) do
    mapping_action = Map.get(indexes.mapping_by_identity, key)
    ticket_action = ticket_action(key, mapping_action, indexes)
    event_action = event_action(mapping_action, ticket_action, indexes)
    mapping = Map.get(indexes.mapping, key)

    tickera_event_id =
      proposed_event_external_id(event_action) ||
        event_id_from_ref(mapping_action && value(mapping_action, "event_ref")) ||
        event_id_from_ref(ticket_action && value(ticket_action, "event_ref")) ||
        (mapping && mapping.event.external_event_id) ||
        structural_event_id(product_id, indexes)

    exact_findings = Map.get(indexes.findings, key, [])
    structural_findings = Map.get(indexes.structural_findings, product_id, [])
    reason_codes = Enum.map(exact_findings ++ structural_findings, & &1.code) |> Enum.uniq()

    classification =
      classify(
        mapping,
        mapping_action,
        ticket_action,
        event_action,
        tickera_event_id,
        exact_findings
      )

    %{
      run_id: run.id,
      dry_run_hash: run.dry_run_hash,
      source_system_id: run.source_system_id,
      tickera_event_id: tickera_event_id,
      woo_product_id: product_id,
      woo_variation_id: variation_id,
      source_label: source_label(mapping_action, ticket_action, mapping),
      proposed_event_action: action(event_action),
      proposed_event_id: value(event_action, "event_id"),
      proposed_event_external_id: proposed_event_external_id(event_action) || tickera_event_id,
      proposed_ticket_type_action: action(ticket_action),
      proposed_ticket_type_id: value(ticket_action, "ticket_type_id"),
      proposed_ticket_type_external_id:
        value(ticket_action, "external_ticket_type_id") || variation_id,
      proposed_ticket_type_name: value(ticket_action, "name"),
      proposed_mapping_action: action(mapping_action),
      existing_mapping_id: mapping && mapping.id,
      existing_event_id: mapping && mapping.event_id,
      existing_event_external_id: mapping && mapping.event.external_event_id,
      existing_ticket_type_id: mapping && mapping.ticket_type_id,
      existing_ticket_type_name: mapping && mapping.ticket_type.name,
      classification: classification,
      reason_codes: reason_codes,
      manual_action_allowed:
        classification == :manual_resolution_required and run.status == :cancelled and
          run.cancellation_reason_code == :mapping_resolution_started
    }
  end

  defp finding_classification(findings) do
    codes = Enum.map(findings, & &1.code)

    cond do
      Enum.any?(codes, &(&1 in @blocking_codes)) ->
        :blocked_ambiguous_name

      "existing_mapping_conflict" in codes ->
        :stale_mapping_conflict

      true ->
        :continue
    end
  end

  defp classify(mapping, mapping_action, ticket_action, event_action, event_id, findings) do
    case finding_classification(findings) do
      classification when classification != :continue ->
        classification

      :continue ->
        cond do
          exact_mapping?(mapping, event_id) ->
            :already_mapped_exact

          adopt_action?(event_action) or adopt_action?(ticket_action) ->
            :planned_adopt_existing

          create_action?(mapping_action) and complete_destination?(event_action, ticket_action) ->
            :planned_create

          true ->
            :manual_resolution_required
        end
    end
  end

  defp exact_mapping?(nil, _event_id), do: false

  defp exact_mapping?(mapping, event_id) do
    is_integer(event_id) and mapping.event.external_event_id == event_id and
      mapping.ticket_type.event_id == mapping.event_id and
      mapping.ticket_type.external_ticket_type_kind == :woo_variation and
      mapping.ticket_type.external_product_id == mapping.woo_product_id and
      mapping.ticket_type.external_variation_id == mapping.woo_variation_id
  end

  defp complete_destination?(event_action, ticket_action) do
    event_destination?(event_action) and ticket_destination?(ticket_action)
  end

  defp event_destination?(action) when is_map(action) do
    present?(value(action, "event_id")) or present?(value(action, "external_event_id")) or
      present?(value(action, "ref"))
  end

  defp event_destination?(_action), do: false

  defp ticket_destination?(action) when is_map(action) do
    present?(value(action, "ticket_type_id")) or
      (present?(value(action, "external_variation_id")) and present?(value(action, "event_ref")))
  end

  defp ticket_destination?(_action), do: false

  defp ticket_action(key, mapping_action, indexes) do
    ref = mapping_action && value(mapping_action, "ticket_type_ref")
    Map.get(indexes.ticket_by_ref, ref) || Map.get(indexes.ticket_by_identity, key)
  end

  defp event_action(mapping_action, ticket_action, indexes) do
    ref =
      (mapping_action && value(mapping_action, "event_ref")) ||
        (ticket_action && value(ticket_action, "event_ref"))

    Map.get(indexes.event_by_ref, ref)
  end

  defp structural_event_id(product_id, indexes) do
    indexes.structural_findings
    |> Map.get(product_id, [])
    |> List.first()
    |> case do
      nil -> nil
      finding -> finding.tickera_event_id
    end
  end

  defp proposed_event_external_id(action), do: value(action, "external_event_id")

  defp event_id_from_ref("tickera_event:" <> value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _other -> nil
    end
  end

  defp event_id_from_ref(_ref), do: nil

  defp source_label(mapping_action, ticket_action, mapping) do
    value(mapping_action, "current_label") || value(mapping_action, "original_label") ||
      value(ticket_action, "name") || (mapping && mapping.current_label) ||
      (mapping && mapping.original_label) || (mapping && mapping.ticket_type.name)
  end

  defp create_action?(value), do: action(value) == :create
  defp adopt_action?(value), do: action(value) == :adopt_existing

  defp action(value) do
    case value(value, "action") do
      "create" -> :create
      "reuse" -> :reuse
      "adopt_existing" -> :adopt_existing
      "update_metadata" -> :update_metadata
      value when is_atom(value) -> value
      _other -> nil
    end
  end

  defp mapping_key(mapping), do: {mapping.woo_product_id, mapping.woo_variation_id}

  defp index_by(values, key_fun) do
    values
    |> Enum.map(&{key_fun.(&1), &1})
    |> Enum.reject(fn {key, _value} -> is_nil(key) or key == {nil, nil} end)
    |> Map.new()
  end

  defp get_in_list(map, keys) do
    case get_in(map, keys) do
      values when is_list(values) -> values
      _other -> []
    end
  end

  defp snapshot_list(map, key) do
    case value(map, key) do
      values when is_list(values) -> values
      _other -> []
    end
  end

  defp value(map, key) when is_map(map), do: Map.get(map, key)
  defp value(_map, _key), do: nil

  defp present?(nil), do: false
  defp present?(""), do: false
  defp present?(_value), do: true
end
