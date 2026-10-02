defmodule EventSales.Analytics do
  @moduledoc """
  Ash domain boundary for metric rules, hot state, cache facades, snapshots, and reporting.

  Slice 1.0 registers the domain boundary only. Resources are added by their owning slices.
  """

  use Ash.Domain

  resources do
    resource EventSales.Analytics.Resources.EventAggregateSnapshot
    resource EventSales.Analytics.Resources.DailySalesAggregateSnapshot
    resource EventSales.Analytics.Resources.EventSourceFreshnessSnapshot
    resource EventSales.Analytics.Resources.EventDimensionAggregateSnapshot
    resource EventSales.Analytics.Resources.EventPeriodAggregateSnapshot
    resource EventSales.Analytics.Resources.EventDimensionPeriodAggregateSnapshot
    resource EventSales.Analytics.Resources.AnalyticsContributionFact
  end
end
