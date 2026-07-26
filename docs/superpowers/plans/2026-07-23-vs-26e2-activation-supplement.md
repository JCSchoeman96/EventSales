# VS-26E.2 Conservative Catalog Auto-Apply Activation Supplement

## 1. Slice and gate identity

- Slice: `VS-26E.2 — Conservative Catalog Auto-Apply`
- Gate: `JC-129 — pre-implementation activation review`
- Parent: `JC-124`
- Planning: `JC-127 Done`
- Independent plan review: `JC-128 APPROVE`
- Implementation: `JC-130 locked until this supplement is accepted`
- Authority: this supplement may authorise implementation only. It does not authorise merge, deployment, a shared-environment migration, configuration mutation, observation, a canary, Catalog Sync, Apply, WordPress mutation, or production activity.

## 2. Exact governance inputs

- JC-129 repository baseline: `8610dd882aa7ea0d1a215e9f9abbea0d5303bed1`
- Approved plan: `docs/superpowers/plans/2026-07-22-vs-26e2-conservative-catalog-auto-apply.md`
- Approved plan SHA-256: `12a6145d96abdeb4bc6e141396572f1050fae58fe95bcf3de37fab65c33efb2a`
- Approved pack: `slices/EventSales_VS-26E.2_PLANNING_PACK_v0.9.1_38df5752.zip`
- Approved pack SHA-256: `4b1b5cc428049690da929c30f755abf85b945f23d974ce78a50059e81e23ef30`
- Pack version: `0.9.1`
- Pack execution authority: `false`
- Activation gate: `JC-129`

Any baseline, plan-digest, pack-digest, or supplement-digest change stops JC-130 until the changed artifact is reviewed.

## 3. Predecessor evidence

VS-26E.1 passed at serving commit `149816a69728b6d09be53275aa6255f4f2e1b0d6`.

Accepted evidence:

- signed receiver protocol passed;
- duplicate and changed-payload handling passed;
- durable payload immutability passed;
- generation fencing reached generation 2;
- dispatcher, Catalog Sync, and Apply activity remained zero;
- final receiver, dispatcher, and feed flags were disabled;
- production mutations were zero;
- no secrets were exposed.

Accepted qualification: this evidence was obtained in isolated Railway staging. It was not an actual production WordPress lifecycle mutation. It does not prove a production auto-Apply lifecycle. The controlled-environment evidence in this supplement is required before any later production enablement.

## 4. Current-main drift

Comparison from planning baseline `d489931c5e18da57fa4055538b7b2ac7a87e704d` to JC-129 baseline adds only:

```text
A docs/superpowers/plans/2026-07-22-vs-26e2-conservative-catalog-auto-apply.md
```

Classification: **none beyond the approved documentation artifact; no material implementation drift**.

Current dependency and interface truth:

| Component | Reviewed version/contract |
|---|---|
| Elixir | `1.19.3`, OTP 28 |
| Phoenix | `1.8.9` |
| Phoenix LiveView | `1.1.32` |
| Ash | `3.29.3` |
| AshPostgres | `2.10.0` |
| Ecto/EctoSQL | `3.14.0` |
| Oban | `2.22.1` |
| Postgrex | `0.22.3` |
| Redix | `1.5.3` |
| Cachex | not a direct dependency; no new Cachex correctness dependency is permitted |
| Repo transaction | `EventSales.Repo.transaction/1` available |
| Initial job insertion | `Oban.insert/3` with `Ecto.Multi` available |
| Same-job retry | default-instance `Oban.retry_job/1` available |
| Ash generation | `mix ash.codegen` and CI `ash.codegen --dry-run` remain current |
| Apply fencing | `TickeraCatalogSync.queue_apply/3`, `claim_for_apply/3`, and `Applier.apply/3` remain available |

Repository readiness: **compatible with the approved plan**.

## 5. Final domain and resource map

