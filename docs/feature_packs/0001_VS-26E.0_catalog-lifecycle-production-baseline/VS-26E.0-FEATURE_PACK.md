# VS-26E.0 — Catalog Lifecycle Deployment and Baseline Certification

## 1. Identity

| Field | Value |
|---|---|
| Slice | `VS-26E.0` |
| Pack | `0001_VS-26E.0` |
| Version | `1.1.0` |
| Status | `review_ready` |
| Repository | `JCSchoeman96/EventSales` |
| Baseline | `main` at `050d66e88d55270655833cd9c9b51476a4bfefeb` |
| GitHub | roadmap `#113`; pack `#114`; canonical PR `#117` |
| Linear | parent `JC-105`; pack `JC-106`; review `JC-107` |
| Successor | VS-26E.1 targeted WordPress catalog-change trigger |

Version 1.1.0 supersedes the unapproved v1.0.0 draft. Independent review found that merging the pack PR would itself trigger Railway deployment and pre-deploy migration before the planning gate. v1.0.0 must not be supplied to an agent.

## 2. Outcome

Certify the Catalog Sync lifecycle already merged in PR #111 before automatic catalog triggers, schedules, or auto-apply increase its production blast radius.

```text
authorised main
-> read-only Railway/database/source preflight
-> reviewed deployment and migration decision
-> migration/index/queue verification
-> one controlled public full-feed dry-run
-> human findings and exact-hash review
-> separate Apply or no-go decision
-> post-Apply catalog verification
-> independent evidence certification
```

A successful deployment or green CI is not certification. The slice is complete only when redacted operational evidence proves the baseline or records a safe no-go.

## 3. Critical merge boundary

The owner confirmed that merging a GitHub PR deploys EventSales to Railway. `railway.toml` runs `EventSales.Release.migrate_and_bootstrap/0` as the pre-deploy command.

Therefore:

- PR #117 remains open during `JC-107`, `JC-108`, and `JC-109`.
- The planning agent uses the approved immutable ZIP against baseline `050d66e88d55270655833cd9c9b51476a4bfefeb`.
- The pack files do not need to be merged for planning.
- Independent pack approval is not merge approval.
- Merging PR #117 is a named production deployment/migration action that `JC-109` must explicitly authorise.

## 4. Current repository truth

### Railway and database

- `railway.toml` runs migration/bootstrap before activation, starts the release, and checks `/health`.
- `EventSales.Release.migrate/0` prefers `DIRECT_DATABASE_URL`; fallback to `DATABASE_URL` is allowed only when the runtime path is documented safe.
- Repository docs describe Railway-managed Postgres without an intentionally introduced PgBouncer, but live topology is still unknown.
- PR #111 added:
  - `20260714100000_add_catalog_sync_retry_metadata.exs`
  - `20260714100100_add_catalog_sync_active_run_index.exs`
- The active-run migration disables the DDL transaction, checks for duplicate active runs, and creates the concurrent partial unique index `ingestion_tickera_catalog_sync_runs_one_active_per_source_idx`.
- Active statuses are `queued`, `discovering`, `retry_scheduled`, `dry_run_ready`, and `applying`.

### Catalog Sync lifecycle

- `TickeraCatalogSync.queue_dry_run/2` is global-admin-only.
- Run creation and real Oban insertion occur in one database transaction.
- The `tickera_sync` queue has concurrency one.
- `DiscoverTickeraCatalogWorker` has three attempts and unique `run_id` execution protection.
- Retry ownership is generation-fenced; stale attempts cannot finalise a newer owner.
- Findings are atomically replaced and a deterministic plan snapshot/hash is stored.
- `ApplyTickeraCatalogWorker` receives only run id and exact dry-run hash.
- `Applier.apply/3` verifies status, exact hash, stored snapshot, and blocking findings before transactional catalog writes.
- Apply uses the reviewed stored snapshot and does not re-fetch WordPress.
- Apply may create, adopt, update, or reuse Events and TicketTypes and create ProductMappings.
- Cache invalidation, PubSub, and missing-catalog recovery are post-commit effects; Postgres remains truth.

### WordPress catalog feed

