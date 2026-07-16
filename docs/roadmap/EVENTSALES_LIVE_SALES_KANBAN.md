# EventSales Live Sales Kanban

## Operating Rule

This board uses a strict work-in-progress limit:

```text
Maximum active implementation slices: 1
Maximum slices in production validation: 1
```

A future slice may be discussed, but its implementation pack must not be treated as current repo truth until the preceding slice is Done or explicitly deferred.

## Board Columns

### 1. Backlog

The outcome is known, but the feature pack has not yet been refreshed against current `main`.

Entry requirements:

- Business outcome identified.
- Rough dependency position known.
- No claim that exact files or contracts are final.

Exit requirement:

- Predecessor is Done or the programme owner explicitly authorizes planning.

### 2. Ready for Pack

The slice is next and may receive a repository audit and detailed feature pack.

Entry requirements:

- All hard dependencies Done.
- No unresolved production blocker.
- Current issue and repo baseline identified.

### 3. Pack in Review

The docs-only feature pack exists and is being checked for correctness, completeness, scope, performance, security, and repo alignment.

Required evidence:

- Exact baseline SHA.
- Current repo truth.
- File inventory.
- TDD sequence.
- Acceptance checklist.
- Rollout and stop conditions.
- Coding-agent prompt.

### 4. Ready for Implementation

The pack is approved and implementation may begin.

Entry requirements:

- Pack review complete.
- Open design questions resolved.
- Migration/data risk accepted where applicable.
- No broader hidden dependency remains.

### 5. In Progress

Tests and implementation are changing on the slice branch.

Rules:

- WIP limit one.
- No unrelated refactors.
- No scope expansion without updating the pack first.
- Stop if the branch baseline or production assumptions become invalid.

### 6. PR Review

Implementation is pushed and awaits exact-head review.

Entry requirements:

- Focused tests green.
- Full local validation complete.
- PR body records scope, tests, migrations, rollout, and prohibited actions.

Exit requirements:

- Exact-head CI green.
- Independent re-review complete.
- No blocker or major finding.

### 7. Ready for Deploy

Merged code is waiting for the authorized rollout window.

Entry requirements:

- Merge complete.
- Deployment/runbook reviewed.
- Required config/secrets/migration route ready.
- Rollback and stop conditions understood.

### 8. Production Validation

The merged slice is deployed and its production acceptance evidence is being collected.

Rules:

- Execute only the pack-authorized actions.
- Record sanitized evidence.
- Stop on any pack-defined safety condition.
- Do not begin the next implementation slice while a critical production validation remains unresolved.

### 9. Done

Implementation and production acceptance are complete.

Required evidence:

- Merge commit.
- CI run.
- Deployment version/commit.
- Migration/config result where applicable.
- Production acceptance outcome.
- Remaining follow-ups converted to explicit issues.

### 10. Blocked

The slice cannot advance safely.

Every blocked card must state:

- blocker;
- owner;
- evidence needed;
- next decision/action;
- which downstream slices are blocked.

## Current Programme Board

### Production Validation

| Slice | Outcome | Blocked by | Blocks | Existing issue |
|---|---|---|---|---|
| VS-26E.0 | Deploy and certify the merged Catalog Sync lifecycle and establish one approved production baseline | Authorized deployment/migration window and production preflight | All automatic catalog slices | PR #111 follow-up evidence |

### Ready for Pack

None until VS-26E.0 reaches Done.

### Backlog — Critical Path

| Order | Slice | Card title | Depends on | Blocks | Existing issue |
|---:|---|---|---|---|---|
| 1 | VS-26E.1 | Targeted WordPress Catalog Change Trigger | VS-26E.0 | VS-26E.2 | Expand #78 |
| 2 | VS-26E.2 | Conservative Catalog Auto-Apply | VS-26E.1 | VS-26E.3 | Expand #78 |
| 3 | VS-26E.3 | Periodic Catalog Reconciliation Sweep | VS-26E.2 | VS-26F.1 | Expand #78 |
| 4 | VS-26F.1 | WooCommerce Order Catch-Up Core | VS-26E.3 | VS-26F.2 | #80 |
| 5 | VS-26F.2 | Scheduled Catch-Up and Admin Operations | VS-26F.1 | VS-26G | Split from #80 |
| 6 | VS-26G | Product and Order-Line Semantics | VS-26F.2 | VS-27B.1 | #82 |
| 7 | VS-27B.1 | Event Sales Metric and Time-Window Contract | VS-26G | VS-27B.2 | New issue |
| 8 | VS-27B.2 | Durable Hourly and Daily Event Sales Buckets | VS-27B.1 | VS-27B.3 | New issue |
| 9 | VS-27B.3 | Event Sales Decision Dashboard | VS-27B.2 | VS-27C | New issue |
| 10 | VS-27C | Event-Scoped Management and Marketing Access | VS-27B.3 | VS-28A.1 | New issue |
| 11 | VS-28A.1 | Historical WooCommerce REST Backfill Core | VS-27C | VS-28A.2 | New issue |
| 12 | VS-28A.2 | Historical Backfill Admin Workflow | VS-28A.1 | VS-28B | New issue |
| 13 | VS-28B | Filtered Event Exports and Reconciliation Pack | VS-28A.2 | VS-27A | New issue |
| 14 | VS-27A | Compact EventSales Order Webhook Contract | VS-28B | Programme completion | #81 |

