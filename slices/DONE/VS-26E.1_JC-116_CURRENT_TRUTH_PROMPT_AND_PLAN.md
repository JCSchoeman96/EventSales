# VS-26E.1 — Current-Truth Planning Prompt and Working Implementation Plan

## Document status

- Slice: `VS-26E.1 — Targeted WordPress Catalog Change Trigger`
- Current authorised gate: `JC-115` pack review, followed by `JC-116` repository reconnaissance and implementation planning
- Current `main` baseline for reconnaissance: `4ed9bca09af173399c114e290b02f41a44795da8`
- Certified production runtime SHA: `59a55523d2afe53f08e2f82becef5adec2bed0d6`
- Planning pack: `EventSales_VS-26E.1_PLANNING_PACK_v0.9.0_050d66e8.zip`
- Planning-pack SHA-256: `1c71236f4111e3f8158ce84f0d55c55521eed18d238eda5bc9cd1d5dca5c4802`
- Original planning baseline: `050d66e88d55270655833cd9c9b51476a4bfefeb`
- Authority: planning only
- Implementation authority: **not granted**
- Mandatory activation gate before code: `JC-123`

---

# Part A — Copy/paste prompt for the coding/planning agent

You are the repository-reconnaissance and implementation-planning agent for:

`VS-26E.1 — Targeted WordPress Catalog Change Trigger`

Repository:

`JCSchoeman96/EventSales`

Your job in this phase is to inspect current repository truth and produce a tests-first, file-specific, end-to-end implementation plan.

You are **not authorised to implement anything**.

## 1. Authority boundary

You may:

- inspect the repository;
- fetch and compare branches/commits;
- read the approved planning pack and current canonical documentation;
- inspect source, tests, migrations, WordPress integration code and deployment configuration;
- run read-only/local verification commands;
- produce or update a planning document outside the repository worktree when required;
- identify exact files likely to be created or changed later;
- recommend architecture and rollout decisions;
- report blockers, drift and operator inputs.

You may not:

- modify repository files;
- create a branch or commit;
- open, update, mark ready or merge a PR;
- generate or run a migration;
- deploy or change Railway;
- change environment variables or secrets;
- change WordPress;
- queue Catalog Sync;
- revoke, dry-run or Apply a Catalog Sync run;
- access or mutate production;
- introduce implementation by “small cleanup” or “preparatory refactor”;
- treat this prompt as implementation approval.

Stop after returning the completed plan.

## 2. Exact starting truth

Use the following only as a verified starting point. Reconfirm it from Git before relying on it:

- Current `main`: `4ed9bca09af173399c114e290b02f41a44795da8`
- Certified production runtime SHA: `59a55523d2afe53f08e2f82becef5adec2bed0d6`
- VS-26E.0 verdict: `CERTIFIED — VS-26E.1 MAY START`
- Certified catalogue:
  - Events: `10`
  - TicketTypes: `31`
  - ProductMappings: `31`
- Existing planning pack baseline: `050d66e88d55270655833cd9c9b51476a4bfefeb`
- Planning-pack SHA-256:
  `1c71236f4111e3f8158ce84f0d55c55521eed18d238eda5bc9cd1d5dca5c4802`
- Current pack status: valid for planning, not valid as implementation authority.
- `JC-123` must refresh current-main and production truth before implementation begins.

The known material runtime drift since the original planning baseline is narrow:

1. The EventSales WordPress feed client now sends:
   - `Accept: application/json`
   - `User-Agent: EventSales/1.0 (+https://voelgoed.co.za)`
2. Those identity headers are not part of the canonical feed HMAC string.
3. The production Catalog Sync lifecycle was certified and its roadmap state was closed.
4. Documentation and immutable planning ZIP registrations advanced.

Do not assume there is no additional drift. Prove it.

## 3. Baseline proof — run first

Run and include the exact output or a precise summary:

```bash
git status --short
git rev-parse HEAD
git fetch origin
git rev-parse origin/main
git merge-base HEAD origin/main
git log --oneline --decorate -n 20
bash scripts/sync_with_origin_main.sh --check
```

Then compare the pack baseline to current `main`:

```bash
git diff --stat \
  050d66e88d55270655833cd9c9b51476a4bfefeb..4ed9bca09af173399c114e290b02f41a44795da8

git diff --name-status \
  050d66e88d55270655833cd9c9b51476a4bfefeb..4ed9bca09af173399c114e290b02f41a44795da8
```

Classify every changed path as:

- material to VS-26E.1;
- non-material documentation/registration drift;
- requires `JC-123` refresh;
- invalidates the planning pack.

Stop with `PACK BLOCKED` when:

- the worktree is dirty;
- current `origin/main` is not the stated baseline and the difference cannot be bounded;
- a required file is missing;
- current code contradicts the pack’s core authority model;
- safe planning requires production access;
- implementation has already started outside the approved gate.

## 4. Read the planning pack completely

Verify the ZIP SHA-256 before using it:

```bash
sha256sum EventSales_VS-26E.1_PLANNING_PACK_v0.9.0_050d66e8.zip
```

Expected:

```text
1c71236f4111e3f8158ce84f0d55c55521eed18d238eda5bc9cd1d5dca5c4802
```

Extract to a temporary directory outside the repository and verify:

```bash
sha256sum -c checksums.sha256
```

Read every file, especially:

- `README.md`
- `VS-26E.1-FEATURE_PACK.md`
- `FILE_INVENTORY.md`
- `CODING_AGENT_PROMPT.md`
- `IMPLEMENTATION_PLAN_TEMPLATE.md`
- `REVIEWER_PROMPT.md`
- `ACCEPTANCE_CHECKLIST.md`
- `ACTIVATION_SUPPLEMENT_TEMPLATE.md`
- `runbooks/WORDPRESS_TRIGGER_CONTRACT.md`
- `runbooks/ROLLOUT_PLAN.md`
- `runbooks/FAILURE_MATRIX.md`
- `runbooks/ROLLBACK_AND_STOP_CONDITIONS.md`

Treat the old blocked scope scaffold as historical context only. It is not authority over the approved v0.9.0 planning pack or current `main`.

## 5. Mandatory current-repository inspection

Read every path from the pack’s `FILE_INVENTORY.md`, plus these current-truth additions:

### Governance and active programme truth

- `AGENTS.md`
- `INDEX.md`
- `docs/agent/01_PROJECT_WIDE_RULES.md`
- `docs/roadmap/EVENTSALES_LIVE_SALES_PROGRAMME.md`
- `docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md`
- `docs/roadmap/EVENTSALES_LIVE_SALES_KANBAN.md`
- `docs/feature_packs/EVENTSALES_FEATURE_PACK_STANDARD.md`

### Current feed and signature contract

- `lib/event_sales/catalog/tickera_catalog/wordpress_feed_client.ex`
- `lib/event_sales/catalog/tickera_catalog/wordpress_feed_signature.ex`
- `lib/event_sales/catalog/tickera_catalog/wordpress_feed_discovery_source.ex`
- `lib/event_sales/catalog/tickera_catalog/configured_discovery_source.ex`
- `docs/ops/tickera_catalog_feed_contract.md`
- `docs/ops/tickera_catalog_feed_eventsales_adapter.md`
- `integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php`
- `integrations/wordpress/eventsales-tickera-catalog-feed/README.md`
- `test/event_sales/catalog/tickera_catalog/wordpress_feed_client_test.exs`
- `test/event_sales/catalog/tickera_catalog/wordpress_feed_discovery_source_test.exs`

### Catalog Sync authority and lifecycle

- `lib/event_sales/ingestion/tickera_catalog_sync.ex`
- `lib/event_sales/ingestion/resources/tickera_catalog_sync_run.ex`
- `lib/event_sales/ingestion/resources/tickera_catalog_sync_finding.ex`
- `lib/event_sales/ingestion/workers/discover_tickera_catalog_worker.ex`
- `lib/event_sales/ingestion/workers/apply_tickera_catalog_worker.ex`
- `lib/event_sales/catalog/tickera_catalog/planner.ex`
- `lib/event_sales/catalog/tickera_catalog/applier.ex`
- `lib/event_sales/catalog/tickera_catalog/pub_sub.ex`
- `lib/event_sales_web/live/admin/catalog_sync_live.ex`
- all tests and helpers for these modules.

