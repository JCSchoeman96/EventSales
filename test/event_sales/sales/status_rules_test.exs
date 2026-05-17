defmodule EventSales.Sales.StatusRulesTest do
  use ExUnit.Case, async: true

  alias EventSales.Sales.Resources.{Order, OrderItem}
  alias EventSales.Sales.StatusRules

  test "completed mapped ticket line counts toward sold tickets" do
    order = %Order{status: :completed}
    item = %OrderItem{mapping_status: :mapped, quantity: 2, item_kind: :ticket}

    assert StatusRules.counts_toward_sold_tickets?(order, item)
    assert StatusRules.counts_toward_completed_revenue?(order, item)
    refute StatusRules.excluded_from_sold?(order, item)
  end

  test "pending order is visible but excluded from sold totals" do
    order = %Order{status: :pending}
    item = %OrderItem{mapping_status: :mapped, quantity: 1, item_kind: :ticket}

    assert StatusRules.visible_status?(order, item)
    refute StatusRules.counts_toward_sold_tickets?(order, item)
    assert StatusRules.excluded_from_sold?(order, item)
  end

  test "unmapped or non-ticket lines are excluded even when order is completed" do
    order = %Order{status: :completed}

    pending = %OrderItem{
      mapping_status: :pending_mapping_resolution,
      quantity: 1,
      item_kind: :unknown
    }

    unmapped = %OrderItem{mapping_status: :unmapped, quantity: 1, item_kind: :ticket}
    non_ticket = %OrderItem{mapping_status: :mapped, quantity: 1, item_kind: :non_ticket}

    refute StatusRules.counts_toward_sold_tickets?(order, pending)
    refute StatusRules.counts_toward_sold_tickets?(order, unmapped)
    refute StatusRules.counts_toward_sold_tickets?(order, non_ticket)
  end
end