### Backlog — Operational Hardening

| Priority trigger | Issue | Card title | Current disposition |
|---|---:|---|---|
| Source has more than 200 Events or an Event has more than 200 TicketTypes | #100 | Searchable/paginated unmapped-alert catalog selectors | Schedule when production size requires it or after critical path |
| Large unmapped tuple risks web-process timeout or memory pressure | #101 | Bounded Oban unmapped-alert recovery | Elevate immediately if production evidence shows scale risk |
| Sanitized feed becomes unviable | #70 | Direct WordPress MySQL adapter evaluation | Not the default path; retain only as contingency evaluation |

## Dependency View

```text
[VS-26E.0 Baseline certification]
  -> [VS-26E.1 Catalog trigger]
  -> [VS-26E.2 Auto-apply]
  -> [VS-26E.3 Catalog sweep]
  -> [VS-26F.1 Catch-up core]
  -> [VS-26F.2 Catch-up operations]
  -> [VS-26G Product semantics]
  -> [VS-27B.1 Metric contract]
  -> [VS-27B.2 Aggregate buckets]
  -> [VS-27B.3 Decision dashboard]
  -> [VS-27C Scoped access]
  -> [VS-28A.1 Backfill core]
  -> [VS-28A.2 Backfill UI]
  -> [VS-28B Exports]
  -> [VS-27A Compact webhook]
```

## Card Template

Every GitHub issue/card should contain:

```markdown
# Outcome

# Why Now

# Current Repo Truth

# Dependencies

# Blocked By

# Blocks

# Scope

# Explicit Non-Goals

# Required Invariants

# Likely Files To Inspect

# Likely Files To Modify/Create

# TDD Sequence

# Acceptance Criteria

# Verification

# Rollout / Production Validation

# Stop Conditions

# Feature Pack

# Evidence
```

## Required Card Metadata

Record these fields in the issue body until a GitHub Project custom-field board is created:

| Field | Allowed value/example |
|---|---|
| Programme | `EventSales Live Sales` |
| Slice | `VS-26E.1` |
| Status | `Backlog`, `Ready for Pack`, `Pack in Review`, `Ready for Implementation`, `In Progress`, `PR Review`, `Ready for Deploy`, `Production Validation`, `Done`, `Blocked` |
| Priority | `P0`, `P1`, `P2`, `P3` |
| Risk | `Low`, `Medium`, `High`, `Critical` |
| Depends on | Slice/issue list |
| Blocks | Slice/issue list |
| Feature pack path | Repository path or `not created` |
| Baseline SHA | Exact `main` commit used for pack |
| Implementation PR | PR number or `not opened` |
| CI run | Workflow run or `not run` |
| Production evidence | Link/comment/path or `not started` |

## Suggested GitHub Project Configuration

When GitHub Projects automation is available, create one project named:

```text
EventSales — Live Sales Programme
```

Suggested fields:

- Status
- Slice
- Priority
- Risk
- Workstream
- Depends on
- Target release
- Production validation required
- Feature pack path

Suggested saved views:

1. **Critical Path** — ordered by the table above.
2. **Current Slice** — Status is not Backlog or Done.
3. **Blocked** — Status is Blocked.
4. **Production Gate** — Ready for Deploy or Production Validation.
5. **Operational Hardening** — issues #100, #101, and future operational follow-ups.

The available GitHub connector does not currently expose GitHub Projects creation or custom-field mutation. Until that capability is available, this Markdown board plus the owning GitHub issues are the authoritative Kanban representation.

## Advancement Checklist

Before moving a card to the next column:

- [ ] Exact current status recorded.
- [ ] Required evidence linked.
- [ ] Dependencies checked again.
- [ ] No unreviewed scope expansion.
- [ ] Security/PII implications reviewed.
- [ ] Performance/scaling implications reviewed.
- [ ] Downstream blocker list updated.

## Current Next Action

Create and approve the feature pack for:

```text
VS-26E.0 — Catalog Lifecycle Deployment and Baseline Certification
```

Do not begin VS-26E.1 implementation until VS-26E.0 production evidence is complete.
