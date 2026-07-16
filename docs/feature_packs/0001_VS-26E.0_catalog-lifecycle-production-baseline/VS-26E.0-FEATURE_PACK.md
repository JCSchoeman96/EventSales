# VS-26E.0 — Catalog Lifecycle Deployment and Baseline Certification

## 1. Identity and status

| Field | Value |
|---|---|
| Slice | `VS-26E.0` |
| Pack | `0001_VS-26E.0` |
| Version | `1.0.0` |
| Status | `review_ready` |
| Repository | `JCSchoeman96/EventSales` |
| Baseline branch | `main` |
| Baseline SHA | `050d66e88d55270655833cd9c9b51476a4bfefeb` |
| GitHub roadmap | `#113` |
| GitHub pack tracker | `#114` |
| Linear parent | `JC-105` |
| Linear pack gate | `JC-106` |
| Linear pack-review gate | `JC-107` |
| Predecessor | PR #111 Catalog Sync lifecycle; PR #112 programme planning |
| Successor | VS-26E.1 targeted WordPress catalog-change trigger |

## 2. Executive summary

PR #111 added a retry-aware, generation-fenced Catalog Sync lifecycle with transactional run/job creation, one-active-run database authority, atomic finding replacement, bounded errors, exact snapshot/hash Apply gating, truthful admin states, and tests. EventSales is deployed on Railway and already receives production WordPress/WooCommerce traffic, but the company has not adopted it operationally and the existing EventSales data may be discarded.

VS-26E.0 certifies the existing catalog path before automation increases its blast radius:

```text
authorised main
-> Railway topology and migration preflight
-> deploy/migration evidence
-> source/feed configuration evidence
-> one controlled full-feed dry-run
-> human findings and exact hash review
-> separate Apply/no-go decision
-> post-Apply catalog verification
-> independent certification
```

This slice is successful only when operational evidence proves the baseline or records a safe, bounded no-go. A green test suite or successful Railway deployment alone is insufficient.

## 3. Current repository truth

### Deployment and database

- `railway.toml` runs `EventSales.Release.migrate_and_bootstrap/0` as a Railway pre-deploy command, then starts the release and checks `/health`.
- `EventSales.Release.migrate/0` prefers `DIRECT_DATABASE_URL`; it falls back to `DATABASE_URL` only when that runtime path is explicitly documented safe.
- Repository deployment guidance configures both variables to Railway's managed Postgres URL and states that no PgBouncer was introduced by the deployment slice.
- The actual live Railway variables/topology are not verified by repository code and must be checked read-only.
- PR #111 added migrations:
  - `20260714100000_add_catalog_sync_retry_metadata.exs`
  - `20260714100100_add_catalog_sync_active_run_index.exs`
- The active-run migration disables the DDL transaction, fails closed on duplicate active runs, and creates a concurrent partial unique index:
  `ingestion_tickera_catalog_sync_runs_one_active_per_source_idx`.
- Active statuses governed by the index are `queued`, `discovering`, `retry_scheduled`, `dry_run_ready`, and `applying`.

### Catalog lifecycle

- `TickeraCatalogSync.queue_dry_run/2` is global-admin-only.
- Run creation and real Oban job insertion occur in one database transaction.
- `tickera_sync` queue concurrency is one.
- `DiscoverTickeraCatalogWorker` uses max attempts three and unique `run_id` execution protection.
- The worker persists attempt ownership, marks transient failures `retry_scheduled`, prevents stale attempts from finalising a newer owner, atomically replaces findings, stores a deterministic plan snapshot/hash, and broadcasts lifecycle events.
- `ApplyTickeraCatalogWorker` accepts only the run id and exact dry-run hash.
- `Applier.apply/3` verifies status, exact hash, stored snapshot, and absence of blocking findings; it claims and applies in one transaction, then invalidates dashboard state and queues missing-catalog resolution for touched product keys.
- Event actions may reuse, adopt, update metadata, or create.
- Ticket types may reuse, adopt, or create.
- Product mappings are created from the stored snapshot.
- Apply does not re-fetch WordPress. The approved immutable snapshot is authority for that Apply attempt.

