# AGENTS.md - EventSales

## Mission

Build **EventSales** as a flash-sale-safe, observable, Ash-native sales intelligence layer for WooCommerce + Tickera.

```text
WooCommerce sells tickets
|> EventSales ingests webhooks
|> Oban processes async work
|> Ash/Postgres stores durable truth
|> Redis/ETS/Cachex serve hot/warm reads
|> LiveView displays internal admin dashboards
|> REST/CSV reconciliation repairs gaps
```

## Canonical docs

Use these files as the source of truth:

```text
docs/EventSales_Hardened_V2_1_Vertical_Slice_Roadmap.md
docs/EventSales_Hardened_V2_1_Folder_Structure.md
docs/EventSales_Hardened_V2_1_Domain_Mapping_Ash_Resource_Dossiers.md
```

Older roadmap/folder/domain docs are superseded.

## Project-wide rules

Full source of truth: [`docs/agent/01_PROJECT_WIDE_RULES.md`](docs/agent/01_PROJECT_WIDE_RULES.md)

Non-negotiable summary:

```text
Build one vertical slice at a time.
Use factual backing: existing code, canonical docs, official package docs, or explicit user direction.
Write or adjust tests before business logic.
Keep LiveView, components, controllers, and MappingResolver away from WooCommerce REST.
Only Oban workers and approved ingestion services may call WooCommerceClient.
Postgres/AshPostgres is durable truth; Redis/ETS/Cachex/HotStateAggregator are read models only.
Webhook intake must verify exact raw-body signatures before JSON parsing.
WooCommerce REST max concurrency is 2.
No secrets or real customer data in code, tests, logs, fixtures, or docs.
Task is not complete unless required checks pass.
Always open or update a PR after meaningful work.
```
- Use rg for broad text search; use ast-grep run or ast-grep scan for structural code discovery.

## Repo helper scripts

Use repo scripts instead of inventing ad-hoc commands.

Prefer `bash scripts/<name>.sh ...` so commands work even when executable bits are not preserved across machines, worktrees, zip downloads, or Windows tooling.

```text
Before starting work
|> bash scripts/sync_with_origin_main.sh --check
|> if clean and safe: bash scripts/sync_with_origin_main.sh --sync

Local Postgres
|> bash scripts/dev_postgres.sh start
|> bash scripts/dev_postgres.sh status
|> bash scripts/dev_postgres.sh logs
|> bash scripts/dev_postgres.sh stop
|> bash scripts/dev_postgres.sh reset only when data loss is intended

Git hooks
|> bash scripts/install_git_hooks.sh
|> installs .githooks as the repo-local hooks path

Before meaningful PR push
|> bash scripts/local_ci.sh

Architecture guardrail
|> bash scripts/check_no_web_woocommerce_refs.sh
|> verifies LiveView/controllers/components/MappingResolver do not call WooCommerce REST or direct HTTP clients

Railway smoke test
|> scripts/smoke_test_railway_release.sh is currently a placeholder for Slice 24.0
|> do not rely on it until that slice implements the real smoke test
```

## Git safety

```text
Never reset hard.
Never clean files.
Never force push.
Never auto-resolve conflicts.
Never rebase pushed/shared branches without approval.
Stop if the working tree is dirty.
```

If unsure:

```text
say unsure
|> explain risk
|> ask concise question
|> do not invent architecture
```
- Use rg for broad text search; use ast-grep run or ast-grep scan for structural code discovery.
