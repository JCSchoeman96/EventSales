defmodule EventSales.Catalog.TickeraCatalog.SourceRiskV3.Compatibility.V2Adapter do
  @moduledoc """
  Historical `compat.v2_to_source_risk_v3.v1` adapter for `historical_v2_compatibility_review`.

  Certainty-monotonic only. All adapted CanonicalFacts are `compatibility_derived`,
  completeness `unknown`, and automation-ineligible. Never used as the live v2 operational path.
  """

  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.CanonicalFact
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.ContractRegistry
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.Evidence
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.Normalizer

  defmodule TranslationRecord do
    @moduledoc false

    @enforce_keys [
      :compatibility_version,
      :source_contract_version,
      :source_emitter,
      :translation_rule_id,
      :translation_result,
      :certainty_change
    ]

    defstruct [
      :compatibility_version,
      :source_contract_version,
      :source_record_identity,
      :source_owner,
      :source_emitter,
      :raw_code,
      :raw_classification,
      :raw_scope,
      :raw_target,
      :translation_rule_id,
      :translation_result,
      :canonical_dimension,
      :canonical_state,
      :canonical_value,
      :canonical_scope,
      :canonical_target,
      :translated_completeness,
      :certainty_change,
      :reason,
      :bounded_provenance_refs,
      :qualified_finding_id,
      :lossy_derivative_of,
      :compatibility_regrouping?
    ]
  end

  @adapter_version "compat.v2_to_source_risk_v3.v1"
  @source_contract_version "2026-07-22.v2"
  @canonical_contract_version "source_risk.v3"

  @emitters MapSet.new([
              "wp.event_risk_codes",
              "wp.review_reasons",
              "phoenix.source_risk.from_code",
              "phoenix.normalizer",
              "phoenix.vocab",
              "contract",
              "planner",
              "unknown"
            ])

  @translation_results MapSet.new([
                         "translated",
                         "translated_weakened",
                         "compatibility_diagnostic",
                         "derived_summary",
                         "structural_projection",
                         "planner_projection",
                         "undeclared_raw",
                         "unrecoverable",
                         "rejected"
                       ])

  @owners ["WordPress", "Phoenix", "contract", "planner"]

  @max_raw_bytes 64

  @type result :: %{
          adapter_version: String.t(),
          source_contract_version: String.t(),
          canonical_contract_version: String.t(),
          automation_eligible?: false,
          record: TranslationRecord.t(),
          fact: CanonicalFact.t() | nil,
          projection: map() | nil
        }

  @spec adapter_version() :: String.t()
  def adapter_version, do: @adapter_version

  @spec source_contract_version() :: String.t()
  def source_contract_version, do: @source_contract_version

  @spec canonical_contract_version() :: String.t()
  def canonical_contract_version, do: @canonical_contract_version

  @spec automation_eligible?() :: false
  def automation_eligible?, do: false

  @spec emitters() :: MapSet.t(String.t())
  def emitters, do: @emitters

  @spec translation_results() :: MapSet.t(String.t())
  def translation_results, do: @translation_results

  @spec translate(map(), keyword()) :: {:ok, result()} | {:error, atom()}
  def translate(input, opts \\ [])

  def translate(input, opts) when is_map(input) and is_list(opts) do
    run_id = Keyword.get(opts, :run_id)

    with :ok <- require_run_id(run_id),
         {:ok, normalized} <- normalize_input(input) do
      dispatch(normalized, run_id)
    end
  end

  def translate(_, _), do: {:error, :invalid_input}

  @spec classify_pair(CanonicalFact.t(), CanonicalFact.t()) ::
          :duplicate | :conflict | :different_identity
  def classify_pair(%CanonicalFact{} = left, %CanonicalFact{} = right) do
    CanonicalFact.compare_pair(left, right)
  end

  @spec known_lossy_lifecycle_derivative?(String.t(), String.t(), String.t(), String.t()) ::
          boolean()
  def known_lossy_lifecycle_derivative?(exact_status, raw_code, source_owner, source_emitter)
      when exact_status in ["trash", "draft"] and is_binary(raw_code) and
             is_binary(source_owner) and is_binary(source_emitter) do
    case {exact_status, raw_code, source_owner, source_emitter} do
      {"trash", "draft_product", "WordPress", "wp.review_reasons"} -> true
      {"draft", "draft_product", "WordPress", "wp.review_reasons"} -> true
      {"trash", "draft_event", "WordPress", "wp.review_reasons"} -> true
      {"draft", "draft_event", "WordPress", "wp.review_reasons"} -> true
      _ -> false
    end
  end

  def known_lossy_lifecycle_derivative?(_, _, _, _), do: false

  defp require_run_id(run_id) when is_binary(run_id) and run_id != "", do: :ok
  defp require_run_id(_), do: {:error, :missing_run_id}

  defp normalize_input(input) do
    with :ok <- reject_non_string_keys(input),
         :ok <- reject_forbidden_self_assertions(input),
         {:ok, raw_code} <- optional_bounded_string(input, "raw_code"),
         {:ok, source_owner} <- require_owner(input),
         {:ok, source_emitter} <- require_emitter(input),
         {:ok, source_record_identity} <- optional_bounded_string(input, "source_record_identity"),
         {:ok, raw_classification} <- optional_bounded_string(input, "raw_classification"),
         {:ok, raw_scope} <- optional_bounded_string(input, "raw_scope"),
         {:ok, event_status} <- optional_bounded_string(input, "event_status"),
         {:ok, product_status} <- optional_bounded_string(input, "product_status_classification"),
         {:ok, variation_status} <-
           optional_bounded_string(input, "variation_status_classification"),
         {:ok, product_type_token} <- optional_bounded_string(input, "product_type_token"),
         {:ok, event_link_ref} <- optional_bounded_string(input, "event_link_reference_state"),
         {:ok, tickera_event_id} <- optional_pos_int(input, "tickera_event_id"),
         {:ok, woo_product_id} <- optional_pos_int(input, "woo_product_id"),
         {:ok, woo_variation_id} <- optional_pos_int(input, "woo_variation_id") do
      {:ok,
       %{
         raw_code: raw_code,
         source_owner: source_owner,
         source_emitter: source_emitter,
         source_record_identity: source_record_identity,
         raw_classification: raw_classification,
         raw_scope: raw_scope,
         event_status: event_status,
         product_status_classification: product_status,
         variation_status_classification: variation_status,
         product_type_token: product_type_token,
         event_link_reference_state: event_link_ref,
         tickera_event_id: tickera_event_id,
         woo_product_id: woo_product_id,
         woo_variation_id: woo_variation_id
       }}
    end
  end

  defp reject_non_string_keys(map) do
    if Enum.all?(Map.keys(map), &is_binary/1), do: :ok, else: {:error, :non_string_map_keys}
  end

  defp reject_forbidden_self_assertions(input) do
    forbidden = ["origin", "authority_slot", "translation_rule_id"]

    if Enum.any?(forbidden, &Map.has_key?(input, &1)) do
      {:error, :forbidden_self_assertion}
    else
      :ok
    end
  end

  defp require_owner(input) do
    case Map.get(input, "source_owner") do
      owner when is_binary(owner) and owner in @owners -> {:ok, owner}
      owner when is_binary(owner) -> {:error, :unknown_source_owner}
      _ -> {:error, :missing_source_owner}
    end
  end

  defp require_emitter(input) do
    case Map.get(input, "source_emitter") do
      emitter when is_binary(emitter) ->
        if MapSet.member?(@emitters, emitter) do
          {:ok, emitter}
        else
          {:error, :unknown_source_emitter}
        end

      _ ->
        {:error, :missing_source_emitter}
    end
  end

  defp optional_bounded_string(input, key) do
    case Map.fetch(input, key) do
      :error ->
        {:ok, nil}

      {:ok, nil} ->
        {:ok, nil}

      {:ok, value} when is_binary(value) ->
        case ContractRegistry.validate_bounded_string(value, @max_raw_bytes) do
          :ok -> {:ok, value}
          {:error, reason} -> {:error, reason}
        end

      {:ok, _} ->
        {:error, :invalid_string_type}
    end
  end

  defp optional_pos_int(input, key) do
    case Map.fetch(input, key) do
      :error -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:ok, id} when is_integer(id) and id > 0 -> {:ok, id}
      {:ok, _} -> {:error, :invalid_target_id}
    end
  end

  defp require_source_record_identity(%{source_record_identity: id})
       when is_binary(id) and id != "",
       do: :ok

  defp require_source_record_identity(_), do: {:error, :missing_source_record_identity}

  # Class A exact retained classifications may drive translation without inventing a raw code.
  defp dispatch(%{raw_code: nil} = input, run_id), do: dispatch_class_a(input, run_id)

  defp dispatch(%{raw_code: code} = input, run_id) do
    case {code, input.source_owner, input.source_emitter} do
      {"trash_event", "WordPress", "wp.event_risk_codes"} ->
        event_lifecycle(input, run_id, "t.trash_event", "trash", "translated", "preserved")

      {"private_event", "WordPress", emitter}
      when emitter in ["wp.event_risk_codes", "wp.review_reasons"] ->
        rule =
          if emitter == "wp.event_risk_codes",
            do: "t.private_event.event_risk_codes",
            else: "t.private_event.review_reasons"

        event_lifecycle(input, run_id, rule, "private", "translated", "preserved")

      {"draft_event", "WordPress", "wp.event_risk_codes"} ->
        event_lifecycle(
          input,
          run_id,
          "t.draft_event.event_risk_codes",
          "draft",
          "translated",
          "preserved"
        )

      {"draft_event", "WordPress", "wp.review_reasons"} ->
        draft_event_review_reasons(input, run_id)

      {"draft_event", "WordPress", "unknown"} ->
        diagnostic(
          input,
          "t.draft_event.unknown_emitter",
          "lifecycle unresolved; emitter unknown"
        )

      {"trashed_event", "Phoenix", "phoenix.vocab"} ->
        event_lifecycle(input, run_id, "t.trashed_event", "trash", "translated", "preserved")

      {"deleted_event", "Phoenix", "phoenix.vocab"} ->
        event_lifecycle(input, run_id, "t.deleted_event", "deleted", "translated", "preserved")

      {"private_product", "WordPress", "wp.review_reasons"} ->
        parent_lifecycle(input, run_id, "t.private_product", "private", "translated", "preserved")

      {"draft_product", "WordPress", "wp.review_reasons"} ->
        draft_product(input, run_id)

      {"trashed_product", "Phoenix", "phoenix.vocab"} ->
        parent_lifecycle(input, run_id, "t.trashed_product", "trash", "translated", "preserved")

      {"deleted_product", "Phoenix", "phoenix.vocab"} ->
        parent_lifecycle(input, run_id, "t.deleted_product", "deleted", "translated", "preserved")

      {"draft_variation", "Phoenix", "phoenix.vocab"} ->
        variation_lifecycle(input, run_id, "t.draft_variation", "draft")

      {"private_variation", "Phoenix", "phoenix.normalizer"} ->
        private_variation(input, run_id)

      {"subscription_product", "WordPress", "wp.review_reasons"} ->
        subscription_present(input, run_id)

      {"subscription", "Phoenix", "phoenix.normalizer"} ->
        subscription_from_phoenix(input, run_id)

      {"payment_plan_product", "WordPress", "wp.review_reasons"} ->
        rejected(
          input,
          "t.payment_plan_product",
          "rejected alias; not payment_plan",
          "contract.unknown_source_risk_code"
        )

      {"missing_ticket_template", "WordPress", "wp.review_reasons"} ->
        ticket_template_absent(input, run_id)

      {"missing_tickera_event", "WordPress", "wp.review_reasons"} ->
        missing_tickera_event(input, run_id)

      {"unknown_product_semantics", "WordPress", "wp.review_reasons"} ->
        derived_summary(input, "t.unknown_product_semantics")

      {dim, "Phoenix", "phoenix.normalizer"}
      when dim in ["payment_plan", "membership", "bundle", "add_on"] ->
        capability_unknown(input, run_id, dim)

      {"unsupported_product_type", "Phoenix", "phoenix.normalizer"} ->
        unsupported_product_type(input, run_id)

      {"variation_mapping_required", "WordPress", "wp.review_reasons"} ->
        structural_planner(
          input,
          "t.variation_mapping_required.review_reasons",
          "structural_projection"
        )

      {"variation_mapping_required", "Phoenix", "phoenix.normalizer"} ->
        structural_planner(
          input,
          "t.variation_mapping_required.normalizer",
          "structural_projection"
        )

      {"missing_source_risk_data", "WordPress", "wp.event_risk_codes"} ->
        event_lifecycle_unknown(input, run_id, "t.missing_source_risk_data.wp_event_unknown")

      {"missing_source_risk_data", "Phoenix", "phoenix.source_risk.from_code"} ->
        unrecoverable(input, "t.missing_source_risk_data.phoenix_fallback")

      {code, "planner", "planner"}
      when code in [
             "ambiguous_variation_name",
             "ambiguous_variation_ticket_type_name",
             "duplicate_ticket_name",
             "duplicate_ticket_type_name",
             "existing_mapping_conflict",
             "product_moved_between_events",
             "ambiguous_identity"
           ] ->
        structural_planner(input, "t.planner.#{code}", "planner_projection")

      _ ->
        undeclared_raw(input)
    end
  end

  defp dispatch_class_a(input, run_id) do
    with :ok <- require_class_a_authority(input),
         {:ok, observation} <- exactly_one_class_a_observation(input) do
      case observation do
        {:event_status, value} ->
          event_lifecycle(input, run_id, nil, value, "translated", "preserved",
            reason: "direct retained Class A evidence"
          )

        {:product_status_classification, value} ->
          parent_lifecycle(input, run_id, nil, value, "translated", "preserved",
            reason: "direct retained Class A evidence"
          )

        {:variation_status_classification, value} ->
          variation_lifecycle(input, run_id, nil, value,
            reason: "direct retained Class A evidence"
          )
      end
    end
  end

  defp require_class_a_authority(%{source_owner: "WordPress", source_emitter: emitter})
       when emitter in ["wp.event_risk_codes", "wp.review_reasons", "unknown"],
       do: :ok

  defp require_class_a_authority(_), do: {:error, :invalid_class_a_authority}

  defp exactly_one_class_a_observation(input) do
    observations =
      []
      |> append_class_a(:event_status, input.event_status)
      |> append_class_a(:product_status_classification, input.product_status_classification)
      |> append_class_a(:variation_status_classification, input.variation_status_classification)

    case observations do
      [only] -> {:ok, only}
      [] -> {:error, :missing_class_a_or_raw_code}
      _ -> {:error, :ambiguous_class_a_input}
    end
  end

  defp append_class_a(acc, field, value) when value in ["private", "draft", "trash"],
    do: [{field, value} | acc]

  defp append_class_a(acc, _field, _value), do: acc

  defp draft_event_review_reasons(input, run_id) do
    case input.event_status do
      "draft" ->
        event_lifecycle(
          input,
          run_id,
          "t.draft_event.review_reasons",
          "draft",
          "translated_weakened",
          "weakened",
          lossy: "draft_event"
        )

      "trash" ->
        event_lifecycle(
          input,
          run_id,
          "t.draft_event.review_reasons",
          "trash",
          "translated_weakened",
          "weakened",
          lossy: "draft_event"
        )

      _ ->
        diagnostic(
          input,
          "t.draft_event.review_reasons",
          "draft_event code-only is lossy; exact event_status unavailable"
        )
    end
  end

  defp draft_product(input, run_id) do
    case input.product_status_classification do
      "draft" ->
        parent_lifecycle(
          input,
          run_id,
          "t.draft_product",
          "draft",
          "translated_weakened",
          "weakened",
          lossy: "draft_product"
        )

      "trash" ->
        parent_lifecycle(
          input,
          run_id,
          "t.draft_product",
          "trash",
          "translated_weakened",
          "weakened",
          lossy: "draft_product"
        )

      _ ->
        diagnostic(
          input,
          "t.draft_product",
          "draft_product code-only is lossy; exact classification unavailable"
        )
    end
  end

  defp private_variation(input, run_id) do
    case input.variation_status_classification do
      status when status in ["private", "draft", "trash"] ->
        variation_lifecycle(input, run_id, "t.private_variation", status)

      _ ->
        case input.raw_classification do
          "explicit_safe" ->
            diagnostic(
              input,
              "t.private_variation",
              "synthetic explicit_safe filler does not invent variation lifecycle observation"
            )

          _ ->
            diagnostic(
              input,
              "t.private_variation",
              "private_variation without retained variation classification"
            )
        end
    end
  end

  defp event_lifecycle(input, run_id, rule_id, value, result, certainty, opts \\ []) do
    with {:ok, target} <- require_event_target(input) do
      mint_fact(input, run_id,
        rule_id: rule_id,
        dimension: "lifecycle",
        scope: "event",
        target: target,
        state: "present",
        value: value,
        source_key: "wp_posts.post_status",
        translation_result: result,
        certainty_change: certainty,
        finding: lifecycle_finding(value),
        lossy: Keyword.get(opts, :lossy),
        reason: Keyword.get(opts, :reason)
      )
    end
  end

  defp event_lifecycle_unknown(input, run_id, rule_id) do
    with {:ok, target} <- require_event_target(input) do
      mint_fact(input, run_id,
        rule_id: rule_id,
        dimension: "lifecycle",
        scope: "event",
        target: target,
        state: "unknown",
        value: nil,
        source_key: "wp_posts.post_status",
        translation_result: "translated_weakened",
        certainty_change: "weakened",
        finding: "source_risk.lifecycle_unresolved"
      )
    end
  end

  defp parent_lifecycle(input, run_id, rule_id, value, result, certainty, opts \\ []) do
    with {:ok, target, regrouped?} <- require_parent_target(input) do
      mint_fact(input, run_id,
        rule_id: rule_id,
        dimension: "lifecycle",
        scope: "parent_product",
        target: target,
        state: "present",
        value: value,
        source_key: "wp_posts.post_status",
        translation_result: if(regrouped?, do: "translated_weakened", else: result),
        certainty_change: if(regrouped?, do: "weakened", else: certainty),
        finding: lifecycle_finding(value),
        lossy: Keyword.get(opts, :lossy),
        regrouping?: regrouped?,
        reason: Keyword.get(opts, :reason)
      )
    end
  end

  defp variation_lifecycle(input, run_id, rule_id, value, opts \\ []) do
    with {:ok, target} <- require_variation_target(input) do
      mint_fact(input, run_id,
        rule_id: rule_id,
        dimension: "lifecycle",
        scope: "variation",
        target: target,
        state: "present",
        value: value,
        source_key: "wp_posts.post_status",
        translation_result: "translated",
        certainty_change: "preserved",
        finding: lifecycle_finding(value),
        reason: Keyword.get(opts, :reason)
      )
    end
  end

  defp subscription_present(input, run_id) do
    with {:ok, target, regrouped?} <- require_parent_target(input) do
      mint_fact(input, run_id,
        rule_id: "t.subscription_product",
        dimension: "subscription",
        scope: "parent_product",
        target: target,
        state: "present",
        value: nil,
        source_key: "wc_product_type+subscription_evidence",
        translation_result: if(regrouped?, do: "translated_weakened", else: "translated"),
        certainty_change: if(regrouped?, do: "weakened", else: "preserved"),
        finding: "source_risk.subscription",
        regrouping?: regrouped?
      )
    end
  end

  defp subscription_from_phoenix(input, run_id) do
    case input.raw_classification do
      "explicit_risky" ->
        with {:ok, target, regrouped?} <- require_parent_target(input) do
          mint_fact(input, run_id,
            rule_id: "t.subscription",
            dimension: "subscription",
            scope: "parent_product",
            target: target,
            state: "present",
            value: nil,
            source_key: "wc_product_type+subscription_evidence",
            translation_result: if(regrouped?, do: "translated_weakened", else: "translated"),
            certainty_change: if(regrouped?, do: "weakened", else: "preserved"),
            finding: "source_risk.subscription",
            regrouping?: regrouped?
          )
        end

      _ ->
        # explicit_safe filler or unknown — never absent+exhaustive
        diagnostic(
          input,
          "t.subscription",
          "historical subscription filler is not exhaustive absence proof"
        )
    end
  end

  defp ticket_template_absent(input, run_id) do
    with {:ok, target, regrouped?} <- require_parent_target(input) do
      mint_fact(input, run_id,
        rule_id: "t.missing_ticket_template",
        dimension: "ticket_template",
        scope: "parent_product",
        target: target,
        state: "absent",
        value: nil,
        source_key: "postmeta:_ticket_template",
        translation_result: if(regrouped?, do: "translated_weakened", else: "translated"),
        certainty_change: "weakened",
        finding: "source_risk.missing_ticket_template",
        regrouping?: regrouped?
      )
    end
  end

  defp missing_tickera_event(input, run_id) do
    case input.event_link_reference_state do
      "absent" ->
        with {:ok, target, _} <- require_parent_target(input) do
          mint_fact(input, run_id,
            rule_id: "t.missing_tickera_event",
            dimension: "event_link",
            scope: "event_product_relationship",
            target: target,
            state: "absent",
            value: nil,
            source_key: "postmeta:_event_name+tc_events.resolve",
            translation_result: "translated_weakened",
            certainty_change: "weakened",
            finding: "source_risk.missing_tickera_event"
          )
        end

      "unresolvable" ->
        with {:ok, target, _} <- require_parent_target(input) do
          mint_fact(input, run_id,
            rule_id: "t.missing_tickera_event",
            dimension: "event_link",
            scope: "event_product_relationship",
            target: target,
            state: "invalid",
            value: nil,
            source_key: "postmeta:_event_name+tc_events.resolve",
            translation_result: "translated_weakened",
            certainty_change: "weakened",
            finding: "contract.blocking_invalid"
          )
        end

      _ ->
        diagnostic(
          input,
          "t.missing_tickera_event",
          "missing_tickera_event alone does not prove event_link absent or invalid"
        )
    end
  end

  defp capability_unknown(input, run_id, dimension) do
    with {:ok, target, regrouped?} <- require_parent_target(input) do
      mint_fact(input, run_id,
        rule_id: "t.#{dimension}",
        dimension: dimension,
        scope: "parent_product",
        target: target,
        state: "unknown",
        value: nil,
        source_key: "product_semantics_capability",
        translation_result: if(regrouped?, do: "translated_weakened", else: "translated"),
        certainty_change: "weakened",
        finding: "source_risk.#{dimension}",
        regrouping?: regrouped?
      )
    end
  end

  defp unsupported_product_type(input, run_id) do
    case input.product_type_token do
      "simple" ->
        with {:ok, target, regrouped?} <- require_parent_target(input) do
          mint_fact(input, run_id,
            rule_id: "t.unsupported_product_type",
            dimension: "product_type",
            scope: "parent_product",
            target: target,
            state: "present",
            value: "simple",
            source_key: "wc_get_product.type",
            translation_result: if(regrouped?, do: "translated_weakened", else: "translated"),
            certainty_change: "weakened",
            finding: "source_risk.unsupported_product_type",
            regrouping?: regrouped?
          )
        end

      token when is_binary(token) ->
        undeclared_raw(input,
          rule_id: "t.unsupported_product_type",
          finding: "source_risk.unsupported_product_type",
          reason: "undeclared product type token retained; registry unchanged",
          retained_token: token
        )

      nil ->
        diagnostic(
          input,
          "t.unsupported_product_type",
          "unsupported_product_type without retained type token; no invented value"
        )
    end
  end

  defp mint_fact(input, run_id, opts) do
    with :ok <- require_source_record_identity(input) do
      evidence = %Evidence{
        dimension: Keyword.fetch!(opts, :dimension),
        producer_scope: Keyword.fetch!(opts, :scope),
        target: Keyword.fetch!(opts, :target),
        state: Keyword.fetch!(opts, :state),
        producer_source_key: Keyword.fetch!(opts, :source_key),
        completeness: "unknown",
        provenance: bounded_producer_provenance(input),
        value: Keyword.get(opts, :value),
        related_targets: %{}
      }

      case Normalizer.normalize_evidence(evidence,
             run_id: run_id,
             origin: "compatibility_derived",
             exhaustive_proven?: false
           ) do
        {:ok, fact} ->
          if fact.completeness == "exhaustive" or fact.origin != "compatibility_derived" do
            {:error, :compatibility_invariant_violation}
          else
            record = %{
              base_record(
                input,
                Keyword.fetch!(opts, :rule_id),
                Keyword.fetch!(opts, :translation_result),
                Keyword.fetch!(opts, :certainty_change)
              )
              | canonical_dimension: fact.dimension,
                canonical_state: fact.state,
                canonical_value: fact.value,
                canonical_scope: fact.semantic_scope,
                canonical_target: fact.target,
                translated_completeness: fact.completeness,
                qualified_finding_id: Keyword.get(opts, :finding),
                lossy_derivative_of: Keyword.get(opts, :lossy),
                compatibility_regrouping?: Keyword.get(opts, :regrouping?, false) == true,
                reason: Keyword.get(opts, :reason) || "historical compatibility translation"
            }

            {:ok, wrap(record, fact, nil)}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp diagnostic(input, rule_id, reason) do
    record = %{
      base_record(input, rule_id, "compatibility_diagnostic", "weakened")
      | reason: reason,
        qualified_finding_id: historical_finding_visibility(input.raw_code)
    }

    {:ok, wrap(record, nil, %{kind: "compatibility_diagnostic", reason: reason})}
  end

  defp rejected(input, rule_id, reason, finding) do
    record = %{
      base_record(input, rule_id, "rejected", "weakened")
      | reason: reason,
        qualified_finding_id: finding
    }

    {:ok, wrap(record, nil, %{kind: "rejected", reason: reason, finding: finding})}
  end

  defp unrecoverable(input, rule_id) do
    record = %{
      base_record(input, rule_id, "unrecoverable", "weakened")
      | reason: "erased producer code cannot be reconstructed",
        qualified_finding_id: "contract.unknown_source_risk_code"
    }

    {:ok, wrap(record, nil, %{kind: "unrecoverable"})}
  end

  defp undeclared_raw(input, opts \\ []) do
    rule_id = Keyword.get(opts, :rule_id, "t.unknown_source_risk_code")
    finding = Keyword.get(opts, :finding, "contract.unknown_source_risk_code")
    reason = Keyword.get(opts, :reason, "undeclared raw code retained")
    retained_token = Keyword.get(opts, :retained_token, input.raw_code)

    record = %{
      base_record(input, rule_id, "undeclared_raw", "weakened")
      | reason: reason,
        qualified_finding_id: finding
    }

    {:ok, wrap(record, nil, %{kind: "undeclared_raw", raw_code: retained_token})}
  end

  defp derived_summary(input, rule_id) do
    with :ok <- require_source_record_identity(input),
         {:ok, _target, _regrouped?} <- require_parent_target(input) do
      record = %{
        base_record(input, rule_id, "derived_summary", "weakened")
        | reason: "derived aggregate only; not a co-equal blocker"
      }

      {:ok,
       wrap(record, nil, %{
         kind: "derived_summary",
         code: "unknown_product_semantics",
         woo_product_id: input.woo_product_id
       })}
    end
  end

  defp structural_planner(input, rule_id, result) do
    with :ok <- require_source_record_identity(input) do
      record = %{
        base_record(input, rule_id, result, "preserved")
        | reason: "non source-risk projection"
      }

      projection =
        case result do
          "structural_projection" ->
            %{kind: "structural_projection", code: input.raw_code, rule_id: rule_id}

          "planner_projection" ->
            %{kind: "planner_projection", code: input.raw_code, rule_id: rule_id}
        end

      {:ok, wrap(record, nil, projection)}
    end
  end

  defp wrap(%TranslationRecord{} = record, fact, projection) do
    %{
      adapter_version: @adapter_version,
      source_contract_version: @source_contract_version,
      canonical_contract_version: @canonical_contract_version,
      automation_eligible?: false,
      record: record,
      fact: fact,
      projection: projection
    }
  end

  defp base_record(input, rule_id, translation_result, certainty_change) do
    unless MapSet.member?(@translation_results, translation_result) do
      raise ArgumentError, "unknown translation_result #{inspect(translation_result)}"
    end

    %TranslationRecord{
      compatibility_version: @adapter_version,
      source_contract_version: @source_contract_version,
      source_record_identity: input.source_record_identity,
      source_owner: input.source_owner,
      source_emitter: input.source_emitter,
      raw_code: input.raw_code,
      raw_classification: input.raw_classification,
      raw_scope: input.raw_scope,
      raw_target: raw_target(input),
      translation_rule_id: rule_id,
      translation_result: translation_result,
      certainty_change: certainty_change,
      bounded_provenance_refs: bounded_refs(input)
    }
  end

  defp raw_target(input) do
    %{
      tickera_event_id: input.tickera_event_id,
      woo_product_id: input.woo_product_id,
      woo_variation_id: input.woo_variation_id
    }
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  defp bounded_refs(input) do
    %{
      "raw_code" => input.raw_code,
      "source_owner" => input.source_owner,
      "source_emitter" => input.source_emitter
    }
    |> maybe_put("product_status_classification", input.product_status_classification)
    |> maybe_put("variation_status_classification", input.variation_status_classification)
    |> maybe_put("event_status", input.event_status)
    |> maybe_put("product_type_token", input.product_type_token)
    |> maybe_put("raw_scope", input.raw_scope)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp bounded_producer_provenance(input) do
    %{}
    |> maybe_put_id("woo_product_id", input.woo_product_id)
    |> maybe_put_id("woo_variation_id", input.woo_variation_id)
    |> maybe_put_id("tickera_event_id", input.tickera_event_id)
    |> maybe_put("raw_producer_code", input.raw_code)
  end

  defp maybe_put_id(map, _key, nil), do: map
  defp maybe_put_id(map, key, id) when is_integer(id) and id > 0, do: Map.put(map, key, id)

  defp require_event_target(%{tickera_event_id: id}) when is_integer(id) and id > 0 do
    {:ok, %{tickera_event_id: id}}
  end

  defp require_event_target(_), do: {:error, :missing_tickera_event_id}

  defp require_parent_target(%{woo_product_id: id} = input)
       when is_integer(id) and id > 0 do
    regrouped? = is_integer(input.woo_variation_id) and input.woo_variation_id > 0
    {:ok, %{woo_product_id: id}, regrouped?}
  end

  defp require_parent_target(_), do: {:error, :missing_woo_product_id}

  defp require_variation_target(%{woo_variation_id: vid, woo_product_id: pid})
       when is_integer(vid) and vid > 0 and is_integer(pid) and pid > 0 do
    {:ok, %{woo_variation_id: vid, woo_product_id: pid}}
  end

  defp require_variation_target(_), do: {:error, :invalid_variation_target}

  defp lifecycle_finding("private"), do: "source_risk.lifecycle_private"
  defp lifecycle_finding("draft"), do: "source_risk.lifecycle_draft"
  defp lifecycle_finding("trash"), do: "source_risk.lifecycle_trashed"
  defp lifecycle_finding("deleted"), do: "source_risk.lifecycle_deleted"
  defp lifecycle_finding(_), do: nil

  defp historical_finding_visibility("draft_event"), do: "source_risk.lifecycle_draft"
  defp historical_finding_visibility("draft_product"), do: "source_risk.lifecycle_draft"

  defp historical_finding_visibility("missing_tickera_event"),
    do: "source_risk.missing_tickera_event"

  defp historical_finding_visibility("missing_ticket_template"),
    do: "source_risk.missing_ticket_template"

  defp historical_finding_visibility(_), do: nil
end
