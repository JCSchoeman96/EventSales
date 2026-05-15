defmodule EventSales.Catalog do
  @moduledoc """
  Ash domain boundary for source systems, events, ticket types, mappings, and dashboard settings.
  """

  use Ash.Domain,
    extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource EventSales.Catalog.Resources.SourceSystem
    resource EventSales.Catalog.Resources.Event
    resource EventSales.Catalog.Resources.TicketType
    resource EventSales.Catalog.Resources.ProductMapping
    resource EventSales.Catalog.Resources.EventDashboardSetting
  end
end