### WordPress feed

- WordPress endpoint: `/wp-json/eventsales/v1/tickera-catalog`.
- Feed schema currently documents `2026-07-08.v1`, with temporary acceptance of `2026-07-05.v1`.
- Authentication uses a dedicated HMAC secret and timestamp with a five-minute skew limit.
- Full-feed pagination must be completely aggregated before planning.
- Production feed configuration requires:
  - `TICKERA_CATALOG_FEED_ENABLED=true`
  - `TICKERA_CATALOG_FEED_BASE_URL`
  - `TICKERA_CATALOG_FEED_SECRET`
- Optional limits include timeout, per-page, and max-pages.
- Manual JSON remains the rollback/debug discovery path.
- The feed excludes order, customer, payment, ticket-delivery, QR, token, and raw provider payload data.
- WordPress feed responses default to excluding private events. Private-event lifecycle handling belongs to later automation contracts; VS-26E.0 certifies the current production public baseline only.

### Current operational facts supplied by the owner

- EventSales and PostgreSQL are on Railway.
- GitHub merge deploys to Railway.
- Production WordPress/Tickera has been live for a long time.
- Production plugin/webhooks already send data to EventSales.
- Existing EventSales data is real but need not be preserved.
- Approximately twenty events are currently live/public.
- Catalog Sync has probably been tried before, but the result is not a certified baseline.
- The desired first baseline is production dry-run with a possible human-approved Apply.

### Explicit unknowns

The pack must not guess:

- whether the live app uses PgBouncer or another pooler;
- whether `DIRECT_DATABASE_URL` exists and is distinct/safe;
- whether both PR #111 migrations ran;
- whether the active-run index exists and is valid;
- whether duplicate active catalog runs or stale Oban jobs exist;
- exact product/variation/special-product counts;
- exact Railway deployment triggered by PR #112 and its migration outcome;
- exact WordPress plugin version and feed schema active in production;
- whether feed variables/secrets are correctly paired;
- current local EventSales event/ticket/mapping counts.

These are preflight outputs.

## 4. Product decisions implemented or protected

VS-26E.0 protects these programme decisions:

- Tickera event is the primary event identity.
- The first baseline concerns live/public events.
- Existing private/draft records must not be silently treated as the certified current public baseline.
- Only completed orders count as sales; this slice does not alter order metrics.
- EventSales data may be reset later, but this slice must not perform an unreviewed reset.
- Backfill, notifications, roles, reporting dimensions, and WordPress write-back remain deferred.
- No target/pacing logic may rely on this catalog certification as proof of complete sales history.

## 5. Goal and observable outcome

A successful slice produces a signed, redacted evidence pack proving:

1. exact deployed application commit;
2. approved migration path and successful migration state;
3. retry columns/constraints and valid one-active-run partial unique index;
4. no unexplained queue-blocking run/job state;
5. correctly configured signed WordPress catalog feed;
6. one controlled production full-feed dry-run reaches `dry_run_ready`;
7. findings, counts, plan snapshot, and dry-run hash are reproducible and reviewed;
8. Apply occurs only after a separate recorded decision, or a no-go is recorded;
9. if applied, local Events, TicketTypes, ProductMappings, run state, and admin visibility match the approved snapshot;
10. no secret, PII, raw protected payload, or unrelated production mutation is introduced;
11. an independent reviewer records `CERTIFIED`, `CONDITIONALLY CERTIFIED`, `NOT CERTIFIED`, or `BLOCKED`.

## 6. Dependencies and blockers

### Available

- PR #111 merged.
- PR #112 merged at `050d66e88d55270655833cd9c9b51476a4bfefeb`.
- Railway deployment pipeline exists.
- Production WordPress/Tickera source exists.
- Signed catalog-feed plugin and EventSales adapter exist.
- Admin Catalog Sync LiveView exists.
- Oban `tickera_sync` queue exists.
- Tests cover lifecycle, concurrency, workers, planner/applier, release, and LiveView.

### Operator input required