### Security and durable-intake precedents

- `lib/event_sales_web/controllers/webhook_controller.ex`
- `lib/event_sales/ingestion/webhook_intake.ex`
- `lib/event_sales/ingestion/webhook_enqueue.ex`
- `lib/event_sales/ingestion/webhook_event_store.ex`
- `lib/event_sales/ingestion/security/webhook_signature.ex`
- `lib/event_sales/ingestion/security/webhook_replay_guard.ex`
- `lib/event_sales_web/plugs/raw_body_reader.ex`
- `lib/event_sales_web/plugs/rate_limit_webhook_intake.ex`
- `lib/event_sales_web/router.ex`
- `lib/event_sales_web/endpoint.ex`

### Runtime, queues and migrations

- `config/config.exs`
- `config/runtime.exs`
- `railway.toml`
- `lib/event_sales/release.ex`
- `priv/repo/migrations/20260703090000_vs_26a_tickera_catalog_sync.exs`
- every later migration touching Catalog Sync, especially timestamp versions:
  - `20260714100000`
  - `20260714100100`
- `scripts/local_ci.sh`
- `scripts/check_no_web_woocommerce_refs.sh`
- `scripts/sync_with_origin_main.sh`

Use:

```bash
git ls-files | grep -E \
'catalog|tickera|wordpress|webhook|oban|runtime|migration|roadmap|feature_pack'
```

to discover related files omitted by the old inventory.

## 6. Current invariants you must preserve

Confirm these from current code and design the plan around them:

1. A Tickera event is primary event identity.
2. WooCommerce products and optional variations are linked ticket entities.
3. The WordPress GET feed remains authoritative catalogue data.
4. A change trigger is only a compact notification; it is not catalogue truth.
5. The trigger must lead to the existing signed feed being fetched.
6. The trigger must queue an existing targeted Catalog Sync dry-run.
7. No signal path may directly write Event, TicketType or ProductMapping.
8. No auto-Apply is allowed in VS-26E.1.
9. Only one active Catalog Sync run may exist per source across:
   - `queued`
   - `discovering`
   - `retry_scheduled`
   - `dry_run_ready`
   - `applying`
10. Existing exact-snapshot/hash Apply authority remains untouched.
11. Postgres/Ash is durable truth.
12. Redis, cache and PubSub may assist but may not be sole durable authority.
13. Controllers and LiveViews may not call the WordPress/WooCommerce source directly.
14. WordPress save requests must never wait for EventSales HTTP completion.
15. The signal payload must contain no customer, order, payment, billing, shipping or ticket-holder data.
16. Full-feed discovery on every WordPress save is forbidden.
17. Do not spoof an admin actor to queue system work.
18. The existing feed HMAC secret should not automatically be reused for trigger POST authentication.
19. Accepted HTTP acknowledgement must correspond to durable recoverable state.
20. Stale source freshness must never overwrite newer pending work.

## 7. Current behaviour to verify explicitly

Your report must prove or correct these observations:

### WordPress feed

- Existing route:
  `/wp-json/eventsales/v1/tickera-catalog`
- Existing schema:
  `2026-07-08.v1`
- Existing targeted filters:
  - `event_id`
  - `product_id`
  - `variation_id`
  - `updated_since`
- Existing cache invalidation hooks:
  - `save_post_product`
  - `save_post_product_variation`
  - `save_post_tc_events`
- Existing plugin currently invalidates cache but does not send a trigger.

### EventSales discovery

The discovery source currently accepts exactly one of:

- full mode;
- `event_id`;
- `product_id`;
- `variation_id`;
- `updated_since`.

The plan must reuse this contract or justify a separately reviewed change.

### Catalog Sync lifecycle

- `queue_dry_run/2` is currently global-admin authorised.
- The shared queue transaction creates the durable run and Oban discovery job together.
- The one-active-run database index is already production-certified.
- The discovery worker uses queue `tickera_sync`, concurrency is currently one, and the worker is unique by `run_id`.
- A successful targeted discovery stops at `dry_run_ready`.
- A `dry_run_ready` run remains active until an authorised human Applies or revokes it.
- New trigger work arriving behind a `dry_run_ready` run therefore requires durable defer/replay semantics.

