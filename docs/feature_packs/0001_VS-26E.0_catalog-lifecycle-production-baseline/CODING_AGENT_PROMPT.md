# Coding/Execution Agent Prompt — VS-26E.0

You are working in `JCSchoeman96/EventSales` on the EventSales VS-26E.0 pack.

## Authorised phase for the first hand-off

**Repository reconnaissance and execution planning only.**

Do not modify code. Do not deploy. Do not run migrations. Do not queue Catalog Sync. Do not Apply a snapshot. Do not change Railway variables, WordPress, production data, Oban jobs, or database state.

## Baseline

- Required repository baseline: `050d66e88d55270655833cd9c9b51476a4bfefeb`
- Pack version: `1.0.0`
- Linear planning gate: `JC-108`
- GitHub pack tracker: `#114`

Start with:

```bash
git status --short
git rev-parse HEAD
git fetch origin
git rev-parse origin/main
bash scripts/sync_with_origin_main.sh --check
```

Stop if the worktree is dirty, HEAD is not the authorised baseline, `main` materially advanced, or the pack contradicts current code.

## Read first

Read every `mandatory read` entry in `FILE_INVENTORY.md`, especially:

- `AGENTS.md`
- canonical project rules and programme/product decisions
- Railway/release/database topology docs and code
- both PR #111 migrations
- Catalog Sync resource, facade, workers, planner, applier, LiveView, feed adapter, WordPress plugin README
- the named focused tests

Use current code as truth. Do not infer live Railway configuration from documentation.

## Goal

Produce a complete `IMPLEMENTATION_PLAN.md` / execution plan for safely certifying the merged Catalog Sync lifecycle on Railway and production WordPress.

The plan must separate:

1. read-only preflight;
2. deployment/migration approval and action;
3. migration/index/queue verification;
4. catalog dry-run approval and action;
5. findings/snapshot/hash review;
6. separate Apply/no-go approval;
7. post-Apply verification;
8. independent evidence certification.

## Required plan coverage

- exact current repository and deployed-app SHAs;
- whether PR #112's docs-only merge deployed and whether pre-deploy migration ran;
- Railway service topology and variable-name presence without values;
- whether `DIRECT_DATABASE_URL` is present and safe for migrations;
- whether a pooler is present;
- exact PR #111 migration status;
- retry columns/constraints;
- partial unique index existence, validity, uniqueness, columns, and predicate;
- duplicate active-run preflight;
- active/retryable `tickera_sync` Oban job preflight;
- source-system identity and feed enablement;
- WordPress plugin/feed schema and bounded paging;
- representative targeted probe only if justified;
- one full public-feed dry-run;
- expected lifecycle/PubSub/admin states;
- safe evidence fields;
- human findings/hash approval;
- Apply authorization boundary;
- post-Apply Event/TicketType/ProductMapping verification;
- rollback limitations;
- stop conditions and operator decisions.

## Hard rules

- No secrets, URLs with credentials, signatures, raw headers, raw feed bodies, PII, webhook payloads, or unredacted screenshots.
- No direct SQL writes or manual state edits.
- No automatic Apply.
- No private-event automation, triggers, schedules, catch-up, backfill, dashboards, roles, targets, notifications, or WordPress write-back.
- No application/migration/config corrective change inside the plan-only phase.
- If a corrective change is required, describe the smallest separate follow-up PR and stop.

## Output

Return:

1. `IMPLEMENTATION_PLAN.md` content.
2. Exact repository files inspected.
3. Exact read-only checks proposed.
4. Operator inputs still required.
5. Risks and stop conditions.
6. Whether the pack remains valid against current `main`.
7. Explicit statement that no prohibited action was performed.

Stop after the plan.
