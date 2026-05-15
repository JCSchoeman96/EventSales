defmodule EventSales.Sales.SourceVersionGuard do
  @moduledoc """
  Source version checks for durable sales writes.

  Slice 4.0 implements only `allows_update?/2` — a `DateTime` comparison used by
  `Order.sync_status_from_source`.

  Slice 6.0 still owns delivery ID, payload hash, webhook idempotency, replay
  guards, and any broader source-version strategy. Do not add those concerns here
  during Slice 4.0.
  """

  @doc """
  Returns true when an incoming source timestamp may replace the stored value.

  `existing` may be `nil` for first-write paths.
  """
  @spec allows_update?(DateTime.t() | nil, DateTime.t()) :: boolean()
  def allows_update?(nil, %DateTime{}), do: true

  def allows_update?(%DateTime{} = existing, %DateTime{} = incoming) do
    DateTime.compare(incoming, existing) == :gt
  end

  def allows_update?(_existing, _incoming), do: false
end
