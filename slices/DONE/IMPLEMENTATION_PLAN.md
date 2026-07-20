# IMPLEMENTATION_PLAN.md

**Plan version:** 1.0.0  
**Target pack:** VS-26E.0 v1.2.0  
**Approved pack ZIP:** `EventSales_VS-26E.0_v1.2.0_561deaf1.zip`  
**Approved pack SHA-256:** `eacd57fe0da1ed6a827bfb0d72a093de4803be56b1955c16433ef1022e533497`  
**Repository:** `JCSchoeman96/EventSales`  
**Plan date:** 2026-07-19  
**Nature of implementation:** operational certification; no runtime feature implementation

## 1. Baseline proof

```text
Current local HEAD: unavailable — no checkout exposed to reviewer
Current origin/main: 561deaf14a2460e1246c3853c9e595567ace48f8
Original pack planning baseline: 050d66e88d55270655833cd9c9b51476a4bfefeb
Approved pack review baseline: 561deaf14a2460e1246c3853c9e595567ace48f8
Exact deployed SHA: unknown
HEAD == origin/main: must be proven during activation refresh
Material runtime drift since pack creation: none in GitHub compare
Current-main Railway commit status: failure
```

Activation refresh must run, in a clean local checkout:

```bash
git status --short
git rev-parse HEAD
git fetch origin
git rev-parse origin/main
bash scripts/sync_with_origin_main.sh --check
```

Expected before activation:

```text
git status --short: empty
HEAD: 561deaf14a2460e1246c3853c9e595567ace48f8, unless a newer main is reviewed through an activation supplement
origin/main: same as HEAD
sync script: pass
```

Any newer `main` requires exact diff review. Any runtime/config/migration/test drift requires a new pack semantic version or an approved activation supplement that proves compatibility.

## 2. Pack review verdict

`PACK_REVIEW_REPORT.md` approves v1.2.0 for planning. Approval does not authorise:

- merging a pack PR;
- deployment or redeployment;
- migration execution;
- changing Railway variables;
- changing WordPress configuration;
- queueing a dry-run;
- queueing Apply;
- production data correction.

## 3. Files and evidence inspected

The review inspected every pack file and every repository path in the v1.2.0 `FILE_INVENTORY.md`, including governance, deployment, runtime config, release migration code, Catalog Sync resources/facade/workers/planner/applier/feed/UI, all listed migrations, focused tests, and architecture indexes. It also inspected PRs #111, #112, #117, GitHub programme/successor issues, and Linear gates JC-105 through JC-113 where available.

## 4. Current-code findings

1. Postgres is the only durable catalogue and sync authority.
2. Redis/cache/PubSub/UI are derived and cannot certify completion.
3. `queue_dry_run` persists one run and one real Oban job transactionally.
4. the database partial unique index owns one-active-run-per-source.
5. discovery ownership is fenced by attempt metadata.
6. findings replacement and ready state commit atomically.
7. Apply requires exact durable run/hash/snapshot and blocks on findings.
8. Apply claim, catalogue writes, and applied transition share one transaction.
9. post-commit side effects are independent and repairable.
10. feed calls occur in the worker path, not LiveView render.
11. feed aggregation is bounded at configured pages/rows, but planner query cost is row-sensitive.
12. finding message/metadata are sanitized but not database-size-bounded.
13. production DB topology documentation conflicts; live Railway evidence must decide.
14. current-main Railway status is failing.

## 5. Certified predecessor interfaces

### PR #111 runtime interface