- Railway project/service access.
- Read-only variable-name/topology inspection.
- Deployment and database migration evidence.
- Production admin access to `/admin/catalog-sync`.
- Known representative product/event IDs for optional targeted probe.
- Human findings/hash approval.
- Separate Apply approval.

### Blocks

- VS-26E.1.
- Any unattended catalog schedule.
- Any catalog auto-apply policy.
- Launch backfill that assumes certified mappings.

## 7. Scope

### Pack and planning scope

- Verify repository baseline and mandatory files.
- Produce exact read-only and authorised execution plan.
- Document commands without secrets.
- Identify required human decisions.

### Controlled execution scope after approval

- Read-only Railway/deployment/database/source preflight.
- If required and explicitly approved, deploy the reviewed commit and allow the repository's pre-deploy migration/bootstrap.
- Verify migration/index/constraint state.
- Verify Catalog Sync and Oban state.
- Queue one controlled full public WordPress-feed dry-run.
- Review run lifecycle, summary, findings, snapshot, and hash.
- Record separate Apply/no-go decision.
- If approved, queue Apply for the exact run/hash.
- Verify resulting catalog and admin state.
- Produce redacted evidence and certification verdict.

## 8. Explicit non-goals

Do not:

- add or modify production application code in this slice unless a newly discovered blocker is spun into a separately reviewed corrective PR;
- add the VS-26E.1 WordPress trigger;
- add scheduling, auto-apply, or background reconciliation;
- alter order webhook ingestion, `OrderUpserter`, `MappingResolver`, payment, ticket issuance, scanner, customer delivery, or WooCommerce checkout;
- implement order catch-up or historical backfill;
- add dashboard analytics, filters, roles, targets, notifications, UTM, coupon, or source dimensions;
- implement private-event automation;
- write back to WordPress;
- reset or clean production data merely because it is disposable;
- edit WordPress content, event publication state, products, variations, or Tickera relationships;
- expose secrets, connection strings, signatures, raw feed bodies, customer data, or unredacted screenshots;
- run Apply automatically after dry-run;
- run unlisted SQL writes or manually edit Catalog Sync run statuses;
- treat Redis/ETS/Cachex/PubSub as truth.

## 9. Durable model and invariants

### `TickeraCatalogSyncRun`

- durable UUID identity;
- source-system identity;
- scope;
- lifecycle status;
- exact dry-run hash;
- immutable stored plan snapshot for Apply;
- summary;
- bounded error;
- retry attempt/max attempts;
- started/finished/cancelled metadata;
- one active run per source enforced by PostgreSQL partial unique index.

### `TickeraCatalogSyncFinding`

- durable per-run finding;
- severity/code/message;
- event/product/variation references;
- bounded metadata;
- prior findings are atomically replaced when the same run retries.

### Catalog truth affected by Apply

- `Catalog.Event`
- `Catalog.TicketType`
- `Catalog.ProductMapping`

### Invariants

- run and discovery job are created atomically;
- one queue-blocking run per source;
- stale worker attempts cannot finalise current ownership;
- retryable source errors remain visible as `retry_scheduled`;
- exact stored snapshot and hash gate Apply;
- blocking findings prevent Apply;
- claim, catalog writes, and `applied` transition are transactional;
- post-commit cache/PubSub failures cannot roll back durable catalog truth;
- duplicate/stale Apply jobs fail closed or discard;
- no source re-fetch occurs inside Apply;
- production evidence never stores protected values.

## 10. Interfaces and contracts

### Admin

- `/admin/catalog-sync`
- admin-only queue, preview, revoke, and Apply controls;
- queue actions are asynchronous through Oban.

### WordPress feed

Supported scopes include:

```elixir
%{"kind" => "wordpress_feed", "mode" => "full"}
%{"kind" => "wordpress_feed", "product_id" => positive_integer}
%{"kind" => "wordpress_feed", "variation_id" => positive_integer}
%{"kind" => "wordpress_feed", "event_id" => positive_integer}
%{"kind" => "wordpress_feed", "updated_since" => RFC3339}
```

VS-26E.0 uses one full-feed scope for certification. A targeted probe may precede it only if the reviewed plan requires it.