```text
WordPress signed feed v2
  -> WordPressFeedResponse
  -> DiscoveryResult
  -> SourceRisk + CatalogRow
  -> Normalizer
  -> Planner
  -> exact eleven-key tickera_catalog_plan.v2
  -> durable run snapshot/findings/hash
  -> pure AutoApplyPolicy
  -> durable TickeraCatalogAutoApplyDecision
  -> TickeraCatalogAutoApply orchestration
  -> exact linked ApplyTickeraCatalogWorker
  -> existing TickeraCatalog.Applier
  -> Event / TicketType / ProductMapping
```

Ownership:

- `TickeraCatalog.Applier` remains the sole automated Event, TicketType, and ProductMapping writer.
- The policy is pure and has no Repo, clock, HTTP, PubSub, cache, WooCommerce, or Oban dependency.
- Orchestration owns durable decision and enqueue transitions.
- Postgres owns eligibility, configuration revision, decision, linkage, and audit truth.
- Oban owns bounded execution only.
- Redis, ETS, and any future cache are optional read accelerators only.
- LiveView renders bounded durable state and receives post-commit PubSub; it does not poll or call WooCommerce.
- Human Apply remains a separate existing path and does not require an auto-Apply decision.

## 6. Final implementation inventory

### Create

```text
lib/event_sales/catalog/tickera_catalog/source_risk.ex
lib/event_sales/catalog/tickera_catalog/snapshot_canonicalizer.ex
lib/event_sales/catalog/tickera_catalog/auto_apply_policy.ex
lib/event_sales/ingestion/resources/tickera_catalog_auto_apply_config.ex
lib/event_sales/ingestion/resources/tickera_catalog_auto_apply_decision.ex
lib/event_sales/ingestion/tickera_catalog_auto_apply.ex
lib/event_sales/ingestion/tickera_catalog_auto_apply_config.ex
lib/event_sales/ingestion/workers/evaluate_tickera_catalog_auto_apply_worker.ex
lib/event_sales/ingestion/workers/recover_tickera_catalog_auto_apply_worker.ex
integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-feed-test.php
```

### Modify

```text
integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php
docs/ops/tickera_catalog_feed_contract.md
lib/event_sales/catalog/tickera_catalog/wordpress_feed_response.ex
lib/event_sales/catalog/tickera_catalog/wordpress_feed_discovery_source.ex
lib/event_sales/catalog/tickera_catalog/discovery_result.ex
lib/event_sales/catalog/tickera_catalog/catalog_row.ex
lib/event_sales/catalog/tickera_catalog/normalizer.ex
lib/event_sales/catalog/tickera_catalog/plan.ex
lib/event_sales/catalog/tickera_catalog/planner.ex
lib/event_sales/catalog/tickera_catalog/applier.ex
lib/event_sales/catalog/resources/source_system.ex
lib/event_sales/ingestion/resources/tickera_catalog_sync_run.ex
lib/event_sales/ingestion/tickera_catalog_sync.ex
lib/event_sales/ingestion/catalog_change_dispatch.ex
lib/event_sales/ingestion/workers/discover_tickera_catalog_worker.ex
lib/event_sales/ingestion/workers/apply_tickera_catalog_worker.ex
lib/event_sales/ingestion.ex
lib/event_sales/telemetry.ex
lib/event_sales_web/live/admin/catalog_sync_live.ex
config/config.exs
config/runtime.exs
test/support/tickera_catalog_fixtures.ex
test/support/catalog_sync_run_helpers.ex
```

All listed modify paths exist at the activation baseline.

### Generated

Ash resources are the only schema authority. JC-130 runs exactly:

```text
mix ash.codegen vs_26e2_catalog_auto_apply
```

Expected generated categories:

```text
priv/repo/migrations/<generated>_vs_26e2_catalog_auto_apply.exs
priv/resource_snapshots/repo/catalog_source_systems/*
priv/resource_snapshots/repo/ingestion_tickera_catalog_sync_runs/*
priv/resource_snapshots/repo/ingestion_tickera_catalog_auto_apply_configs/*
priv/resource_snapshots/repo/ingestion_tickera_catalog_auto_apply_decisions/*
docs/architecture/domain_map.json
docs/architecture/module_manifest.json
```

No hand-authored second migration is allowed. Generated artifacts do not yet exist and were not reviewed by JC-129. JC-130 must review them against Section 11 before committing.

### Tests

Create:

```text
test/event_sales/catalog/tickera_catalog/source_risk_test.exs
test/event_sales/catalog/tickera_catalog/snapshot_canonicalizer_test.exs
test/event_sales/catalog/tickera_catalog/auto_apply_policy_test.exs
test/event_sales/ingestion/resources/tickera_catalog_auto_apply_config_test.exs
test/event_sales/ingestion/tickera_catalog_auto_apply_test.exs
test/event_sales/ingestion/workers/evaluate_tickera_catalog_auto_apply_worker_test.exs
test/event_sales/ingestion/workers/recover_tickera_catalog_auto_apply_worker_test.exs
```

Modify:

```text
test/event_sales/catalog/tickera_catalog/wordpress_feed_response_test.exs
test/event_sales/catalog/tickera_catalog/wordpress_feed_discovery_source_test.exs
test/event_sales/catalog/tickera_catalog/normalizer_test.exs
test/event_sales/catalog/tickera_catalog/planner_applier_test.exs
test/event_sales/ingestion/tickera_catalog_sync_test.exs
test/event_sales/ingestion/tickera_catalog_sync_concurrency_test.exs
test/event_sales/ingestion/workers/discover_tickera_catalog_worker_test.exs
test/event_sales/ingestion/workers/apply_tickera_catalog_worker_test.exs
test/event_sales_web/live/admin/catalog_sync_live_test.exs
test/event_sales/ash_resource_smoke_test.exs
test/event_sales/domain_boundaries_test.exs
```

### Documentation

```text
docs/architecture/tickera-catalog-auto-apply.md
docs/runbooks/tickera-catalog-auto-apply.md
docs/runbooks/tickera-catalog-auto-apply-rollback.md
docs/evidence/vs-26e2-implementation-evidence.md
```

No unlisted path may be added without explaining why it is generated or obtaining review for a material scope change.

## 7. Final snapshot and policy contracts

- Snapshot schema: `tickera_catalog_plan.v2`.
- The persisted snapshot is the approved closed eleven-key object.
- Unknown keys, including a `dry_run_hash` snapshot key, fail closed.
- Canonical bytes use the approved recursive scalar normalization, map ordering, and list sort keys.
- SHA-256 is calculated over the exact canonical bytes.
- `dry_run_hash` is external to the snapshot and stored on the run, decision, and automatic job linkage.
- Recomputed snapshot hash, run hash, decision hash, and automatic job hash must match.
- Existing unversioned snapshots and `tickera_catalog_plan.v1` remain Human-only and are never rewritten.
- Policy version: `conservative_auto_apply.v1`.
- A missing or unsupported snapshot/policy version is ineligible.

Initial action policy:

| Resource | Candidate actions | Manual/ineligible |
|---|---|---|
| Event | `create`; proven no-mutation `reuse` | `update_metadata`, `adopt_existing`, unknown |
| TicketType | `create`; proven same-event `reuse` | `adopt_existing`, unknown |
| ProductMapping | `create` | `move`, `update`, `deactivate`, `delete`, unknown |

Additional invariants:

- every variation is ineligible;
- one disallowed action makes the whole run ineligible;
- mixed plans are not partially auto-applied;
- only origin `targeted_catalog_change` is eligible;
- `human_admin` and `legacy_unknown` are ineligible;
- finding-code allowlist is empty: any finding is ineligible;
- unknown/missing risk, action, finding, origin, history, or version is ineligible.

