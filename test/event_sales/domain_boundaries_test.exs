defmodule EventSales.DomainBoundariesTest do
  use ExUnit.Case, async: true

  @business_domains [
    EventSales.Accounts,
    EventSales.Catalog,
    EventSales.Sales,
    EventSales.Ingestion,
    EventSales.Analytics,
    EventSales.Audit
  ]
  @accounts_resources [
    EventSales.Accounts.Resources.EventAccessGrant.Version,
    EventSales.Accounts.Resources.User,
    EventSales.Accounts.Resources.Role,
    EventSales.Accounts.Resources.UserRole,
    EventSales.Accounts.Resources.EventAccessGrant
  ]
  @catalog_resources [
    EventSales.Catalog.Resources.ProductMapping.Version,
    EventSales.Catalog.Resources.SourceSystem,
    EventSales.Catalog.Resources.Event,
    EventSales.Catalog.Resources.TicketType,
    EventSales.Catalog.Resources.ProductMapping,
    EventSales.Catalog.Resources.EventDashboardSetting
  ]
  @sales_resources [
    EventSales.Sales.Resources.Order,
    EventSales.Sales.Resources.OrderItem,
    EventSales.Sales.Resources.CouponSnapshot
  ]
  @ingestion_resources [
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
  ]
  @analytics_resources [
    EventSales.Analytics.Resources.EventAggregateSnapshot,
    EventSales.Analytics.Resources.DailySalesAggregateSnapshot
  ]
  @audit_resources [
    EventSales.Audit.Resources.AuditLog
  ]
  @accounts_ash_admin_resources [
    EventSales.Accounts.Resources.User,
    EventSales.Accounts.Resources.Role,
    EventSales.Accounts.Resources.UserRole,
    EventSales.Accounts.Resources.EventAccessGrant
  ]
  @hidden_ash_admin_domains [
    EventSales.AshBaseline.Domain,
    EventSales.Catalog,
    EventSales.Sales,
    EventSales.Ingestion,
    EventSales.Analytics,
    EventSales.Audit
  ]

  @forbidden_woocommerce_rest_patterns [
    "WooCommerceClient",
    "Req.",
    "Tesla.",
    "Finch.",
    "HTTPoison.",
    "/wp-json/wc/"
  ]
  @forbidden_tickera_rest_patterns [
    "TickeraAttendeeClient",
    "/tc-api/",
    "tickets_info"
  ]

  test "business Ash domain modules compile and load" do
    for domain <- @business_domains do
      assert Code.ensure_loaded?(domain)
    end
  end

  test "business Ash domains are registered after the baseline domain" do
    configured_domains = Application.fetch_env!(:event_sales, :ash_domains)

    assert configured_domains == [
             EventSales.AshBaseline.Domain,
             EventSales.Accounts,
             EventSales.Catalog,
             EventSales.Sales,
             EventSales.Ingestion,
             EventSales.Analytics,
             EventSales.Audit
           ]
  end

  test "business Ash domains expose only resources owned by completed slices" do
    assert Ash.Domain.Info.resources(EventSales.Accounts) == @accounts_resources
    assert Ash.Domain.Info.resources(EventSales.Catalog) == @catalog_resources

    assert Ash.Domain.Info.resources(EventSales.Sales) == @sales_resources
    assert Ash.Domain.Info.resources(EventSales.Ingestion) == @ingestion_resources
    assert Ash.Domain.Info.resources(EventSales.Analytics) == @analytics_resources

    assert Ash.Domain.Info.resources(EventSales.Audit) == @audit_resources

    for domain <-
          @business_domains --
            [
              EventSales.Accounts,
              EventSales.Catalog,
              EventSales.Sales,
              EventSales.Ingestion,
              EventSales.Analytics,
              EventSales.Audit
            ] do
      assert Ash.Domain.Info.resources(domain) == []
    end
  end

  test "AshAdmin only exposes the Accounts domain and its owned resources" do
    assert AshAdmin.Domain.show?(EventSales.Accounts)

    assert EventSales.Accounts
           |> AshAdmin.Domain.show_resources()
           |> Enum.sort() == Enum.sort(@accounts_ash_admin_resources)

    for domain <- @hidden_ash_admin_domains do
      refute AshAdmin.Domain.show?(domain)
    end

    refute EventSales.Accounts.Resources.EventAccessGrant.Version in AshAdmin.Domain.show_resources(
             EventSales.Accounts
           )

    refute EventSales.Audit.Resources.AuditLog in AshAdmin.Domain.show_resources(
             EventSales.Accounts
           )
  end

  test "web layer does not define Ash resources" do
    assert [] =
             implementation_files("lib/event_sales_web") |> files_containing("use Ash.Resource")
  end

  test "core business modules do not depend on web-layer modules" do
    allowed_files = [
      "lib/event_sales/application.ex"
    ]

    matches =
      implementation_files("lib/event_sales")
      |> Enum.reject(fn path ->
        path
        |> Path.relative_to_cwd()
        |> String.replace("\\", "/")
        |> then(&(&1 in allowed_files))
      end)
      |> files_containing("EventSalesWeb.")

    assert [] = matches
  end

  test "web layer and MappingResolver do not reference WooCommerce REST boundaries" do
    scan_paths =
      implementation_files("lib/event_sales_web") ++
        ["lib/event_sales/catalog/mapping_resolver.ex"]

    for pattern <- @forbidden_woocommerce_rest_patterns do
      assert [] = files_containing(scan_paths, pattern)
    end
  end

  test "dashboard live code does not scan sales rows directly" do
    forbidden_patterns = [
      "EventAggregator",
      "sales_order_items",
      "OrderItem",
      "Repo",
      "WooCommerce"
    ]

    scan_paths = implementation_files("lib/event_sales_web/live/admin")

    for path <- scan_paths,
        path |> Path.basename() |> String.starts_with?("dashboard") do
      for pattern <- forbidden_patterns do
        assert [] = files_containing([path], pattern)
      end
    end
  end

  test "event-scoped dashboard facade remains aggregate-only" do
    forbidden_patterns = [
      "Repo",
      "sales_order_items",
      "sales_orders",
      "OrderItem",
      "Order",
      "WooCommerce",
      "Tickera",
      "EventSalesWeb"
    ]

    scan_path = "lib/event_sales/analytics/event_scoped_dashboard.ex"

    for pattern <- forbidden_patterns do
      assert [] = files_containing([scan_path], pattern)
    end
  end

  test "WooCommerceClient is wired only into approved ingestion REST boundaries" do
    allowed_prefixes = [
      "lib/event_sales/ingestion/clients/"
    ]

    allowed_files = [
      "lib/event_sales/ingestion/workers/missing_catalog_resolution_worker.ex",
      "lib/event_sales/ingestion/workers/reconcile_orders_worker.ex",
      "lib/event_sales/ingestion/order_reconciliation.ex"
    ]

    matches =
      implementation_files("lib/event_sales")
      |> Enum.reject(fn path ->
        normalized =
          path
          |> Path.relative_to_cwd()
          |> String.replace("\\", "/")

        Enum.any?(allowed_prefixes, &String.starts_with?(normalized, &1)) or
          normalized in allowed_files
      end)
      |> files_containing("WooCommerceClient")

    assert [] = matches
  end

  test "Tickera attendee client is wired only into approved production ingestion boundaries" do
    allowed_prefixes = [
      "lib/event_sales/ingestion/clients/"
    ]

    allowed_files = [
      "lib/event_sales/ingestion/tickera_attendee_sync.ex",
      "lib/event_sales/ingestion/tickera_attendee_sync_queue.ex",
      "lib/event_sales/ingestion/workers/sync_tickera_attendees_worker.ex"
    ]

    for pattern <- @forbidden_tickera_rest_patterns do
      matches =
        implementation_files("lib/event_sales")
        |> Enum.reject(fn path ->
          normalized =
            path
            |> Path.relative_to_cwd()
            |> String.replace("\\", "/")

          Enum.any?(allowed_prefixes, &String.starts_with?(normalized, &1)) or
            normalized in allowed_files
        end)
        |> files_containing(pattern)

      assert [] = matches
    end
  end

  test "web layer does not reference Tickera sync worker or REST paths" do
    scan_paths = implementation_files("lib/event_sales_web")

    for pattern <- [
          "SyncTickeraAttendeesWorker",
          "ReconcileTickeraAttendeesWorker",
          "TickeraAttendeeSync",
          "TickeraReconciliation",
          "/tc-api/",
          "tickets_info"
        ] do
      assert [] = files_containing(scan_paths, pattern)
    end
  end

  test "Tickera reconciliation modules do not reference external API clients" do
    scan_paths = [
      "lib/event_sales/ingestion/tickera_reconciliation.ex",
      "lib/event_sales/ingestion/tickera_reconciliation_runs.ex",
      "lib/event_sales/ingestion/tickera_reconciliation_findings.ex",
      "lib/event_sales/ingestion/workers/reconcile_tickera_attendees_worker.ex"
    ]

    for pattern <- @forbidden_woocommerce_rest_patterns ++ @forbidden_tickera_rest_patterns do
      assert [] = files_containing(scan_paths, pattern)
    end
  end

  test "Tickera durable state resources do not store API key fields" do
    resources = [
      EventSales.Ingestion.Resources.TickeraAttendeeSyncRun,
      EventSales.Ingestion.Resources.TickeraAttendeeSnapshot
    ]

    for resource <- resources do
      attribute_names =
        resource
        |> Ash.Resource.Info.attributes()
        |> Enum.map(& &1.name)

      refute :api_key in attribute_names
      refute :tickera_api_key in attribute_names
    end
  end

  defp implementation_files(path) do
    path
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp files_containing(paths, pattern) when is_list(paths) do
    paths
    |> Enum.filter(fn path ->
      path
      |> File.read!()
      |> String.contains?(pattern)
    end)
  end
end
