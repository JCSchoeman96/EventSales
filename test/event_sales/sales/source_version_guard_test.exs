defmodule EventSales.Sales.SourceVersionGuardTest do
  use ExUnit.Case, async: true

  alias EventSales.Sales.SourceVersionGuard

  test "allows update when incoming source timestamp is newer" do
    existing = ~U[2026-05-01 08:00:00Z]
    incoming = ~U[2026-05-01 08:05:00Z]
    assert SourceVersionGuard.allows_update?(existing, incoming)
  end

  test "rejects update when incoming is older or equal" do
    existing = ~U[2026-05-01 08:05:00Z]
    refute SourceVersionGuard.allows_update?(existing, ~U[2026-05-01 08:05:00Z])
    refute SourceVersionGuard.allows_update?(existing, ~U[2026-05-01 08:00:00Z])
  end

  test "allows first write when existing is nil" do
    assert SourceVersionGuard.allows_update?(nil, ~U[2026-05-01 08:00:00Z])
  end
end