- Endpoint: `/wp-json/eventsales/v1/tickera-catalog`.
- Current documented schema: `2026-07-08.v1`; temporary compatibility: `2026-07-05.v1`.
- Authentication uses a dedicated HMAC secret and timestamp with a five-minute skew limit.
- Full pagination is aggregated before planning.
- Required runtime settings are the feed-enabled flag, base URL, and dedicated secret; optional settings bound timeout, page size, and page count.
- The feed excludes customer, order, payment, delivery, QR, token, and raw provider payload data.
- The public baseline excludes private events by default. Private-event lifecycle automation is a later contract.

### Confirmed operational facts

- EventSales and PostgreSQL run on Railway.
- Production WordPress/Tickera is active and already sends webhooks to EventSales.
- Current EventSales data is real but does not need to be preserved.
- Approximately twenty events are live/public.
- Catalog Sync was probably attempted before, but no certified baseline exists.
- The intended first operation is a production dry-run with a possible separately approved Apply.

### Unknowns that must not be guessed

- live pooler/proxy topology;
- whether `DIRECT_DATABASE_URL` exists and is safe;
- whether both PR #111 migrations ran;
- whether the partial unique index exists and is valid;
- duplicate active runs or stale/retryable Oban jobs;
- exact product, variation, membership, subscription, payment-plan, bundle, and add-on counts;
- the deployment/migration outcome caused by PR #112;
- active WordPress plugin/feed schema and variable pairing;
- current Event, TicketType, and ProductMapping counts.

## 5. Product decisions protected

- Tickera event is the primary event identity.
- This baseline concerns live/public events.
- Draft/private records must not be silently certified as current public truth.
- Only completed orders count as sales; this slice does not change order metrics.
- Existing data may be reset later, but no reset or cleanup is authorised here.
- Backfill, dashboards, roles, acquisition dimensions, targets, notifications, private-event automation, and WordPress write-back remain out of scope.
- Catalog certification does not prove complete sales history or target-alert eligibility.

## 6. Dependencies and blockers

Available:

- PR #111 and PR #112 are merged.
- Railway deployment pipeline, signed catalog feed, admin Catalog Sync UI, Oban queue, planner/applier, and focused tests exist.

Operator inputs required:

- Railway project/service access;
- safe read-only topology and variable-name inspection;
- production admin access to `/admin/catalog-sync`;
- migration/index/job evidence;
- optional representative event/product identifiers;
- human findings/hash review;
- separate Apply approval.

This slice blocks VS-26E.1, unattended catalog scheduling, catalog auto-apply, and launch backfill that assumes certified mappings.

## 7. Scope

### Pack and planning

- Verify the exact repository baseline and mandatory files.
- Produce an execution plan with exact read-only checks, approvals, stop conditions, and evidence.
- Keep PR #117 open while the ZIP is used for planning.
- Identify all unresolved human/operator inputs.

### Controlled execution after approval

- Inspect Railway, deployment, database, source, feed, and Oban state read-only.
- If explicitly authorised, merge/deploy the reviewed commit and allow the repository pre-deploy migration/bootstrap path.
- Verify migrations, constraints, partial unique index, duplicate-run state, and jobs.
- Queue one bounded full public-feed dry-run.
- Review lifecycle, summary, findings, snapshot, and hash.
- Record a separate exact-run/hash Apply or no-go decision.
- If approved, queue Apply through the existing admin path.
- Reconcile Events, TicketTypes, ProductMappings, run state, admin visibility, and bounded post-commit effects.
- Produce redacted evidence and an independent verdict.

## 8. Explicit non-goals

Do not:

- merge PR #117 before `JC-109` authorisation;
- modify runtime code, config, migrations, tests, dependencies, Railway configuration, or the WordPress plugin inside the pack PR;
- add automatic triggers, schedules, reconciliation, or auto-apply;
- change order webhooks, `OrderUpserter`, `MappingResolver`, payment, ticket issuance, scanner, customer delivery, or checkout;
- implement catch-up or historical backfill;
- add dashboard features, filters, roles, targets, notifications, coupon/UTM/source dimensions, or private-event automation;
- write back to WordPress or edit source events/products;
- reset or clean production data;
- expose credentials, signatures, raw headers, raw feed/webhook bodies, customer data, cookies, or unredacted screenshots;
- run Apply automatically or manually rewrite run states;
- treat Redis, ETS, Cachex, or PubSub as durable truth.

