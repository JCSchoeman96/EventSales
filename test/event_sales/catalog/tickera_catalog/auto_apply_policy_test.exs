defmodule EventSales.Catalog.TickeraCatalog.AutoApplyPolicyTest do
  use ExUnit.Case, async: true

  alias EventSales.Catalog.TickeraCatalog.AutoApplyPolicy

  test "eligible additive targeted v2 plan is deterministic and pure" do
    input = eligible_input()

    assert {:ok, %{result: :eligible, reason_codes: [], summaries: summaries}} =
             AutoApplyPolicy.evaluate(input)

    assert AutoApplyPolicy.evaluate(input) == AutoApplyPolicy.evaluate(input)
    assert summaries.action_summary["event_create"] == 1
  end

  test "rejects every manual or unsupported action for the whole run" do
    cases = [
      {"event_actions", "update_metadata"},
      {"event_actions", "adopt_existing"},
      {"event_actions", "unknown"},
      {"ticket_type_actions", "adopt_existing"},
      {"ticket_type_actions", "unknown"},
      {"product_mapping_actions", "move"},
      {"product_mapping_actions", "update"},
      {"product_mapping_actions", "deactivate"},
      {"product_mapping_actions", "delete"},
      {"product_mapping_actions", "unknown"}
    ]

    for {collection, action} <- cases do
      input = put_in(eligible_input(), [:snapshot, collection], [%{"action" => action}])

      assert {:ok, %{result: :ineligible, reason_codes: reasons}} =
               AutoApplyPolicy.evaluate(input)

      assert :unsupported_action in reasons
    end
  end

  test "any finding, risk, variation, or historical impact rejects the whole run" do
    finding = put_in(eligible_input(), [:snapshot, "findings"], [%{"code" => "any"}])

    risk =
      update_in(
        eligible_input(),
        [:snapshot, "source_risks"],
        fn [first | rest] ->
          [Map.put(first, "evidence_classification", "explicit_risky") | rest]
        end
      )

    variation =
      put_in(
        eligible_input(),
        [:snapshot, "product_mapping_actions", Access.at(0), "woo_variation_id"],
        99
      )

    history =
      put_in(
        eligible_input(),
        [:snapshot, "historical_impact", "totals", "affected_pending_lines"],
        1
      )

    for {input, reason} <- [
          {finding, :finding_present},
          {risk, :source_risk_present},
          {variation, :variation_present},
          {history, :historical_impact_present}
        ] do
      assert {:ok, %{result: :ineligible, reason_codes: reasons}} =
               AutoApplyPolicy.evaluate(input)

      assert reason in reasons
    end
  end

  test "source proof must be complete, unique, and explicitly safe" do
    assert {:ok, %{result: :ineligible, reason_codes: empty_reasons}} =
             eligible_input()
             |> put_in([:snapshot, "source_risks"], [])
             |> AutoApplyPolicy.evaluate()

    assert :missing_source_risk_proof in empty_reasons

    [first | rest] = eligible_input().snapshot["source_risks"]

    for risks <- [
          rest,
          [Map.put(first, "evidence_classification", "missing") | rest],
          [Map.put(first, "evidence_classification", "unknown") | rest],
          [Map.put(first, "evidence_classification", "explicit_risky") | rest],
          [first, first | rest]
        ] do
      assert {:ok, %{result: :ineligible, reason_codes: reasons}} =
               eligible_input()
               |> put_in([:snapshot, "source_risks"], risks)
               |> AutoApplyPolicy.evaluate()

      assert Enum.any?(
               [:missing_source_risk_proof, :source_risk_present, :duplicate_source_risk_proof],
               &(&1 in reasons)
             )
    end
  end

  test "missing or unsupported versions and origin fail closed" do
    cases = [
      {Map.put(eligible_input(), :policy_version, "other"), :unsupported_policy_version},
      {put_in(eligible_input(), [:snapshot, "snapshot_schema_version"], "v1"),
       :unsupported_snapshot_version},
      {Map.put(eligible_input(), :origin, :human_admin), :unsupported_origin},
      {Map.delete(eligible_input(), :dry_run_hash), :missing_policy_input}
    ]

    for {input, reason} <- cases do
      assert {:ok, %{result: :ineligible, reason_codes: reasons}} =
               AutoApplyPolicy.evaluate(input)

      assert reason in reasons
    end
  end

  test "accepts exact one-to-one Event and TicketType reuse proof" do
    assert {:ok, %{result: :eligible, reason_codes: []}} =
             reuse_input()
             |> AutoApplyPolicy.evaluate()
  end

  test "rejects reuse proof with mutation or missing, extra, or mismatched identity" do
    cases = [
      {:reuse_mutation_present,
       put_in(
         reuse_input(),
         [:snapshot, "identity_membership_proof", "events", Access.at(0), "no_mutation"],
         false
       )},
      {:missing_reuse_proof,
       put_in(reuse_input(), [:snapshot, "identity_membership_proof", "events"], [])},
      {:extra_reuse_proof,
       update_in(
         reuse_input(),
         [:snapshot, "identity_membership_proof", "events"],
         fn [proof] -> [proof, Map.put(proof, "external_event_id", 2)] end
       )},
      {:mismatched_reuse_proof,
       put_in(
         reuse_input(),
         [:snapshot, "identity_membership_proof", "events", Access.at(0), "event_id"],
         "00000000-0000-0000-0000-000000000099"
       )},
      {:mismatched_reuse_proof,
       put_in(
         reuse_input(),
         [
           :snapshot,
           "identity_membership_proof",
           "ticket_types",
           Access.at(0),
           "ticket_type_id"
         ],
         "00000000-0000-0000-0000-000000000099"
       )},
      {:invalid_reuse_membership,
       put_in(
         reuse_input(),
         [:snapshot, "identity_membership_proof", "ticket_types", Access.at(0), "event_id"],
         "00000000-0000-0000-0000-000000000099"
       )}
    ]

    for {reason, input} <- cases do
      assert {:ok, %{result: :ineligible, reason_codes: reasons}} =
               AutoApplyPolicy.evaluate(input)

      assert reason in reasons
    end
  end

  test "rejects duplicate and conflicting reuse proof" do
    event_proof =
      reuse_input().snapshot["identity_membership_proof"]["events"]
      |> List.first()

    duplicate =
      update_in(
        reuse_input(),
        [:snapshot, "identity_membership_proof", "events"],
        &[event_proof | &1]
      )

    conflicting =
      update_in(
        reuse_input(),
        [:snapshot, "identity_membership_proof", "events"],
        &[Map.put(event_proof, "event_id", "00000000-0000-0000-0000-000000000099") | &1]
      )

    for {input, reason} <- [
          {duplicate, :duplicate_reuse_proof},
          {conflicting, :conflicting_reuse_proof}
        ] do
      assert {:ok, %{result: :ineligible, reason_codes: reasons}} =
               AutoApplyPolicy.evaluate(input)

      assert reason in reasons
    end
  end

  defp eligible_input do
    %{
      run_id: "00000000-0000-0000-0000-000000000001",
      dry_run_hash: String.duplicate("a", 64),
      origin: :targeted_catalog_change,
      findings: [],
      policy_version: "conservative_auto_apply.v1",
      snapshot: %{
        "snapshot_schema_version" => "tickera_catalog_plan.v2",
        "event_actions" => [%{"action" => "create", "external_event_id" => 1}],
        "ticket_type_actions" => [
          %{"action" => "create", "external_product_id" => 10, "external_variation_id" => nil}
        ],
        "product_mapping_actions" => [
          %{"action" => "create", "woo_product_id" => 10, "woo_variation_id" => nil}
        ],
        "findings" => [],
        "source_risks" => safe_source_risks(),
        "historical_impact" => %{
          "totals" => %{
            "affected_pending_lines" => 0,
            "affected_quantity" => 0,
            "eligible_lines" => 0,
            "eligible_quantity" => 0,
            "deferred_lines" => 0,
            "deferred_quantity" => 0,
            "conflicting_lines" => 0,
            "conflicting_quantity" => 0,
            "already_mapped_lines" => 0,
            "already_mapped_quantity" => 0
          },
          "warning_count" => 0,
          "unresolved_destination_count" => 0,
          "unknown_classification_count" => 0,
          "destinations" => []
        },
        "identity_membership_proof" => %{
          "events" => [],
          "ticket_types" => [],
          "product_mappings" => []
        }
      }
    }
  end

  defp reuse_input do
    event_id = "00000000-0000-0000-0000-000000000011"
    ticket_type_id = "00000000-0000-0000-0000-000000000012"
    source_system_id = "00000000-0000-0000-0000-000000000001"

    eligible_input()
    |> put_in(
      [:snapshot, "event_actions"],
      [
        %{
          "action" => "reuse",
          "ref" => "event:1",
          "event_id" => event_id,
          "source_system_id" => source_system_id,
          "external_event_kind" => "tickera_event",
          "external_event_id" => 1
        }
      ]
    )
    |> put_in(
      [:snapshot, "ticket_type_actions"],
      [
        %{
          "action" => "reuse",
          "ref" => "ticket:10",
          "ticket_type_id" => ticket_type_id,
          "event_id" => event_id,
          "external_ticket_type_kind" => "woo_product",
          "external_ticket_type_id" => 10,
          "external_product_id" => 10,
          "external_variation_id" => nil
        }
      ]
    )
    |> put_in(
      [:snapshot, "identity_membership_proof"],
      %{
        "events" => [
          %{
            "source_system_id" => source_system_id,
            "external_event_kind" => "tickera_event",
            "external_event_id" => 1,
            "event_id" => event_id,
            "action" => "reuse",
            "no_mutation" => true
          }
        ],
        "ticket_types" => [
          %{
            "external_ticket_type_kind" => "woo_product",
            "external_ticket_type_id" => 10,
            "external_product_id" => 10,
            "external_variation_id" => nil,
            "ticket_type_id" => ticket_type_id,
            "event_id" => event_id,
            "event_ref" => nil,
            "action" => "reuse",
            "no_mutation" => true
          }
        ],
        "product_mappings" => []
      }
    )
  end

  defp safe_source_risks do
    event = [
      safe_risk("event", 1, "private_event", "wp_post_status", "publish")
    ]

    product =
      [
        {"private_product", "wp_post_status", "publish"},
        {"subscription", "subscription_meta", "absent"},
        {"payment_plan", "planner_identity_query", "exact"},
        {"membership", "planner_identity_query", "exact"},
        {"bundle", "planner_identity_query", "exact"},
        {"add_on", "planner_identity_query", "exact"},
        {"missing_ticket_template", "ticket_template_meta", "present"},
        {"unsupported_product_type", "wc_product_type", "simple"}
      ]
      |> Enum.map(fn {code, source, value} ->
        safe_risk("product", 10, code, source, value)
      end)

    event ++ product
  end

  defp safe_risk(target_type, target_id, code, source, value) do
    %{
      "target_type" => target_type,
      "target_id" => target_id,
      "code" => code,
      "evidence_classification" => "explicit_safe",
      "evidence_source" => source,
      "evidence_value" => value
    }
  end
end
