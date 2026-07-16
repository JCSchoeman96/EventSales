# EventSales Feature Pack Standard

## Purpose

Every meaningful EventSales slice must receive a repository-specific feature pack before implementation begins.

A feature pack is not a generic product brief. It is an implementation contract anchored to:

- the exact current `main` commit;
- the actual modules, resources, tests, migrations, routes, and scripts in the repository;
- the current production evidence and open issues;
- EventSales architectural and security rules.

The pack exists to prevent coding agents from guessing architecture, creating parallel write paths, changing unrelated authority, or implementing against stale repo assumptions.

## Standard Folder

Use:

```text
docs/feature_packs/<ordinal>_<slice>_<short-slug>/
```

Example:

```text
docs/feature_packs/0001_VS-26E.0_catalog-lifecycle-production-baseline/
```

Do not reuse or renumber an existing ordinal. When the next pack begins, inspect the directory and choose the next available number.

## Required Files

Every feature pack must contain:

```text
<SLICE>-FEATURE_PACK.md
CODING_AGENT_PROMPT.md
TOON_PROMPTS.md
ACCEPTANCE_CHECKLIST.md
pack.json
```

Add these when relevant:

```text
EVIDENCE_TEMPLATE.md
ROLLBACK_PLAN.md
MIGRATION_PLAN.md
PERFORMANCE_EVIDENCE.md
SECURITY_REVIEW.md
RUNBOOK.md
FAILURE_MATRIX.md
```

A planning-only slice may contain only documentation deliverables, but it still requires the same scope, non-goal, acceptance, verification, and stop-condition discipline.

## Required Feature Pack Sections

The main `<SLICE>-FEATURE_PACK.md` must contain the following sections.

### 1. Title and Status

Include:

- Slice ID.
- Human-readable name.
- Pack version.
- Pack status: `draft`, `review_ready`, `implementation_ready`, `implemented`, or `production_validated`.
- Exact baseline branch and SHA.
- Owning GitHub issue.
- Programme and predecessor/successor.

### 2. Executive Summary

Describe:

- the exact operator/user outcome;
- why the slice is needed now;
- what durable invariant it establishes;
- why it is a vertical slice rather than a broad refactor.

### 3. Current Repository Truth

This section is mandatory and must be refreshed from the repository when the pack is created.

List:

- existing relevant modules and their current responsibilities;
- existing resources/actions/state machines;
- existing routes/LiveViews/controllers;
- existing workers and queue configuration;
- existing tests and fixtures;
- existing migrations/indexes;
- existing scripts/runbooks;
- relevant merged PRs and open issues;
- known production evidence;
- known placeholders or incomplete paths.

Do not copy an old pack’s repo truth without re-verifying every claim.

### 4. Goal and User Outcome

State what becomes possible after the slice.

The goal must be testable and operationally observable.

Bad:

```text
Improve sync.
```

Good:

```text
A missed WooCommerce order update is fetched through an updated-since cursor, processed through the existing OrderUpserter, reflected in the affected event aggregate, and visible on the event page without creating a duplicate order or order item.
```

### 5. Dependencies and Blockers

List:

- hard slice dependencies;
- issue/PR dependencies;
- production validation dependencies;
- config/secret dependencies;
- package or infrastructure dependencies;
- which downstream slices this pack blocks.

Classify each dependency as:

- merged/available;
- pending;
- production-validation required;
- explicitly out of scope.

### 6. Scope

Describe the smallest end-to-end behavior included.

Cover all layers needed for the outcome:

- source/contract;
- intake/controller when applicable;
- orchestration/worker;
- Ash resource/actions;
- persistence/indexes;
- cache/PubSub/read models;
- LiveView/admin surface;
- tests;
- docs/runbooks;
- deployment/validation.

### 7. Explicit Non-Goals

List what must not change.

Typical EventSales exclusions:

- payment authority;
- scanner authority;
- ticket issuance;
- PDF/wallet/delivery;
- refund/revocation semantics;
- webhook signature/intake behavior;
- `OrderUpserter` semantics;
- `MappingResolver` authority;
- historical mapped OrderItem mutation;
- direct Woo REST from web modules;
- public routes;
- customer PII exposure;
- unrelated frontend redesign;
- Redis as durable truth.

Do not use “unchanged unless needed.” Name the boundary precisely.

### 8. Domain Model and Durable Truth

Identify:

- entities/resources involved;
- durable identity keys;
- relationships;
- source-of-truth fields;
- state transitions;
- uniqueness rules;
- concurrency/ownership rules;
- immutable history rules;
- audit requirements.

