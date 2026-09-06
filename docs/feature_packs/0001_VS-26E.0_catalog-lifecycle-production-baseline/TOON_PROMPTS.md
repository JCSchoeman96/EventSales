# TOON Prompts — VS-26E.0

## 1. Repository audit and plan

```text
TASK: Audit JCSchoeman96/EventSales at 561deaf14a2460e1246c3853c9e595567ace48f8 using the attached VS-26E.0 v1.2.1 pack.
MODE: PLAN ONLY.
DO: validate baseline; read FILE_INVENTORY mandatory files; map Railway/release/migrations/Catalog Sync/feed/tests; produce exact gated execution plan.
DO NOT: edit code; merge PR #117 or any PR; deploy; migrate; queue dry-run; Apply; mutate Railway/WordPress/database/Oban.
STOP: dirty/stale baseline, contradicted pack, unknown safety-critical topology, required corrective code.
OUTPUT: plan, inspected files, read-only checks, operator inputs, risks, stop conditions, prohibited-actions statement.
```

## 2. Pack reviewer

```text
TASK: Independently review VS-26E.0 pack source and immutable ZIP.
CHECK: baseline, semantic version, canonical-source parity, checksums, repo truth, migration route, explicit unmerged-pack-PR rule, separate authorisations, scope/non-goals, security, boundedness, evidence and stop conditions.
OUTPUT: blocker/major/minor findings and APPROVE|REQUEST CHANGES|BLOCKED.
```

## 3. Execution-plan reviewer

```text
TASK: Review the VS-26E.0 execution plan.
CHECK: read-only preflight; Railway pre-deploy migration behavior; direct migration route; duplicate-run/index fail-closed checks; feed limits; dry-run/Apply separation; evidence redaction; rollback limitations.
OUTPUT: APPROVE FOR PREFLIGHT ONLY|APPROVE FOR NAMED PHASES|REQUEST CHANGES|BLOCKED.
```

## 4. Corrective implementation agent

```text
TASK: Implement only the separately approved VS-26E.0 corrective PR.
BASELINE/PACK: state exact values.
DO: tests first; minimal code/migration/config change; required focused tests and local CI; open PR.
DO NOT: deploy, run production migrations, queue production work, Apply, broaden authority, alter unrelated data.
OUTPUT: exact files, tests, CI, migration/deploy implications, risks, PR head.
```

## 5. Exact-head PR reviewer

```text
TASK: Review exact corrective PR head against approved pack and plan.
CHECK: scope, architecture, concurrency, idempotency, migration/index safety, security/PII, performance bounds, tests/CI, rollout/rollback.
OUTPUT: blocker/major/minor findings; APPROVE|REQUEST CHANGES|BLOCKED.
```

## 6. Production operator

```text
TASK: Execute only the explicitly authorised VS-26E.0 phase.
DO: follow reviewed runbook; record redacted evidence; stop at next approval boundary.
DO NOT: combine deploy/migrate/dry-run/Apply approvals; expose protected values; edit state manually; exceed scope.
OUTPUT: phase, commands, observed state, evidence, blockers, next gate.
```

## 7. Evidence certifier

```text
TASK: Independently certify VS-26E.0 evidence.
CHECK: deployed SHA, migrations, constraints/index, run/job state, feed health, dry-run lifecycle/findings/hash, separate Apply approval, post-Apply catalog, redaction, remaining blockers.
OUTPUT: CERTIFIED|CONDITIONALLY CERTIFIED|NOT CERTIFIED|BLOCKED with exact evidence references.
```


## v1.2.1 activation note

Use current review baseline `561deaf14a2460e1246c3853c9e595567ace48f8`. The original planning baseline was `050d66e88d55270655833cd9c9b51476a4bfefeb`. GitHub reports a failing Railway status for current `main`; prove the actual active Railway SHA and diagnose the failure read-only before any production action. Do not claim a database size bound for finding messages/metadata. Require the exact successor certificate from the approved pack.