## 8. Final source-risk contract

Closed v1 risk vocabulary:

```text
private_event
draft_event
trashed_event
deleted_event
private_product
draft_product
trashed_product
deleted_product
private_variation
draft_variation
variation_mapping_required
ambiguous_variation_name
subscription_product
payment_plan_product
membership_product
bundle_product
addon_product
unsupported_product_type
missing_ticket_template
unknown_product_semantics
duplicate_ticket_name
existing_mapping_conflict
product_moved_between_events
ambiguous_identity
missing_source_risk_data
```

Repository evidence confirms current Human-only feed schemas `2026-07-08.v1` and `2026-07-05.v1`; neither may produce an auto-eligible v2 snapshot. Current feed code exposes repository-backed status, WooCommerce product-type taxonomy, `_ticket_template`, reviewed subscription fields, variation identity, and signed target reason/membership evidence.

Payment plan beyond reviewed subscription evidence, membership, bundle, and add-on have no confirmed deterministic source in current repository evidence. V2 must persist `unknown_product_semantics` and remain ineligible. It must not infer semantics from title, slug, description, category labels, or arbitrary metadata names. Non-published or absent targeted rows must produce durable risk/tombstone/missing evidence; they may not disappear silently.

WordPress was not accessed during JC-129. Sender version/state and a suitable isolated canary source remain controlled-environment evidence, not prerequisites for writing fail-closed implementation code.

## 9. Final zero-history contract

Automatic eligibility requires all of the following present as non-negative integers and equal to zero:

```text
affected_pending_lines
affected_quantity
eligible_lines
deferred_lines
conflicting_lines
already_mapped_lines
warning_count
unresolved_destination_count
unknown_classification_count
```

Every destination must be resolved. Missing, malformed, negative, non-zero, unsupported-status, or unknown historical evidence is ineligible. Legacy warning collections remain Human-only; v2 uses `warning_count`.

## 10. Durable decision, configuration, and state contracts

Dedicated decision identity:

```text
(catalog_sync_run_id, dry_run_hash, policy_version)
```

The decision stores direct `source_system_id`. A private transactional action accepts only the run ID, locks the run, copies its source, rejects a run without a source, and prevents either relationship from changing.

Decision results:

```text
observe | eligible | ineligible
```

Enqueue states:

```text
not_applicable | pending | claimed | enqueued
retryable_failure | terminal_failure | superseded
```

Apply audit states:

```text
not_started | claim_rejected | claimed | completed | failed
```

Configuration:

- one database-enforced singleton row with `singleton_key='global'`;
- unique singleton key plus check constraint;
- private insert-on-conflict/get bootstrap;
- no public create/delete;
- revision starts at 1;
- real eligibility changes increment revision exactly once under lock;
- no-op leaves revision unchanged;
- caller cannot set revision;
- stale revision returns a bounded conflict;
- fingerprint is deterministic SHA-256 over the approved closed projection;
- every decision persists revision and fingerprint;
- revision/fingerprint change supersedes an old decision rather than activating it.

## 11. Final database and migration contract

No generated migration exists at JC-129. JC-129 approves the expected contract, not generated output.

Required tables/columns:

- additive auto-Apply configuration table;
- additive auto-Apply decision table;
- direct decision `source_system_id` foreign key;
- nullable run origin expansion with database default `legacy_unknown`;
- primary-key-batched backfill of existing runs;
- validation before non-null;
- permanent v1 `legacy_unknown` default;
- SourceSystem mode `inherit` and allowlist `false` safe defaults.

Required uniqueness and indexes:

```text
UNIQUE (catalog_sync_run_id, dry_run_hash, policy_version)
UNIQUE (apply_enqueue_key)
UNIQUE (apply_job_id) WHERE apply_job_id IS NOT NULL
INDEX (catalog_sync_run_id, evaluated_at DESC, id DESC)
INDEX (source_system_id, inserted_at DESC, id DESC)
INDEX (next_attempt_at, source_system_id, id)
  WHERE enqueue_state IN ('pending', 'claimed', 'retryable_failure')
INDEX (policy_version, snapshot_schema_version, evaluated_at DESC)
```

