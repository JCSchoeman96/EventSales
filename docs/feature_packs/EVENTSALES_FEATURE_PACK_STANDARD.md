# EventSales Feature Pack Standard

## Purpose

Every meaningful EventSales vertical slice must receive a repository-specific, reviewed feature pack before implementation or production execution begins.

A feature pack is not a generic brief. It is a scoped execution contract anchored to:

- an exact `main` commit;
- verified repository files and current behaviour;
- relevant production evidence and infrastructure facts;
- approved product decisions;
- EventSales architecture, security, performance, and rollout rules.

The pack exists to prevent agents from guessing architecture, inventing production topology, creating parallel writers, broadening authority, or implementing against stale assumptions.

## Authority Hierarchy

```text
GitHub repository and reviewed PRs
= canonical technical truth

Canonical feature-pack folder in GitHub
= editable source, changed only by reviewed commits

Versioned ZIP generated from that folder
= immutable execution capsule for one agent hand-off

Linear
= status, ownership, blockers, dependencies, hand-offs, and evidence
```

The ZIP is never the long-term source of truth. The canonical source folder is never silently modified after a ZIP is issued; a material change creates a new semantic version and new ZIP.

## One-Slice Rule

Do not create implementation-ready packs for the whole roadmap upfront.

A detailed pack may be created only when:

- its predecessor is Done or explicitly deferred;
- current `main` is known;
- related production evidence has been checked;
- open issues and dependencies have been re-evaluated;
- the programme WIP limit permits it.

Future roadmap descriptions are intent, not current file-level truth.

## Canonical Folder Naming

Use:

```text
docs/feature_packs/<ordinal>_<slice>_<short-slug>/
```

Example:

```text
docs/feature_packs/0001_VS-26E.0_catalog-lifecycle-production-baseline/
```

Rules:

- inspect existing folders before selecting the ordinal;
- never reuse or renumber an ordinal;
- use the same canonical folder for later pack versions, with version history recorded in `pack.json` and Git;
- never put secrets, credentials, production payloads, or customer PII in the folder.

## Immutable ZIP Naming

Use:

```text
EventSales_<SLICE>_v<semver>_<baseline-short-sha>.zip
```

Example:

```text
EventSales_VS-26E.0_v1.0.0_abcdef12.zip
```

Record:

- full baseline SHA;
- ZIP filename;
- ZIP SHA-256;
- canonical source commit/PR;
- pack semantic version;
- creation timestamp;
- owning Linear parent and pack-review issues.

## Required Pack Structure

Every full pack should contain:

```text
<pack-root>/
├── README.md
├── <SLICE>-FEATURE_PACK.md
├── CODING_AGENT_PROMPT.md
├── REVIEWER_PROMPT.md
├── TOON_PROMPTS.md
├── ACCEPTANCE_CHECKLIST.md
├── FILE_INVENTORY.md
├── REPO_BASELINE.json
├── pack.json
├── checksums.sha256
├── IMPLEMENTATION_REPORT_TEMPLATE.md
├── REVIEW_REPORT_TEMPLATE.md
├── LINEAR_UPDATE_TEMPLATE.md
├── runbooks/
│   ├── DEPLOYMENT_PLAN.md                 # when applicable
│   ├── MIGRATION_PREFLIGHT.md             # when applicable
│   ├── ROLLBACK_AND_STOP_CONDITIONS.md    # when applicable
│   ├── FAILURE_MATRIX.md                  # when applicable
│   └── RUNBOOK.md                         # when applicable
└── evidence/
    └── EVIDENCE_TEMPLATE.md               # when production validation applies
```

A small docs-only slice may omit irrelevant optional files, but must retain baseline, scope, non-goals, acceptance, review, checksums, and stop-condition discipline.

## Baseline Lock

`REPO_BASELINE.json` must include at least:

```json
{
  "repository": "JCSchoeman96/EventSales",
  "default_branch": "main",
  "baseline_sha": "<full-main-sha>",
  "pack_id": "0001_VS-26E.0",
  "pack_version": "1.0.0",
  "pack_status": "review_ready",
  "canonical_source_commit": "<sha>",
  "created_at": "<ISO-8601>"
}
```

