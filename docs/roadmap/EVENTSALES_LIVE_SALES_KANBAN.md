# EventSales Live Sales Kanban

## Authority Model

This programme separates technical truth from workflow state:

```text
GitHub repository and reviewed PRs
= canonical technical truth

Canonical feature-pack source in GitHub
= reviewed slice contract

Versioned immutable ZIP
= exact agent execution capsule

Linear project and issues
= current status, ownership, dependencies, blockers, hand-offs, and evidence

This Markdown file
= repository snapshot of the workflow model and critical path
```

Linear is the operational Kanban. This document must be updated when the critical path or workflow rules change, but it is not a substitute for current Linear state.

## WIP Limits

```text
Maximum active pack/implementation slice: 1
Maximum slice in production validation: 1
```

Future outcomes may be discussed, but a detailed implementation-ready pack is created only when its predecessor is Done or explicitly deferred and current `main` has been re-audited.

## Linear Project

Project: **EventSales Live Sales Programme**

Team: `JC-Dev`

Current milestone: **M1 — Catalog Automation**

Current active parent:

- `JC-105` — VS-26E.0 Catalog Lifecycle Deployment and Baseline Certification

Current active child:

- `JC-106` — Prepare canonical feature pack and immutable ZIP

Gated children:

1. `JC-107` — independent pack review.
2. `JC-108` — agent reconnaissance and execution plan.
3. `JC-109` — plan review and authorisation boundaries.
4. `JC-110` — controlled deploy/migrate/dry-run/Apply procedure.
5. `JC-111` — independent production-evidence validation.
6. `JC-112` — closeout and VS-26E.1 unlock.

Creating a Linear card does not authorise production action.

## Linear Status Mapping

The workspace currently uses:

| Linear status | Programme meaning |
|---|---|
| `Backlog` | Outcome known; detailed pack not current or not yet authorised. |
| `Todo` | Next gated action is defined but not started. |
| `In Progress` | The one active pack, planning, implementation, or execution action. |
| `In Review` | Independent pack, plan, PR, or evidence review. |
| `Done` | The specific child gate passed; parent is Done only after production acceptance where required. |
| `Canceled` | Work intentionally abandoned with reason. |
| `Duplicate` | Work represented by another issue. |

Use stage labels to distinguish the active phase:

- `stage:pack`
- `stage:plan`
- `stage:implementation`
- `stage:review`
- `stage:integration`
- `stage:validation`
- `blocked`

## Slice Gate Model

Every meaningful slice should use a parent issue and only the children relevant to that slice.

Typical child sequence:

```text
PACK
-> PACK-REVIEW
-> PLAN
-> PLAN-REVIEW
-> IMPLEMENT or EXECUTE
-> PR-REVIEW where code changes exist
-> INTEGRATE/DEPLOY
-> VALIDATE
-> CLOSE
```

A docs-only validation slice may omit implementation/PR gates. A production-code slice must not omit independent exact-head PR review.

## Advancement Rules

### Pack preparation may start when

- the predecessor is Done or formally deferred;
- the target outcome is approved;
- exact current `main` is known;
- relevant production evidence and open issues have been rechecked;
- one-slice WIP is available.

### Pack review may pass when

- canonical source is committed in a PR;
- the baseline SHA is exact;
- current repository truth and file inventory are verified;
- scope, non-goals, tests, security, performance, rollout, evidence, and stop conditions are explicit;
- immutable ZIP content matches canonical source;
- all file and ZIP checksums verify.

### Planning may pass when

- the agent validated a clean worktree and baseline;
- all mandatory files were inspected;
- proposed files/actions and TDD or execution sequence are exact;
- unknown production topology remains explicitly unknown rather than guessed;
- no code or production mutation occurred during a plan-only gate.

### Implementation/Execution may start when

- the reviewed plan states the exact authorised phase;
- migrations, config, secrets, source access, and rollback/stop conditions are resolved as applicable;
- no hidden dependency remains;
- Linear reflects `In Progress` for only that action.

### PR review may pass when

- focused verification and full required CI pass on the exact head;
- the diff is within pack scope;
- no blocker or major review finding remains;
- migrations/config/rollout are accurately documented;
- the reviewer confirms prohibited actions were not performed.

### Production validation may pass when

- deployed SHA matches the approved version;
- required migration/config state is verified;
- redacted acceptance evidence passes;
- no unresolved blocker remains for the next slice;
- accepted risks are recorded explicitly.