| Authority | Exact interface | Guarantee consumed by VS-26E.0 |
|---|---|---|
| Queue facade | `TickeraCatalogSync.queue_dry_run/2` | global-admin authorization; run/job transaction; active-run error |
| Apply facade | `queue_apply/3` | exact hash; snapshot/finding checks; real Oban job |
| Revocation | `revoke_ready_dry_run/3` | durable cancelled state and reason; snapshot retained |
| Read facade | `list_runs/1`, `get_run_preview/2`, `active_run_for_source/2` | bounded admin reads from Postgres |
| Run resource | `TickeraCatalogSyncRun` actions/state constraints | durable lifecycle and retry ownership |
| Database authority | `ingestion_tickera_catalog_sync_runs_one_active_per_source_idx` | one queue-blocking run per source |
| Discovery worker | `DiscoverTickeraCatalogWorker` | three attempts; owner fencing; atomic findings/ready transition |
| Planner | `Planner.plan/3` | deterministic JSON-safe snapshot and SHA-256 |
| Apply worker | `ApplyTickeraCatalogWorker` | exact run/hash job boundary |
| Applier | `Applier.apply/3` | claim + catalogue writes + applied state in one DB transaction |

### PR #112 governance interface

PR #112 provides programme decisions and feature-pack discipline only. It does not own runtime behavior.

### WordPress feed interface

- signed GET endpoint `/wp-json/eventsales/v1/tickera-catalog`;
- schema `2026-07-08.v1`, with temporary previous-schema acceptance in EventSales;
- one selected scope: full, product, variation, event, or updated-since;
- public-only by default; no `include_private` in certification;
- no customer/order/payment payloads;
- page and per-page included in HMAC;
- 300-second replay/skew window on WordPress side;
- current defaults 100 rows/page, 50 pages, 5 seconds/page.

## 6. Architecture and authority chain

```text
Production WordPress/Tickera catalogue
  [source authority]
        |
        v
Signed, read-only, PII-free feed
        |
        v
ConfiguredDiscoverySource -> WordPressFeedDiscoverySource -> WordPressFeedClient
        |
        v
DiscoverTickeraCatalogWorker
        |
        v
Planner
        |
        +--> durable findings
        +--> durable plan_snapshot + dry_run_hash
        v
TickeraCatalogSyncRun(:dry_run_ready)
        |
        +--> human exact-run/hash review and explicit decision
        v
ApplyTickeraCatalogWorker
        v
Applier transaction
        +--> Catalog.Event
        +--> Catalog.TicketType
        +--> Catalog.ProductMapping
        +--> TickeraCatalogSyncRun(:applied)
        |
        v
Post-commit cache invalidation, PubSub, bounded recovery jobs
```

### No-go boundaries

- no catalogue writes from WordPress signal intake, LiveView, cache, PubSub, dashboards, or evidence tooling;
- no manual SQL status rewrites;
- no auto-apply;
- no private/draft certification;
- no order history, metric, dashboard, access-role, target, notification, import, backfill, or WordPress write-back work;
- no runtime corrective code inside VS-26E.0.

## 7. Data and lifecycle contracts

### Run identity and lifecycle

- ID: UUID generated by Ash/Postgres.
- source identity: `source_system_id` foreign key.
- scope: durable map; certification scope exactly `%{"kind" => "wordpress_feed", "mode" => "full"}`.
- active states: `queued`, `discovering`, `retry_scheduled`, `dry_run_ready`, `applying`.
- terminal states: `applied`, `failed`, `cancelled`.
- owner generation: `retry_attempt` and `retry_max_attempts`.
- exact Apply authority: run UUID + 64-character lower-case SHA-256.

### Equal/stale/duplicate behavior

- duplicate queue for one source: database conflict -> safe `catalog_sync_already_active`;
- duplicate same-attempt discovery: discard without mutating live owner;
- higher retry attempt: may supersede stale owner; stale owner cannot finalize;
- stale Apply hash: reject, keep ready run unchanged;
- cancelled/applied/failed run: cannot Apply;
- repeated Apply after applied: `run_not_ready` / discard, no duplicate writes.

### Finding contract

- durable severity/code/message/source IDs/metadata;
- evidence records only safe counts/codes and reviewed excerpts if needed;
- no hard DB size bound currently exists for message/metadata;
- unexpected size growth is a stop and corrective-slice trigger.

### Transaction boundaries

1. run create + discovery Oban insert: one `Repo.transaction`;
2. delete old findings + create new findings + mark ready: one transaction;
3. Apply claim + Event/TicketType/ProductMapping changes + mark applied: one transaction;
4. notifier/cache/PubSub/recovery jobs: post-commit, not catalogue authority.