Before planning or implementation, the agent must run or otherwise prove the equivalent of:

```bash
git status --short
git rev-parse HEAD
git fetch origin
git rev-parse origin/main
bash scripts/sync_with_origin_main.sh --check
```

The agent must stop when:

- the worktree is dirty;
- the authorised baseline is not checked out;
- `origin/main` materially advanced and the pack has not been refreshed;
- an expected file no longer exists;
- current code contradicts a material pack assumption;
- safe completion requires forbidden scope.

The correct response to baseline drift is a pack-refresh request, not improvisation.

## Semantic Versioning and Immutability

Use standard semantic versions:

```text
1.0.0  approved initial execution contract
1.0.1  non-material wording/checksum/typo correction
1.1.0  clarified or expanded scope without architectural replacement
2.0.0  materially changed design, authority, or execution approach
```

After a ZIP is issued:

1. never replace the ZIP under the same filename;
2. never silently change canonical source and pretend the old ZIP represents it;
3. create a new version for material changes;
4. record why the earlier version was superseded;
5. update Linear and any active agent hand-off;
6. stop active execution if the superseding change invalidates its plan.

## Required Feature-Pack Sections

`<SLICE>-FEATURE_PACK.md` must contain:

### 1. Identity and status

- slice ID and name;
- pack semantic version and status;
- baseline branch/SHA;
- canonical source PR/commit;
- GitHub issue and Linear parent/child IDs;
- predecessor and successor.

### 2. Executive summary

State the exact operator/user outcome, why it is needed now, and the durable invariant it establishes.

### 3. Current repository truth

Refresh from the actual repository. List:

- relevant modules and responsibilities;
- Ash resources/actions/state machines;
- routes, LiveViews, controllers, and components;
- workers, queues, concurrency, and scheduling;
- tests, fixtures, migrations, indexes, scripts, and runbooks;
- related merged PRs/open issues;
- known production evidence and unknowns;
- placeholders/incomplete paths.

Do not copy repo truth from an older pack without re-verification.

### 4. Product decision inputs

Reference `docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md` and state which decisions this slice implements, defers, or must clarify.

### 5. Goal and observable outcome

The goal must be testable and operationally visible.

Bad:

```text
Improve sync.
```

Good:

```text
A missed WooCommerce update is fetched through the durable cursor, processed through OrderUpserter, reflected in the affected event read model, and visible without duplicate durable effects.
```

### 6. Dependencies and blockers

Classify every dependency as:

- merged/available;
- pending;
- production validation required;
- operator input required;
- explicitly out of scope.

List downstream slices blocked by this pack.

### 7. Scope

Describe the smallest end-to-end behaviour and every required layer:

- source contract;
- intake boundary;
- worker/orchestration;
- Ash actions/persistence;
- indexes/constraints;
- cache/PubSub/read models;
- admin/LiveView surface;
- tests;
- docs/runbooks;
- rollout and production validation.

### 8. Explicit non-goals

Name exact boundaries. Avoid “unchanged unless needed.” Typical exclusions include:

- payment authority;
- ticket issuance/scanner/customer delivery;
- unrelated webhook intake changes;
- parallel order writers;
- direct Woo REST from LiveView/controllers/components;
- customer PII exposure;
- unbounded historical import;
- unrelated frontend redesign;
- Redis as durable truth;
- production actions outside the authorised runbook.

### 9. Domain model and durable truth

Identify:

- resources/entities;
- durable identities and source keys;
- relationships;
- authoritative timestamps;
- uniqueness and concurrency rules;
- state transitions;
- source-version/stale-update handling;
- immutable/audit history;
- why each new field/table/index is required.

### 10. Interfaces and contracts

Document exact changes to:

- HTTP/feed/webhook shapes;
- authentication/signature/replay behaviour;
- worker args and uniqueness;
- Ash actions and accepted attributes;
- PubSub topics/messages;
- cache keys/TTLs;
- LiveView params/events;
- CSV/XLSX/export columns;
- environment variables and compatibility.

Never add a public interface implicitly.

### 11. Architectural boundaries

Restate applicable rules:

```text
LiveView/controller/component -> facade or read model
approved ingestion/Oban worker -> WooCommerceClient
Ash action/domain service -> durable mutation
Postgres -> authority
Redis/ETS/Cachex -> derived hot/warm state
PubSub -> notification, never truth
```

### 12. Security, privacy, and evidence

Specify:

- authentication/authorization;
- PII visibility;
- secrets and forbidden evidence values;
- raw-payload restrictions;
- audit requirements;
- safe bounded error codes;
- telemetry/log cardinality;
- evidence redaction.

### 13. Performance and scale

For each path state:

- hot/warm/cold classification;
- expected and maximum cardinality;
- query/source-call bounds;
- supporting indexes;
- worker concurrency and timeout/backoff;
- duplicate/overlap protection;
- cache/read-model strategy;
- representative query/load evidence.

EventSales must remain bounded even though the initial target is roughly 10,000 tickets over weeks and fifty concurrent dashboard viewers.

### 14. Failure modes and recovery

For each failure define durable state, retry/terminal classification, operator visibility, and safe continuation. Include as relevant:

- intake accepted but enqueue failed;
- duplicate execution;
- stale worker/source update;
- partial page processing;
- cursor failure;
- cache/PubSub failure after commit;
- source timeout/rate limit;
- migration/index failure;
- deploy during active work;
- LiveView disconnect;
- production topology mismatch.

### 15. Files to inspect first

List exact current paths, including:

- `AGENTS.md`;
- canonical docs;
- relevant source modules;
- tests/fixtures;
- migrations/indexes;
- asset conventions for UI work;
- WordPress integration files when applicable;
- deployment/release scripts and runbooks.

### 16. Expected and forbidden files

Separate:

```text
Expected create
Expected modify
Generated only if required
Explicitly forbidden
```

This is a scope guide, not permission to touch every listed path.

### 17. Tests-first or execution sequence

For code slices, specify ordered red/green steps with focused verification and stop conditions.

For deployment/validation slices, specify:

1. read-only preflight;
2. explicit authorisation checkpoint;
3. bounded action;
4. evidence capture;
5. separate next-phase decision;
6. stop/rollback path.

### 18. Acceptance criteria

Include as relevant:

- happy path;
- duplicate/idempotent path;
- stale/out-of-order path;
- retry and terminal failure;
- authorization/PII path;
- performance/boundedness;
- observability;
- compatibility;
- deployment and production acceptance.

### 19. Verification commands