A required corrective code/config/migration change becomes a separate reviewed PR and stops this pack phase.

## 9. Durable model and invariants

`TickeraCatalogSyncRun` owns durable source, scope, status, retry ownership, snapshot, dry-run hash, summary, bounded error, and lifecycle timestamps.

`TickeraCatalogSyncFinding` owns durable per-run severity, code, message, source identifiers, and bounded metadata.

Apply affects `Catalog.Event`, `Catalog.TicketType`, and `Catalog.ProductMapping`.

Invariants:

- run and discovery job are atomic;
- one queue-blocking run per source is database-enforced;
- stale attempts cannot finalise current ownership;
- retryable source failures remain visible;
- findings replacement is atomic;
- exact stored snapshot/hash gates Apply;
- blocking findings prevent Apply;
- claim, catalog writes, and applied transition are transactional;
- stale/duplicate Apply fails closed;
- post-commit notification failure cannot roll back catalog truth;
- evidence never stores protected values.

## 10. Interfaces and architecture

Admin surface: `/admin/catalog-sync`, global-admin-only, asynchronous through Oban.

Supported feed scopes include full, event, product, variation, and updated-since. VS-26E.0 certifies one full public-feed scope; a targeted probe is optional only when the reviewed plan justifies it.

Lifecycle PubSub messages notify UI state, but evidence reloads durable truth.

Architectural path:

```text
CatalogSyncLive
-> TickeraCatalogSync facade
-> transactional run + Oban job

DiscoverTickeraCatalogWorker
-> ConfiguredDiscoverySource
-> signed WordPress feed
-> Planner
-> findings + snapshot/hash

ApplyTickeraCatalogWorker
-> Applier
-> exact stored snapshot
-> Ash/Postgres catalog mutations
-> bounded post-commit effects
```

LiveView/controllers/components do not perform source HTTP. Production SQL is read-only verification except for the reviewed release migration path.

## 11. Security and privacy

- Preserve global-admin authorisation.
- Never record database URLs, secrets, signatures, raw headers/bodies, passwords, cookies, customer PII, payment data, ticket/QR/delivery tokens, or production credentials.
- Record safe names, booleans, counts, statuses, timestamps, UUIDs/hashes where appropriate, and bounded error codes.
- Redact screenshots and logs.
- If protected data enters evidence, stop, contain it, and treat it as an incident.

## 12. Performance and boundedness

- `tickera_sync` concurrency remains one.
- The full feed is paginated and bounded by timeout, page size, and max pages.
- One active run per source prevents overlap.
- Discovery attempts remain bounded to three.
- Do not run catalog reconciliation or backfill concurrently for the same source.
- Record page count, row count, duration, and limit symptoms without retaining payloads.
- Do not increase limits merely to force success.
- No unbounded source call or dashboard query is accepted despite modest initial volume.

## 13. Failure principles

- Unknown migration route, duplicate active runs, or invalid index: stop before deployment/dry-run.
- Feed authentication/configuration failure: correct only under separate approval and never log secrets.
- Transient source errors may use bounded worker retry; inspect durable state.
- Pagination limit or invalid schema: stop and investigate.
- Blocking/ambiguous/destructive findings: no Apply.
- Missing snapshot, hash mismatch, or run-not-ready: no Apply.
- Apply transaction failure or catalog mismatch: stop; no ad-hoc repair.
- Cache/PubSub failure after commit: verify Postgres and plan bounded repair separately.
- Deployment rollback does not undo migrations or catalog Apply.

Use the detailed failure matrix and rollback runbook.

## 14. Mandatory files

Use `FILE_INVENTORY.md`. It covers governance, programme decisions, Railway/release/database topology, Catalog Sync resources/workers/planner/applier/UI, WordPress feed, migrations, focused tests, and architecture indexes.

The canonical pack PR may change only files under:

`docs/feature_packs/0001_VS-26E.0_catalog-lifecycle-production-baseline/`

## 15. Gated delivery sequence