### Webhook precedent

Current WooCommerce intake demonstrates:

- raw body captured before JSON parsing;
- signature verification against raw bytes;
- rate-limited HTTP boundary;
- durable receipt before asynchronous business processing;
- duplicate delivery handling;
- duplicate-payload mismatch detection;
- stale-replay handling;
- bounded safe HTTP errors.

Reuse patterns, not the WooCommerce webhook resource or secret.

## 8. Goal

Produce a complete implementation plan for:

```text
relevant WordPress catalogue change
→ cache invalidation
→ asynchronous compact signed signal
→ EventSales raw-body verification
→ durable idempotent receipt
→ durable target coalescing
→ bounded dispatcher
→ defer behind active Catalog Sync run when necessary
→ automatically recheck/replay deferred work
→ queue exactly one existing targeted Catalog Sync dry-run
→ fetch authoritative signed WordPress feed
→ produce reviewable dry-run findings and exact hash
→ no Apply
```

Normal target: the resulting targeted dry-run should become visible within five minutes when no existing active run blocks it.

## 9. Architecture questions the plan must decide

Do not leave these as vague “implementation details”:

### HTTP contract

- exact route and path-token/source resolution;
- method and content type;
- maximum raw-body bytes;
- exact JSON schema and enums;
- exact headers;
- exact canonical signature bytes;
- timestamp skew and retry timestamp behaviour;
- stable signal ID behaviour across retries;
- body-hash algorithm;
- dedicated secret and rotation strategy;
- duplicate response;
- payload-mismatch response;
- error and retry status-code matrix;
- rate-limit approach and key;
- safe user-agent requirement.

### WordPress sender

- exact hooks for:
  - event save/status transition;
  - product save/status transition;
  - variation save/status transition;
  - relevant meta relationship changes;
  - trash, restore and permanent deletion;
- autosave/revision suppression;
- allowed post types and meta keys;
- cache invalidation ordering;
- Action Scheduler availability and fallback behaviour;
- asynchronous job group, args and retry schedule;
- signal ID creation and preservation;
- local hook-storm suppression;
- 4xx terminal handling;
- 5xx/timeout retry handling;
- maximum attempts and maximum backlog;
- sender kill switch and optional target/source canary;
- safe diagnostics without body, signature or secret logging.

### EventSales durable model

Decide whether one table is sufficient or two resources are required.

The preferred design hypothesis to evaluate is:

1. `CatalogChangeSignal`
   - immutable/auditable receipt per source + signal ID;
   - payload hash;
   - target identity;
   - source freshness;
   - reason;
   - received/verified timestamps;
   - disposition;
   - linkage to coalesced work and resulting run.

2. `CatalogChangePendingTarget`
   - one mutable aggregate per source + target type + target ID;
   - newest source freshness wins atomically;
   - quiet/debounce deadline;
   - reason set or bounded reason summary;
   - pending/deferred/queued/preview-ready/failed state;
   - resulting Catalog Sync run link;
   - attempt and safe error metadata.

Justify a simpler or different model with concurrency proofs.

### Transaction boundary

Specify how the system guarantees:

- no success response before durable acceptance;
- receipt uniqueness under a race;
- duplicate payload mismatch detection;
- pending-target upsert with newest-freshness-wins semantics;
- durable dispatcher job creation;
- recovery when Oban insertion fails;
- no orphaned receipt or orphaned work item.

Prefer one database transaction for receipt, coalescing/upsert and durable job insertion unless current repository constraints prove another pattern safer.

### Coalescing

Specify:

- coalescing key;
- quiet window;
- freshness comparison;
- how reasons combine;
- bounded target batch size;
- threshold for escalating many targets to one `updated_since` run;
- overlap/safety window for `updated_since`;
- maximum pending rows per source;
- fairness;
- cleanup and retention;
- behaviour for stale/out-of-order signals.

### Active-run defer and replay

This is a critical design section.

The plan must account for `dry_run_ready` being an active state that can persist until human review.

Define:

- how the dispatcher detects an active run;
- how pending targets become durably deferred;
- how and when they are rechecked;
- whether replay is triggered by lifecycle transitions, scheduled bounded recheck, or both;
- how repeated rechecks avoid an Oban storm;
- how an indefinitely unreviewed dry-run is surfaced to an operator;
- how pending signals continue coalescing while blocked;
- how the next run is queued only after the active run is terminal;
- how the one-active-run index remains the final race authority.

Do not rely on PubSub alone for replay.

### Internal Catalog Sync authority

Design a narrow non-admin function, for example:

```elixir
queue_triggered_dry_run(source_system_id, scope, opts)
```

The final name is not prescribed.

It must:

- reject full-feed scope from the trigger path;
- allow only one supported targeted mode;
- validate positive IDs or strict RFC3339 `updated_since`;
- verify the source is active and compatible;
- reuse the existing run-plus-job transaction;
- keep `requested_by_user_id` nil or use explicit system provenance;
- never impersonate an admin;
- return the created run/job;
- preserve the existing unique-index error mapping;
- expose enough linkage for audit and admin status.

### Admin and observability

Define:

- whether to extend `/admin/catalog-sync` or add a focused trigger-status page;
- bounded queries and indexes;
- safe fields only;
- resulting run link;
- deferred reason and age;
- retry count and safe last error;
- backlog warning;
- telemetry event names and bounded metadata;
- PubSub messages as notification only;
- no raw payload, signature, secret or protected data display.

## 10. Working implementation hypothesis to validate

Do not implement this. Assess it and improve it in the plan.

### Proposed flow

1. WordPress hook invalidates the existing feed cache immediately.
2. Hook schedules an Action Scheduler job and returns.
3. Sender creates one compact body:

```json
{
  "version": "2026-07-20.v1",
  "signal_id": "<uuid-v4-or-v7>",
  "source": "wordpress_tickera",
  "target_type": "event|product|variation",
  "target_id": 123,
  "source_updated_at": "2026-07-20T12:00:00Z",
  "reason": "saved|status_changed|metadata_changed|trashed|restored|deleted"
}
```

4. Each retry preserves body and `signal_id`, but generates a fresh timestamp and signature.
5. EventSales verifies raw body, timestamp, signal ID, dedicated secret and source.
6. EventSales transaction:
   - inserts the immutable receipt;
   - handles duplicate/mismatch;
   - upserts the pending target using freshness-safe atomic semantics;
   - inserts or ensures one dispatcher job.
7. Dispatcher waits for the quiet window.
8. If a Catalog Sync run is active:
   - mark pending work deferred;
   - schedule one bounded unique recheck;
   - retain and continue coalescing newer signals.
9. If no run is active:
   - choose one target scope, or an `updated_since` scope after a bounded burst threshold;
   - queue through narrow internal Catalog Sync authority;
   - link pending work to the run.
10. Existing discovery fetches the signed authoritative WordPress feed.
11. Existing planner creates findings and exact dry-run hash.
12. Trigger status becomes `preview_ready` when the run becomes `dry_run_ready`.
13. Nothing Applies automatically.
14. New pending work waits until the active dry-run is Applied, revoked, cancelled or failed.
15. Durable replay resumes after terminal transition or bounded recheck.

### Recommended initial bounds for the plan to evaluate

These are hypotheses, not locked values:

- HTTP body: `<= 4 KiB`
- timestamp skew: `300 seconds`
- WordPress attempts: `5`
- WordPress retry delays: bounded exponential backoff with jitter
- EventSales quiet window: `3–10 seconds`
- direct-target batch threshold: `<= 10`
- escalation threshold: more than `10` pending targets for one source
- dispatcher target fetch: `<= 50`
- deferred recheck: `30–60 seconds`, unique per source
- maximum pending targets per source: explicitly bounded, e.g. `1,000`
- safe error length: `<= 120 characters`
- receipt retention: decide and justify, e.g. `30–90 days`

## 11. Expected future file categories

Your plan must return exact filenames after reconnaissance.

Likely creates to evaluate:

```text
lib/event_sales/ingestion/resources/catalog_change_signal.ex
lib/event_sales/ingestion/resources/catalog_change_pending_target.ex
lib/event_sales/ingestion/catalog_change_intake.ex
lib/event_sales/ingestion/catalog_change_dispatch.ex
lib/event_sales/ingestion/security/catalog_change_signature.ex
lib/event_sales/ingestion/workers/catalog_change_dispatch_worker.ex
lib/event_sales_web/controllers/catalog_change_controller.ex
lib/event_sales_web/plugs/rate_limit_catalog_change_intake.ex
priv/repo/migrations/<timestamp>_add_catalog_change_trigger_tables.exs
test/event_sales/ingestion/catalog_change_intake_test.exs
test/event_sales/ingestion/catalog_change_dispatch_test.exs
test/event_sales/ingestion/workers/catalog_change_dispatch_worker_test.exs
test/event_sales_web/controllers/catalog_change_controller_test.exs
```

Likely modifications to evaluate:

```text
lib/event_sales/ingestion/tickera_catalog_sync.ex
lib/event_sales/ingestion.ex
lib/event_sales_web/router.ex
lib/event_sales_web/live/admin/catalog_sync_live.ex
config/config.exs
config/runtime.exs
integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php
integrations/wordpress/eventsales-tickera-catalog-feed/README.md
docs/ops/tickera_catalog_feed_contract.md
docs/ops/tickera_catalog_feed_eventsales_adapter.md
```

Potential additional lifecycle modifications:

- discovery worker terminal failure path;
- Apply worker terminal path;
- ready-run revocation path;
- PubSub module;
- test support helpers.

Do not include these automatically. Name them only when needed for durable replay.

Explicitly forbidden:

- direct writes to Event/TicketType/ProductMapping from the trigger;
- auto-Apply;
- broad OrderUpserter or order-webhook changes;
- Redis-only pending work;
- source calls from controller or LiveView;
- full feed for each save;
- admin impersonation;
- unrelated dashboard redesign;
- secret values in tests/docs/evidence;
- runtime code changes during this planning phase.

## 12. Tests-first plan requirements

Return an ordered red/green sequence, not a generic list.

At minimum cover:

1. Contract parser and strict body-size validation.
2. Raw-body signature success/failure.
3. timestamp skew.
4. signal ID validation.
5. source/version/reason/target enum validation.
6. no PII or unknown fields accepted.
7. first receipt accepted durably.
8. exact duplicate is idempotent.
9. same signal ID with different body hash is rejected and audited.
10. stale source freshness cannot replace newer pending freshness.
11. concurrent duplicate receipt race.
12. concurrent pending-target upsert race.
13. receipt + pending target + Oban insertion atomicity.
14. enqueue failure produces no false success.
15. quiet-window coalescing.
16. repeated same-target hook burst.
17. distinct target fairness.
18. active run causes durable defer.
19. `dry_run_ready` causes continued defer.
20. terminal run enables replay.
21. database unique index remains final authority in a queue race.
22. internal queue authority accepts only supported targeted scopes.
23. trigger path cannot queue full mode.
24. resulting run uses existing discovery/planner path.
25. resulting run reaches `dry_run_ready`.
26. no Apply worker is enqueued.
27. WordPress save hook performs no remote HTTP inline.
28. WordPress retry preserves signal ID.
29. 4xx is terminal; 5xx/timeouts retry boundedly.
30. cache invalidation still occurs.
31. admin page uses bounded queries and displays no protected fields.
32. feature disabled by default.
33. receiver/sender version skew is safe.
34. rollback kill switches work.
35. end-to-end local acceptance from synthetic signal to targeted preview.

