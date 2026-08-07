defmodule EventSales.Catalog.TickeraCatalog.SourceRiskV3.CanonicalFactTest do
  use ExUnit.Case, async: true

  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.CanonicalFact

  defp fact(overrides) do
    base = %{
      run_id: "run-1",
      dimension: "lifecycle",
      semantic_scope: "parent_product",
      target: %{woo_product_id: 10},
      authority_slot: "slot.lifecycle.wp_post_status",
      authority: "auth.wp_post_status",
      state: "present",
      value: "private",
      completeness: "partial",
      origin: "native",
      provenance: [%{"raw_producer_code" => "private_product"}]
    }

    struct!(CanonicalFact, Map.merge(base, Map.new(overrides)))
  end

  test "identity fields are exactly run, dimension, scope, target, and authority slot" do
    identity = CanonicalFact.identity(fact(%{}))

    assert Map.keys(identity) |> Enum.sort() ==
             [:authority_slot, :dimension, :run_id, :semantic_scope, :target]

    assert identity.run_id == "run-1"
    assert identity.dimension == "lifecycle"
    assert identity.semantic_scope == "parent_product"
    assert identity.target == %{woo_product_id: 10}
    assert identity.authority_slot == "slot.lifecycle.wp_post_status"
  end

  test "state and value are excluded from identity" do
    left = fact(%{state: "present", value: "private"})
    right = fact(%{state: "present", value: "draft"})

    assert CanonicalFact.same_identity?(left, right)
    refute Map.has_key?(CanonicalFact.identity(left), :state)
    refute Map.has_key?(CanonicalFact.identity(left), :value)
    refute Map.has_key?(CanonicalFact.identity(left), :provenance)
  end

  test "same identity plus same semantic claim is a duplicate" do
    left = fact(%{value: "private", completeness: "partial"})
    right = fact(%{value: "private", completeness: "partial", provenance: [%{"other" => "x"}]})

    assert CanonicalFact.compare_pair(left, right) == :duplicate
    assert CanonicalFact.same_semantic_claim?(left, right)
  end

  test "provenance differences remain duplicates and are excluded from claim equality" do
    left = fact(%{provenance: [%{"producer_version" => "2026-08-07.1"}]})

    right =
      fact(%{
        provenance: [%{"producer_version" => "2026-08-07.1", "raw_producer_code" => "a"}]
      })

    assert CanonicalFact.compare_pair(left, right) == :duplicate
    refute Map.has_key?(CanonicalFact.semantic_claim(left), :provenance)
    refute Map.has_key?(CanonicalFact.identity(left), :provenance)
  end

  test "provenance records sort deterministically by sorted key/value pairs" do
    a = %{"raw_producer_code" => "b", "producer_version" => "1"}
    b = %{"raw_producer_code" => "a", "producer_version" => "1"}

    assert CanonicalFact.sort_provenance_records([a, b]) ==
             CanonicalFact.sort_provenance_records([b, a])

    assert CanonicalFact.sort_provenance_records([a, b]) == [b, a]
  end

  test "same identity plus conflicting claim is a conflict" do
    left = fact(%{value: "private"})
    right = fact(%{value: "draft"})

    assert CanonicalFact.compare_pair(left, right) == :conflict
  end

  test "event_link identity uses woo_product_id only; event id is a claim value" do
    left =
      fact(%{
        dimension: "event_link",
        semantic_scope: "event_product_relationship",
        target: %{woo_product_id: 55},
        authority_slot: "slot.event_link.meta",
        authority: "auth.event_name_meta",
        state: "present",
        value: 10
      })

    right =
      fact(%{
        dimension: "event_link",
        semantic_scope: "event_product_relationship",
        target: %{woo_product_id: 55},
        authority_slot: "slot.event_link.meta",
        authority: "auth.event_name_meta",
        state: "present",
        value: 20
      })

    assert CanonicalFact.same_identity?(left, right)
    assert CanonicalFact.compare_pair(left, right) == :conflict
    assert CanonicalFact.identity(left).target == %{woo_product_id: 55}
  end

  test "deterministic ordering sorts by locked compare key" do
    a = fact(%{dimension: "lifecycle", value: "publish", target: %{woo_product_id: 2}})

    b =
      fact(%{
        dimension: "event_link",
        semantic_scope: "event_product_relationship",
        target: %{woo_product_id: 1},
        authority_slot: "slot.event_link.meta",
        authority: "auth.event_name_meta",
        value: 9
      })

    c = fact(%{dimension: "lifecycle", value: "draft", target: %{woo_product_id: 1}})

    sorted = CanonicalFact.sort_facts([a, b, c])
    assert Enum.map(sorted, & &1.dimension) == ["event_link", "lifecycle", "lifecycle"]
    assert Enum.map(sorted, & &1.target[:woo_product_id]) == [1, 1, 2]
  end

  test "target identity validation rejects wrong shapes" do
    assert {:ok, %{woo_product_id: 1}} =
             CanonicalFact.validate_target_for_scope("parent_product", %{woo_product_id: 1})

    assert {:error, :invalid_target_shape} =
             CanonicalFact.validate_target_for_scope("parent_product", %{
               woo_product_id: 1,
               woo_variation_id: 2
             })

    assert {:error, :invalid_target_shape} =
             CanonicalFact.validate_target_for_scope("variation", %{woo_variation_id: 2})
  end
end
