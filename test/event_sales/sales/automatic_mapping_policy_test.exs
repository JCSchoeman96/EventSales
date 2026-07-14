defmodule EventSales.Sales.AutomaticMappingPolicyTest do
  use ExUnit.Case, async: true

  alias EventSales.Sales.AutomaticMappingPolicy

  test "defers on-hold and permits every other supported Order status" do
    assert {:ok, :deferred} = AutomaticMappingPolicy.classify_order_status(:on_hold)

    for status <- AutomaticMappingPolicy.supported_statuses() -- [:on_hold] do
      assert {:ok, :eligible} = AutomaticMappingPolicy.classify_order_status(status)
    end
  end

  test "rejects unsupported input explicitly" do
    assert {:error, :unsupported_order_status} =
             AutomaticMappingPolicy.classify_order_status(:unknown)
  end
end
