defmodule EventSales.Catalog.TickeraCatalog.SourceRiskV3.ContractRegistryTest do
  use ExUnit.Case, async: true

  alias EventSales.Catalog.TickeraCatalog.SourceRiskV3.ContractRegistry

  test "exposes closed dimensions" do
    assert ContractRegistry.dimensions() == [
             "lifecycle",
             "ticket_template",
             "event_link",
             "subscription",
             "payment_plan",
             "membership",
             "bundle",
             "add_on",
             "product_type"
           ]

    assert ContractRegistry.dimension?("lifecycle")
    refute ContractRegistry.dimension?("unknown_product_semantics")
    assert {:error, :unknown_dimension} = ContractRegistry.fetch_dimension("not_a_dimension")
  end

  test "exposes closed scopes" do
    assert "event_product_relationship" in ContractRegistry.scopes()
    assert ContractRegistry.scope?("parent_product")
    refute ContractRegistry.scope?("catalog_row")
    assert {:error, :unknown_scope} = ContractRegistry.fetch_scope("row")
  end

  test "exposes closed evidence states without a generic error token" do
    assert ContractRegistry.states() == [
             "present",
             "absent",
             "unknown",
             "missing",
             "unsupported",
             "invalid",
             "producer_error",
             "parser_error"
           ]

    refute ContractRegistry.state?("error")
    refute "error" in ContractRegistry.producer_emittable_states()
    refute ContractRegistry.producer_emittable_state?("parser_error")
  end

  test "exposes closed completeness values only" do
    assert ContractRegistry.completeness_values() == ["exhaustive", "partial", "unknown"]
    refute ContractRegistry.completeness?("read_complete")

    assert {:error, :unknown_completeness} =
             ContractRegistry.fetch_completeness("type_read_complete")
  end

  test "exposes authorities and authority slots/groups" do
    assert "auth.wp_post_status" in ContractRegistry.authorities()
    assert "slot.event_link.meta" in ContractRegistry.authority_slots()

    assert {:ok, "slot.lifecycle.wp_post_status"} =
             ContractRegistry.authority_slot_for_dimension("lifecycle")

    assert {:ok, "auth.event_name_meta"} =
             ContractRegistry.authority_for_slot("slot.event_link.meta")

    assert {:error, :unknown_authority_slot} =
             ContractRegistry.authority_for_slot("slot.lifecycle.none")

    assert {:ok, "postmeta:_event_name+tc_events.resolve"} =
             ContractRegistry.producer_source_key_for_authority("auth.event_name_meta")

    assert {:ok, "wc_product_type+subscription_evidence"} =
             ContractRegistry.producer_source_key_for_authority("auth.subscription_detection")
  end

  test "bounded strings require valid UTF-8" do
    assert :ok = ContractRegistry.validate_bounded_string("ok", 64)
    assert {:error, :invalid_utf8} = ContractRegistry.validate_bounded_string(<<0xFF>>, 64)

    assert {:error, :oversized_string} =
             ContractRegistry.validate_bounded_string(String.duplicate("a", 65), 64)
  end

  test "exposes allowed canonical values" do
    assert {:ok, values} = ContractRegistry.allowed_values_for_dimension("lifecycle")
    assert MapSet.member?(values, "publish")
    assert MapSet.member?(values, "trash")

    assert {:ok, product_types} = ContractRegistry.allowed_values_for_dimension("product_type")
    assert MapSet.equal?(product_types, MapSet.new(["simple"]))
  end

  test "rejects unknown registry identifiers" do
    assert {:error, :unknown_authority} = ContractRegistry.fetch_authority("auth.invented")
    assert {:error, :unknown_disposition} = ContractRegistry.fetch_disposition("safe_maybe")
    assert {:error, :unknown_origin} = ContractRegistry.fetch_origin("inferred")
  end

  test "native safe-negative allowlist is empty" do
    assert ContractRegistry.safe_negative_allowlist() == []
    refute ContractRegistry.member_of_safe_negative_allowlist?(%{state: "absent"})
  end

  test "scope and state membership are dimension-local and fail closed" do
    assert ContractRegistry.scope_allowed_for_dimension?("ticket_template", "parent_product")
    refute ContractRegistry.scope_allowed_for_dimension?("ticket_template", "variation")
    assert ContractRegistry.state_allowed_for_dimension?("payment_plan", "unsupported")
    refute ContractRegistry.state_allowed_for_dimension?("payment_plan", "present")
  end

  test "event_link primary target keys are woo_product_id only" do
    assert {:ok, [:woo_product_id]} =
             ContractRegistry.target_keys_for_scope("event_product_relationship")
  end
end