## 8. Exact files and code changes

### Runtime files to create

None.

### Runtime files to modify

None.

### Dependencies to add/update

None.

### Migrations to create/execute as code changes

None. Existing production migration application is a separately authorised operational step.

### Documentation-only remote registration PR

A repository steward may create a new docs-only PR from exact current `main` with these source files under:

```text
docs/feature_packs/0001_VS-26E.0_catalog-lifecycle-production-baseline/
```

Create exactly the 21 files in the v1.2.0 pack root, excluding the external ZIP itself. Do not modify runtime paths. Attach the ZIP and sidecar externally to GitHub/Linear unless the owner explicitly chooses a binary-in-repo policy.

The registration PR must stop before merge. A merge is a Railway deployment boundary.

### Files explicitly not to modify

```text
lib/**
config/**
priv/repo/migrations/**
assets/**
test/**
integrations/wordpress/**
mix.exs
mix.lock
railway.toml
Dockerfile
```

Any need to modify one of these paths terminates this plan and requires a new corrective feature pack.

## 9. Resources, actions and services

No new resource/action/service is planned. Activation consumes only:

- `TickeraCatalogSyncRun`
- `TickeraCatalogSyncFinding`
- `TickeraCatalogSync` facade
- discovery/apply workers
- current planner/applier
- current feed adapter/client
- current `/admin/catalog-sync` UI
- existing `Catalog.Event`, `TicketType`, `ProductMapping` actions invoked by `Applier`.

## 10. Migrations and indexes

### Existing migrations to verify

```text
20260703090000_vs_26a_tickera_catalog_sync
20260713100621_vs_26a_catalog_dry_run_revocation
20260714100000_add_catalog_sync_retry_metadata
20260714100100_add_catalog_sync_active_run_index
```

### Read-only preflight

Prove:

- all expected versions are applied;
- retry columns exist with expected types/nullability;
- attempt/max and `last_error` constraints exist;
- active index is unique, valid, and ready;
- key is `source_system_id`;
- predicate includes exactly the five active states;
- duplicate active-source query returns zero rows;
- no unexplained discover/apply jobs are available/scheduled/executing/retryable.

### Lock and connection risks

- the active index migration uses `@disable_ddl_transaction true` and `CREATE UNIQUE INDEX CONCURRENTLY`;
- it deliberately fails if duplicate active runs already exist;
- migrations require a direct/session-capable route;
- conflicting docs mean topology must be proven from Railway without exposing values;
- no production data cleanup/backfill may be hidden in deployment.

### Migration rollout

1. Determine actual active deployed SHA.
2. Determine whether migrations are already applied.
3. If already applied and valid: no migration action.
4. If pending: obtain explicit deployment/migration approval.
5. Prefer repository Railway pre-deploy path.
6. Capture redacted pre-deploy result.
7. Re-run schema/index/job checks.

### Rollback

Do not automatically roll back. `EventSales.Release.rollback/2` requires a reviewed target version, backup, and data compatibility decision. A deployment rollback does not undo schema or catalogue Apply.

## 11. Tests-first sequence

No production or registration merge begins before the existing test contract is re-proven against exact activation `main`.

### Stage T0 — baseline/static proof

```bash
git status --short
git rev-parse HEAD
git fetch origin
git rev-parse origin/main
bash scripts/sync_with_origin_main.sh --check
git diff --check
```

### Stage T1 — release/migration selection

```bash
mix test test/event_sales/release_test.exs
```

Must prove direct URL preference, fallback behavior, redaction, migration-before-bootstrap, and fail-stop ordering.

### Stage T2 — facade and database authority

```bash
mix test test/event_sales/ingestion/tickera_catalog_sync_test.exs
mix test test/event_sales/ingestion/tickera_catalog_sync_concurrency_test.exs
```

Must prove authorization, run/job atomicity, active index predicate, real separate-connection race behavior, exact apply hash job, revocation, and bounded reads.

### Stage T3 — worker ownership/retry/failure