Required row checks:

- closed decision/enqueue/audit/origin/mode values;
- lowercase 64-hex dry-run hash and configuration fingerprint;
- bounded snapshot/policy version format;
- non-negative configuration revision;
- enqueue attempts `0..20`;
- at most 32 reason codes, each at most 80 characters;
- closed summary byte limits;
- retry timestamp/state consistency;
- linkage required for enqueued/completed states;
- no linkage for not-applicable;
- terminal/superseded irreversibility through private actions.

Migration sequence:

1. Ash resources are authoritative.
2. Run `mix ash.codegen vs_26e2_catalog_auto_apply` once.
3. Review the generated migration and resource snapshots.
4. Add nullable/default-safe fields.
5. Backfill run origins in primary-key batches of 1,000.
6. Validate values and constraints.
7. Add/validate non-null while retaining `legacy_unknown`.
8. Do not rewrite existing snapshots or hashes.
9. Do not delete audit rows.

Migration safety:

- use `lock_timeout` 5 seconds and `statement_timeout` 60 seconds;
- new-table indexes may be transactional because tables start empty;
- no transaction-pooling compatibility is claimed;
- shared migration execution requires a proven direct or session-capable connection;
- code rollback retains additive schema;
- schema rollback is allowed only when no decision rows or linked jobs exist;
- otherwise disable automation and preserve audit data.

Implementation STOP conditions:

- `DIRECT_DATABASE_URL` or an equivalent proven session-capable route is absent;
- connection topology cannot support advisory-lock/session-sensitive DDL;
- current run cardinality is greater than 10,000;
- a projected backfill batch exceeds 60 seconds;
- generated output differs materially from this contract;
- a second hand-written migration appears;
- an existing snapshot/hash rewrite appears;
- an unsafe table rewrite or unacceptable lock appears.

## 12. Railway and database topology evidence

Read-only, redacted evidence at JC-129:

| Fact | Production-named pre-handover environment | Staging |
|---|---|---|
| EventSales service | present, healthy | present, healthy |
| PostgreSQL service | present, healthy | present, healthy |
| Redis service | present, healthy | present, healthy |
| Read replica | not observed | not observed |
| `DATABASE_URL` | present; private/direct-like endpoint | present; private/direct-like endpoint |
| `DIRECT_DATABASE_URL` | present; private/direct-like endpoint | present; private/direct-like endpoint |
| Runtime/direct values distinct | no | no |
| Documented pooling mode | session pooling; transaction pooling not selected | same |
| Oban database | `EventSales.Repo` on runtime Postgres | same |

The variable names and configuration paths distinguish runtime and migration ownership, but the observed variables currently resolve to the same private endpoint. JC-130 may implement against this topology. Before any shared migration, release/deployment review must prove that the selected endpoint is direct or session-capable; inability to prove that is a hard STOP.

A local read-only cardinality query could not resolve the Railway private hostname. It was not retried and no database value was printed or changed. JC-130 must obtain bounded run/source counts from an execution context with private-network access before considering a shared migration. This uncertainty does not block local code, migration generation, or review.

## 13. Final configuration defaults and kill switches

Implementation defaults:

```text
CATALOG_AUTO_APPLY_HARD_ENABLED=false or absent -> interpreted false
durable global mode=disabled
source mode=inherit
source allowlisted=false
enabled policy versions=[]
supported snapshot versions may include tickera_catalog_plan.v2 for evaluation
```

An enabled policy version list remains empty until a separately authorised activation. Supporting v2 evaluation never overrides disabled mode.

Precedence:

```text
hard kill false -> disabled
global disabled -> disabled
source disabled or not allowlisted -> disabled
global observe -> observe
source observe -> observe
enabled only when hard kill true, global enabled,
  source enabled/inherit, source allowlisted,
  policy enabled, and snapshot supported
```

Malformed hard-kill input resolves disabled with an operator-visible bounded health error. Observation persists decisions but never queues Apply. Human Apply ignores automation configuration.

Planned operator surfaces:

- hard disable: set `CATALOG_AUTO_APPLY_HARD_ENABLED=false`;
- durable global disable: `TickeraCatalogAutoApplyConfig.set_global_mode(:disabled, expected_revision: revision, actor: admin)`;
- source disable: `TickeraCatalogAutoApplyConfig.set_source_mode(source_id, :disabled, expected_revision: revision, actor: admin)`;
- source allowlist removal: `TickeraCatalogAutoApplyConfig.set_source_allowlisted(source_id, false, expected_revision: revision, actor: admin)`;
- policy disable: `TickeraCatalogAutoApplyConfig.set_enabled_policy_versions([], expected_revision: revision, actor: admin)`.

JC-130 must implement and test these exact domain/facade surfaces or stop for review before renaming them. JC-129 did not execute any command.

Read-only current state:

- `CATALOG_AUTO_APPLY_HARD_ENABLED` is absent in both inspected environments and therefore must remain interpreted false after implementation;
- Catalog Change receiver/dispatcher are absent in the production-named pre-handover environment and disabled in staging;
- Catalog Feed is disabled in both inspected environments.

## 14. Oban and concurrency contract

Current Oban truth:

- repo: `EventSales.Repo`;
- notifier: `Oban.Notifiers.Postgres`;
- Apply queue: `tickera_sync`, concurrency 1;
- Apply worker attempts: 3;
- current Apply uniqueness: 300 seconds by run ID, defense in depth only;
- Cron owns queue snapshots every minute and failed-job alerts every five minutes;
- no dedicated evaluator/recovery queue exists.

JC-130 must either use the existing `tickera_sync` queue with bounded work or add reviewed `catalog_auto_apply` evaluator/recovery queue configuration. Adding a queue is implementation configuration only; enabling automation or changing a Railway variable is not authorised. The final implementation report must state the selected queue and concurrency.

Correctness invariants:

- Postgres unique decision identity;
- durable unique enqueue key;
- one non-null linked Apply job ID;
- decision claim, `Oban.insert/3`, job linkage, and enqueued transition in one `Ecto.Multi` transaction;
- same-job `Oban.retry_job/1` only after linkage;
- never insert a replacement after linkage;
- initial insertion consumes attempt 1;
- attempt 20 failure is terminal and attempt 21 is impossible;
- recovery is indexed, source-scoped, batch 100, and uses `FOR UPDATE SKIP LOCKED`;
- automatic Apply revalidates hash, versions, origin, source, configuration, and linkage at claim;
- Human Apply and cancellation race through the existing atomic run claim;
- Oban uniqueness is never the correctness guarantee;
- no GenServer, Redis, ETS, or cache owns correctness.

## 15. Performance and scaling review

| Path | Layer/cardinality | Required index/bound | Cache/PubSub and multi-node rule |
|---|---|---|---|
| Evaluate one run | cold Postgres; one run, findings, source, singleton config | PK/run FK lookups; no source-wide scan | no cache required; one durable decision identity |
| Canonical policy | in-memory bounded snapshot already loaded by run | closed size-bounded snapshot | pure; no source call or process authority |
| Decision create/read | cold Postgres; one per run/hash/policy | unique identity and run index | optional read cache only after commit |
| Initial enqueue | Postgres + Oban; one linked job | unique enqueue/job identities; row lock | one transaction across nodes |
| Recovery | cold Postgres/Oban; recoverable states only | partial source-scoped index; batch 100; `SKIP LOCKED` | no scan, no replacement job |
| Latest run decision | cold Postgres; one bounded result | run/evaluated-at index | optional cache invalidated after commit |
| Source admin history | cold Postgres; bounded page | `(source_system_id, inserted_at DESC, id DESC)` | cursor page 25, max 100; no polling/count |
| Historical proof | persisted aggregate | no raw-line load; existing forecast bounded at 5,000 pairs | SQL aggregation/streaming remains upstream |
| Admin notification | post-commit PubSub | bounded identifiers/status only | notification, never authority |