Include exact focused commands and full verification:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
bash scripts/check_no_web_woocommerce_refs.sh
mix test <focused paths>
mix test
mix dialyzer
bash scripts/local_ci.sh
git diff --check
php -l integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php
```

Identify whether the repository currently has a PHP/WordPress automated test harness. If not, propose the smallest credible test addition without introducing a disproportionate toolchain.

## 13. Migration and index plan requirements

For every proposed table/index, list:

- exact column type;
- nullability;
- default;
- foreign key;
- unique constraint;
- partial condition;
- index order;
- expected query;
- race it prevents;
- retention implication.

At minimum evaluate:

- unique `(source_system_id, signal_id)`;
- unique `(source_system_id, target_type, target_id)` for pending work;
- pending/deferred scan by source, state, quiet/recheck timestamp;
- resulting run ID lookup;
- receipt retention by inserted timestamp;
- newest-freshness atomic update;
- safe foreign-key behaviour to Catalog Sync runs.

New tables are initially empty, so justify whether standard transactional indexes are sufficient. Do not assume `CREATE INDEX CONCURRENTLY` is necessary.

## 14. Rollout plan requirements

Return an exact compatibility sequence:

1. Review and approve plan in `JC-117`.
2. Refresh `main`, production facts, final files and interfaces in `JC-123`.
3. Only an `APPROVE` activation supplement unlocks implementation.
4. Implement tests first on a branch from the exact activated SHA.
5. Exact-head independent review in `JC-119`.
6. Separate merge authorisation.
7. Deploy EventSales receiver with feature disabled.
8. Run authorised migration and verify indexes/queues.
9. Configure dedicated trigger path and secret without exposing values.
10. Deploy WordPress sender disabled.
11. Verify version compatibility and health.
12. Enable one controlled source/target.
13. Make one safe event/product/variation edit.
14. Verify:
    - one accepted receipt;
    - one coalesced target;
    - one targeted Catalog Sync run;
    - authoritative feed fetch;
    - `dry_run_ready`;
    - no Apply.
15. Test same-signal duplicate.
16. Test hook burst coalescing.
17. Test active-run defer/replay.
18. Confirm no PII/protected payload in evidence.
19. Expand normal hook enablement only after separate operator verdict.

Rollback order:

1. disable WordPress sender;
2. disable EventSales dispatcher/receiver as appropriate;
3. preserve durable receipts and pending work;
4. do not directly rewrite Catalog Sync run state;
5. resolve existing dry-runs through the existing lifecycle;
6. revert code/config only after schema compatibility review.

## 15. Required output document

Return a completed:

`VS-26E.1_IMPLEMENTATION_PLAN_CURRENT_TRUTH.md`

Use this exact structure:

1. Executive verdict
2. Baseline proof
3. Planning-pack verification
4. Drift from `050d66e8…` to current `main`
5. Files inspected
6. Current repository behaviour
7. Confirmed invariants
8. Proposed architecture and sequence diagram
9. Exact HTTP/signal contract
10. WordPress hooks, suppression and Action Scheduler design
11. Durable resource model
12. Transaction and recovery model
13. Coalescing algorithm
14. Active-run defer/replay algorithm
15. Narrow internal Catalog Sync authority
16. Admin/telemetry/PubSub
17. Exact create/modify/generated/forbidden files
18. Ordered tests-first implementation sequence
19. Migration/index plan
20. Exact verification commands
21. Compatibility rollout
22. Production evidence plan
23. Inputs required from owner/operator
24. Risks and stop conditions
25. `JC-123` activation-supplement inputs
26. Prohibited-actions statement
27. Final verdict:
    - `PACK VALID`
    - `PACK REFRESH RECOMMENDED`
    - `PACK BLOCKED`

Include a Mermaid sequence diagram and state transition table.

## 16. Final response contract

Your response must end with:

```text
Planning baseline inspected:
Current HEAD:
Current origin/main:
Worktree clean:
Planning ZIP SHA-256 verified:
Internal checksums verified:
Pack verdict:
Material drift:
Proposed new resources:
Proposed migrations:
Proposed routes:
Proposed WordPress hooks:
Open owner/operator inputs:
Implementation authorised: no
Files modified: none
Commits created: none
PRs changed: none
Production actions: none
Next gate: JC-117 plan review, then JC-123 activation refresh
```

Also state explicitly:

> No implementation, commit, PR mutation, deployment, migration, WordPress change, Catalog Sync action or production mutation was performed.

---

# Part B — Owner’s working plan

This is the recommended sequence for managing the agent and the slice.

## Gate 1 — JC-115 pack review

Reviewer checks:

- ZIP external SHA;
- internal checksums;
- source/ZIP parity;
- planning baseline;
- current-main drift;
- scope completeness;
- no-auto-apply boundary;
- dedicated trigger secret;
- raw-body HMAC/replay;
- durable receipt before 2xx;
- idempotency and payload mismatch;
- coalescing and bounds;
- active-run defer/replay;
- no admin impersonation;
- migration/index coverage;
- rollout and kill switches.

Recommended verdict:

`APPROVE FOR JC-116 PLANNING ONLY`

Reason:

The pack is internally sound and its two-stage authority explicitly anticipates baseline drift. Current drift does not invalidate planning, but `JC-123` must refresh it before code.

## Gate 2 — JC-116 planning agent

Give the agent:

1. the planning ZIP;
2. this prompt;
3. repository access;
4. current main SHA `4ed9bca09af173399c114e290b02f41a44795da8`;
5. production runtime SHA `59a55523d2afe53f08e2f82becef5adec2bed0d6`;
6. VS-26E.0 closeout evidence identity;
7. permission for local/read-only reconnaissance only.

Expected output:

- one complete current-truth implementation plan;
- no repository mutation;
- clear `PACK VALID`, `PACK REFRESH RECOMMENDED` or `PACK BLOCKED` verdict.

## Gate 3 — JC-117 independent plan review

Challenge especially:

- whether one or two durable resources are needed;
- whether HTTP success can occur before recoverable state;
- whether coalescing can lose newer freshness;
- how deferred work resumes behind `dry_run_ready`;
- whether Action Scheduler retries preserve signal ID;
- whether system queue authority is too broad;
- whether full-mode escalation is accidentally allowed;
- whether lifecycle changes are sufficient for replay;
- whether all query paths have indexes and bounds;
- whether rollout is compatible in both deployment orders.

Do not approve with unresolved “implementation detail” placeholders in these areas.

## Gate 4 — JC-123 activation refresh

Refresh:

- exact current `main`;
- current production SHA;
- VS-26E.0 certified counts and lifecycle state;
- active Catalog Sync runs/jobs;
- WordPress plugin deployed version;
- Action Scheduler availability;
- final route/version/header names;
- final files;
- final migrations/indexes;
- environment-variable names;
- test inventory;
- rollout order;
- stop conditions.

Only `APPROVE` unlocks JC-118.

## Gate 5 — JC-118 implementation

Future authority should be tests-first and exact-file bounded.

Do not combine:

- implementation;
- PR merge;
- deployment;
- migrations;
- WordPress enablement;
- production validation.

Each remains separately reviewed and authorised.

## Gate 6 — JC-119 exact-head review

Require:

- exact head SHA;
- no scope drift;
- all focused/full CI green;
- contract/diff parity;
- migration review;
- concurrency review;
- security/privacy review;
- no-auto-apply proof;
- rollback/runbook parity.

## Gate 7 — JC-120 controlled rollout

Use disabled-by-default receiver first, then disabled WordPress sender, then canary enablement.

Stop on:

- false 2xx;
- duplicate active runs;
- unbounded retries/backlog;
- newer freshness loss;
- synchronous HTTP in save hooks;
- protected data exposure;
- auto-Apply;
- version mismatch;
- absent durable replay.

## Gate 8 — JC-121 certification

Certification evidence should prove:

- target edit sent signal asynchronously;
- receipt durable;
- duplicates idempotent;
- burst coalesced;
- active run deferred safely;
- work replayed after terminal state;
- one targeted dry-run queued;
- feed fetched authoritatively;
- preview visible within target;
- no Apply;
- no PII/secrets;
- queues/indexes healthy.

## Gate 9 — JC-122 closeout

Only after certification:

- commit roadmap state;
- attach immutable evidence;
- close VS-26E.1;
- unlock VS-26E.2 conservative auto-apply planning.

---

# Recommended planning verdict

`PACK VALID FOR PLANNING — REFRESH REQUIRED BEFORE IMPLEMENTATION`

The v0.9.0 planning pack is internally valid and remains useful because it explicitly separates early planning from later implementation activation. Current `main` and production certification must be incorporated by `JC-123`; the agent must not silently reinterpret the old ZIP as current implementation authority.