```bash
mix test test/event_sales/ingestion/workers/discover_tickera_catalog_worker_test.exs
mix test test/event_sales/ingestion/workers/apply_tickera_catalog_worker_test.exs
```

Must prove duplicate/stale attempt fencing, retry visibility, final claim failure, post-commit independence, stale hash, revocation race, and truthful terminal state.

### Stage T4 — planner/applier and corrections boundary

```bash
mix test test/event_sales/catalog/tickera_catalog/planner_applier_test.exs
mix test test/event_sales/catalog/mapping_conflict_resolver_test.exs
```

Must prove deterministic plans, source identity adoption/reuse, stale hash/missing snapshot, rollback, idempotency, conflict guardrails, audit, and no order-history rewrite.

### Stage T5 — feed adapter/client contract

```bash
mix test test/event_sales/catalog/tickera_catalog/wordpress_feed_client_test.exs
mix test test/event_sales/catalog/tickera_catalog/wordpress_feed_discovery_source_test.exs
```

Must prove HMAC query contract, exact-one scope, strict IDs/timestamps, pagination aggregation, safe errors, schema validation, and no payload leakage.

### Stage T6 — admin/access/performance facade

```bash
mix test test/event_sales_web/live/admin/catalog_sync_live_test.exs
```

Must prove global-admin access, selected-preview loading only, bounded HTML/query behavior, exact Apply control, revocation, durable reload after PubSub, and safe errors.