### PubSub

Lifecycle notifications include start, retry scheduled, preview ready, failed, cancelled, and applied. PubSub is notification only; reload durable state for evidence.

### Runtime variables

Inspect names/presence and safe topology only. Never record values.

- `DATABASE_URL`
- `DIRECT_DATABASE_URL`
- `TICKERA_CATALOG_FEED_ENABLED`
- `TICKERA_CATALOG_FEED_BASE_URL`
- `TICKERA_CATALOG_FEED_SECRET`
- optional feed timeout/page limits
- `EVENTSALES_BOOTSTRAP_SOURCE_*`
- Oban/Redis variables needed to confirm runtime health

## 11. Architectural boundaries

```text
CatalogSyncLive
-> TickeraCatalogSync facade
-> transactionally persisted run + Oban job

DiscoverTickeraCatalogWorker
-> ConfiguredDiscoverySource
-> signed WordPress feed
-> Planner
-> durable findings + plan snapshot/hash

ApplyTickeraCatalogWorker
-> Applier
-> exact stored snapshot
-> Ash/Postgres catalog mutations
-> post-commit cache/PubSub/recovery jobs
```

No LiveView/controller/component performs source HTTP. No direct SQL write replaces Ash/domain actions. Production SQL in this slice is read-only verification unless it is the reviewed migration command.

## 12. Security, privacy, and evidence

- Admin authorization remains mandatory.
- Feed secret is dedicated and never reused as WooCommerce REST credentials.
- Never record URL credentials, secret values, signatures, raw request headers, raw response bodies, admin passwords, customer data, webhook payloads, or production cookies.
- Screenshots must crop/redact browser session details and protected data.
- SQL evidence records object names, booleans, counts, statuses, timestamps, and hashes only.
- Error strings must remain bounded safe codes.
- Evidence must identify the operator and approval decision without exposing credentials.

## 13. Performance and scale

- `tickera_sync` queue concurrency is one.
- WordPress full feed is paginated and bounded by configured per-page/max-pages.
- All pages are aggregated before planning.
- One active run per source prevents overlap.
- Discovery worker max attempts: three.
- Full-feed certification is a controlled cold-path action.
- Do not run concurrent reconciliation/backfill/catalog work against the same source during the dry-run or Apply.
- Verify the observed page count, row count, duration, and memory/timeout symptoms without storing raw payloads.
- Do not increase limits merely to force success; a limit breach is evidence requiring review.
- Initial business scale is modest, but no unbounded query/source-call pattern is accepted.

## 14. Failure and recovery principles

- Missing/unsafe migration route: stop before deployment.
- Duplicate active runs: stop; do not manually rewrite statuses.
- Invalid/missing partial index: stop and assess migration state.
- Feed unauthorized/misconfigured: correct configuration under separate approval; do not log secrets.
- Timeout/rate-limit/server/transport error: allow bounded worker retry and inspect durable state.
- Pagination limit/invalid feed: stop and investigate source/limit contract.
- Blocking finding: no Apply.
- Hash mismatch/missing snapshot/run not ready: no Apply.
- Unexpected catalog scope or destructive result: revoke/no-go.
- Post-Apply cache/PubSub issue: durable catalog may still be correct; verify DB truth and queue bounded repair separately.
- Deployment rollback does not automatically roll back applied catalog data.
- Migration rollback requires reviewed data-compatibility analysis and backup.

## 15. Files to inspect first

Use `FILE_INVENTORY.md`. Minimum anchors include:

- `AGENTS.md`
- project-wide rules and programme decisions
- `railway.toml`
- `config/config.exs`
- `config/runtime.exs`
- `lib/event_sales/release.ex`
- deployment/database docs
- Catalog Sync resource/facade/workers/LiveView
- planner/applier/feed adapter and WordPress plugin README
- PR #111 tests and migrations
- current architecture indexes/manifests

## 16. Expected and forbidden files

This is primarily an operational validation pack. The planning and execution agent must not modify application code.

Expected pack-authoring changes only:

