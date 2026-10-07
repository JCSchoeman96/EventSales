# WP-SOURCE-08 verified package delivery plan

Plan ID: JC-328  
Plan version: v1  
Status: implemented on branch `parallel/wp-verified-package-delivery`  
Scope: EventSales WordPress native manual updates with immutable release verification  
Last updated: 2026-10-07  
Authority: Linear JC-328; supersedes notification-only assumptions in WP-SOURCE-06 docs where they conflict on installability

### Revision log

- v1 — initial plan aligned to JC-328 implementation

## Goal

Allow WordPress administrators to run **Update now** for EventSales plugins only when the offered package is a verified sentinel tied to an immutable GitHub release asset whose SHA-256 matches `release-manifest.json`.

## Non-goals

- No new GitHub release, tag, or publication from this slice
- No EventSales background auto-updates
- No Phoenix or analytics changes

## Architecture

- **Notification authority** (JC-320): `update_plugins_github.com` may still report newer versions from `releases/latest` without `package`.
- **Execution authority** (WP-SOURCE-08): `package` is set only when `immutable=true` and the eight-asset release contract plus per-ZIP digest checks pass.
- **Sentinel**: `eventsales-verified://<github-release-id>/<asset-id>/<slug>` (non-network; intercepted by `upgrader_pre_download`).
- **Click-time revalidation**: fetch release by ID, re-check immutable + manifest + asset digest, stream download, `hash_file` before returning a temp path to `Plugin_Upgrader`.
- **Auto-update denial**: `auto_update_plugin` returns `false` for EventSales basenames only.

## Validation

```bash
php integrations/wordpress/eventsales-integration-health/tests/update-discovery-test.php
php integrations/wordpress/eventsales-integration-health/tests/verified-package-delivery-test.php
bash scripts/ci_wordpress_plugin_distribution.sh
```
