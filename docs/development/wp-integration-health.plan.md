# WP-SOURCE-02 — WordPress integration readiness and version health

**Plan ID:** wp-integration-health

**Plan version:** v3

**Status:** active

**Scope:** Read-only Site Health observability for EventSales WordPress producer plugins

**Authority:** This file is the active contract for WP-SOURCE-02 (JC-311).

**Last updated:** 2026-10-02

**Change summary (v3):** Reconnaissance text matches the six-field Site Health test callback result.

### Revision log

- `v1` — reconnaissance complete; health states, guards, and implementation paths locked.
- `v2` — READY requires non-empty contract constants; sender lifecycle tied to catalog producer; Site Health callbacks return `badge` and `test`.
- `v3` — Site Health reconnaissance documents full callback result (`badge`, `test`), not the obsolete four-field shape.

## Goal

Give administrators a safe, read-only view of EventSales WordPress integration readiness via native Site Health and debug information. No new REST routes, no network probes, no writes.

## Accepted base

- **Branch:** `parallel/wp-integration-health`
- **Worktree:** `/home/jcschoeman96/projects/worktrees/EventSales-wp-integration-health`
- **Base SHA:** `89c19bacbb48b29b0e372d31fa544f316de029e8` (`origin/main` at worktree creation)

## Reconnaissance (locked)

### Site Health extension points

- `site_status_tests` filter receives `$tests` with groups `direct` and `async`. EventSales adds **direct** tests only (no cron, no remote I/O).
- Each direct test callback returns a completed Site Health result with: `label`, `status` (`good`|`recommended`|`critical`), `badge` (`label`, `color`), `description`, `actions`, and stable `test` (unique id such as `eventsales_catalog_feed`).
- `debug_information` filter receives `$info` sections; EventSales adds section `eventsales` with nested `fields` (label/value, no secrets).

### Installed vs active

- **Installed:** `get_plugins()` contains the plugin basename key and the file exists under `WP_PLUGIN_DIR`.
- **Active:** `is_plugin_active($basename)` (requires `wp-admin/includes/plugin.php` in real WP; tests mock via `$GLOBALS['active_plugins']`).
- **Loaded contract:** `class_exists` on the integration final class confirms runtime load when active.

### Plugin basenames (exact)

| Integration | Basename |
|-------------|----------|
| Tickera catalog feed | `eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php` |
| Woo order index feed | `eventsales-woo-order-index-feed/eventsales-woo-order-index-feed.php` |
| Woo order line identity | `eventsales-woo-order-line-identity/eventsales-woo-order-line-identity.php` |

### Marketing versions (plugin headers)

| Plugin | Version |
|--------|---------|
| Tickera catalog feed | `0.1.0` |
| Woo order index feed | `0.2.0` |
| Woo order line identity | `0.1.0` |

### Contract constants (runtime, when plugin loaded)

| Source | Constants |
|--------|-----------|
| Catalog | `EVENTSALES_TICKERA_CATALOG_SCHEMA_VERSION` (`2026-08-07.v3`), `EVENTSALES_TICKERA_CATALOG_CANONICAL_CONTRACT_VERSION` (`source_risk.v3`), `EVENTSALES_TICKERA_CATALOG_PRODUCER_VERSION` (`2026-08-07.1`) |
| Order index | `EVENTSALES_WOO_ORDER_INDEX_SCHEMA_VERSION` (`2026-08-12.v1`) |
| Order line identity | none (by design) |

### Authentication precedence (boolean presence only)

| Boundary | Precedence |
|----------|------------|
| Catalog feed | `EVENTSALES_TICKERA_CATALOG_SECRET` constant, else option `eventsales_tickera_catalog_secret` |
| Order index | `EVENTSALES_WOO_ORDER_INDEX_KEY_ID` + `EVENTSALES_WOO_ORDER_INDEX_SECRET` constants, else options `eventsales_woo_order_index_key_id` and `eventsales_woo_order_index_secret` (option names from `EventSales_Woo_Order_Index_Feed::key_id_option_name()` / `secret_option_name()` when class exists) |
| Catalog-change sender | Constants only: `EVENTSALES_CATALOG_CHANGE_ENDPOINT`, `EVENTSALES_CATALOG_CHANGE_KEY_ID`, `EVENTSALES_CATALOG_CHANGE_SECRET`; gated by `EVENTSALES_CATALOG_CHANGE_SENDER_ENABLED` |

### Order index storage (read-only)

- Tables: `{prefix}eventsales_order_manifests`, `{prefix}eventsales_order_manifest_items` (see `EventSales_Woo_Order_Index_Manifest_Store`).
- Created on plugin activation via `install_schema`; not auto-created on every request.
- Health uses bounded `SHOW TABLES LIKE %s` per table name; no row reads.

### WooCommerce dependency

- `class_exists('WooCommerce')` or `defined('WC_VERSION')` after Woo bootstrap.

### Tickera event capability

- `post_type_exists('tc_events')` aligned with `EventSales_Tickera_Event_Resolver::POST_TYPE_EVENT`.

### Action Scheduler (catalog-change sender)

- Enqueue path: `as_enqueue_async_action` (`flush_catalog_changes`).
- Retry path: `as_schedule_single_action` (`deliver_catalog_change`).
- Health `scheduler_available` requires both functions when sender is enabled.

## Health state vocabulary

`ABSENT` | `INACTIVE` | `DISABLED` | `MISCONFIGURED` | `DEPENDENCY_UNAVAILABLE` | `READY`

Observational only; no durable writes.

### Catalogue feed

| Status | Guard |
|--------|-------|
| ABSENT | not installed |
| INACTIVE | installed, not active / class not loaded |
| MISCONFIGURED | active, `authentication_configured` false |
| DEPENDENCY_UNAVAILABLE | active, auth ok, any contract constant missing or empty |
| READY | active, auth configured, all three contract constants non-empty |

### Catalogue-change sender

| Status | Guard |
|--------|-------|
| ABSENT | catalog producer not installed |
| INACTIVE | catalog installed but not active/loaded |
| DISABLED | catalog active/loaded and sender flag false |
| MISCONFIGURED | catalog active, sender enabled, endpoint/key/secret incomplete |
| DEPENDENCY_UNAVAILABLE | catalog active, sender enabled and configured, scheduler unavailable |
| READY | catalog active, sender enabled and configured, scheduler available |

### Order index feed

| Status | Guard |
|--------|-------|
| ABSENT | not installed |
| INACTIVE | installed, not active |
| MISCONFIGURED | active, auth incomplete |
| DEPENDENCY_UNAVAILABLE | active, auth ok, tables missing or schema constant missing/empty |
| READY | active, auth ok, tables present, schema constant non-empty |

### Order line identity

| Status | Guard |
|--------|-------|
| ABSENT | not installed |
| INACTIVE | installed, not active |
| DEPENDENCY_UNAVAILABLE | active, Woo or `tc_events` capability missing |
| READY | active, Woo and `tc_events` available |

## Producer modification

None required. Health observes public WordPress APIs and runtime constants/classes.

## Implementation paths

```text
integrations/wordpress/eventsales-integration-health/
docs/development/wp-integration-health.plan.md
docs/ops/wordpress-integration-health.md
```

## Tests

`integrations/wordpress/eventsales-integration-health/tests/integration-health-test.php` plus existing producer suites unchanged.
