# Independent Reviewer Prompt — VS-26E.0

Review VS-26E.0 independently. Do not rely on the implementer/operator's confidence.

## Review target

State exactly which artifact you review:

- pack version and ZIP SHA;
- plan revision;
- GitHub PR exact head;
- deployment/evidence revision.

Baseline contract: `050d66e88d55270655833cd9c9b51476a4bfefeb` unless a reviewed pack version supersedes it.

## Required checks

### Pack review

- ZIP contents match canonical source.
- All file checksums pass.
- Baseline and pack version are consistent.
- Repository truth, product decisions, scope, non-goals, migration route, security, performance, evidence, and stop conditions are explicit.
- No production topology is invented.
- No later slice leaks into scope.
- The pack PR is explicitly kept open through JC-108 and JC-109; independent pack approval is not merge approval.

### Plan review

- Read-only preflight is genuinely read-only.
- Deployment/migration, dry-run, and Apply are separate authorisations.
- Railway's pre-deploy migration behavior is accounted for.
- Merging PR #117 is treated as a named deployment/migration action requiring JC-109 authorisation.
- Direct/session-capable migration path is resolved safely.
- Duplicate active runs and invalid index fail closed.
- Oban queue/job state is bounded.
- Feed verification avoids protected values.
- Full-feed pagination and limits are bounded.
- Evidence and rollback limitations are practical.

### PR review, if a corrective PR exists

- Exact diff versus approved corrective scope.
- Tests first and all required CI green on exact head.
- No authority expansion or parallel writer.
- Migration is safe, bounded, and compatible.
- No secrets/PII/raw payload.
- Deployment implications are explicit.

### Evidence review

- Deployed SHA and migration state are proven.
- Index metadata is exact and valid.
- Dry-run lifecycle and summary/findings/hash are durable and reproducible.
- Apply occurred only after matching hash approval, or no-go is recorded.
- Post-Apply catalog matches the approved snapshot.
- No unresolved blocker remains for VS-26E.1.
- Evidence is redacted.

## Finding classes

- **Blocker:** unsafe to proceed/certify.
- **Major:** material contract gap or incorrect evidence.
- **Minor:** clarity or non-blocking improvement.

Reference exact pack file/section, plan step, code path, or evidence row.

## Verdicts

Pack/plan/PR:

- `APPROVE`
- `REQUEST CHANGES`
- `BLOCKED`

Production evidence:

- `CERTIFIED — VS-26E.1 MAY START`
- `CONDITIONALLY CERTIFIED`
- `NOT CERTIFIED — CORRECTIONS REQUIRED`
- `BLOCKED`

Do not certify because deployment or tests alone succeeded.
