# EventSales — Hardened V2.1 Folder Structure

This V2.1 structure hardens the remaining gaps: explicit Repo/Release modules, PgBouncer/Oban topology support, raw-body webhook verification, replay guard, intake rate limiting, out-of-order webhook support, and richer operational docs.

```text
lib/
  event_sales/
    application.ex
    repo.ex
    release.ex
    telemetry.ex

    accounts/
      resources/
        user.ex
        role.ex
        user_role.ex
        event_access_grant.ex
      policies.ex
      pii_policy.ex
      auth_overrides.ex

    catalog/
      resources/
        source_system.ex
        event.ex
        ticket_type.ex
        product_mapping.ex
        event_dashboard_setting.ex
      mapping_resolver.ex
      missing_catalog_resolver.ex
      product_metadata_cache.ex
      product_metadata_updater.ex

    sales/
      resources/
        order.ex
        order_item.ex
        coupon_snapshot.ex
      order_upserter.ex
      order_item_mapper.ex
      status_rules.ex
      source_version_guard.ex

    ingestion/
      resources/
        webhook_event.ex
        webhook_delivery_failure.ex
        sync_run.ex
        sync_cursor.ex
        csv_import_batch.ex
        csv_import_row.ex
      workers/
        process_webhook_worker.ex
        missing_catalog_resolution_worker.ex
        reconcile_orders_worker.ex
        backfill_orders_worker.ex
        process_csv_import_worker.ex
        redis_webhook_buffer_drainer.ex
        purge_raw_payloads_worker.ex
      clients/
        woocommerce_client.ex
        woocommerce_error.ex
      security/
        raw_body_reader.ex
        webhook_signature.ex
        webhook_replay_guard.ex
      parsers/
        woocommerce_order_parser.ex
      handlers/
        product_updated_handler.ex
      csv/
        parser.ex
        dry_run_validator.ex
        apply_import.ex
      redis_webhook_buffer.ex
      webhook_processor.ex
      webhook_replay.ex
      intake_backpressure.ex
      rest_rate_limiter.ex
      rest_circuit_breaker.ex

    analytics/
      resources/
        event_aggregate_snapshot.ex
        daily_sales_aggregate_snapshot.ex
      workers/
        rebuild_hot_state_worker.ex
        refresh_snapshot_worker.ex
      aggregators/
        event_aggregator.ex
      aggregate_event.ex
      aggregate_event_idempotency.ex
      hot_state_aggregator.ex
      dashboard_cache.ex
      cache_keys.ex
      metric_rules.ex
      snapshot_queries.ex

    audit/
      resources/
        audit_log.ex
      logger.ex
      paper_trail.ex
      metadata_sanitizer.ex

    exports/
      event_sales_csv.ex

    maintenance/
      cache_cleanup_worker.ex
      db_topology_check_worker.ex

  event_sales_web/
    telemetry.ex
    router.ex

    auth/
      routes.ex
      hooks.ex

    controllers/
      auth_controller.ex
      webhook_controller.ex
      export_controller.ex

    live/
      auth/
        sign_in_live.ex
        reset_password_live.ex
      admin/
        dashboard_live.ex
        events_live.ex
        event_detail_live.ex
        orders_live.ex
        mappings_live.ex
        webhooks_live.ex
        sync_live.ex
        imports_live.ex
      components/
        stat_card.ex
        status_badge.ex
        sales_chart.ex
        order_table.ex
        unmapped_item_alert.ex
        stale_data_banner.ex

    plugs/
      admin_only.ex
      load_current_user.ex
      rate_limit_manual_actions.ex
      rate_limit_webhook_intake.ex

    presenters/
      customer_presenter.ex

config/
  config.exs
  dev.exs
  prod.exs
  runtime.exs
  test.exs

rel/
  overlays/

scripts/
  smoke_test_oban_topology.exs
  smoke_test_webhook_signature.exs
  smoke_test_railway_release.sh

docs/
  architecture/
    overview.md
    domain-map.md
    telemetry.md
    historical-reporting.md
    cache-invalidation.md
    state-machines.md
    webhook-security.md
    idempotency-and-ordering.md
    fixture-verification.md
    db-topology.md
    oban-pgbouncer.md
  deployment/
    railway.md
    pgbouncer.md
    migrations-and-release.md
    runtime-config.md
  runbooks/
    production-smoke-test.md
    webhook-troubleshooting.md
    event-launch-checklist.md
    reconciliation.md
    csv-import.md
    security.md
    incident-response.md
    oban-queue-backlog.md
    redis-buffer-recovery.md

test/
  event_sales/
    accounts/
    catalog/
    sales/
      source_version_guard_test.exs
    ingestion/
      raw_body_signature_test.exs
      webhook_replay_guard_test.exs
      rest_rate_limiter_test.exs
      rest_circuit_breaker_test.exs
    analytics/
      aggregate_event_idempotency_test.exs
    audit/
    exports/
    maintenance/
    e2e/
      webhook_to_dashboard_test.exs
  event_sales_web/
    auth/
    controllers/
    live/
    plugs/
      rate_limit_webhook_intake_test.exs
  fixtures/
    woocommerce/
      order_completed.json
      order_pending.json
      order_refunded.json
      order_mixed_event.json
      order_with_non_ticket_item.json
      order_with_unknown_product.json
      order_out_of_order_older_update.json
      order_out_of_order_newer_update.json
      product_updated.json
      product_variation_updated.json
      product_missing_then_recovered.json
    csv/
      import_valid.csv
      import_invalid.csv
      import_duplicate_rows.csv
      import_unknown_mapping.csv
  support/
    woocommerce_webhook_helpers.ex
    oban_helpers.ex
    auth_helpers.ex
    telemetry_helpers.ex
    fixture_helpers.ex
    db_topology_helpers.ex
```

