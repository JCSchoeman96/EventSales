defmodule EventSales.Catalog.TickeraCatalog.SourceRiskV3.NormalizerTest do
  use ExUnit.Case, async: true

  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.CanonicalFact
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.Evidence
  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.Normalizer

  defp evidence(overrides) do
    base = %{
      "dimension" => "lifecycle",
      "producer_scope" => "parent_product",
      "target" => %{"woo_product_id" => 42},
      "state" => "present",
      "producer_source_key" => "wp_posts.post_status",
      "completeness" => "partial",
      "provenance" => %{"producer_version" => "2026-08-07.1"},
      "value" => "publish"
    }

    assert {:ok, validated} = Evidence.validate(Map.merge(base, Map.new(overrides)))
    validated
  end

  test "constructs a valid canonical fact from closed registry inputs" do
    assert {:ok, fact} = Normalizer.normalize_evidence(evidence(%{}), run_id: "run-a")

    assert %CanonicalFact{
             run_id: "run-a",
             dimension: "lifecycle",
             semantic_scope: "parent_product",
             target: %{woo_product_id: 42},
             authority_slot: "slot.lifecycle.wp_post_status",
             authority: "auth.wp_post_status",
             state: "present",
             value: "publish",
             completeness: "partial",
             origin: "native"
           } = fact
  end

  test "rejects unknown states and values fail closed" do
    assert {:error, :unknown_state} =
             Evidence.validate(%{
               "dimension" => "lifecycle",
               "producer_scope" => "parent_product",
               "target" => %{"woo_product_id" => 1},
               "state" => "error",
               "producer_source_key" => "wp_posts.post_status",
               "completeness" => "partial",
               "provenance" => %{}
             })

    assert {:error, :unknown_value} =
             Normalizer.normalize_evidence(
               evidence(%{"value" => "pending"}),
               run_id: "run-a"
             )
  end

  test "rejects undeclared product type tokens without truncation aliasing" do
    assert {:ok, validated} =
             Evidence.validate(%{
               "dimension" => "product_type",
               "producer_scope" => "parent_product",
               "target" => %{"woo_product_id" => 7},
               "state" => "present",
               "producer_source_key" => "wc_get_product.type",
               "completeness" => "partial",
               "provenance" => %{},
               "value" => "variable"
             })

    assert {:error, :undeclared_product_type} =
             Normalizer.normalize_evidence(validated, run_id: "run-a")
  end

  test "authority and scope validation fail closed" do
    assert {:error, :scope_mismatch} =
             Normalizer.normalize_evidence(
               evidence(%{
                 "dimension" => "ticket_template",
                 "producer_scope" => "variation",
                 "target" => %{"woo_variation_id" => 9, "woo_product_id" => 1},
                 "producer_source_key" => "postmeta:_ticket_template",
                 "value" => "tmpl-1"
               }),
               run_id: "run-a"
             )

    assert {:error, :authority_mismatch} =
             Normalizer.normalize_evidence(
               evidence(%{"producer_source_key" => "invented.source"}),
               run_id: "run-a"
             )
  end

  test "target validation preserves event_link primary identity as woo_product_id" do
    assert {:ok, validated} =
             Evidence.validate(%{
               "dimension" => "event_link",
               "producer_scope" => "event_product_relationship",
               "target" => %{"woo_product_id" => 55},
               "state" => "present",
               "producer_source_key" => "postmeta:_event_name",
               "completeness" => "partial",
               "provenance" => %{},
               "value" => 101,
               "related_targets" => %{"tickera_event_id" => 101}
             })

    assert {:ok, fact} = Normalizer.normalize_evidence(validated, run_id: "run-a")
    assert fact.target == %{woo_product_id: 55}
    assert fact.value == 101
  end

  test "unknown missing unsupported and error states never become safe" do
    for state <- ["unknown", "missing", "unsupported", "invalid", "producer_error"] do
      assert Normalizer.never_safe_state?(state)
    end

    assert Normalizer.never_safe_state?("parser_error")
    refute Normalizer.never_safe_state?("present")
    refute Normalizer.never_safe_state?("absent")
  end

  test "classifies duplicate and conflict candidates via CanonicalFact helpers" do
    assert {:ok, left} = Normalizer.normalize_evidence(evidence(%{}), run_id: "run-a")

    assert {:ok, duplicate} =
             Normalizer.normalize_evidence(evidence(%{}), run_id: "run-a")

    assert {:ok, conflict} =
             Normalizer.normalize_evidence(evidence(%{"value" => "draft"}), run_id: "run-a")

    assert %{duplicate_of: ^left, conflicts_with: []} =
             Normalizer.classify_against_existing(duplicate, [left])

    assert %{duplicate_of: nil, conflicts_with: [^left]} =
             Normalizer.classify_against_existing(conflict, [left])
  end

  test "dimension-local facts do not promote parent evidence to variation identity" do
    assert {:error, :invalid_target_shape} =
             Evidence.validate(%{
               "dimension" => "lifecycle",
               "producer_scope" => "parent_product",
               "target" => %{"woo_product_id" => 1, "woo_variation_id" => 2},
               "state" => "present",
               "producer_source_key" => "wp_posts.post_status",
               "completeness" => "partial",
               "provenance" => %{},
               "value" => "publish"
             })
  end

  test "rejects oversized evidence values fail closed" do
    oversized = String.duplicate("a", 65)

    assert {:error, :oversized_string} =
             Evidence.validate(%{
               "dimension" => "ticket_template",
               "producer_scope" => "parent_product",
               "target" => %{"woo_product_id" => 1},
               "state" => "present",
               "producer_source_key" => "postmeta:_ticket_template",
               "completeness" => "partial",
               "provenance" => %{},
               "value" => oversized
             })
  end
end