- canonical pack files under `docs/feature_packs/0001_VS-26E.0_catalog-lifecycle-production-baseline`.

Possible follow-up corrective PR, only after a blocker and separate approval:

- narrowly scoped migration/config/code/tests/docs identified by evidence.

Forbidden in this pack PR:

- `lib/`, `config/`, `priv/repo/migrations/`, `assets/`, WordPress plugin runtime code, tests, dependencies, or unrelated docs.

## 17. Gated sequence

1. Pack review (`JC-107`).
2. Planning/reconnaissance (`JC-108`).
3. Plan review and exact phase authorization (`JC-109`).
4. Read-only preflight.
5. Separate deploy/migrate authorization if needed.
6. Database/index/queue verification.
7. Separate catalog dry-run authorization.
8. Full-feed dry-run.
9. Human findings/hash review.
10. Separate Apply/no-go decision.
11. If approved, exact-hash Apply.
12. Post-Apply verification.
13. Independent evidence review (`JC-111`).
14. Closeout (`JC-112`).

## 18. Acceptance criteria

- exact baseline validated;
- no code/runtime changes in pack PR;
- Railway deployment SHA identified;
- migration URL topology identified without values;
- PR #111 migrations and constraints verified;
- active-run index exists, is unique, partial, valid, and has exact predicate;
- no unexplained active run/job conflict;
- signed feed configured and healthy;
- full dry-run reaches a truthful terminal/ready state;
- retry/failure evidence is bounded if encountered;
- preview counts/findings/snapshot/hash captured and reproducible;
- blocking/ambiguous changes prevent Apply;
- explicit Apply/no-go approval recorded;
- if applied, catalog counts/identities and lifecycle state match approved snapshot;
- admin visibility and PubSub-driven state are truthful;
- no PII/secret/raw payload leak;
- independent certification verdict recorded;
- VS-26E.1 remains locked until certification.

## 19. Verification commands

Repository verification before planning:

```bash
git status --short
git rev-parse HEAD
git fetch origin
git rev-parse origin/main
bash scripts/sync_with_origin_main.sh --check
```

Pack/source verification:

```bash
sha256sum -c checksums.sha256
unzip -l EventSales_VS-26E.0_v1.0.0_050d66e8.zip
```

Code baseline evidence already required before execution:

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

Production commands must be resolved in the reviewed execution plan and must not print protected values.

## 20. Migration, rollout, and evidence

- Merging a PR may trigger Railway deploy and therefore pre-deploy migrations. Do not merge a corrective execution PR without explicit deploy/migrate approval.
- Prefer the existing release entry point and documented direct migration URL.
- Verify backup/restore readiness before a migration corrective action.
- Distinguish:
  - deployed commit;
  - migration status;
  - application health;
  - catalog dry-run state;
  - Apply state.
- Do not call a deployment successful merely because GitHub merge completed.
- Use `evidence/EVIDENCE_TEMPLATE.md`.

## 21. Stop conditions

Stop immediately when:

- worktree/baseline is wrong;
- `main` materially advanced;
- Railway topology or migration path required for safety is unknown;
- a deployment would run unreviewed migrations;
- duplicate active runs exist;
- active-run index is absent/invalid/mismatched;
- unexpected Catalog Sync/Oban work is active;
- feed credentials/configuration cannot be verified safely;
- source response exceeds bounded limits;
- findings are blocking, ambiguous, destructive, or outside public baseline scope;
- snapshot/hash cannot be reproduced;
- Apply approval is absent or references a different hash;
- protected data appears in evidence;
- a code/migration/config fix is required;
- the requested action exceeds this pack.

## 22. Final response contract

Every agent/operator report must include:

- baseline and observed deployed SHA;
- phase authorised and phase completed;
- files changed, if any;
- commands actually run;
- read-only findings;
- migration/index/queue/feed state;
- run id/hash only when safe;
- finding counts and decision;
- Apply/no-go decision;
- post-Apply result where applicable;
- evidence location;
- blockers/risks;
- prohibited actions not performed;
- next authorised Linear gate.

Never claim production certification before `JC-111`.
