defmodule EventSales.AshResourceSmokeTest do
  use ExUnit.Case, async: true

  @business_domains [
    EventSales.Accounts,
    EventSales.Catalog,
    EventSales.Sales,
    EventSales.Ingestion,
    EventSales.Analytics,
    EventSales.Audit
  ]

  @expected_resources_by_domain %{
    EventSales.Accounts => [
      EventSales.Accounts.Resources.EventAccessGrant.Version,
      EventSales.Accounts.Resources.User,
      EventSales.Accounts.Resources.Role,
      EventSales.Accounts.Resources.UserRole,
      EventSales.Accounts.Resources.EventAccessGrant
    ],
    EventSales.Catalog => [
      EventSales.Catalog.Resources.ProductMapping.Version,
      EventSales.Catalog.Resources.SourceSystem,
      EventSales.Catalog.Resources.Event,
      EventSales.Catalog.Resources.TicketType,
      EventSales.Catalog.Resources.ProductMapping,
      EventSales.Catalog.Resources.EventDashboardSetting
    ],
    EventSales.Sales => [
      EventSales.Sales.Resources.Order,
      EventSales.Sales.Resources.OrderItem,
      EventSales.Sales.Resources.CouponSnapshot
    ],
    EventSales.Ingestion => [
      EventSales.Ingestion.Resources.WebhookEvent,
      EventSales.Ingestion.Resources.WebhookDeliveryFailure,
      EventSales.Ingestion.Resources.SyncRun,
      EventSales.Ingestion.Resources.SyncCursor,
      EventSales.Ingestion.Resources.TickeraEventSource,
      EventSales.Ingestion.Resources.TickeraAttendeeSyncRun,
      EventSales.Ingestion.Resources.TickeraAttendeeSnapshot,
      EventSales.Ingestion.Resources.TickeraReconciliationRun,
      EventSales.Ingestion.Resources.TickeraReconciliationFinding,
      EventSales.Ingestion.Resources.CsvImportBatch,
      EventSales.Ingestion.Resources.CsvImportRow
    ],
    EventSales.Analytics => [
      EventSales.Analytics.Resources.EventAggregateSnapshot,
      EventSales.Analytics.Resources.DailySalesAggregateSnapshot
    ],
    EventSales.Audit => [
      EventSales.Audit.Resources.AuditLog
    ]
  }

  test "configured business Ash domains compile and load" do
    configured_domains = Application.fetch_env!(:event_sales, :ash_domains)

    for domain <- @business_domains do
      assert domain in configured_domains
      assert Code.ensure_loaded?(domain)
    end
  end

  test "critical shipped resources are registered in their domains" do
    for {domain, expected_resources} <- @expected_resources_by_domain do
      assert Ash.Domain.Info.resources(domain) == expected_resources
    end
  end

  test "registered resources expose basic read actions" do
    for domain <- @business_domains,
        resource <- Ash.Domain.Info.resources(domain) do
      assert Ash.Resource.Info.action(resource, :read, :read),
             "#{inspect(resource)} must expose a read action"
    end
  end
end
