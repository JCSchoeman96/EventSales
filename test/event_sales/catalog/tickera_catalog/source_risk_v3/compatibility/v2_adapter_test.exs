defmodule EventSales.Catalog.TickeraCatalog.SourceRiskV3.Compatibility.V2AdapterTest do
  use ExUnit.Case, async: true

  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.CanonicalFact
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.Compatibility.V2Adapter
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.ContractRegistry

  defp input(overrides) do
    Map.merge(
      %{
        "source_owner" => "WordPress",
        "source_emitter" => "wp.review_reasons",
        "source_record_identity" => "hist-1"
      },
      Map.new(overrides)
    )
  end

  defp translate!(overrides) do
    assert {:ok, result} = V2Adapter.translate(input(overrides), run_id: "run-hist")
    result
  end

  test "locks adapter/source/canonical versions and automation ineligibility" do
    assert V2Adapter.adapter_version() == "compat.v2_to_source_risk_v3.v1"
    assert V2Adapter.source_contract_version() == "2026-07-22.v2"
    assert V2Adapter.canonical_contract_version() == "source_risk.v3"
    refute V2Adapter.automation_eligible?()

    result =
      translate!(%{
        "raw_code" => "private_event",
        "source_emitter" => "wp.event_risk_codes",
        "tickera_event_id" => 9
      })

    assert result.adapter_version == "compat.v2_to_source_risk_v3.v1"
    assert result.source_contract_version == "2026-07-22.v2"
    assert result.canonical_contract_version == "source_risk.v3"
    refute result.automation_eligible?
    assert result.fact.origin == "compatibility_derived"
    assert result.fact.completeness == "unknown"
    refute result.record.certainty_change == "strengthened"
  end

  test "closed emitter and translation-result vocabularies" do
    assert "wp.event_risk_codes" in MapSet.to_list(V2Adapter.emitters())
    assert "unknown" in MapSet.to_list(V2Adapter.emitters())
    assert "translated" in MapSet.to_list(V2Adapter.translation_results())
    assert "unrecoverable" in MapSet.to_list(V2Adapter.translation_results())

    assert {:error, :unknown_source_emitter} =
             V2Adapter.translate(
               input(%{"raw_code" => "private_event", "source_emitter" => "invented.emitter"}),
               run_id: "run-hist"
             )
  end

  describe "draft_event emitter split" do
    test "event_risk_codes becomes present/draft" do
      result =
        translate!(%{
          "raw_code" => "draft_event",
          "source_emitter" => "wp.event_risk_codes",
          "tickera_event_id" => 11
        })

      assert result.record.translation_rule_id == "t.draft_event.event_risk_codes"
      assert result.fact.state == "present"
      assert result.fact.value == "draft"
      assert result.fact.semantic_scope == "event"
      assert result.fact.target == %{tickera_event_id: 11}
      assert result.fact.origin == "compatibility_derived"
      assert result.fact.completeness == "unknown"
    end

    test "review_reasons with exact draft/trash status" do
      draft =
        translate!(%{
          "raw_code" => "draft_event",
          "event_status" => "draft",
          "tickera_event_id" => 12
        })

      assert draft.fact.value == "draft"
      assert draft.record.lossy_derivative_of == "draft_event"

      trash =
        translate!(%{
          "raw_code" => "draft_event",
          "event_status" => "trash",
          "tickera_event_id" => 12
        })

      assert trash.fact.value == "trash"
      assert trash.record.lossy_derivative_of == "draft_event"
    end

    test "review_reasons code-only and unknown emitter never mint present/draft" do
      code_only =
        translate!(%{"raw_code" => "draft_event", "tickera_event_id" => 13})

      assert code_only.fact == nil
      assert code_only.record.translation_result == "compatibility_diagnostic"
      assert code_only.record.translation_rule_id == "t.draft_event.review_reasons"

      unknown =
        translate!(%{
          "raw_code" => "draft_event",
          "source_emitter" => "unknown",
          "tickera_event_id" => 13
        })

      assert unknown.fact == nil
      assert unknown.record.translation_rule_id == "t.draft_event.unknown_emitter"
      assert unknown.record.translation_result == "compatibility_diagnostic"
    end
  end

  describe "parent lifecycle and draft_product lossy handling" do
    test "private_product becomes parent present/private" do
      result =
        translate!(%{
          "raw_code" => "private_product",
          "woo_product_id" => 40
        })

      assert result.fact.semantic_scope == "parent_product"
      assert result.fact.target == %{woo_product_id: 40}
      assert result.fact.value == "private"
      refute Map.has_key?(result.fact.target, :woo_variation_id)
    end

    test "draft_product with exact classification and code-only diagnostic" do
      draft =
        translate!(%{
          "raw_code" => "draft_product",
          "product_status_classification" => "draft",
          "woo_product_id" => 41
        })

      assert draft.fact.value == "draft"
      assert draft.record.lossy_derivative_of == "draft_product"

      trash =
        translate!(%{
          "raw_code" => "draft_product",
          "product_status_classification" => "trash",
          "woo_product_id" => 41
        })

      assert trash.fact.value == "trash"
      assert V2Adapter.known_lossy_lifecycle_derivative?("trash", "draft_product")

      only =
        translate!(%{"raw_code" => "draft_product", "woo_product_id" => 41})

      assert only.fact == nil
      assert only.record.translation_result == "compatibility_diagnostic"
    end

    test "known lossy derivative does not conflict with exact status fact" do
      exact =
        translate!(%{
          "raw_code" => "draft_product",
          "product_status_classification" => "trash",
          "woo_product_id" => 50
        }).fact

      assert exact.value == "trash"
      assert V2Adapter.known_lossy_lifecycle_derivative?("trash", "draft_product")
      # Lossy code is provenance only — no second independent claim to conflict with.
      assert V2Adapter.classify_pair(exact, exact) == :duplicate
    end
  end

  describe "event aliases and missing_source_risk_data split" do
    test "trash_event and private_event exact cases" do
      trash =
        translate!(%{
          "raw_code" => "trash_event",
          "source_emitter" => "wp.event_risk_codes",
          "tickera_event_id" => 7
        })

      assert trash.fact.value == "trash"
      assert trash.record.translation_rule_id == "t.trash_event"

      private =
        translate!(%{
          "raw_code" => "private_event",
          "source_emitter" => "wp.event_risk_codes",
          "tickera_event_id" => 7
        })

      assert private.fact.value == "private"
    end

    test "WP missing_source_risk_data becomes event lifecycle unknown" do
      result =
        translate!(%{
          "raw_code" => "missing_source_risk_data",
          "source_emitter" => "wp.event_risk_codes",
          "tickera_event_id" => 8
        })

      assert result.record.translation_rule_id ==
               "t.missing_source_risk_data.wp_event_unknown"

      assert result.fact.dimension == "lifecycle"
      assert result.fact.state == "unknown"
      assert result.fact.completeness == "unknown"
      assert result.fact.origin == "compatibility_derived"
    end

    test "Phoenix fallback missing_source_risk_data is unrecoverable" do
      result =
        translate!(%{
          "raw_code" => "missing_source_risk_data",
          "source_owner" => "Phoenix",
          "source_emitter" => "phoenix.source_risk.from_code"
        })

      assert result.fact == nil
      assert result.record.translation_result == "unrecoverable"

      assert result.record.translation_rule_id ==
               "t.missing_source_risk_data.phoenix_fallback"
    end
  end

  describe "ticket template" do
    test "missing_ticket_template becomes absent with unknown completeness" do
      result =
        translate!(%{
          "raw_code" => "missing_ticket_template",
          "woo_product_id" => 60
        })

      assert result.fact.dimension == "ticket_template"
      assert result.fact.state == "absent"
      assert result.fact.semantic_scope == "parent_product"
      assert result.fact.completeness == "unknown"
      assert result.fact.origin == "compatibility_derived"
      refute result.automation_eligible?
    end

    test "synthetic explicit_safe does not mint present template" do
      # Adapter does not accept inventing present from filler classifications alone.
      assert {:ok, result} =
               V2Adapter.translate(
                 input(%{
                   "raw_code" => "missing_ticket_template",
                   "raw_classification" => "explicit_safe",
                   "woo_product_id" => 61
                 }),
                 run_id: "run-hist"
               )

      refute result.fact.state == "present"
      assert result.fact.state == "absent"
    end
  end

  describe "event link / missing_tickera_event" do
    test "code-only never becomes absent or invalid" do
      result =
        translate!(%{
          "raw_code" => "missing_tickera_event",
          "woo_product_id" => 70
        })

      assert result.fact == nil
      assert result.record.translation_result == "compatibility_diagnostic"
    end

    test "Class A proven absent and unresolvable" do
      absent =
        translate!(%{
          "raw_code" => "missing_tickera_event",
          "woo_product_id" => 71,
          "event_link_reference_state" => "absent"
        })

      assert absent.fact.dimension == "event_link"
      assert absent.fact.state == "absent"
      assert absent.fact.target == %{woo_product_id: 71}
      assert absent.fact.completeness == "unknown"

      invalid =
        translate!(%{
          "raw_code" => "missing_tickera_event",
          "woo_product_id" => 71,
          "event_link_reference_state" => "unresolvable"
        })

      assert invalid.fact.state == "invalid"
      assert invalid.fact.target == %{woo_product_id: 71}
    end
  end

  describe "subscription and payment_plan_product" do
    test "subscription_product becomes present; absence of code does not invent absent" do
      result =
        translate!(%{
          "raw_code" => "subscription_product",
          "woo_product_id" => 80
        })

      assert result.fact.dimension == "subscription"
      assert result.fact.state == "present"
      assert result.fact.completeness == "unknown"
      assert result.fact.origin == "compatibility_derived"

      filler =
        translate!(%{
          "raw_code" => "subscription",
          "source_owner" => "Phoenix",
          "source_emitter" => "phoenix.normalizer",
          "raw_classification" => "explicit_safe",
          "woo_product_id" => 80
        })

      assert filler.fact == nil
      assert filler.record.translation_result == "compatibility_diagnostic"
    end

    test "payment_plan_product is rejected and never maps to payment_plan" do
      result =
        translate!(%{
          "raw_code" => "payment_plan_product",
          "woo_product_id" => 81
        })

      assert result.fact == nil
      assert result.record.translation_result == "rejected"
      assert result.record.translation_rule_id == "t.payment_plan_product"
      assert result.projection.finding == "contract.unknown_source_risk_code"
      refute result.record.canonical_dimension == "payment_plan"
    end
  end

  describe "product semantics and product type" do
    test "capability dimensions translate to unknown with nil values" do
      for dim <- ["payment_plan", "membership", "bundle", "add_on"] do
        result =
          translate!(%{
            "raw_code" => dim,
            "source_owner" => "Phoenix",
            "source_emitter" => "phoenix.normalizer",
            "woo_product_id" => 90
          })

        assert result.fact.dimension == dim
        assert result.fact.state == "unknown"
        assert result.fact.value == nil
        assert result.fact.semantic_scope == "parent_product"
        assert result.fact.origin == "compatibility_derived"
        assert result.fact.completeness == "unknown"
      end
    end

    test "unknown_product_semantics is derived_summary only" do
      result =
        translate!(%{
          "raw_code" => "unknown_product_semantics",
          "woo_product_id" => 91
        })

      assert result.fact == nil
      assert result.record.translation_result == "derived_summary"
      assert result.projection.kind == "derived_summary"
    end

    test "retained simple becomes present/simple; undeclared token stays out of registry" do
      simple =
        translate!(%{
          "raw_code" => "unsupported_product_type",
          "source_owner" => "Phoenix",
          "source_emitter" => "phoenix.normalizer",
          "product_type_token" => "simple",
          "woo_product_id" => 92
        })

      assert simple.fact.state == "present"
      assert simple.fact.value == "simple"

      undeclared =
        translate!(%{
          "raw_code" => "unsupported_product_type",
          "source_owner" => "Phoenix",
          "source_emitter" => "phoenix.normalizer",
          "product_type_token" => "variable",
          "woo_product_id" => 92
        })

      assert undeclared.fact == nil
      assert undeclared.record.translation_result == "undeclared_raw"
      assert {:ok, values} = ContractRegistry.allowed_values_for_dimension("product_type")
      refute MapSet.member?(values, "variable")

      no_token =
        translate!(%{
          "raw_code" => "unsupported_product_type",
          "source_owner" => "Phoenix",
          "source_emitter" => "phoenix.normalizer",
          "woo_product_id" => 92
        })

      assert no_token.fact == nil
      assert no_token.record.translation_result == "compatibility_diagnostic"
    end
  end

  describe "regrouping structural planner and conflict" do
    test "parent semantic on variation row regroups to parent_product" do
      result =
        translate!(%{
          "raw_code" => "private_product",
          "woo_product_id" => 100,
          "woo_variation_id" => 200
        })

      assert result.fact.semantic_scope == "parent_product"
      assert result.fact.target == %{woo_product_id: 100}
      refute Map.has_key?(result.fact.target, :woo_variation_id)
      assert result.record.compatibility_regrouping?
      assert result.record.certainty_change == "weakened"
    end

    test "missing parent id fails closed rather than inventing" do
      assert {:error, :missing_woo_product_id} =
               V2Adapter.translate(
                 input(%{
                   "raw_code" => "private_product",
                   "woo_variation_id" => 200
                 }),
                 run_id: "run-hist"
               )
    end

    test "variation_mapping_required emitters remain distinct and produce no canonical fact" do
      wp =
        translate!(%{
          "raw_code" => "variation_mapping_required",
          "source_emitter" => "wp.review_reasons",
          "woo_variation_id" => 1,
          "woo_product_id" => 2
        })

      phoenix =
        translate!(%{
          "raw_code" => "variation_mapping_required",
          "source_owner" => "Phoenix",
          "source_emitter" => "phoenix.normalizer",
          "woo_variation_id" => 1,
          "woo_product_id" => 2
        })

      assert wp.fact == nil
      assert phoenix.fact == nil
      assert wp.record.translation_rule_id == "t.variation_mapping_required.review_reasons"
      assert phoenix.record.translation_rule_id == "t.variation_mapping_required.normalizer"
      assert wp.projection.kind == "structural_projection"
      assert phoenix.projection.kind == "structural_projection"
      refute wp.record.translation_rule_id == phoenix.record.translation_rule_id
    end

    test "planner-owned code becomes planner_projection" do
      result =
        translate!(%{
          "raw_code" => "ambiguous_identity",
          "source_owner" => "planner",
          "source_emitter" => "planner"
        })

      assert result.fact == nil
      assert result.record.translation_result == "planner_projection"
      assert result.projection.kind == "planner_projection"
    end

    test "independent same-identity private vs draft is conflict" do
      private =
        translate!(%{
          "raw_code" => "private_product",
          "woo_product_id" => 110
        }).fact

      draft =
        translate!(%{
          "raw_code" => "draft_product",
          "product_status_classification" => "draft",
          "woo_product_id" => 110
        }).fact

      assert CanonicalFact.same_identity?(private, draft)
      assert V2Adapter.classify_pair(private, draft) == :conflict
    end
  end

  describe "bounds and safety" do
    test "invalid UTF-8 and oversized raw codes are rejected" do
      assert {:error, :invalid_utf8} =
               V2Adapter.translate(
                 input(%{"raw_code" => <<0xFF, 0xFE>>, "woo_product_id" => 1}),
                 run_id: "run-hist"
               )

      oversized = String.duplicate("a", 65)

      assert {:error, :oversized_string} =
               V2Adapter.translate(
                 input(%{"raw_code" => oversized, "woo_product_id" => 1}),
                 run_id: "run-hist"
               )
    end

    test "compatibility facts never become exhaustive or native" do
      result =
        translate!(%{
          "raw_code" => "subscription_product",
          "woo_product_id" => 120
        })

      assert result.fact.origin == "compatibility_derived"
      assert result.fact.completeness == "unknown"
      refute result.automation_eligible?
      refute result.fact.completeness == "exhaustive"
    end

    test "producer provenance cannot self-assert native origin" do
      # Adapter strips/ignores forbidden self-asserted origin; output remains compatibility_derived.
      result =
        translate!(%{
          "raw_code" => "private_product",
          "woo_product_id" => 121,
          "origin" => "native",
          "authority_slot" => "slot.lifecycle.wp_post_status"
        })

      assert result.fact.origin == "compatibility_derived"
      refute Map.has_key?(result.fact.provenance, "origin")
    end
  end
end