1. Complete `JC-106` pack generation while PR #117 remains open.
2. Independently review v1.1.0 under `JC-107`; approval does not authorise merge.
3. Give the approved ZIP to the planning agent under `JC-108`; checkout remains at the authorised `main` baseline and PR #117 remains open.
4. Review the execution plan under `JC-109`.
5. Run only explicitly authorised read-only preflight.
6. `JC-109` records whether PR #117 merge/deploy/migration is authorised.
7. If authorised, merge/deploy and verify exact SHA and pre-deploy result.
8. Verify database/index/job state.
9. Separately authorise and run the full-feed dry-run.
10. Review findings and exact hash.
11. Separately decide Apply or no-go.
12. If approved, run exact-hash Apply and post-Apply reconciliation.
13. Independently certify evidence under `JC-111`.
14. Close and unlock the successor only under `JC-112`.

## 16. Acceptance criteria

- v1.1.0 ZIP and canonical PR match byte-for-byte and all checksums pass;
- v1.0.0 is recorded as superseded and never handed to an agent;
- PR #117 remains unmerged during pack review and planning;
- exact baseline and deployed SHA are known;
- migration topology is known without exposing values;
- PR #111 migrations, constraints, and exact partial unique index are verified;
- duplicate active-run and relevant Oban state are clean or cause a stop;
- signed feed is configured and bounded;
- one full public dry-run reaches truthful ready/terminal state;
- findings, snapshot, hash, and counts are reproducible and human-reviewed;
- blocking/ambiguous findings prevent Apply;
- Apply/no-go is a separate decision tied to exact run/hash;
- if applied, catalog and side effects reconcile to the approved snapshot;
- evidence is redacted;
- independent certification is recorded;
- VS-26E.1 stays locked until certification.

## 17. Verification

Before planning:

```bash
git status --short
git rev-parse HEAD
git fetch origin
git rev-parse origin/main
bash scripts/sync_with_origin_main.sh --check
```

Pack verification:

```bash
sha256sum -c checksums.sha256
unzip -l EventSales_VS-26E.0_v1.1.0_050d66e8.zip
```

Code baseline before execution:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
bash scripts/check_no_web_woocommerce_refs.sh
mix test test/event_sales/release_test.exs
mix test test/event_sales/ingestion/tickera_catalog_sync_test.exs
mix test test/event_sales/ingestion/tickera_catalog_sync_concurrency_test.exs
mix test test/event_sales/ingestion/workers/discover_tickera_catalog_worker_test.exs
mix test test/event_sales/ingestion/workers/apply_tickera_catalog_worker_test.exs
mix test test/event_sales/catalog/tickera_catalog/planner_applier_test.exs
mix test test/event_sales_web/live/admin/catalog_sync_live_test.exs
mix test
bash scripts/local_ci.sh
git diff --check
```

Production commands must be resolved in the reviewed plan and must not print protected values.

## 18. Migration, rollout, and evidence

- PR #117 merge is itself a deployment/pre-deploy boundary.
- Prefer the existing release entry point and documented direct/session-capable migration route.
- Verify backup/restore readiness before any corrective migration.
- Distinguish deployed commit, migration status, application health, dry-run state, and Apply state.
- A GitHub merge does not prove successful deployment or certification.
- Use `evidence/EVIDENCE_TEMPLATE.md` and the stage runbooks.

## 19. Stop conditions

Stop when:

- worktree or baseline is wrong, or `main` materially advanced;
- PR #117 merge is attempted before explicit JC-109 authorisation;
- live Railway/migration topology required for safety is unknown;
- a deployment would run unreviewed migrations;
- duplicate active runs, invalid/missing index, or unexpected active/retryable jobs exist;
- feed configuration cannot be verified safely or bounded limits are exceeded;
- findings are blocking, ambiguous, destructive, or outside public scope;
- snapshot/hash cannot be reproduced;
- Apply approval is absent or references another hash;
- protected data enters evidence;
- corrective code/config/migration is required;
- the requested action exceeds this pack.

## 20. Required report

Every agent/operator report states:

- pack version, baseline, observed deployed SHA, and authorised phase;
- files changed or production actions executed;
- commands actually run and evidence produced;
- migration/index/queue/feed state;
- safe run/hash and finding counts where applicable;
- Apply/no-go and post-Apply result where applicable;
- blockers, risks, prohibited actions not performed, and next Linear gate.

Never claim production certification before `JC-111`.