Default code baseline:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
bash scripts/check_no_web_woocommerce_refs.sh
mix test <focused tests>
mix test
bash scripts/local_ci.sh
git diff --check
```

Add relevant asset, Ash codegen, static-analysis, dependency-audit, PHP lint, migration, or query-plan checks. Do not claim commands were run when they were only documented.

### 20. Migration, rollout, and production evidence

When applicable define:

- read-only preflight;
- direct/session-capable migration connection requirement;
- deploy/migrate/action order;
- active-job/traffic gate;
- rollback limitations;
- index method/validation;
- expected state changes;
- exact operator steps;
- pass/fail evidence;
- sign-off owner;
- downstream gate released.

A successful test suite is not migration or production proof.

### 21. Stop conditions

Include all material stop conditions, such as:

- dirty worktree or stale baseline;
- unknown production topology required for safe execution;
- migration/index conflict;
- duplicate durable mutation possible;
- stale owner can overwrite current owner;
- unbounded query/source call;
- secret/PII/raw protected data leak;
- broader authority change required;
- current production state contradicts pack assumptions;
- exact-head CI or security gate failure.

### 22. Final response contract

Require the agent to report:

- exact baseline and final head;
- files changed or production actions executed;
- behaviour/evidence produced;
- tests/commands actually run;
- migrations/config implications;
- open risks and blockers;
- PR/CI/deployment status;
- prohibited actions not performed;
- next authorised gate.

## Prompt Files

### `CODING_AGENT_PROMPT.md`

Must be directly reusable and include repository, slice, baseline checks, exact goal, repo truth, hard rules, file inventory, tests/execution sequence, verification, stop conditions, and final report.

The initial hand-off should normally authorise planning only:

```text
Validate the baseline, inspect the mandatory files, and produce the requested plan.
Do not modify production code or production state. Stop after the plan.
```

Implementation/execution requires a separate explicit instruction after plan review.

### `REVIEWER_PROMPT.md`

Must be independent of the implementer prompt and require:

- exact pack/PR head;
- contract-to-diff or contract-to-evidence comparison;
- blocker/major/minor classification;
- architecture, concurrency, security, performance, migration, rollout, and scope checks;
- final verdict: APPROVE, REQUEST CHANGES, or BLOCKED.

### `TOON_PROMPTS.md`

Provide compact stage prompts for:

- repository-audit/planning agent;
- implementation agent;
- adversarial test reviewer;
- security/privacy reviewer;
- performance/query reviewer;
- exact-head PR reviewer;
- production-validation operator.

Each must preserve slice, version, baseline, allowed scope, forbidden scope, output, and stop conditions.

## Acceptance Checklist

`ACCEPTANCE_CHECKLIST.md` should contain unchecked boxes for:

```text
Baseline and planning
Repository truth
Product decisions
Architecture
Data model and state
Concurrency/idempotency
Security/PII
Performance/bounds
Tests and CI
Migration/config
PR review
Deployment
Production evidence
Linear/GitHub closeout
```

## File Inventory

`FILE_INVENTORY.md` must distinguish:

- mandatory read;
- expected create;
- expected modify;
- generated;
- forbidden;
- production-only artefacts that must not be committed.

The inventory must be verified against current `main`.

## `pack.json` Minimum Schema

```json
{
  "pack_id": "0001_VS-26E.0",
  "slice": "VS-26E.0",
  "name": "Catalog Lifecycle Deployment and Baseline Certification",
  "version": "1.0.0",
  "status": "review_ready",
  "repository": "JCSchoeman96/EventSales",
  "default_branch": "main",
  "baseline_sha": "<full-sha>",
  "canonical_source_commit": "<sha>",
  "github_issue": 113,
  "linear_parent": "JC-105",
  "linear_pack_issue": "JC-106",
  "linear_review_issue": "JC-107",
  "repository_path": "docs/feature_packs/0001_VS-26E.0_catalog-lifecycle-production-baseline",
  "zip_filename": "EventSales_VS-26E.0_v1.0.0_<short-sha>.zip",
  "zip_sha256": null,
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

Do not place secrets, real database URLs, production credentials, customer identifiers, or raw payloads in JSON.

## Checksums and Packaging

Before issuing the ZIP:

1. generate `checksums.sha256` for every included file except the checksum file itself;
2. verify the checksum list from a clean generated directory;
3. create the ZIP deterministically where practical;
4. calculate the ZIP SHA-256;
5. inspect the archive listing;
6. prove the ZIP content matches canonical source at the recorded commit;
7. record filename, SHA-256, baseline, version, and source commit in Linear.

The ZIP must not include:

- `.git`;
- the whole repository;
- build/dependency directories;
- secrets or env files;
- production payloads/data exports;
- unredacted screenshots;
- stale generated repository indexes;
- arbitrary binaries.

## Pack Lifecycle

Canonical pack status:

```text
draft
-> review_ready
-> implementation_ready
-> implemented
-> production_validated
-> superseded (when a later pack version replaces it)
```

A ZIP remains immutable even when canonical status later changes. Generate a new ZIP/version when an active agent needs materially changed instructions.

## Linear Update Contract

`LINEAR_UPDATE_TEMPLATE.md` must capture:

- current gate and verdict;
- pack version/baseline/source commit;
- ZIP name/SHA-256;
- plan or implementation PR;
- exact reviewed head and CI;
- deployment/migration state;
- evidence link/verdict;
- blockers and next authorised issue.

Only the appropriate child issue should be `In Progress`. The parent closes after all required gates pass.

## Review Standard

A pack is not implementation-ready while any of these remain materially ambiguous:

- durable authority;
- identity/idempotency key;
- ownership/concurrency;
- state transitions;
- timestamp/source-version semantics;
- authorization/PII;
- query/source-call bounds;
- retry versus terminal failure;
- migration/rollout route;
- production evidence and sign-off;
- explicit non-goals.

When approved, the pack is scoped law for that version of the slice. Contradictory implementation requires a reviewed pack revision before work continues.