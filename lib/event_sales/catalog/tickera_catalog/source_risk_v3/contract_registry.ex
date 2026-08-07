defmodule EventSales.Catalog.TickeraCatalog.SourceRiskV3.ContractRegistry do
  @moduledoc """
  Immutable compile-time `source_risk.v3` vocabulary and contract tables.

  Unknown identifiers fail closed. Native safe-negative allowlist is empty.
  """

  @canonical_contract_version "source_risk.v3"
  @native_producer_schema_version "2026-08-07.v3"
  @native_normalization_mode "native"

  @dimensions ~w(
    lifecycle
    ticket_template
    event_link
    subscription
    payment_plan
    membership
    bundle
    add_on
    product_type
  )

  @scopes ~w(
    event
    parent_product
    variation
    ticket_template
    event_product_relationship
    product_variation_relationship
  )

  @states ~w(
    present
    absent
    unknown
    missing
    unsupported
    invalid
    producer_error
    parser_error
  )

  @producer_emittable_states ~w(
    present
    absent
    unknown
    missing
    unsupported
    invalid
    producer_error
  )

  @completeness_values ~w(exhaustive partial unknown)

  @authorities ~w(
    auth.wp_post_status
    auth.ticket_template_meta
    auth.event_name_meta
    auth.subscription_detection
    auth.wc_product_type
    auth.wp_semantic_capability
  )

  @authority_slots ~w(
    slot.lifecycle.wp_post_status
    slot.ticket_template.meta
    slot.event_link.meta
    slot.subscription.detection
    slot.product_type.wc
    slot.payment_plan.capability
    slot.membership.capability
    slot.bundle.capability
    slot.add_on.capability
  )

  @origins ~w(native compatibility_derived)

  @dispositions ~w(
    safe_positive_proof
    safe_negative_proof
    explicit_risk
    blocking_unknown
    blocking_missing
    blocking_unsupported
    blocking_invalid
    blocking_error
    blocking_scope_mismatch
    blocking_authority_mismatch
    blocking_conflict
    blocking_contract_error
    not_applicable
  )

  @lifecycle_values ~w(publish private draft trash deleted)
  @product_type_values ~w(simple)

  @finding_owners ~w(source_risk contract structural planner.status planner.action)

  @scope_target_keys %{
    "event" => [:tickera_event_id],
    "parent_product" => [:woo_product_id],
    "variation" => [:woo_variation_id, :woo_product_id],
    "ticket_template" => [:ticket_template_id],
    "event_product_relationship" => [:woo_product_id],
    "product_variation_relationship" => [:woo_product_id, :woo_variation_id]
  }

  @dimension_scopes %{
    "lifecycle" => MapSet.new(~w(event parent_product variation)),
    "ticket_template" => MapSet.new(~w(parent_product)),
    "event_link" => MapSet.new(~w(event_product_relationship)),
    "subscription" => MapSet.new(~w(parent_product)),
    "payment_plan" => MapSet.new(~w(parent_product)),
    "membership" => MapSet.new(~w(parent_product)),
    "bundle" => MapSet.new(~w(parent_product)),
    "add_on" => MapSet.new(~w(parent_product)),
    "product_type" => MapSet.new(~w(parent_product))
  }

  @dimension_states %{
    "lifecycle" => MapSet.new(~w(present unknown missing invalid producer_error)),
    "ticket_template" =>
      MapSet.new(~w(present absent missing unknown unsupported invalid producer_error)),
    "event_link" => MapSet.new(~w(present absent missing unknown invalid producer_error)),
    "subscription" =>
      MapSet.new(~w(present absent unknown unsupported missing invalid producer_error)),
    "payment_plan" => MapSet.new(~w(unsupported unknown producer_error)),
    "membership" => MapSet.new(~w(unsupported unknown producer_error)),
    "bundle" => MapSet.new(~w(unsupported unknown producer_error)),
    "add_on" => MapSet.new(~w(unsupported unknown producer_error)),
    "product_type" => MapSet.new(~w(present unsupported unknown missing invalid producer_error))
  }

  @dimension_authority_slot %{
    "lifecycle" => "slot.lifecycle.wp_post_status",
    "ticket_template" => "slot.ticket_template.meta",
    "event_link" => "slot.event_link.meta",
    "subscription" => "slot.subscription.detection",
    "product_type" => "slot.product_type.wc",
    "payment_plan" => "slot.payment_plan.capability",
    "membership" => "slot.membership.capability",
    "bundle" => "slot.bundle.capability",
    "add_on" => "slot.add_on.capability"
  }

  @authority_slot_to_authority %{
    "slot.lifecycle.wp_post_status" => "auth.wp_post_status",
    "slot.ticket_template.meta" => "auth.ticket_template_meta",
    "slot.event_link.meta" => "auth.event_name_meta",
    "slot.subscription.detection" => "auth.subscription_detection",
    "slot.product_type.wc" => "auth.wc_product_type",
    "slot.payment_plan.capability" => "auth.wp_semantic_capability",
    "slot.membership.capability" => "auth.wp_semantic_capability",
    "slot.bundle.capability" => "auth.wp_semantic_capability",
    "slot.add_on.capability" => "auth.wp_semantic_capability"
  }

  @authority_producer_source_keys %{
    "auth.wp_post_status" => "wp_posts.post_status",
    "auth.ticket_template_meta" => "postmeta:_ticket_template",
    "auth.event_name_meta" => "postmeta:_event_name",
    "auth.subscription_detection" => "wc_product_type",
    "auth.wc_product_type" => "wc_get_product.type",
    "auth.wp_semantic_capability" => "product_semantics_capability"
  }

  @authority_allowed_states %{
    "auth.wp_post_status" => MapSet.new(~w(present unknown missing invalid producer_error)),
    "auth.ticket_template_meta" =>
      MapSet.new(~w(present absent missing unknown invalid producer_error)),
    "auth.event_name_meta" =>
      MapSet.new(~w(present absent missing unknown invalid producer_error)),
    "auth.subscription_detection" =>
      MapSet.new(~w(present unknown unsupported missing invalid producer_error)),
    "auth.wc_product_type" =>
      MapSet.new(~w(present unsupported unknown missing invalid producer_error)),
    "auth.wp_semantic_capability" => MapSet.new(~w(unsupported unknown producer_error))
  }

  @exhaustive_negative_permitted MapSet.new(["ticket_template", "event_link"])

  @dimension_values %{
    "lifecycle" => MapSet.new(@lifecycle_values),
    "product_type" => MapSet.new(@product_type_values)
  }

  # Native v3 MVP safe-negative allowlist is intentionally empty.
  @safe_negative_allowlist []

  @safe_positive_rules [
    %{
      dimension: "lifecycle",
      scopes: MapSet.new(~w(event parent_product variation)),
      state: "present",
      value: "publish",
      authority: "auth.wp_post_status"
    },
    %{
      dimension: "ticket_template",
      scopes: MapSet.new(~w(parent_product)),
      state: "present",
      value: :any_valid_id,
      authority: "auth.ticket_template_meta"
    },
    %{
      dimension: "product_type",
      scopes: MapSet.new(~w(parent_product)),
      state: "present",
      value: "simple",
      authority: "auth.wc_product_type"
    },
    %{
      dimension: "event_link",
      scopes: MapSet.new(~w(event_product_relationship)),
      state: "present",
      value: :resolved_tickera_event_id,
      authority: "auth.event_name_meta"
    }
  ]

  @producer_provenance_keys MapSet.new([
                              "discovery_snapshot_id",
                              "producer_version",
                              "producer_source_key",
                              "raw_producer_code",
                              "woo_product_id",
                              "woo_variation_id",
                              "tickera_event_id"
                            ])

  @rejected_producer_provenance_keys MapSet.new([
                                       "origin",
                                       "authority_slot",
                                       "translation_rule_id",
                                       "alias_id",
                                       "canonical_contract_version",
                                       "run_id",
                                       "schema_version"
                                     ])

  @max_closed_id_length 64
  @max_raw_producer_code_bytes 64
  @max_producer_source_key_bytes 128
  @max_evidence_value_bytes 64
  @max_evidence_items_per_page 500

  @closed_id_regex ~r/^[a-z][a-z0-9_]*$/

  @spec canonical_contract_version() :: String.t()
  def canonical_contract_version, do: @canonical_contract_version

  @spec native_producer_schema_version() :: String.t()
  def native_producer_schema_version, do: @native_producer_schema_version

  @spec native_normalization_mode() :: String.t()
  def native_normalization_mode, do: @native_normalization_mode

  @spec dimensions() :: [String.t()]
  def dimensions, do: @dimensions

  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @spec states() :: [String.t()]
  def states, do: @states

  @spec producer_emittable_states() :: [String.t()]
  def producer_emittable_states, do: @producer_emittable_states

  @spec completeness_values() :: [String.t()]
  def completeness_values, do: @completeness_values

  @spec authorities() :: [String.t()]
  def authorities, do: @authorities

  @spec authority_slots() :: [String.t()]
  def authority_slots, do: @authority_slots

  @spec origins() :: [String.t()]
  def origins, do: @origins

  @spec dispositions() :: [String.t()]
  def dispositions, do: @dispositions

  @spec lifecycle_values() :: [String.t()]
  def lifecycle_values, do: @lifecycle_values

  @spec product_type_values() :: [String.t()]
  def product_type_values, do: @product_type_values

  @spec finding_owners() :: [String.t()]
  def finding_owners, do: @finding_owners

  @spec safe_negative_allowlist() :: []
  def safe_negative_allowlist, do: @safe_negative_allowlist

  @spec safe_positive_rules() :: [map()]
  def safe_positive_rules, do: @safe_positive_rules

  @spec producer_provenance_keys() :: MapSet.t(String.t())
  def producer_provenance_keys, do: @producer_provenance_keys

  @spec rejected_producer_provenance_keys() :: MapSet.t(String.t())
  def rejected_producer_provenance_keys, do: @rejected_producer_provenance_keys

  @spec max_closed_id_length() :: pos_integer()
  def max_closed_id_length, do: @max_closed_id_length

  @spec max_raw_producer_code_bytes() :: pos_integer()
  def max_raw_producer_code_bytes, do: @max_raw_producer_code_bytes

  @spec max_producer_source_key_bytes() :: pos_integer()
  def max_producer_source_key_bytes, do: @max_producer_source_key_bytes

  @spec max_evidence_value_bytes() :: pos_integer()
  def max_evidence_value_bytes, do: @max_evidence_value_bytes

  @spec max_evidence_items_per_page() :: pos_integer()
  def max_evidence_items_per_page, do: @max_evidence_items_per_page

  @spec dimension?(term()) :: boolean()
  def dimension?(id), do: id in @dimensions

  @spec scope?(term()) :: boolean()
  def scope?(id), do: id in @scopes

  @spec state?(term()) :: boolean()
  def state?(id), do: id in @states

  @spec producer_emittable_state?(term()) :: boolean()
  def producer_emittable_state?(id), do: id in @producer_emittable_states

  @spec completeness?(term()) :: boolean()
  def completeness?(id), do: id in @completeness_values

  @spec authority?(term()) :: boolean()
  def authority?(id), do: id in @authorities

  @spec authority_slot?(term()) :: boolean()
  def authority_slot?(id), do: id in @authority_slots

  @spec origin?(term()) :: boolean()
  def origin?(id), do: id in @origins

  @spec disposition?(term()) :: boolean()
  def disposition?(id), do: id in @dispositions

  @spec finding_owner?(term()) :: boolean()
  def finding_owner?(id), do: id in @finding_owners

  @spec fetch_dimension(term()) :: {:ok, String.t()} | {:error, :unknown_dimension}
  def fetch_dimension(id) when id in @dimensions, do: {:ok, id}
  def fetch_dimension(_), do: {:error, :unknown_dimension}

  @spec fetch_scope(term()) :: {:ok, String.t()} | {:error, :unknown_scope}
  def fetch_scope(id) when id in @scopes, do: {:ok, id}
  def fetch_scope(_), do: {:error, :unknown_scope}

  @spec fetch_state(term()) :: {:ok, String.t()} | {:error, :unknown_state}
  def fetch_state(id) when id in @states, do: {:ok, id}
  def fetch_state(_), do: {:error, :unknown_state}

  @spec fetch_completeness(term()) :: {:ok, String.t()} | {:error, :unknown_completeness}
  def fetch_completeness(id) when id in @completeness_values, do: {:ok, id}
  def fetch_completeness(_), do: {:error, :unknown_completeness}

  @spec fetch_authority(term()) :: {:ok, String.t()} | {:error, :unknown_authority}
  def fetch_authority(id) when id in @authorities, do: {:ok, id}
  def fetch_authority(_), do: {:error, :unknown_authority}

  @spec fetch_authority_slot(term()) :: {:ok, String.t()} | {:error, :unknown_authority_slot}
  def fetch_authority_slot(id) when id in @authority_slots, do: {:ok, id}
  def fetch_authority_slot(_), do: {:error, :unknown_authority_slot}

  @spec fetch_disposition(term()) :: {:ok, String.t()} | {:error, :unknown_disposition}
  def fetch_disposition(id) when id in @dispositions, do: {:ok, id}
  def fetch_disposition(_), do: {:error, :unknown_disposition}

  @spec fetch_origin(term()) :: {:ok, String.t()} | {:error, :unknown_origin}
  def fetch_origin(id) when id in @origins, do: {:ok, id}
  def fetch_origin(_), do: {:error, :unknown_origin}

  @spec authority_slot_for_dimension(String.t()) ::
          {:ok, String.t()} | {:error, :unknown_dimension}
  def authority_slot_for_dimension(dimension) do
    case Map.fetch(@dimension_authority_slot, dimension) do
      {:ok, slot} -> {:ok, slot}
      :error -> {:error, :unknown_dimension}
    end
  end

  @spec authority_for_slot(String.t()) ::
          {:ok, String.t()} | {:error, :unknown_authority_slot}
  def authority_for_slot(slot) do
    case Map.fetch(@authority_slot_to_authority, slot) do
      {:ok, authority} -> {:ok, authority}
      :error -> {:error, :unknown_authority_slot}
    end
  end

  @spec producer_source_key_for_authority(String.t()) ::
          {:ok, String.t()} | {:error, :unknown_authority}
  def producer_source_key_for_authority(authority) do
    case Map.fetch(@authority_producer_source_keys, authority) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, :unknown_authority}
    end
  end

  @spec scope_allowed_for_dimension?(String.t(), String.t()) :: boolean()
  def scope_allowed_for_dimension?(dimension, scope) do
    case Map.fetch(@dimension_scopes, dimension) do
      {:ok, scopes} -> MapSet.member?(scopes, scope)
      :error -> false
    end
  end

  @spec state_allowed_for_dimension?(String.t(), String.t()) :: boolean()
  def state_allowed_for_dimension?(dimension, state) do
    case Map.fetch(@dimension_states, dimension) do
      {:ok, states} -> MapSet.member?(states, state)
      :error -> false
    end
  end

  @spec state_allowed_for_authority?(String.t(), String.t()) :: boolean()
  def state_allowed_for_authority?(authority, state) do
    case Map.fetch(@authority_allowed_states, authority) do
      {:ok, states} -> MapSet.member?(states, state)
      :error -> false
    end
  end

  @spec exhaustive_negative_permitted?(String.t()) :: boolean()
  def exhaustive_negative_permitted?(dimension),
    do: MapSet.member?(@exhaustive_negative_permitted, dimension)

  @spec target_keys_for_scope(String.t()) ::
          {:ok, [atom()]} | {:error, :unknown_scope}
  def target_keys_for_scope(scope) do
    case Map.fetch(@scope_target_keys, scope) do
      {:ok, keys} -> {:ok, keys}
      :error -> {:error, :unknown_scope}
    end
  end

  @spec allowed_values_for_dimension(String.t()) ::
          {:ok, MapSet.t(String.t())} | :unbounded_optional | {:error, :unknown_dimension}
  def allowed_values_for_dimension(dimension)
      when dimension in ["lifecycle", "product_type"] do
    {:ok, Map.fetch!(@dimension_values, dimension)}
  end

  def allowed_values_for_dimension(dimension)
      when dimension in ["ticket_template", "event_link", "subscription"] do
    :unbounded_optional
  end

  def allowed_values_for_dimension(dimension)
      when dimension in ["payment_plan", "membership", "bundle", "add_on"] do
    {:ok, MapSet.new()}
  end

  def allowed_values_for_dimension(_), do: {:error, :unknown_dimension}

  @spec validate_closed_id(term()) :: :ok | {:error, atom()}
  def validate_closed_id(id) when is_binary(id) do
    byte_size = byte_size(id)

    cond do
      byte_size == 0 -> {:error, :empty_id}
      byte_size > @max_closed_id_length -> {:error, :oversized_id}
      Regex.match?(@closed_id_regex, id) -> :ok
      true -> {:error, :invalid_id_charset}
    end
  end

  def validate_closed_id(_), do: {:error, :invalid_id_type}

  @spec validate_bounded_string(term(), pos_integer()) :: :ok | {:error, atom()}
  def validate_bounded_string(value, max_bytes)
      when is_binary(value) and is_integer(max_bytes) and max_bytes > 0 do
    if byte_size(value) <= max_bytes do
      :ok
    else
      {:error, :oversized_string}
    end
  end

  def validate_bounded_string(nil, _max_bytes), do: :ok
  def validate_bounded_string(_, _), do: {:error, :invalid_string_type}

  @spec member_of_safe_negative_allowlist?(map()) :: false
  def member_of_safe_negative_allowlist?(_claim), do: false
end
