defmodule EventSales.Sales.Resources.RefundTest do
  use EventSales.DataCase, async: false

  alias EventSales.Sales
  alias EventSales.Sales.Resources.Refund
  alias EventSales.TestSupport.SalesHelpers

  test "supports an unresolved parent and keeps refund identity source scoped" do
    source_a = SalesHelpers.create_source_system!()
    source_b = SalesHelpers.create_source_system!()

    refund_a = create_reference!(source_a, %{woo_refund_id: 91_001})
    refund_b = create_reference!(source_b, %{woo_refund_id: 91_001})

    assert refund_a.order_id == nil
    assert refund_a.source_system_id == source_a.id
    assert refund_b.source_system_id == source_b.id
    assert refund_a.woo_refund_id == refund_b.woo_refund_id
  end

  test "rejects duplicate refund identity within one source and preserves Decimal facts" do
    source = SalesHelpers.create_source_system!()

    refund =
      Ash.create!(
        Refund,
        %{
          source_system_id: source.id,
          woo_order_id: 10_001,
          woo_refund_id: 91_002,
          currency: "ZAR",
          header_amount: Decimal.new("45.50"),
          shipping_refund_amount: Decimal.new("5.00"),
          shipping_refund_tax: Decimal.new("0.50"),
          fee_refund_amount: Decimal.new("2.00"),
          fee_refund_tax: Decimal.new("0.20"),
          unallocated_header_amount: Decimal.new("0.00"),
          source_state: :active,
          detail_status: :complete
        },
        action: :create_normalized,
        domain: Sales
      )

    assert refund.header_amount == Decimal.new("45.50")
    assert refund.shipping_refund_tax == Decimal.new("0.50")

    assert_raise Ash.Error.Invalid, fn ->
      Ash.create!(
        Refund,
        %{source_system_id: source.id, woo_order_id: 10_001, woo_refund_id: 91_002},
        action: :create_reference,
        domain: Sales
      )
    end

    assert_raise Ash.Error.Invalid, fn ->
      Ash.create!(
        Refund,
        %{
          source_system_id: source.id,
          woo_order_id: 10_001,
          woo_refund_id: 91_003,
          header_amount: Decimal.new("-1.00")
        },
        action: :create_normalized,
        domain: Sales
      )
    end
  end

  test "allows only the active and voided source states and detail states" do
    source = SalesHelpers.create_source_system!()

    assert %{source_state: :active, detail_status: :reference_only} =
             create_reference!(source, %{woo_refund_id: 91_004})

    assert_raise Ash.Error.Invalid, fn ->
      Ash.create!(
        Refund,
        %{
          source_system_id: source.id,
          woo_order_id: 10_001,
          woo_refund_id: 91_005,
          source_state: :deleted
        },
        action: :create_normalized,
        domain: Sales
      )
    end

    assert_raise Ash.Error.Invalid, fn ->
      Ash.create!(
        Refund,
        %{
          source_system_id: source.id,
          woo_order_id: 10_001,
          woo_refund_id: 91_006,
          detail_status: :pending
        },
        action: :create_normalized,
        domain: Sales
      )
    end
  end

  test "represents unresolved detail and voiding without a destroy action" do
    source = SalesHelpers.create_source_system!()
    refund = create_reference!(source, %{woo_refund_id: 91_007})

    unresolved =
      Ash.update!(
        refund,
        %{unresolved_reason: "missing_refund_detail"},
        action: :mark_unresolved,
        domain: Sales
      )

    assert unresolved.detail_status == :unresolved
    assert unresolved.unresolved_reason == "missing_refund_detail"

    voided =
      Ash.update!(
        unresolved,
        %{void_reason: "source_absent", voided_at: ~U[2026-05-01 10:00:00Z]},
        action: :mark_voided,
        domain: Sales
      )

    assert voided.source_state == :voided
    assert voided.void_reason == "source_absent"
    assert voided.voided_at == ~U[2026-05-01 10:00:00.000000Z]
  end

  defp create_reference!(source, attrs) do
    defaults = %{source_system_id: source.id, woo_order_id: 10_001, woo_refund_id: 91_000}

    Ash.create!(Refund, Map.merge(defaults, attrs), action: :create_reference, domain: Sales)
  end
end
