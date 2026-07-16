# VS-26E.0 File Inventory

Baseline: `050d66e88d55270655833cd9c9b51476a4bfefeb`

## Mandatory read — governance and product

- `AGENTS.md`
- `docs/agent/01_PROJECT_WIDE_RULES.md`
- `docs/EventSales_Hardened_V2_1_Vertical_Slice_Roadmap.md`
- `docs/EventSales_Hardened_V2_1_Folder_Structure.md`
- `docs/EventSales_Hardened_V2_1_Domain_Mapping_Ash_Resource_Dossiers.md`
- `docs/roadmap/EVENTSALES_LIVE_SALES_PROGRAMME.md`
- `docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md`
- `docs/roadmap/EVENTSALES_LIVE_SALES_KANBAN.md`
- `docs/feature_packs/EVENTSALES_FEATURE_PACK_STANDARD.md`

## Mandatory read — deployment/database

- `railway.toml`
- `Dockerfile`
- `config/config.exs`
- `config/runtime.exs`
- `lib/event_sales/release.ex`
- `docs/deployment/railway.md`
- `docs/deployment/runtime-config.md`
- `docs/deployment/migrations-and-release.md`
- `docs/deployment/pgbouncer.md`
- `docs/architecture/db-topology.md`
- `docs/architecture/oban-pgbouncer.md`
- `docs/runbooks/database-backup-restore.md`
- `docs/runbooks/production-smoke-test.md`
- `scripts/smoke_test_railway_release.sh`
- `scripts/smoke_test_oban_topology.exs`

## Mandatory read — Catalog Sync

- `lib/event_sales/ingestion/resources/tickera_catalog_sync_run.ex`
- `lib/event_sales/ingestion/resources/tickera_catalog_sync_finding.ex`
- `lib/event_sales/ingestion/tickera_catalog_sync.ex`
- `lib/event_sales/ingestion/workers/discover_tickera_catalog_worker.ex`
- `lib/event_sales/ingestion/workers/apply_tickera_catalog_worker.ex`
- `lib/event_sales/catalog/tickera_catalog/planner.ex`
- `lib/event_sales/catalog/tickera_catalog/applier.ex`
- `lib/event_sales/catalog/tickera_catalog/configured_discovery_source.ex`
- `lib/event_sales/catalog/tickera_catalog/wordpress_feed_discovery_source.ex`
- `lib/event_sales/catalog/tickera_catalog/pub_sub.ex`
- `lib/event_sales_web/live/admin/catalog_sync_live.ex`
- `docs/ops/tickera_catalog_feed_eventsales_adapter.md`
- `integrations/wordpress/eventsales-tickera-catalog-feed/README.md`

## Mandatory read — migrations

- `priv/repo/migrations/20260703090000_vs_26a_tickera_catalog_sync.exs`
- `priv/repo/migrations/20260713100621_vs_26a_catalog_dry_run_revocation.exs`
- `priv/repo/migrations/20260714100000_add_catalog_sync_retry_metadata.exs`
- `priv/repo/migrations/20260714100100_add_catalog_sync_active_run_index.exs`

## Mandatory read — tests

- `test/event_sales/release_test.exs`
- `test/event_sales/ingestion/tickera_catalog_sync_test.exs`
- `test/event_sales/ingestion/tickera_catalog_sync_concurrency_test.exs`
- `test/event_sales/ingestion/workers/discover_tickera_catalog_worker_test.exs`
- `test/event_sales/ingestion/workers/apply_tickera_catalog_worker_test.exs`
- `test/event_sales/catalog/tickera_catalog/planner_applier_test.exs`
- `test/event_sales/catalog/mapping_conflict_resolver_test.exs`
- `test/event_sales_web/live/admin/catalog_sync_live_test.exs`
- `test/support/catalog_sync_run_helpers.ex`

## Architecture/index references

- `INDEX.md`
- `docs/architecture/domain_map.json`
- `docs/architecture/module_manifest.json`

## Expected create in pack PR

Only files under:

`docs/feature_packs/0001_VS-26E.0_catalog-lifecycle-production-baseline/`

## Expected modify in pack PR

None outside the pack folder.

## Generated locally / attached externally

- `EventSales_VS-26E.0_v1.0.0_050d66e8.zip`
- external ZIP SHA-256 record
- optional redacted evidence produced later

Do not commit production evidence or ZIP binaries unless the repository owner explicitly chooses that policy. The canonical Markdown/JSON source is committed; the ZIP is attached to Linear and linked from the PR/issue.

## Explicitly forbidden in the pack PR

- `lib/**`
- `config/**`
- `priv/repo/migrations/**`
- `assets/**`
- `test/**`
- `integrations/wordpress/**` runtime changes
- `mix.exs`
- `mix.lock`
- `railway.toml`
- `Dockerfile`
- secrets, `.env`, production exports, raw payloads, screenshots

A discovered need to touch a forbidden path is a blocker requiring a separately scoped corrective PR.
