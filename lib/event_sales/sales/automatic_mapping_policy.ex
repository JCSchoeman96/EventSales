defmodule EventSales.Sales.AutomaticMappingPolicy do
  @moduledoc "Pure eligibility policy for automatic OrderItem mapping."

  @supported_statuses [
    :pending,
    :processing,
    :on_hold,
    :completed,
    :cancelled,
    :refunded,
    :failed
  ]

  @type eligibility :: :eligible | :deferred

  @spec supported_statuses() :: [atom()]
  def supported_statuses, do: @supported_statuses

  @spec classify_order_status(term()) ::
          {:ok, eligibility()} | {:error, :unsupported_order_status}
  def classify_order_status(:on_hold), do: {:ok, :deferred}

  def classify_order_status(status) when status in @supported_statuses,
    do: {:ok, :eligible}

  def classify_order_status(_status), do: {:error, :unsupported_order_status}
end
