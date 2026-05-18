defmodule EventSales.Analytics do
  @moduledoc """
  Ash domain boundary for metric rules, hot state, cache facades, snapshots, and reporting.

  Slice 1.0 registers the domain boundary only. Resources are added by their owning slices.
  """

  use Ash.Domain

  resources do
    resource EventSales.Analytics.Resources.EventAggregateSnapshot
    resource EventSales.Analytics.Resources.DailySalesAggregateSnapshot
  end
end