### Parent Done rule

A parent slice is not Done merely because:

- a pack exists;
- code was written;
- a PR merged;
- Railway deployed automatically.

The parent reaches Done only when every required child gate, including production validation, passes or the programme owner records a formal risk acceptance.

## Critical Path

| Order | Slice | Outcome | Depends on | Existing tracker |
|---:|---|---|---|---|
| 0 | VS-26E.0 | Certify deployed Catalog Sync baseline | PR #111 and planning PR #112 | Linear `JC-105` |
| 1 | VS-26E.1 | Targeted WordPress catalog-change trigger | VS-26E.0 | Expand GitHub #78 |
| 2 | VS-26E.2 | Conservative live/public catalog auto-apply | VS-26E.1 | Expand GitHub #78 |
| 3 | VS-26E.3 | Periodic catalog reconciliation | VS-26E.2 | Expand GitHub #78 |
| 4 | VS-26F.1 | WooCommerce order catch-up core | VS-26E.3 | GitHub #80 |
| 5 | VS-26F.2 | Scheduled catch-up, queued refresh, and live status | VS-26F.1 | Split from #80 |
| 6 | VS-26G | Product/order-line/tax/fee semantics | VS-26F.2 | GitHub #82 |
| 7 | VS-27B.1 | Metric and time-window contract | VS-26G | New issue when active |
| 8 | VS-27B.2 | Durable hourly/daily aggregates | VS-27B.1 | New issue when active |
| 9 | VS-27B.3 | All-event and event decision dashboards | VS-27B.2 | New issue when active |
| 10 | VS-27C | Event-scoped management/marketing access | VS-27B.3 | New issue when active |
| 11 | VS-27D | Targets, pacing, and notifications | VS-27C | New issue when active |
| 12 | VS-28A.1 | Current public-event backfill core | VS-27D | New issue when active |
| 13 | VS-28A.2 | Backfill admin workflow | VS-28A.1 | New issue when active |
| 14 | VS-28B | CSV/XLSX import, exports, reconciliation, corrections | VS-28A.2 | New issue when active |
| 15 | VS-27A | Compact webhook contract hardening | VS-28B | GitHub #81 |

Dependency view:

```text
VS-26E.0
-> VS-26E.1
-> VS-26E.2
-> VS-26E.3
-> VS-26F.1
-> VS-26F.2
-> VS-26G
-> VS-27B.1
-> VS-27B.2
-> VS-27B.3
-> VS-27C
-> VS-27D
-> VS-28A.1
-> VS-28A.2
-> VS-28B
-> VS-27A
```

## Operational Hardening Backlog

| Trigger | Issue | Disposition |
|---|---:|---|
| Catalog selectors become too large for bounded admin rendering | #100 | Promote when production evidence or catalog size requires it. |
| Unmapped recovery risks web-process timeout/memory pressure | #101 | Promote immediately if observed. |
| Signed catalog feed becomes unviable | #70 | Direct WordPress MySQL adapter remains contingency-only. |

## Required Parent-Issue Metadata

Each active parent issue must record:

- Slice ID and pack version.
- Canonical pack path and source PR/commit.
- Baseline `main` SHA.
- Immutable ZIP filename and SHA-256.
- Dependencies and downstream blocks.
- Current gate and owner.
- Implementation PR and exact reviewed head where applicable.
- CI run.
- Deployment SHA.
- Migration/config result.
- Production evidence and verdict.
- Accepted risks and unresolved follow-ups.

## Blocked Work

A blocked issue must state:

1. the exact blocker;
2. evidence for the blocker;
3. owner/decision-maker;
4. safe next action;
5. which downstream cards remain locked;
6. whether a pack refresh is required.

A stale pack baseline is a blocker. The correct response is to refresh and version the pack, not to let the agent improvise.

## Current Board State

```text
Project: In Progress
Active slice: VS-26E.0
Active gate: JC-106 PACK
Production validation: none
Next gate: JC-107 PACK-REVIEW
Next slice: locked
```

## Current Next Action

1. Review and merge planning PR #112 on an exact green head.
2. Lock the VS-26E.0 pack against the resulting `main` merge SHA.
3. Generate the immutable ZIP and checksums.
4. Record the ZIP metadata in `JC-106`.
5. Move `JC-106` to In Review and activate only `JC-107`.

Do not begin VS-26E.1 before `JC-111` certifies the production baseline and `JC-112` closes VS-26E.0.