Targets and safeguards:

- normal indexed single-decision and source-page reads target staging p95 below 100 ms;
- no full-table counts during peak;
- no unbounded source/history/identifier arrays;
- no evaluator WooCommerce call;
- no checkout, scanner, or ticket-sale write-path work;
- no cache required for correctness;
- any introduced read cache uses post-commit invalidation and existing stampede protection;
- multiple nodes converge through database uniqueness and locks.

JC-130 evidence must include `EXPLAIN` for:

1. recovery lookup;
2. latest decision for run;
3. recent source decisions.

## 16. Security, privacy, and source isolation

Decisions, summaries, logs, PubSub, telemetry, tests, and admin UI must exclude:

- customer names/emails and other PII;
- billing/shipping data;
- order payloads;
- payment data;
- ticket tokens;
- WordPress credentials;
- raw WordPress responses;
- arbitrary source metadata or descriptions;
- raw exception messages and stack traces;
- secrets and connection values.

Allowed decision content is closed, bounded identifiers, enums, counts, versions, modes, timestamps, reason codes, and an internal error reference. No source-controlled string may become a dynamic atom. Telemetry event names/labels are fixed and low-cardinality.

Every recovery/admin query carries `source_system_id`; the decision stores it directly, copied transactionally from the locked run. Admin visibility remains authorised and source-scoped. PubSub carries bounded authorised IDs/status only.

Security/privacy readiness: **no unresolved blocker; JC-130 must prove protected-key rejection and source-isolation tests**.

## 17. JC-130 implementation evidence

JC-130 must produce, without deployment or enablement:

- exact baseline/plan/pack/supplement digest verification;
- tests-first commits for every implementation unit;
- focused feed/parser/Normalizer/Planner/policy/resource/worker/UI tests;
- full repository CI;
- canonical hash permutation, unknown-key, legacy, and linkage tests;
- source-risk propagation and silent-filter prevention tests;
- empty finding allowlist and zero-history tests;
- database constraint/index and direct-source ownership tests;
- decision/evaluator/enqueue multi-node race tests;
- initial insertion rollback and same-job recovery tests;
- attempt-20/no-attempt-21 tests;
- Human Apply/cancellation/automatic claim race regressions;
- malformed/disabled configuration tests;
- migration diff and generated resource snapshot review;
- old/new-code migration compatibility and rollback tests;
- bounded summary/protected-data/source-isolation tests;
- admin cursor pagination and no-polling tests;
- query-plan evidence where locally available;
- updated architecture and runbooks;
- exact implementation evidence report;
- draft implementation PR only.

Generated migration review occurs in JC-130. No claim that it has already passed review is permitted.

## 18. Later controlled-environment evidence

These actions are not authorised or performed by JC-129 or JC-130:

1. Deploy with hard kill false and durable global mode disabled.
2. Verify migration state, constraints, indexes, health, and actual topology.
3. Enable observation only for one isolated source.
4. Prove decisions persist while Apply jobs remain zero.
5. Exercise and record ineligible cases:
   - `update_metadata`;
   - variation;
   - any finding/warning;
   - historical impact;
   - missing risk;
   - unknown semantics;
   - unsupported origin;
   - source disabled/not allowlisted;
   - configuration revision mismatch.
6. Exercise one additive, published, simple, zero-history candidate.
7. Verify exact run/decision/job hash linkage.
8. Verify at most one Apply job.
9. Verify the existing Applier is the only catalogue writer.
10. Verify global/source/policy kill switches.
11. Verify Human Apply remains available.
12. Record bounded durable evidence without protected payloads.

