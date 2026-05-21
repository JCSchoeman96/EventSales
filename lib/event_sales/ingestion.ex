defmodule EventSales.Ingestion do
  @moduledoc """
  Ash domain boundary for webhooks, syncs, imports, replay, and external ingestion boundaries.

  Slice 1.0 registers the domain boundary only. Resources are added by their owning slices.
  """

  use Ash.Domain

  resources do
    resource EventSales.Ingestion.Resources.WebhookEvent
    resource EventSales.Ingestion.Resources.WebhookDeliveryFailure
    resource EventSales.Ingestion.Resources.SyncRun
    resource EventSales.Ingestion.Resources.SyncCursor
    resource EventSales.Ingestion.Resources.TickeraEventSource
    resource EventSales.Ingestion.Resources.TickeraAttendeeSyncRun
    resource EventSales.Ingestion.Resources.TickeraAttendeeSnapshot
    resource EventSales.Ingestion.Resources.TickeraReconciliationRun
    resource EventSales.Ingestion.Resources.TickeraReconciliationFinding
    resource EventSales.Ingestion.Resources.CsvImportBatch
    resource EventSales.Ingestion.Resources.CsvImportRow
  end
end