## V2 Boundary Rules

```text
Ash resources live under lib/event_sales/*/resources.
LiveViews and controllers live only under lib/event_sales_web.
No controller calls WooCommerce REST.
WooCommerce REST code lives only under ingestion/clients and is called only by workers/service modules.
Webhook signature verification must use raw request body bytes.
MappingResolver must not call WooCommerce REST.
HotStateAggregator must not be the durable source of truth.
Redis/ETS/Cachex integration lives behind analytics/cache modules.
AshAdmin and Oban Web must be protected and internal-only.
Auth/session plumbing must use AshAuthentication conventions unless a proven limitation blocks it.
PgBouncer transaction mode must be treated as an explicit compatibility decision, not a default assumption.
```

## Fixture Catalogue Rules

- JSON fixtures must be representative of real WooCommerce payloads but sanitized.
- Include out-of-order webhook fixtures to test stale update protection.
- CSV fixtures must include valid, invalid, duplicate, and unknown-mapping cases.
- Fixtures must never include real customer data, production secrets, or live WordPress URLs.


## V2.1 Runtime Configuration Additions

```text
EVENTSALES_BUSINESS_TIMEZONE=Africa/Johannesburg
EVENTSALES_DEFAULT_CURRENCY=ZAR
```

These values must be read from runtime configuration and used by metric rules, date-bucketed snapshots, dashboard “today” metrics, and exports.

## V2.1 Payload Verification Additions

Add `docs/architecture/fixture-verification.md` to record sanitized real WooCommerce/Tickera payload checks before parser implementation. The fixture catalogue must be compared against real payloads for completed, pending, refunded, mixed-event, variation, non-ticket, product update, and variation update cases.

## V2.1 REST Boundary Clarification

```text
No LiveView, component, controller, or MappingResolver may call WooCommerce REST.
Only Oban workers and approved ingestion service modules may call WooCommerceClient.
The webhook controller receives WooCommerce webhooks but must not call WooCommerce REST.
```
