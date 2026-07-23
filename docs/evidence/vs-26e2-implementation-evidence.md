# VS-26E.2 Implementation Evidence

## Authority

- JC-129 baseline: `8610dd882aa7ea0d1a215e9f9abbea0d5303bed1`
- Plan SHA-256: `12a6145d96abdeb4bc6e141396572f1050fae58fe95bcf3de37fab65c33efb2a`
- Pack SHA-256: `4b1b5cc428049690da929c30f755abf85b945f23d974ce78a50059e81e23ef30`
- Supplement SHA-256: `61885c2bd4161bc151cef449a02e059adb081179ff9cf34cefcf1692b6a35589`
- Branch: `feat/vs-26e2-conservative-catalog-auto-apply`
- Implementation code head: `9b39f72` (`Satisfy catalog auto-apply type contracts`)

## Generated database artifacts

- Migration: `priv/repo/migrations/20260723065153_vs_26e2_catalog_auto_apply.exs`
- Migration SHA-256: `ad0570ba2111498048890005c8f3634774ef57b54b079c2b0a97c89a25c8e58e`
- Resource snapshots: SourceSystem, TickeraCatalogSyncRun, TickeraCatalogAutoApplyConfig, TickeraCatalogAutoApplyDecision.
- `mix ash.codegen vs_26e2_catalog_auto_apply --check`: pass; no generated drift.

The migration is additive, retains `legacy_unknown`, creates database uniqueness/check/index enforcement, and does not rewrite historical snapshots or hashes. It was exercised only against the local test database.

## Contract evidence

- Feed v2 parsing persists status, product-type, template, subscription, deletion, and unknown-semantics risk proof.
- The canonicalizer validates the closed v2 snapshot, produces deterministic compact JSON, and stores SHA-256 externally.
- The pure v1 policy has no I/O and rejects findings, history, variations, unsupported actions/origins/versions, and missing risk.
- Decision creation copies source ownership from the locked run.
- Initial enqueue commits decision claim, Oban insertion, and linkage atomically.
- Recovery keeps one job identity, delays same-job retries, bounds batches, and terminates at attempt 20.
- Automatic Apply revalidates decision/configuration/hash/linkage; Human Apply remains on its existing route.
- Admin rendering exposes bounded state/reason codes only and refreshes after durable PubSub notification.

## Disabled-default and privacy evidence

Hard enable defaults false; durable global mode defaults disabled; allowlists and enabled policies default empty. Tests and rendering use closed reason/summary fields and fixed telemetry metadata. No protected payload is stored or rendered by the auto-Apply contract.

## Validation

- Focused catalog/ingestion/admin/assets suites: 141 tests, 0 failures.
- Auto-Apply refactor regression suite: 21 tests, 0 failures.
- Ash resource/domain registration regression: 17 tests, 0 failures.
- `mix credo --strict`: pass, no issues.
- `mix project.index --check`: pass.
- `bash scripts/check_no_web_woocommerce_refs.sh`: pass.
- `mix assets.build`: pass.
- Full local CI (`bash scripts/local_ci.sh`): pass.
  - ExUnit: 1,088 tests, 0 failures.
  - Credo: no issues.
  - Dialyzer: 0 errors.
  - Ash codegen check, project index, compile/format, and WooCommerce web-boundary checks: pass.

Local test-database `EXPLAIN` was captured for recovery, latest-decision-by-run, and recent-source-decision queries. The empty local tables led PostgreSQL to prefer sequential scans on cost; the migration contains the reviewed identity, source-recent, and partial recovery indexes. Non-empty staging `EXPLAIN` evidence remains a later activation requirement and was not fabricated locally.

The draft PR records the final branch head and complete commit list. The implementation code head above is immutable; the later evidence-only commit changes no runtime behavior.

## Prohibited actions

No deployment, shared migration, Railway/WordPress/configuration mutation, observation mode, canary, shared Catalog Sync, or shared Apply was performed.
