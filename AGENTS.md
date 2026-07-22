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

## Pre-handover development velocity mode

EventSales is still under active development. It has not been handed over to management and is not serving live customer operations. The Railway environment currently named `production` is the project's pre-handover integration environment until the owner explicitly declares a management handover or live launch.

This section takes precedence over generic conservative or uncertainty guidance while the project remains pre-handover.

Default operating mode:

```text
Optimize for useful output, short feedback loops, and working vertical slices.
Proceed with reasonable, documented assumptions instead of blocking on hypothetical risks.
Prefer the smallest reversible change, focused validation, and fix-forward development.
Do not stop merely because staging is missing, an environment is named production, a public proxy exists, or a reversible pre-handover change might temporarily break the development environment.
Use the least number of tools needed and avoid long audits that do not change the implementation decision.
When the current task requires it, normal development mutations to the pre-handover Railway environment are allowed unless the task explicitly says read-only.
```

Normal pre-handover development work may include:

```text
Deploying or restarting the EventSales application.
Changing scoped application variables or feature flags.
Running migrations against development/pre-handover databases.
Creating isolated staging services and synthetic test data.
Rotating development credentials when required.
Running synthetic webhooks, smoke tests, and focused integration tests.
Resetting disposable non-customer development data when the task explicitly requires it.
```

Keep these hard boundaries:

```text
Never print, commit, or intentionally expose secrets.
Never use real customer or management data for development tests.
Never trigger payments, customer emails, external notifications, or other irreversible third-party side effects without explicit approval.
Never delete a database, volume, environment, repository history, or non-disposable data without explicit approval and a recovery path.
Never force push, reset hard, clean untracked files, or rewrite shared history.
Stop when the target may be an actual live management environment rather than the pre-handover EventSales environment.
Stop when a change is not reasonably reversible or its blast radius extends beyond EventSales.
```

Decision rule:

```text
Reversible and limited to the pre-handover EventSales system? Proceed, test, and report.
Potentially irreversible, externally visible, or involving real users/data? Ask for approval first.
Uncertain but low-risk and reversible? State the assumption and continue.
```

Time and retry limits:

```text
Time-box investigation that does not modify the implementation decision to 15 minutes.
Attempt a failing operation no more than twice unless new evidence justifies another attempt.
After two failed attempts or 30 minutes blocked, stop and report the smallest concrete blocker and next action.
Stop after the requested task and validation are complete; do not expand into adjacent work automatically.
```

After management handover or live launch, the owner must update this section and restore stricter production-change controls.

## UI, assets, and component rules

EventSales uses Phoenix 1.8 LiveView with Tailwind v4, vendored DaisyUI, Mishka Chelekom, and Chart.js.

Source of truth:

```text
assets/css/app.css
assets/js/app.js
assets/css/safelist.txt
assets/vendor/daisyui.mjs
assets/vendor/mishka_chelekom.css
assets/vendor/mishka_components.js
lib/event_sales_web/components/layouts/root.html.heex
lib/event_sales_web/live/admin/components/sales_chart.ex
```

Rules:

```text
Do not add assets/tailwind.config.js.
Do not reintroduce Tailwind v3 config patterns.
Do not install DaisyUI through npm unless the asset strategy is intentionally changed.
Do not add a second DaisyUI plugin source.
Do not remove or reorder the Mishka CSS import before Tailwind in assets/css/app.css.
Do not overwrite Mishka LiveView hooks in assets/js/app.js.
Do not import Chart.js again in assets/js/app.js while it is loaded globally in root.html.heex.
```

Use this UI priority:

```text
1. Existing EventSales component
2. DaisyUI primitive
3. Mishka Chelekom component or hook
4. Small local Phoenix function component
5. Custom JavaScript only for browser-owned behavior
```

DaisyUI is preferred for generic UI primitives:

```text
btn, card, alert, badge, table, tabs, modal, dropdown, stat, skeleton, loading
```

Mishka is preferred when the component needs existing Mishka design tokens, CSS variables, or LiveView hooks.

When adding LiveView hooks, always merge with Mishka hooks:

```js
hooks: { ...MishkaComponents, ...NewHooks }
```

Never replace the existing hook map with only the new hooks.

Chart.js rules:

```text
Use lib/event_sales_web/live/admin/components/sales_chart.ex as the canonical pattern.
Use a stable unique canvas id.
Pass server data through data-* attributes as JSON.
Use phx-update="ignore" on the chart canvas or wrapper.
Destroy an existing chart instance before recreating it.
Do not let LiveView patch an active Chart.js canvas.
Use cached aggregates/read models for chart data; do not trigger large table scans from UI components.
```

Dynamic Tailwind classes:

```text
Prefer stable literal classes in HEEx.
If a class must be generated dynamically, add it to assets/css/safelist.txt.
```

Required checks after UI or asset changes:

```bash
mix format --check-formatted
mix compile --warnings-as-errors
mix assets.build
mix test test/event_sales/assets_pipeline_config_test.exs
mix test
```

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
ONLY use subagents if/when the user explicitly asks requests them
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
