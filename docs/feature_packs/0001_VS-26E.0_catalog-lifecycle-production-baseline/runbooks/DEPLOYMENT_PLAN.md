# VS-26E.0 Deployment Plan

## Principle

A GitHub merge may trigger Railway deployment, and `railway.toml` runs `EventSales.Release.migrate_and_bootstrap/0` before activation. Deployment and migration therefore form a production write boundary and require explicit approval.

This applies to the canonical docs-only pack PR #117 itself. Pack approval does not authorise merge. Keep PR #117 open during JC-108 planning. Its merge is deferred until JC-109 records explicit authorisation for the deployment/pre-deploy boundary.

## Current review state

At v1.2.1 review time, GitHub `main` is `561deaf14a2460e1246c3853c9e595567ace48f8` and its Railway commit status is failing. This is a hard activation blocker. Do not assume the failed deployment became active, and do not infer the active SHA from GitHub history.

Do not merge a documentation-only pack PR merely to make this pack available. Register the source and ZIP/SHA, then keep the PR unmerged until the deployment boundary is separately authorised.

## Phase A — read-only deployment preflight

Record without secret values:

1. current GitHub `main` SHA;
2. current Railway active deployment SHA;
3. Railway application, Postgres, and Redis service names;
4. whether a pooler/proxy is present;
5. whether `DATABASE_URL` and `DIRECT_DATABASE_URL` variable names exist;
6. whether the direct URL is the Railway managed Postgres connection or a pooler path;
7. latest deployment status/log outcome, redacted;
8. `/health` status;
9. whether PR #112's docs-only merge caused a deployment and pre-deploy migration.

Do not print variable values.

## Phase B — deployment decision

### No deployment needed

PR #117 may remain open while read-only planning and preflight design are completed. The agent consumes the reviewed ZIP, not merged pack files.

Use when the active Railway SHA already includes PR #111 and required migrations are verified.

Proceed to database verification only.

### Deployment needed

Before a merge or redeploy, obtain explicit approval that acknowledges:

- pre-deploy will run all pending migrations;
- bootstrap will run idempotently;
- deployment is blocked on pre-deploy failure;
- PR #111 active-run index migration is concurrent but fails on duplicate active runs;
- no catalog dry-run or Apply is implied.

## Approved mechanism

Prefer repository-configured Railway deployment from reviewed `main`. Do not invent an alternate migration mechanism unless the reviewed plan proves it is necessary.

Repository authority:

```text
preDeployCommand = bin/event_sales eval 'EventSales.Release.migrate_and_bootstrap()'
startCommand = bin/event_sales start
healthcheckPath = /health
```

## Deployment evidence

Record:

- approved commit;
- deployment identifier;
- start/end timestamps;
- pre-deploy outcome;
- active SHA;
- `/health` result;
- bounded error code if failed;
- no secret-bearing log lines.

## Failure

If pre-deploy fails:

- do not force activation;
- preserve redacted log evidence;
- classify migration/bootstrap/application failure;
- do not rerun repeatedly without diagnosis;
- do not manually alter catalog run state;
- open a separately scoped corrective issue/PR when code/config is required.

## Deployment is not certification

After activation, migration/index/feed/dry-run/Apply evidence remains required.
