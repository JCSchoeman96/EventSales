defmodule EventSales.Catalog.TickeraCatalog.SourceRiskTest do
  use ExUnit.Case, async: true

  alias EventSales.Catalog.TickeraCatalog.SourceRisk

  @codes ~w(
    private_event draft_event trashed_event deleted_event
    private_product draft_product trashed_product deleted_product
    private_variation draft_variation variation_mapping_required ambiguous_variation_name
    subscription payment_plan membership bundle add_on unsupported_product_type
    missing_ticket_template unknown_product_semantics duplicate_ticket_name
    existing_mapping_conflict product_moved_between_events ambiguous_identity
    missing_source_risk_data
  )

  test "normalizes every approved source-risk code without dynamic atoms" do
    for code <- @codes do
      risk = SourceRisk.from_code(:product, 42, code)
      assert Atom.to_string(risk.code) == code
    end
  end

  test "unknown codes fail closed as missing source-risk data" do
    assert %SourceRisk{
             code: :missing_source_risk_data,
             evidence_classification: :missing
           } =
             SourceRisk.from_code(:product, 42, "unreviewed_code")
  end
end
