defmodule EventSales.Catalog.TickeraCatalog.SourceRiskV3.FindingPolicyTest do
  use ExUnit.Case, async: true

  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.CanonicalFact
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.FindingPolicy

  defp fact(overrides) do
    base = %{
      run_id: "run-1",
      dimension: "lifecycle",
      semantic_scope: "parent_product",
      target: %{woo_product_id: 10},
      authority_slot: "slot.lifecycle.wp_post_status",
      authority: "auth.wp_post_status",
      state: "present",
      value: "publish",
      completeness: "partial",
      origin: "native",
      provenance: %{}
    }

    struct!(CanonicalFact, Map.merge(base, Map.new(overrides)))
  end

  test "policy owns disposition and severity separately from state" do
    result = FindingPolicy.evaluate(fact(%{state: "present", value: "publish"}))

    assert result.disposition == "safe_positive_proof"
    assert result.severity == nil
    assert result.dimension_local_only?

    blocking = FindingPolicy.evaluate(fact(%{state: "unknown", value: nil}))
    assert blocking.disposition == "blocking_unknown"
    assert blocking.severity == :blocking
  end

  test "blocking states fail closed" do
    assert FindingPolicy.evaluate(fact(%{state: "missing", value: nil})).disposition ==
             "blocking_missing"

    assert FindingPolicy.evaluate(
             fact(%{
               dimension: "product_type",
               authority_slot: "slot.product_type.wc",
               authority: "auth.wc_product_type",
               state: "unsupported",
               value: nil
             })
           ).disposition == "blocking_unsupported"

    assert FindingPolicy.evaluate(fact(%{state: "invalid", value: nil})).disposition ==
             "blocking_invalid"

    assert FindingPolicy.evaluate(fact(%{state: "producer_error", value: nil})).disposition ==
             "blocking_error"
  end

  test "explicit risk mappings for lifecycle subscription and absences" do
    assert FindingPolicy.evaluate(fact(%{value: "private"})).qualified_finding_id ==
             "source_risk.lifecycle_private"

    assert FindingPolicy.evaluate(
             fact(%{
               dimension: "subscription",
               authority_slot: "slot.subscription.detection",
               authority: "auth.subscription_detection",
               state: "present",
               value: "present"
             })
           ).disposition == "explicit_risk"

    assert FindingPolicy.evaluate(
             fact(%{
               dimension: "ticket_template",
               authority_slot: "slot.ticket_template.meta",
               authority: "auth.ticket_template_meta",
               state: "absent",
               value: nil,
               completeness: "exhaustive"
             })
           ).qualified_finding_id == "source_risk.missing_ticket_template"

    assert FindingPolicy.evaluate(
             fact(%{
               dimension: "event_link",
               semantic_scope: "event_product_relationship",
               authority_slot: "slot.event_link.meta",
               authority: "auth.event_name_meta",
               state: "absent",
               value: nil,
               completeness: "exhaustive"
             })
           ).qualified_finding_id == "source_risk.missing_tickera_event"
  end

  test "subscription non-safe state matrix uses subscription_unresolved" do
    expected = %{
      "unknown" => "blocking_unknown",
      "unsupported" => "blocking_unsupported",
      "missing" => "blocking_missing",
      "invalid" => "blocking_invalid",
      "producer_error" => "blocking_error",
      "absent" => "blocking_unknown"
    }

    for {state, disposition} <- expected do
      result =
        FindingPolicy.evaluate(
          fact(%{
            dimension: "subscription",
            authority_slot: "slot.subscription.detection",
            authority: "auth.subscription_detection",
            state: state,
            value: nil
          })
        )

      assert result.disposition == disposition,
             "subscription/#{state} expected #{disposition}, got #{result.disposition}"

      assert result.qualified_finding_id == "source_risk.subscription_unresolved"
      assert result.severity == :blocking
    end

    present =
      FindingPolicy.evaluate(
        fact(%{
          dimension: "subscription",
          authority_slot: "slot.subscription.detection",
          authority: "auth.subscription_detection",
          state: "present",
          value: nil
        })
      )

    assert present.disposition == "explicit_risk"
    assert present.qualified_finding_id == "source_risk.subscription"
  end

  test "capability dimension state matrix uses source_risk.<dimension>" do
    for dimension <- ["payment_plan", "membership", "bundle", "add_on"] do
      for {state, disposition} <- [
            {"unsupported", "blocking_unsupported"},
            {"unknown", "blocking_unknown"},
            {"producer_error", "blocking_error"}
          ] do
        result =
          FindingPolicy.evaluate(
            fact(%{
              dimension: dimension,
              authority_slot: "slot.#{dimension}.capability",
              authority: "auth.wp_semantic_capability",
              state: state,
              value: nil
            })
          )

        assert result.disposition == disposition,
               "#{dimension}/#{state} expected #{disposition}, got #{result.disposition}"

        assert result.qualified_finding_id == "source_risk.#{dimension}"
        assert result.severity == :blocking
      end
    end
  end

  test "conflict and contract error dispositions" do
    left = fact(%{value: "private"})
    right = fact(%{value: "draft"})

    conflict = FindingPolicy.evaluate_conflict(left, right)
    assert conflict.disposition == "blocking_conflict"
    assert conflict.qualified_finding_id == "contract.evidence_conflict"
    assert conflict.severity == :blocking

    contract = FindingPolicy.evaluate_contract_error(:scope_mismatch)
    assert contract.disposition == "blocking_scope_mismatch"
    assert contract.qualified_finding_id == "contract.scope_mismatch"
  end

  test "native safe-negative allowlist remains empty" do
    assert FindingPolicy.native_safe_negative_allowlist_empty?()

    # Exhaustive absent subscription is not safe-negative under native v3 MVP.
    result =
      FindingPolicy.evaluate(
        fact(%{
          dimension: "subscription",
          authority_slot: "slot.subscription.detection",
          authority: "auth.subscription_detection",
          state: "absent",
          value: nil,
          completeness: "exhaustive"
        })
      )

    refute result.disposition == "safe_negative_proof"
  end

  test "safe proofs never imply row plan run or Apply safety" do
    result = FindingPolicy.evaluate(fact(%{value: "publish"}))

    assert result.disposition == "safe_positive_proof"
    refute result.implies_row_safe?
    refute result.implies_target_safe?
    refute result.implies_plan_safe?
    refute result.implies_run_safe?
    refute result.implies_apply_eligible?
    refute FindingPolicy.implies_apply_safety?(result)
  end
end