For every new field/table/index, state why existing data cannot safely represent the requirement.

### 9. Contracts and Interfaces

Document exact changes to:

- HTTP routes and request/response bodies;
- webhook/feed versions;
- worker args and return values;
- Ash actions and accepted attributes;
- PubSub topics/messages;
- cache keys and TTLs;
- LiveView params/events;
- CSV/export columns;
- environment variables.

Include compatibility and versioning behavior.

Never add a new public interface implicitly.

### 10. Architectural Boundaries

The pack must explicitly restate applicable boundaries, including:

```text
LiveView/controller/component -> domain facade/read model only
approved ingestion service/Oban worker -> WooCommerceClient
Ash actions/domain services -> durable mutations
Postgres -> source of truth
Redis/ETS/Cachex -> hot/warm mirror only
PubSub -> notification only, never truth
```

Name any exception and justify it.

### 11. Security, Privacy, and Evidence Rules

Cover:

- authentication and authorization;
- replay/signature rules;
- PII visibility;
- secrets/tokens/raw payload restrictions;
- log/telemetry cardinality;
- audit logging;
- safe error codes;
- evidence redaction.

List forbidden values explicitly when the slice touches external systems or production evidence.

### 12. Performance and Scaling Review

For every read/write path, answer:

- Is it hot, warm, or cold?
- What is the maximum expected cardinality?
- Is the query bounded?
- What index supports it?
- Could it scan raw orders during a LiveView request?
- What is the worker concurrency?
- What protects WooCommerce and Postgres?
- What is the timeout/backoff policy?
- What prevents duplicate or overlapping work?
- What is the cache/read-model strategy?
- What representative query/load evidence is required?

Do not add an index based only on intuition; require representative query evidence when appropriate.

### 13. Failure Modes and Recovery

List concrete failure paths such as:

- request accepted but enqueue fails;
- worker crashes after claim;
- duplicate worker execution;
- stale source update;
- partial page processing;
- cursor advancement failure;
- cache/PubSub failure after durable commit;
- migration/index failure;
- source timeout/rate limit;
- LiveView disconnect;
- production deploy during active work.

For each, define durable state, retry behavior, operator visibility, and whether work may continue.

### 14. Files To Inspect First

List exact current repository paths the coding agent must read before changing code.

This list should include:

- `AGENTS.md`;
- relevant canonical docs;
- current domain modules;
- current tests;
- current migrations/indexes;
- current asset conventions for UI slices;
- relevant integration plugin files.

### 15. Files Expected To Create/Modify

Separate:

```text
Expected create
Expected modify
Generated only if required
Explicitly forbidden
```

The list is a scope guide, not permission to change every file. The coding agent must stop if a fundamentally different architecture becomes necessary.

### 16. TDD Implementation Sequence

Specify ordered red/green steps.

Each step should state:

1. failing test or proof;
2. implementation boundary;
3. focused verification;
4. stop condition.

Include concurrency, idempotency, stale update, crash recovery, authorization, and PII tests where relevant.

### 17. Acceptance Criteria

Acceptance criteria must be externally meaningful and testable.

Include:

- happy path;
- duplicate/idempotent path;
- stale/out-of-order path;
- transient failure/retry path;
- deterministic failure path;
- authorization path;
- performance/boundedness path;
- observability path;
- compatibility path;
- production acceptance path.

### 18. Verification Commands

List exact commands in required order.