Before any production auto-Apply enablement, the activation review must identify the exact WordPress sender/plugin version, sender state, isolated source, deterministic source fields, and target lifecycle protocol. Payment plan, membership, bundle, and add-on remain unknown/ineligible unless separately reviewed deterministic evidence exists.

## 19. Rollback and implementation STOP conditions

Rollback posture:

- disable the hard gate first;
- set global mode disabled;
- disable/remove the source allowlist;
- disable the policy version;
- preserve decisions, runs, jobs, and audit rows;
- roll code back while retaining additive schema;
- never automatically drop audit data;
- Human Apply remains available.

JC-130 stops immediately when:

- current main, plan, pack, or supplement digest differs;
- generated migration materially differs from Section 11;
- a safe session-capable migration path cannot be proven before shared migration;
- run cardinality exceeds 10,000 or batch projection exceeds 60 seconds;
- unsafe rewrite/lock or a second migration appears;
- Applier is no longer the sole automated catalogue writer;
- Human Apply requires an auto decision or changes authorization/warnings;
- source risk can disappear or unknown data becomes safe;
- the canonical snapshot/hash contract changes;
- a legacy snapshot becomes auto-eligible;
- uniqueness cannot be database-enforced;
- concurrent tests can create duplicate decisions/jobs or mismatched source ownership;
- linkage/retry can create a replacement job;
- attempt exhaustion lacks a terminal state;
- malformed/absent hard kill does not disable;
- observation can enqueue Apply;
- a query is unbounded or loses source isolation;
- protected data enters decisions, logs, PubSub, telemetry, or UI;
- implementation requires Railway, WordPress, shared-database, Redis, Catalog Sync, Apply, deployment, or production mutation;
- focused/full CI or evidence remains incomplete.

JC-130 stops after code, generated migration/snapshots, tests, evidence, and a draft implementation PR. It does not merge, deploy, migrate a shared environment, change configuration, run a canary, or enable automation.

## 20. Material uncertainties

The following are explicit, fail-closed uncertainties rather than implementation blockers:

1. `DATABASE_URL` and `DIRECT_DATABASE_URL` are both present but currently resolve to the same private endpoint. Prove session-capable migration execution before a shared migration.
2. Current run/source cardinality was not obtainable from the local host because Railway private DNS is not locally resolvable. Measure it from a private-network execution context before a shared migration.
3. WordPress sender/plugin version, sender state, isolated canary source, and lifecycle facts were not inspected. They are required before controlled-environment activation, not before fail-closed implementation.
4. Payment-plan, membership, bundle, and add-on semantics have no confirmed deterministic source and therefore remain unknown/ineligible.
5. The dedicated evaluator/recovery queue does not exist; JC-130 must select the bounded existing queue or add reviewed configuration while keeping the feature disabled.

None of these uncertainties permits a safe value to be inferred or authorises an environment mutation.

## 21. Final verdict

**APPROVE**

Current main, approved plan, and approved pack match exactly. Drift is documentation-only. Required files and APIs remain compatible. The implementation inventory, migration contract, disabled defaults, database-backed concurrency, fail-closed source policy, performance bounds, privacy controls, evidence requirements, and implementation STOP conditions are decision-complete.

This APPROVE authorises only JC-130 implementation against:

```text
baseline: 8610dd882aa7ea0d1a215e9f9abbea0d5303bed1
plan: 12a6145d96abdeb4bc6e141396572f1050fae58fe95bcf3de37fab65c33efb2a
pack: 4b1b5cc428049690da929c30f755abf85b945f23d974ce78a50059e81e23ef30
supplement: digest recorded after final validation
```

It does not authorise merge, deployment, a shared migration, Railway/WordPress/database/Redis mutation, observation, canary execution, Catalog Sync, Apply, or production activity.
