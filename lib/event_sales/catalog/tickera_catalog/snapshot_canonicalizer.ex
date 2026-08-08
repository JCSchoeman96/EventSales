defmodule EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizer do
  @moduledoc """
  Closed deterministic byte and hash boundary for `tickera_catalog_plan.v2` and
  `tickera_catalog_plan.v3`.

  Each snapshot version owns a separate closed schema. The v2 allowlists are never
  widened for `source_risk.*` / `contract.*` semantics.
  """

  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.ContractRegistry

  @top_level_keys ~w(
    snapshot_schema_version source_system_id origin event_actions
    ticket_type_actions product_mapping_actions findings source_risks
    historical_impact identity_membership_proof touched_identifiers
  )
  @historical_keys ~w(
    totals warning_count unresolved_destination_count unknown_classification_count destinations
  )
  @total_keys ~w(
    affected_pending_lines affected_quantity eligible_lines eligible_quantity
    deferred_lines deferred_quantity conflicting_lines conflicting_quantity
    already_mapped_lines already_mapped_quantity
  )
  @proof_keys ~w(events ticket_types product_mappings)
  @touched_keys ~w(event_ids ticket_type_ids mapping_ids product_keys)
  @origins ~w(human_admin targeted_catalog_change legacy_unknown)
  @statuses ~w(publish private draft trash deleted unknown)
  @finding_severities ~w(info warning blocking)
  @finding_targets ~w(event product variation run)
  @risk_targets ~w(event product variation)
  @risk_classifications ~w(explicit_safe explicit_risky missing unknown unsupported)
  @risk_sources ~w(
    wp_post_status wc_product_type ticket_template_meta subscription_meta
    signed_target_reason planner_identity_query
  )
  @risk_codes ~w(
    private_event draft_event trashed_event deleted_event private_product draft_product
    trashed_product deleted_product private_variation draft_variation
    variation_mapping_required ambiguous_variation_name subscription payment_plan membership
    bundle add_on unsupported_product_type missing_ticket_template unknown_product_semantics
    duplicate_ticket_name existing_mapping_conflict product_moved_between_events
    ambiguous_identity missing_source_risk_data
  )
  @finding_codes ~w(
    duplicate_meta_collapsed variation_mapping_required ambiguous_variation_ticket_type_name
    duplicate_ticket_type_name private_event_skipped draft_event_skipped
    published_event_without_ticket_products existing_mapping_conflict existing_mapping_adopted
    vwg_pretoria_preserved
  ) ++ @risk_codes

  @event_create ~w(action ref source_system_id name slug status external_event_id external_event_kind source_status source_updated_at starts_at ends_at venue_name booking_fee_type booking_fee_value)
  @event_reuse ~w(action ref event_id source_system_id external_event_kind external_event_id)
  @event_update ~w(action ref event_id source_status source_updated_at starts_at ends_at venue_name booking_fee_type booking_fee_value)
  @event_adopt ~w(action event_id external_event_id external_event_kind source_status source_updated_at starts_at ends_at venue_name booking_fee_type booking_fee_value)
  @ticket_create ~w(action ref event_ref name active external_ticket_type_id external_ticket_type_kind external_product_id external_variation_id source_status source_updated_at)
  @ticket_reuse ~w(action ref ticket_type_id event_id external_ticket_type_kind external_ticket_type_id external_product_id external_variation_id)
  @ticket_adopt ~w(action ticket_type_id event_id external_ticket_type_id external_ticket_type_kind external_product_id external_variation_id source_status source_updated_at)
  @mapping_create ~w(action event_ref ticket_type_ref source_system_id woo_product_id woo_variation_id original_label current_label active)
  @finding_keys ~w(severity code target_type target_id context)
  @risk_keys ~w(target_type target_id code evidence_classification evidence_source evidence_value)
  @destination_keys ~w(woo_product_id woo_variation_id proposed_event_external_id proposed_ticket_type_external_id resolution pending_line_count quantity eligible_line_count deferred_line_count conflicting_line_count conflicting_quantity already_mapped_line_count already_mapped_quantity unknown_classification_count)
  @event_proof_keys ~w(source_system_id external_event_kind external_event_id event_id action no_mutation)
  @ticket_proof_keys ~w(external_ticket_type_kind external_ticket_type_id external_product_id external_variation_id ticket_type_id event_id event_ref action no_mutation)
  @mapping_proof_keys ~w(source_system_id woo_product_id woo_variation_id event_ref ticket_type_ref action no_existing_conflict no_movement)
  @product_key_keys ~w(woo_product_id woo_variation_id)

  @v3_schema_version "tickera_catalog_plan.v3"
  @v3_source_schema_version "2026-08-07.v3"
  @v3_canonical_contract_version "source_risk.v3"
  @v3_producer_version "2026-08-07.1"

  @v3_top_level_keys ~w(
    snapshot_schema_version source_system_id origin source event_actions
    ticket_type_actions product_mapping_actions findings
    canonical_source_risk_facts canonical_source_risk_findings
    historical_impact identity_membership_proof touched_identifiers
  )
  @v3_source_keys ~w(
    schema_version canonical_contract_version producer_version source_system_id
    discovery_snapshot_id source_snapshot_at evidence_origin
  )
  @v3_fact_keys ~w(
    run_id dimension semantic_scope target authority_slot authority state
    completeness origin value provenance
  )
  @v3_risk_finding_keys ~w(
    qualified_finding_id severity disposition dimension_local_only implies_apply_eligible
  )
  @v3_target_keys ~w(tickera_event_id woo_product_id woo_variation_id ticket_template_id)

  @v3_structural_finding_codes ~w(
    duplicate_meta_collapsed variation_mapping_required ambiguous_variation_ticket_type_name
    duplicate_ticket_type_name private_event_skipped draft_event_skipped
    published_event_without_ticket_products existing_mapping_conflict existing_mapping_adopted
    vwg_pretoria_preserved
  )
  @v3_qualified_finding_codes ~w(
    source_risk.lifecycle_private source_risk.lifecycle_draft source_risk.lifecycle_trashed
    source_risk.lifecycle_deleted source_risk.lifecycle_unresolved
    source_risk.missing_ticket_template source_risk.missing_tickera_event
    source_risk.subscription source_risk.subscription_unresolved
    source_risk.payment_plan source_risk.membership source_risk.bundle source_risk.add_on
    contract.evidence_conflict contract.contract_violation contract.scope_mismatch
    contract.authority_mismatch contract.parser_error contract.blocking_missing
    contract.blocking_unsupported contract.blocking_invalid
  )
  @v3_finding_codes @v3_structural_finding_codes ++ @v3_qualified_finding_codes

  @v3_dimensions ContractRegistry.dimensions()
  @v3_scopes ContractRegistry.scopes()
  @v3_states ContractRegistry.states()
  @v3_completeness ContractRegistry.completeness_values()
  @v3_authorities ContractRegistry.authorities()
  @v3_authority_slots ContractRegistry.authority_slots()
  @v3_origins ContractRegistry.origins()
  @v3_dispositions ContractRegistry.dispositions()
  @v3_provenance_keys MapSet.to_list(ContractRegistry.producer_provenance_keys())
  @v3_provenance_id_keys ~w(woo_product_id woo_variation_id tickera_event_id)

  @spec v3_schema_version() :: String.t()
  def v3_schema_version, do: @v3_schema_version

  @spec canonicalize(map()) ::
          {:ok, binary(), String.t()}
          | {:error, :invalid_snapshot_schema | :invalid_snapshot_value}
  def canonicalize(%{"snapshot_schema_version" => @v3_schema_version} = snapshot),
    do: canonicalize_v3(snapshot)

  def canonicalize(snapshot) when is_map(snapshot), do: canonicalize_v2(snapshot)

  def canonicalize(_snapshot), do: {:error, :invalid_snapshot_schema}

  defp canonicalize_v2(snapshot) do
    with false <- contains_float?(snapshot),
         :ok <- validate_schema(snapshot),
         {:ok, normalized} <- snapshot |> sort_collections() |> normalize(),
         {:ok, bytes} <- encode(normalized) do
      hash = bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
      {:ok, bytes, hash}
    else
      true -> {:error, :invalid_snapshot_value}
      error -> error
    end
  end

  defp canonicalize_v3(snapshot) do
    with false <- contains_float?(snapshot),
         :ok <- validate_v3_schema(snapshot),
         {:ok, normalized} <- snapshot |> sort_v3_collections() |> normalize(),
         {:ok, bytes} <- encode(normalized) do
      hash = bytes |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
      {:ok, bytes, hash}
    else
      true -> {:error, :invalid_snapshot_value}
      error -> error
    end
  end

  defp validate_v3_schema(snapshot) do
    if valid_v3_root?(snapshot) and valid_v3_source?(snapshot["source"]) and
         valid_actions?(snapshot) and valid_v3_source_risk?(snapshot) do
      :ok
    else
      {:error, :invalid_snapshot_schema}
    end
  end

  defp valid_v3_source_risk?(snapshot) do
    valid_v3_findings?(snapshot["findings"]) and
      valid_v3_facts?(snapshot["canonical_source_risk_facts"]) and
      valid_v3_risk_findings?(snapshot["canonical_source_risk_findings"]) and
      valid_historical?(snapshot["historical_impact"]) and
      valid_proof?(snapshot["identity_membership_proof"]) and
      valid_touched?(snapshot["touched_identifiers"])
  end

  defp valid_v3_root?(snapshot) do
    exact_keys?(snapshot, @v3_top_level_keys) and
      snapshot["snapshot_schema_version"] == @v3_schema_version and
      uuid?(snapshot["source_system_id"]) and snapshot["origin"] in @origins and
      lists?(
        snapshot,
        ~w(
          event_actions ticket_type_actions product_mapping_actions findings
          canonical_source_risk_facts canonical_source_risk_findings
        )
      )
  end

  defp valid_v3_source?(source) when is_map(source) do
    Enum.all?([
      exact_keys?(source, @v3_source_keys),
      source["schema_version"] == @v3_source_schema_version,
      source["canonical_contract_version"] == @v3_canonical_contract_version,
      source["producer_version"] == @v3_producer_version,
      source["evidence_origin"] == "native",
      bounded?(source["source_system_id"], 160, false),
      bounded?(source["discovery_snapshot_id"], 128, false),
      datetime_or_nil?(source["source_snapshot_at"])
    ])
  end

  defp valid_v3_source?(_source), do: false

  defp valid_v3_findings?(values) do
    Enum.all?(values, fn value ->
      exact_keys?(value, @finding_keys) and value["severity"] in @finding_severities and
        value["code"] in @v3_finding_codes and value["target_type"] in @finding_targets and
        valid_target_id?(value["target_type"], value["target_id"]) and
        valid_v3_context?(value["context"])
    end)
  end

  defp valid_v3_context?(context) when is_map(context) do
    Enum.all?(context, fn
      {"event_lifecycle", value} -> value in ~w(past current future unknown)
      {"disposition", value} -> value in @v3_dispositions
      {"dimension_local_only", value} -> is_boolean(value)
      {_key, _value} -> false
    end)
  end

  defp valid_v3_context?(_context), do: false

  defp valid_v3_facts?(values) do
    Enum.all?(values, fn value ->
      Enum.all?([
        exact_keys?(value, @v3_fact_keys),
        bounded?(value["run_id"], 128, false),
        value["dimension"] in @v3_dimensions,
        value["semantic_scope"] in @v3_scopes,
        value["authority_slot"] in @v3_authority_slots,
        value["authority"] in @v3_authorities,
        value["state"] in @v3_states,
        value["completeness"] in @v3_completeness,
        value["origin"] in @v3_origins,
        valid_v3_target?(value["target"]),
        valid_v3_fact_value?(value["value"]),
        valid_v3_provenance_list?(value["provenance"])
      ])
    end)
  end

  defp valid_v3_target?(target) when is_map(target) and map_size(target) > 0 do
    Enum.all?(target, fn {key, value} ->
      key in @v3_target_keys and positive_integer?(value)
    end)
  end

  defp valid_v3_target?(_target), do: false

  defp valid_v3_fact_value?(nil), do: true
  defp valid_v3_fact_value?(value) when is_integer(value), do: value > 0

  defp valid_v3_fact_value?(value) when is_binary(value),
    do: value != "" and byte_size(value) <= ContractRegistry.max_evidence_value_bytes()

  defp valid_v3_fact_value?(_value), do: false

  defp valid_v3_provenance_list?(records) when is_list(records) and records != [],
    do: Enum.all?(records, &valid_v3_provenance?/1)

  defp valid_v3_provenance_list?(_records), do: false

  defp valid_v3_provenance?(record) when is_map(record) and map_size(record) > 0 do
    Enum.all?(record, fn
      {key, value} when key in @v3_provenance_id_keys -> positive_integer?(value)
      {key, value} when key in @v3_provenance_keys -> bounded?(value, 128, false)
      {_key, _value} -> false
    end)
  end

  defp valid_v3_provenance?(_record), do: false

  defp valid_v3_risk_findings?(values) do
    Enum.all?(values, fn value ->
      exact_keys?(value, @v3_risk_finding_keys) and
        value["qualified_finding_id"] in @v3_qualified_finding_codes and
        value["severity"] in @finding_severities and
        value["disposition"] in @v3_dispositions and
        is_boolean(value["dimension_local_only"]) and
        value["implies_apply_eligible"] == false
    end)
  end

  defp sort_v3_collections(snapshot) do
    snapshot
    |> Map.update!("event_actions", &Enum.sort_by(&1, fn v -> event_sort_key(v) end))
    |> Map.update!("ticket_type_actions", &Enum.sort_by(&1, fn v -> ticket_sort_key(v) end))
    |> Map.update!("product_mapping_actions", &Enum.sort_by(&1, fn v -> mapping_sort_key(v) end))
    |> Map.update!("findings", &Enum.sort_by(&1, fn v -> v3_finding_sort_key(v) end))
    |> Map.update!("canonical_source_risk_facts", fn facts ->
      facts
      |> Enum.map(&Map.update!(&1, "provenance", fn records -> sort_maps(records) end))
      |> Enum.sort_by(fn v -> v3_fact_sort_key(v) end)
    end)
    |> Map.update!(
      "canonical_source_risk_findings",
      &Enum.sort_by(&1, fn v -> v3_risk_finding_sort_key(v) end)
    )
    |> update_in(
      ["historical_impact", "destinations"],
      &Enum.sort_by(&1, fn v -> destination_sort_key(v) end)
    )
    |> update_in(
      ["identity_membership_proof", "events"],
      &Enum.sort_by(&1, fn v -> event_proof_sort_key(v) end)
    )
    |> update_in(
      ["identity_membership_proof", "ticket_types"],
      &Enum.sort_by(&1, fn v -> ticket_proof_sort_key(v) end)
    )
    |> update_in(
      ["identity_membership_proof", "product_mappings"],
      &Enum.sort_by(&1, fn v -> mapping_sort_key(v) end)
    )
    |> update_in(["touched_identifiers", "event_ids"], &Enum.sort/1)
    |> update_in(["touched_identifiers", "ticket_type_ids"], &Enum.sort/1)
    |> update_in(["touched_identifiers", "mapping_ids"], &Enum.sort/1)
    |> update_in(
      ["touched_identifiers", "product_keys"],
      &Enum.sort_by(&1, fn v -> product_key_sort_key(v) end)
    )
  end

  defp v3_finding_sort_key(v),
    do:
      {v["severity"], v["code"], v["target_type"], v["target_id"] || 0,
       map_sort_key(v["context"])}

  defp v3_fact_sort_key(v),
    do:
      {v["dimension"], v["semantic_scope"], map_sort_key(v["target"]), v["authority_slot"],
       v["origin"], v["state"], value_sort_key(v["value"]), v["completeness"],
       Enum.map(v["provenance"], &map_sort_key/1)}

  defp v3_risk_finding_sort_key(v),
    do:
      {v["qualified_finding_id"], v["severity"], v["disposition"], v["dimension_local_only"],
       v["implies_apply_eligible"]}

  defp sort_maps(values) when is_list(values), do: Enum.sort_by(values, &map_sort_key/1)
  defp sort_maps(values), do: values

  defp map_sort_key(value) when is_map(value),
    do:
      value
      |> Enum.map(fn {key, inner} -> {to_string(key), value_sort_key(inner)} end)
      |> Enum.sort()

  defp map_sort_key(_value), do: []

  defp value_sort_key(nil), do: {0, 0, ""}
  defp value_sort_key(value) when is_integer(value), do: {1, value, ""}
  defp value_sort_key(value) when is_binary(value), do: {2, 0, value}
  defp value_sort_key(value) when is_boolean(value), do: {3, 0, to_string(value)}
  defp value_sort_key(value), do: {4, 0, inspect(value)}

  defp validate_schema(snapshot) do
    if valid_root?(snapshot) and valid_actions?(snapshot) and
         valid_findings?(snapshot["findings"]) and
         valid_risks?(snapshot["source_risks"]) and
         valid_historical?(snapshot["historical_impact"]) and
         valid_proof?(snapshot["identity_membership_proof"]) and
         valid_touched?(snapshot["touched_identifiers"]) do
      :ok
    else
      {:error, :invalid_snapshot_schema}
    end
  end

  defp valid_actions?(snapshot) do
    Enum.all?(snapshot["event_actions"], &valid_event_action?/1) and
      Enum.all?(snapshot["ticket_type_actions"], &valid_ticket_action?/1) and
      Enum.all?(snapshot["product_mapping_actions"], &valid_mapping_action?/1)
  end

  defp valid_event_action?(%{"action" => "create"} = value) do
    Enum.all?([
      exact_keys?(value, @event_create),
      bounded?(value["ref"], 160, false),
      uuid?(value["source_system_id"]),
      bounded?(value["name"], 255, false),
      bounded?(value["slug"], 255, false),
      value["status"] == "active",
      positive_integer?(value["external_event_id"]),
      value["external_event_kind"] == "tickera_event",
      value["source_status"] in @statuses,
      datetime_or_nil?(value["source_updated_at"]),
      datetime_or_nil?(value["starts_at"]),
      datetime_or_nil?(value["ends_at"]),
      bounded?(value["venue_name"], 255, true),
      value["booking_fee_type"] in [nil, "fixed", "percentage"],
      decimal_or_nil?(value["booking_fee_value"])
    ])
  end

  defp valid_event_action?(%{"action" => "reuse"} = value) do
    exact_keys?(value, @event_reuse) and bounded?(value["ref"], 160, false) and
      uuid?(value["event_id"]) and uuid?(value["source_system_id"]) and
      value["external_event_kind"] == "tickera_event" and
      positive_integer?(value["external_event_id"])
  end

  defp valid_event_action?(%{"action" => "update_metadata"} = value),
    do: exact_keys?(value, @event_update) and valid_event_metadata?(value, true)

  defp valid_event_action?(%{"action" => "adopt_existing"} = value),
    do:
      exact_keys?(value, @event_adopt) and valid_event_metadata?(value, false) and
        positive_integer?(value["external_event_id"]) and
        value["external_event_kind"] == "tickera_event"

  defp valid_event_action?(_), do: false

  defp valid_event_metadata?(value, has_ref?) do
    Enum.all?([
      not has_ref? or bounded?(value["ref"], 160, true),
      uuid?(value["event_id"]),
      value["source_status"] in @statuses,
      datetime_or_nil?(value["source_updated_at"]),
      datetime_or_nil?(value["starts_at"]),
      datetime_or_nil?(value["ends_at"]),
      bounded?(value["venue_name"], 255, true),
      value["booking_fee_type"] in [nil, "fixed", "percentage"],
      decimal_or_nil?(value["booking_fee_value"])
    ])
  end

  defp valid_ticket_action?(%{"action" => "create"} = value) do
    Enum.all?([
      exact_keys?(value, @ticket_create),
      bounded?(value["ref"], 160, false),
      bounded?(value["event_ref"], 160, false),
      bounded?(value["name"], 255, false),
      value["active"] == true,
      positive_integer?(value["external_ticket_type_id"]),
      ticket_kind?(value["external_ticket_type_kind"]),
      positive_integer?(value["external_product_id"]),
      positive_or_nil?(value["external_variation_id"]),
      value["source_status"] in @statuses,
      datetime_or_nil?(value["source_updated_at"])
    ])
  end

  defp valid_ticket_action?(%{"action" => "reuse"} = value) do
    exact_keys?(value, @ticket_reuse) and bounded?(value["ref"], 160, false) and
      uuid?(value["ticket_type_id"]) and uuid?(value["event_id"]) and
      ticket_kind?(value["external_ticket_type_kind"]) and
      positive_integer?(value["external_ticket_type_id"]) and
      positive_integer?(value["external_product_id"]) and
      positive_or_nil?(value["external_variation_id"])
  end

  defp valid_ticket_action?(%{"action" => "adopt_existing"} = value) do
    exact_keys?(value, @ticket_adopt) and uuid?(value["ticket_type_id"]) and
      uuid?(value["event_id"]) and
      positive_integer?(value["external_ticket_type_id"]) and
      ticket_kind?(value["external_ticket_type_kind"]) and
      positive_integer?(value["external_product_id"]) and
      positive_or_nil?(value["external_variation_id"]) and value["source_status"] in @statuses and
      datetime_or_nil?(value["source_updated_at"])
  end

  defp valid_ticket_action?(_), do: false

  defp valid_mapping_action?(%{"action" => "create"} = value) do
    exact_keys?(value, @mapping_create) and bounded?(value["event_ref"], 160, false) and
      bounded?(value["ticket_type_ref"], 160, false) and uuid?(value["source_system_id"]) and
      positive_integer?(value["woo_product_id"]) and positive_or_nil?(value["woo_variation_id"]) and
      bounded?(value["original_label"], 255, true) and bounded?(value["current_label"], 255, true) and
      value["active"] == true
  end

  defp valid_mapping_action?(_), do: false

  defp valid_findings?(values) do
    Enum.all?(values, fn value ->
      exact_keys?(value, @finding_keys) and value["severity"] in @finding_severities and
        value["code"] in @finding_codes and value["target_type"] in @finding_targets and
        valid_target_id?(value["target_type"], value["target_id"]) and
        valid_context?(value["context"])
    end)
  end

  defp valid_context?(value) when value == %{}, do: true

  defp valid_context?(%{"event_lifecycle" => value} = context),
    do: exact_keys?(context, ["event_lifecycle"]) and value in ~w(past current future unknown)

  defp valid_context?(_), do: false

  defp valid_risks?(values) do
    Enum.all?(values, fn value ->
      exact_keys?(value, @risk_keys) and value["target_type"] in @risk_targets and
        positive_integer?(value["target_id"]) and value["code"] in @risk_codes and
        value["evidence_classification"] in @risk_classifications and
        value["evidence_source"] in @risk_sources and valid_evidence_value?(value)
    end)
  end

  defp valid_evidence_value?(%{"evidence_classification" => "missing", "evidence_value" => nil}),
    do: true

  defp valid_evidence_value?(%{"evidence_value" => value}) when is_binary(value),
    do: byte_size(value) <= 80

  defp valid_evidence_value?(_), do: false

  defp valid_root?(snapshot) do
    exact_keys?(snapshot, @top_level_keys) and
      snapshot["snapshot_schema_version"] == "tickera_catalog_plan.v2" and
      uuid?(snapshot["source_system_id"]) and snapshot["origin"] in @origins and
      lists?(
        snapshot,
        ~w(event_actions ticket_type_actions product_mapping_actions findings source_risks)
      )
  end

  defp valid_historical?(historical) do
    exact_keys?(historical, @historical_keys) and
      exact_non_negative_integers?(historical["totals"], @total_keys) and
      Enum.all?(
        ~w(warning_count unresolved_destination_count unknown_classification_count),
        &non_negative_integer?(historical[&1])
      ) and
      is_list(historical["destinations"]) and
      Enum.all?(historical["destinations"], &valid_destination?/1)
  end

  defp valid_destination?(value) do
    exact_keys?(value, @destination_keys) and positive_integer?(value["woo_product_id"]) and
      positive_or_nil?(value["woo_variation_id"]) and
      positive_or_nil?(value["proposed_event_external_id"]) and
      positive_or_nil?(value["proposed_ticket_type_external_id"]) and
      value["resolution"] in ~w(proposed existing_active_mapping missing_destination conflict) and
      Enum.all?(
        @destination_keys --
          ~w(woo_product_id woo_variation_id proposed_event_external_id proposed_ticket_type_external_id resolution),
        &non_negative_integer?(value[&1])
      )
  end

  defp valid_proof?(proof) do
    exact_list_container?(proof, @proof_keys) and
      Enum.all?(proof["events"], &valid_event_proof?/1) and
      Enum.all?(proof["ticket_types"], &valid_ticket_proof?/1) and
      Enum.all?(proof["product_mappings"], &valid_mapping_proof?/1)
  end

  defp valid_event_proof?(value) do
    exact_keys?(value, @event_proof_keys) and uuid?(value["source_system_id"]) and
      value["external_event_kind"] == "tickera_event" and
      positive_integer?(value["external_event_id"]) and uuid_or_nil?(value["event_id"]) and
      value["action"] in ~w(create reuse update_metadata adopt_existing) and
      is_boolean(value["no_mutation"])
  end

  defp valid_ticket_proof?(value) do
    Enum.all?([
      exact_keys?(value, @ticket_proof_keys),
      ticket_kind?(value["external_ticket_type_kind"]),
      positive_integer?(value["external_ticket_type_id"]),
      positive_integer?(value["external_product_id"]),
      positive_or_nil?(value["external_variation_id"]),
      uuid_or_nil?(value["ticket_type_id"]),
      uuid_or_nil?(value["event_id"]),
      bounded?(value["event_ref"], 160, true),
      value["action"] in ~w(create reuse adopt_existing),
      is_boolean(value["no_mutation"])
    ])
  end

  defp valid_mapping_proof?(value) do
    exact_keys?(value, @mapping_proof_keys) and uuid?(value["source_system_id"]) and
      positive_integer?(value["woo_product_id"]) and positive_or_nil?(value["woo_variation_id"]) and
      bounded?(value["event_ref"], 160, false) and bounded?(value["ticket_type_ref"], 160, false) and
      value["action"] == "create" and is_boolean(value["no_existing_conflict"]) and
      is_boolean(value["no_movement"])
  end

  defp valid_touched?(touched) do
    exact_list_container?(touched, @touched_keys) and
      Enum.all?(~w(event_ids ticket_type_ids mapping_ids), fn key ->
        Enum.all?(touched[key], &uuid?/1)
      end) and
      Enum.all?(touched["product_keys"], fn value ->
        exact_keys?(value, @product_key_keys) and positive_integer?(value["woo_product_id"]) and
          positive_or_nil?(value["woo_variation_id"])
      end)
  end

  defp normalize(%Decimal{} = value) do
    normalized =
      if Decimal.equal?(value, Decimal.new(0)) do
        "0"
      else
        value |> Decimal.normalize() |> Decimal.to_string(:normal)
      end

    {:ok, normalized}
  end

  defp normalize(%DateTime{} = value) do
    utc = DateTime.shift_zone!(value, "Etc/UTC")
    fixed_precision = %{utc | microsecond: {elem(utc.microsecond, 0), 6}}
    {:ok, DateTime.to_iso8601(fixed_precision, :extended)}
  end

  defp normalize(value) when is_float(value), do: {:error, :invalid_snapshot_value}

  defp normalize(value)
       when is_binary(value) or is_integer(value) or is_boolean(value) or is_nil(value),
       do: {:ok, value}

  defp normalize(value) when is_atom(value), do: {:ok, Atom.to_string(value)}

  defp normalize(values) when is_list(values), do: map_ok(values, &normalize/1)

  defp normalize(%{} = map) do
    map
    |> Enum.map(fn {key, value} -> {to_string(key), value} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize(value) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, key, normalized)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp normalize(_value), do: {:error, :invalid_snapshot_value}

  defp encode(value) do
    {:ok, IO.iodata_to_binary(encode_iodata(value))}
  rescue
    Protocol.UndefinedError -> {:error, :invalid_snapshot_value}
  end

  defp encode_iodata(%{} = map) do
    entries =
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, value} -> [Jason.encode!(key), ?:, encode_iodata(value)] end)

    [?{, Enum.intersperse(entries, ?,), ?}]
  end

  defp encode_iodata(values) when is_list(values),
    do: [?[, Enum.intersperse(Enum.map(values, &encode_iodata/1), ?,), ?]]

  defp encode_iodata(value), do: Jason.encode!(value)

  defp sort_collections(snapshot) do
    snapshot
    |> Map.update!(
      "event_actions",
      &Enum.sort_by(&1, fn v -> event_sort_key(v) end)
    )
    |> Map.update!(
      "ticket_type_actions",
      &Enum.sort_by(&1, fn v -> ticket_sort_key(v) end)
    )
    |> Map.update!(
      "product_mapping_actions",
      &Enum.sort_by(&1, fn v -> mapping_sort_key(v) end)
    )
    |> Map.update!(
      "findings",
      &Enum.sort_by(&1, fn v -> finding_sort_key(v) end)
    )
    |> Map.update!(
      "source_risks",
      &Enum.sort_by(&1, fn v -> risk_sort_key(v) end)
    )
    |> update_in(
      ["historical_impact", "destinations"],
      &Enum.sort_by(&1, fn v -> destination_sort_key(v) end)
    )
    |> update_in(
      ["identity_membership_proof", "events"],
      &Enum.sort_by(&1, fn v -> event_proof_sort_key(v) end)
    )
    |> update_in(
      ["identity_membership_proof", "ticket_types"],
      &Enum.sort_by(&1, fn v -> ticket_proof_sort_key(v) end)
    )
    |> update_in(
      ["identity_membership_proof", "product_mappings"],
      &Enum.sort_by(&1, fn v -> mapping_sort_key(v) end)
    )
    |> update_in(["touched_identifiers", "event_ids"], &Enum.sort/1)
    |> update_in(["touched_identifiers", "ticket_type_ids"], &Enum.sort/1)
    |> update_in(["touched_identifiers", "mapping_ids"], &Enum.sort/1)
    |> update_in(
      ["touched_identifiers", "product_keys"],
      &Enum.sort_by(&1, fn v -> product_key_sort_key(v) end)
    )
  end

  defp event_sort_key(v),
    do: {v["external_event_id"] || 0, v["action"], v["event_id"] || "", v["ref"] || ""}

  defp ticket_sort_key(v),
    do:
      {v["external_product_id"], v["external_variation_id"] || 0, v["action"],
       v["ticket_type_id"] || "", v["ref"] || ""}

  defp mapping_sort_key(v),
    do:
      {v["woo_product_id"], v["woo_variation_id"] || 0, v["action"], v["ticket_type_ref"],
       v["event_ref"]}

  defp finding_sort_key(v),
    do: {v["severity"], v["code"], v["target_type"], v["target_id"] || 0}

  defp risk_sort_key(v),
    do:
      {v["target_type"], v["target_id"], v["code"], v["evidence_source"],
       v["evidence_value"] || ""}

  defp destination_sort_key(v),
    do:
      {v["woo_product_id"], v["woo_variation_id"] || 0,
       v["proposed_ticket_type_external_id"] || 0}

  defp event_proof_sort_key(v), do: {v["external_event_id"], v["action"], v["event_id"] || ""}

  defp ticket_proof_sort_key(v),
    do:
      {v["external_product_id"], v["external_variation_id"] || 0, v["action"],
       v["ticket_type_id"] || ""}

  defp product_key_sort_key(v), do: {v["woo_product_id"], v["woo_variation_id"] || 0}

  defp exact_keys?(map, keys) when is_map(map),
    do: map |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() == Enum.sort(keys)

  defp exact_keys?(_map, _keys), do: false

  defp exact_list_container?(map, keys),
    do: exact_keys?(map, keys) and lists?(map, keys)

  defp exact_non_negative_integers?(map, keys) do
    exact_keys?(map, keys) and Enum.all?(keys, &non_negative_integer?(map[&1]))
  end

  defp lists?(map, keys) when is_map(map), do: Enum.all?(keys, &is_list(map[&1]))
  defp lists?(_map, _keys), do: false
  defp non_negative_integer?(value), do: is_integer(value) and value >= 0
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp positive_or_nil?(nil), do: true
  defp positive_or_nil?(value), do: positive_integer?(value)
  defp uuid_or_nil?(nil), do: true
  defp uuid_or_nil?(value), do: uuid?(value)
  defp ticket_kind?(value), do: value in ~w(woo_product woo_variation)
  defp datetime_or_nil?(nil), do: true
  defp datetime_or_nil?(%DateTime{}), do: true

  defp datetime_or_nil?(value) when is_binary(value),
    do: match?({:ok, _, _}, DateTime.from_iso8601(value))

  defp datetime_or_nil?(_), do: false
  defp decimal_or_nil?(nil), do: true
  defp decimal_or_nil?(%Decimal{}), do: true
  defp decimal_or_nil?(value) when is_binary(value), do: match?({_, ""}, Decimal.parse(value))
  defp decimal_or_nil?(_), do: false
  defp bounded?(nil, _max, true), do: true

  defp bounded?(value, max, _nullable),
    do: is_binary(value) and byte_size(value) <= max and value != ""

  defp valid_target_id?("run", nil), do: true

  defp valid_target_id?(target, value) when target in ~w(event product variation),
    do: positive_integer?(value)

  defp valid_target_id?(_, _), do: false

  defp uuid?(value) when is_binary(value) do
    match?({:ok, _}, Ecto.UUID.cast(value)) and value == String.downcase(value)
  end

  defp uuid?(_value), do: false

  defp map_ok(values, mapper) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case mapper.(value) do
        {:ok, mapped} -> {:cont, {:ok, [mapped | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      error -> error
    end
  end

  defp contains_float?(value) when is_float(value), do: true
  defp contains_float?(%Decimal{}), do: false
  defp contains_float?(%DateTime{}), do: false
  defp contains_float?(values) when is_list(values), do: Enum.any?(values, &contains_float?/1)

  defp contains_float?(%{} = map),
    do: Enum.any?(map, fn {_key, value} -> contains_float?(value) end)

  defp contains_float?(_value), do: false
end