Default baseline:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
bash scripts/check_no_web_woocommerce_refs.sh
mix test <focused tests>
mix test
bash scripts/local_ci.sh
git diff --check
```

Add as required:

```bash
mix assets.build
mix test test/event_sales/assets_pipeline_config_test.exs
mix ash.codegen --check
mix credo --strict
mix dialyzer
mix hex.audit
mix deps.audit
php -l <plugin-file>
```

### 19. Migration and Rollout Plan

When a migration or runtime configuration is involved, define:

- preflight query/check;
- direct/session-capable migration connection requirement;
- deploy order;
- active-job/traffic gate;
- rollback limitations;
- index creation method;
- post-deploy verification;
- expected production state changes.

Never treat `mix test` as migration rollout proof.

### 20. Production Validation and Evidence

Define:

- exact human/operator steps;
- safe identifiers/statuses that may be recorded;
- forbidden evidence values;
- expected metrics/logs/PubSub/UI result;
- pass/fail criteria;
- who signs off;
- downstream gate released by the evidence.

### 21. Stop Conditions

List conditions that require implementation or rollout to stop.

Examples:

- dirty worktree;
- baseline head changed unexpectedly;
- unresolved migration/index conflict;
- broader authority change required;
- customer PII or secret exposure;
- unbounded query or source call;
- duplicate durable mutation possible;
- stale worker can overwrite current owner;
- production state differs from pack assumptions;
- CI/security gate fails;
- representative query plan is unsafe.

### 22. Final Agent Response Contract

The coding prompt must require the final response to include:

- exact baseline and final head;
- files changed;
- behavior implemented;
- tests and commands run;
- generated artifacts;
- migrations/config changes;
- open risks/follow-ups;
- PR/CI status;
- production actions not performed;
- next authorized step.

## Coding-Agent Prompt Standard

`CODING_AGENT_PROMPT.md` must be directly reusable.

It must:

1. Name the repository and slice.
2. Tell the agent to read `AGENTS.md` and the feature pack first.
3. Require worktree and baseline checks.
4. State the exact goal.
5. State current repo truth.
6. List hard rules and non-goals.
7. List exact files to inspect.
8. Give the TDD sequence.
9. Give verification commands.
10. Define stop conditions.
11. Require a PR and exact final report.

Do not write vague prompts such as “implement issue #80.” The prompt must contain enough verified context to prevent architectural guessing.

## TOON Prompt Standard

`TOON_PROMPTS.md` should provide compact prompts for different agents/stages:

- planning/repo-audit agent;
- implementation agent;
- test/adversarial agent;
- security/privacy reviewer;
- performance/query reviewer;
- final PR reviewer;
- production validation operator.

Each prompt should preserve:

- slice identity;
- baseline SHA;
- allowed scope;
- forbidden scope;
- exact output expected;
- stop conditions.

## Acceptance Checklist Standard

`ACCEPTANCE_CHECKLIST.md` must be executable as a review checklist.

Recommended sections:

```text
Planning
Architecture
Data model
Concurrency/idempotency
Security/PII
Performance/scaling
Tests
CI
Migration/config
PR review
Deployment
Production evidence
Closeout
```

Use unchecked Markdown boxes so the checklist can be copied into the owning issue or PR.

## pack.json Minimum Schema

Every pack must include valid JSON similar to:

```json
{
  "pack_id": "0001_VS-26E.0",
  "slice": "VS-26E.0",
  "name": "Catalog Lifecycle Deployment and Baseline Certification",
  "version": "1.0-planning-ready",
  "status": "review_ready",
  "repository": "JCSchoeman96/EventSales",
  "default_branch": "main",
  "baseline_sha": "<exact-sha>",
  "github_issue": null,
  "repository_path": "docs/feature_packs/0001_VS-26E.0_catalog-lifecycle-production-baseline",
  "goal": "<testable outcome>",
  "dependencies": [],
  "blocks": [],
  "recommended_files_inspect": [],
  "recommended_files_create": [],
  "recommended_files_update": [],
  "must_not_change": [],
  "new_routes": [],
  "new_environment_variables": [],
  "migration_required": false,
  "production_validation_required": true,
  "verification_commands": [],
  "stop_conditions": []
}
```

Additional structured fields are encouraged when useful, but do not put secrets, production identifiers, or customer data in `pack.json`.

## Pack Lifecycle

Use these statuses:

```text
draft
-> review_ready
-> implementation_ready
-> implemented
-> production_validated
```

Rules:

- `review_ready`: repo audit complete; open questions clearly listed.
- `implementation_ready`: design accepted; no unresolved blocker.
- `implemented`: merged and CI green, but production validation may remain.
- `production_validated`: rollout and acceptance evidence complete.

Update the pack after material implementation changes so the repository does not retain a misleading planning document.

## One-Slice Rule

Do not build all feature packs upfront as if their file inventories and contracts are stable.

The programme roadmap may describe future slices, but the detailed pack for a slice must be created only when:

- its predecessor is Done or explicitly deferred;
- current `main` is known;
- related production evidence is available;
- current open issues and dependencies have been rechecked.

This prevents later packs from freezing assumptions that earlier slices will invalidate.

## Review Standard

A feature pack is not implementation-ready if any of these remain ambiguous:

- durable source of truth;
- identity/idempotency key;
- ownership/concurrency behavior;
- state transitions;
- source-version/stale update behavior;
- authorization/PII behavior;
- query bounds/index strategy;
- retry versus terminal failure;
- migration/rollout plan;
- production acceptance evidence;
- explicit non-goals.

When a pack is accepted, it becomes the scoped law for that slice. Implementation changes that contradict it require updating and re-reviewing the pack before code proceeds.