### Stage T7 — full local CI

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix credo --strict
mix dialyzer
bash scripts/check_no_web_woocommerce_refs.sh
mix assets.build
mix test
bash scripts/local_ci.sh
git diff --check
```

Any failure blocks activation. Do not “fix forward” under this pack.

### Stage T8 — production read-only tests

Only after plan review:

- active deployment SHA/status;
- `/health` status;
- safe deployment/pre-deploy logs;
- topology variable names/presence, never values;
- schema/index/duplicate/job queries;
- feed plugin/schema/clock/config presence;
- expected source scale and configured cap.

### Stage T9 — write canary and certification tests

Only after explicit dry-run authorisation:

1. optional targeted product/event dry-run using an operator-supplied reviewed identifier;
2. verify lifecycle, safe failure mapping, snapshot/hash, and no private data;
3. retain/revoke truthfully;
4. queue exactly one full public-feed dry-run;
5. reload preview from Postgres and complete human review.

Apply is a separate Stage T10 authorisation, not part of T9.

## 12. Failure, retry and repair

| Condition | Required behavior |
|---|---|
| current Railway status failing | stop; identify active SHA and failure category read-only |
| baseline moved | exact compare; refresh supplement or new pack |
| duplicate active runs | stop; no status rewrite |
| index absent/invalid | stop; corrective pack/PR if migration cannot safely establish it |
| unexpected active/retryable jobs | stop until ownership and purpose are known |
| feed unauthorized/forbidden | no secret logging; fix pairing only under separate approval |
| timeout/rate-limit/server/transport | observe bounded worker retries and durable attempt state |
| pagination limit | stop; no blind limit increase |
| invalid schema/JSON | stop; source or code correction outside this pack |
| oversized/unreviewable findings | stop; preserve durable truth; corrective hardening slice |
| blocking/ambiguous findings | no Apply; revoke/no-go or separate correction |
| stale hash/missing snapshot | no Apply; reload current durable preview |
| Apply transaction failure | stop; no blind retry or SQL repair |
| cache/PubSub failure after commit | verify Postgres; plan read-model repair separately |
| recovery job explosion | stop broadening; inspect queue and touched-key count |
| protected-data leak | contain, restrict evidence, rotate if needed, block certification |

## 13. Privacy and security

### Allowed evidence fields

- commit/deployment IDs;
- migration versions and schema/index names;
- booleans and counts;
- safe lifecycle states/error codes;
- timestamps;
- source-system UUID or approved alias;
- run UUID and dry-run hash;
- feed schema version;
- redacted representative catalogue identities.

### Forbidden evidence fields

- database/Redis URLs or credentials;
- WordPress secret, signatures, raw headers, signed URLs;
- raw feed/webhook bodies;
- admin credentials/cookies/session tokens;
- customer name/email/phone/address;
- payment transaction data;
- ticket, QR, token, or delivery values.

### Logging/telemetry

- do not log URLs containing signed query params;
- use low-cardinality operation/source/status/reason metadata;
- do not add run UUID, product IDs, event IDs, or hashes as metric label dimensions;
- per-run IDs may appear in bounded operational logs, not metric labels;
- review screenshots manually before attachment.

### Browser/DTO boundary

The admin UI may display safe catalogue plan fields and durable status. It must not display raw feed payloads, secrets, order/customer/payment data, or unrestricted metadata.

## 14. Performance and query plans

### Expected cardinality

Product owner expectation is approximately 20 live/public events, but this is not authoritative until observed. Configured technical ceiling is currently 5,000 rows per full fetch (`100 × 50`).

### Query shapes

Planner performs, per row:

- active mapping lookup by source/product/variation;
- source Event lookup when mapping missing;
- source TicketType lookup when event exists;
- relationship load for existing mapping.

Apply performs writes proportional to planned changes and enqueues one missing-catalog recovery job per touched product key.

### Required indexes to prove

- ProductMapping active source/product/variation uniqueness/index path;
- Event source/external identity lookup;
- TicketType event/external identity lookup;
- run source/status active index;
- run inserted-at list path where relevant.

### Query-plan evidence

Use production-safe `EXPLAIN` first. Use `EXPLAIN (ANALYZE, BUFFERS)` only in staging or under explicit production approval with a representative bounded key lookup. Never run full-feed `ANALYZE` merely to satisfy a document.

### Batch/transaction constraints

- no concurrent catalog reconciliation/backfill for the same source;
- one `tickera_sync` worker at a time;
- no limit increase during incident response;
- record full-run page count, row count, total duration, job attempts, and touched-key count;
- stop near configured cap or on DB/queue saturation.

### Acceptance evidence

- one full-run observation: duration, rows/pages, attempts, query/saturation symptoms;
- existing telemetry history may provide p50/p95 only if enough comparable samples exist and labels are safe;
- otherwise record `p50/p95: not established by VS-26E.0`.

## 15. Static and CI gates

- formatting, warnings-as-errors, Credo, Dialyzer;
- no-web-WooCommerce reference script;
- full tests and local CI;
- asset build;
- architecture manifest/index checks already included by repository CI;
- exact-head GitHub CI status;
- Railway status is not treated as ordinary CI success: it is a production deployment signal requiring separate review.

## 16. Child PR sequence

### Decision

There is **no runtime implementation PR** for VS-26E.0. The smallest complete units are operational gates, not code slices.

### R0 — pack registration PR

- scope: v1.2.0 canonical Markdown/JSON source only;
- dependencies: exact current main and approved pack;
- output: reviewable docs-only PR plus external ZIP/SHA links;
- tests: checksum regeneration, archive test, docs/static CI;
- exclusion: all runtime paths;
- gate: stop before merge because merge deploys.

### A0 — activation refresh

- read-only baseline, GitHub status, Railway active SHA, deployment failure diagnosis;
- no production write.

### A1 — schema/topology/feed preflight

- read-only database/index/jobs and WordPress feed configuration/schema evidence;
- no deployment or dry-run.

### A2 — deployment/migration decision

- only if actual active state lacks required code/migrations;
- explicit approval required;
- no dry-run implied.

### A3 — targeted canary dry-run

- optional, separately authorised, reviewed identifier;
- no Apply.

### A4 — full public-feed dry-run

- exactly one certification run;
- human review and exact hash decision.

### A5 — Apply or no-go

- separate approval referencing exact run/hash;
- Apply through current admin/facade only.

### A6 — post-Apply validation/evidence

- reconcile catalogue resources and bounded side effects;
- independent evidence review;
- JC-112 closeout/unlock decision.

Each gate stops independently. No later gate is implied by an earlier pass.

## 17. Feature flags and rollout

No new feature flags are introduced.

### Disabled/default mode

- no automatic trigger;
- no schedule;
- no auto-apply;
- feed may be disabled and manual rows remain rollback/debug path.

### Shadow mode

A dry-run is the shadow mode: it computes and persists a plan without catalogue writes.

### Canary

A targeted product/event dry-run is the preferred canary when a reviewed identifier is available. It does not replace full certification.

### Broadening

Only after canary review may one full public-feed dry-run be queued. Only after full human review may exact-hash Apply be considered.

### Kill switch

- disable/unset `TICKERA_CATALOG_FEED_ENABLED` and restart under approval to remove feed adapter;
- do not change variables in this planning chat;
- cancellation/revocation prevents a ready plan from Apply.

## 18. Production validation

Required evidence sequence:

1. current main and actual active Railway SHA;
2. current-main failure diagnosis and last known active deployment;
3. health status and redacted deployment/pre-deploy outcome;
4. topology and variable-name presence without values;
5. migration versions, constraints, index, duplicate query, Oban state;
6. feed plugin/schema/config/clock and source scale;
7. optional targeted canary dry-run;
8. one full public-feed dry-run;
9. lifecycle, retries, summary, findings, snapshot/hash, performance observation;
10. separate Apply/no-go;
11. if Apply, exact transaction result and catalogue reconciliation;
12. cache/PubSub/recovery side effects;
13. redaction review;
14. independent certificate verdict.

## 19. Rollback and stop conditions

### Stop before deployment

- failing/unexplained current-main Railway status;
- active SHA unknown;
- topology or direct migration path unknown;
- duplicate active runs;
- unexpected pending migrations or runtime drift;
- backup/restore confidence absent for a required migration.

### Stop before dry-run

- required code/migrations/index not active;
- unexplained catalog jobs/runs;
- feed plugin/schema/secret pairing/clock unresolved;
- source size near/exceeding configured bounds;
- production pressure or competing catalog/backfill work.

### Stop before Apply

- missing separate approval;
- stale decision or changed production state;
- blocking, ambiguous, destructive, private, subscription/payment-plan/bundle/add-on findings;
- missing live events;
- hash/snapshot mismatch;
- performance or finding-size evidence unacceptable.

### Stop after Apply

- run/catalog state mismatch;
- unexpected resource changes;
- duplicate identities/mappings;
- order data changed;
- recovery jobs loop/explode;
- protected-data leak.

Correction requires a separate pack. No ad-hoc SQL rewrite.

## 20. Successor handoff

VS-26E.1 receives one allowlisted certificate, not raw evidence. Required fields:

```text
certified_main_sha
active_deployed_sha
migration_versions
active_run_index_contract
feed_schema_version
source_system_id
source_snapshot_at
dry_run_run_id
dry_run_hash
scope
lifecycle_timestamps
summary_counts
finding_counts_by_severity_and_code
apply_or_no_go
applied_at_or_revoked_at
catalog_reconciliation_counts
known_exceptions
accepted_risks
evidence_review_verdict
certified_at
```

VS-26E.1 remains blocked through JC-112/JC-123 until this certificate is complete and an activation supplement refreshes its own exact main. It must reuse the current targeted dry-run and one-active-run authority and cannot auto-apply.

## 21. Risks and unresolved decisions

1. actual active Railway SHA and failure category;
2. live DB topology: direct vs session-pooler;
3. actual migration/index state;
4. WordPress plugin/schema/config/clock state;
5. actual full-feed cardinality and planner query pressure;
6. actual finding sizes;
7. representative canary identifier;
8. whether Apply will be approved after findings review;
9. remote v1.2.0 registration mechanism and reviewer gate;
10. repository documentation topology conflict.

None may be guessed.

## 22. Prohibited-actions confirmation

This plan performed no repository write, branch, commit, PR, dependency update, migration, config change, WordPress change, production job, dry-run, Apply, merge, deploy, backfill, correction, or production query.

## 23. Verdict

The operational plan is complete and handoff-ready, but activation is hard-blocked until the failing Railway status, actual active SHA, live topology/migration state, and remote v1.2.0 registration are resolved through the activation refresh.

**PACK VALID**
