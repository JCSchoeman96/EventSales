# AGENTS.md — EventSales

## Authority and precedence

This file defines how coding agents must work in the EventSales repository.

When instructions conflict, use this order:

```text
1. Explicit current user instruction
2. This AGENTS.md
3. Current vertical-slice specification
4. Canonical architecture documentation
5. Older planning and historical documentation
```

Do not let obsolete Railway-first, mandatory-PR, or broad-audit instructions override this local-first workflow.

---

## Mission

Build **EventSales** as a flash-sale-safe, observable, Ash-native operational and sales-intelligence layer for WooCommerce and Tickera.

```text
WooCommerce and Tickera
|> EventSales receives catalogue and order data
|> raw webhook signatures are verified
|> Oban processes asynchronous work
|> Ash/Postgres stores durable truth
|> Redis/ETS/Cachex serve hot and shared state
|> PubSub and LiveView push operational updates
|> REST and reconciliation repair missed changes
```

---

## Canonical documentation

Use these as architecture references:

```text
docs/EventSales_Hardened_V2_1_Vertical_Slice_Roadmap.md
docs/EventSales_Hardened_V2_1_Folder_Structure.md
docs/EventSales_Hardened_V2_1_Domain_Mapping_Ash_Resource_Dossiers.md
docs/agent/01_PROJECT_WIDE_RULES.md
```

Older roadmap, folder, domain, deployment, or workflow documents are superseded where they conflict with this file or current user direction.

---

## Core project rules

```text
Build one vertical slice at a time.
Use Ash 3.x and the existing Ash domains and resources.
Inspect existing code before creating new abstractions.
Use the smallest change that completes the slice.
Write or adjust focused tests with the implementation.
Do not repeat broad repository, infrastructure, or architecture audits.
Do not rebuild EventSales functionality that already exists.
Do not perform unrelated refactors or dependency upgrades.
Do not expose secrets or real customer data.
Task completion requires focused validation and a clear result.
```

Use factual backing from:

```text
existing code
current tests
canonical documentation
official package documentation
explicit user direction
```

Use `rg` for broad text search.

Use `ast-grep run` or `ast-grep scan` when structural code discovery is materially better than text search.

---

## Local-first development environment

EventSales is currently developed and certified through a local integration environment.

Repository:

```text
/home/jcschoeman96/projects/current/EventSales
```

Application data flow:

```text
Local WordPress
http://localhost:10059
        ↓ authenticated catalogue, webhook, or REST traffic
Native Phoenix / EventSales
http://127.0.0.1:4000
        ↓
Docker Compose infrastructure
PostgreSQL: 127.0.0.1:5432
Redis:      127.0.0.1:6379
```

Agent access flow:

```text
Coding agent
├── EventSales repository and local shell
├── voelgoed-staging MCP
│   └── only after confirming its target is http://localhost:10059
└── GitHub
    └── source-control and review checkpoint after local validation
```

### Environment authority

During normal development:

```text
Local WordPress
|> source WooCommerce and Tickera system

Local Phoenix
|> active EventSales runtime

Local PostgreSQL
|> durable development truth

Local Redis
|> shared or high-velocity development state when explicitly enabled

GitHub
|> source control, backup, collaboration, review, and merge checkpoint

Railway / VPS / production WordPress
|> later staging or deployment targets only
|> out of scope without explicit authorisation
```

Do not require a remote environment before implementing or validating a local vertical slice.

Do not use public tunnels during normal local development.

---

## WordPress access

Use `voelgoed-staging MCP` for local WordPress inspection and supported controlled changes only after confirming that its active target is:

```text
http://localhost:10059
```

Do not assume the MCP name proves its target.

Before any MCP mutation, verify the target.

STOP if it resolves to:

```text
a wpstage.net address
the production Voelgoed domain
a public staging domain
an unknown WordPress installation
```

If the MCP does not support the required local operation, use the smallest explicitly local alternative:

```text
local WP-CLI
local curl
the signed EventSales catalogue client
another verified localhost-only tool
```

Do not activate unrelated WordPress functionality, including:

```text
copied staging webhooks
Payfast or other payments
SMTP or customer email
CRM
SMS or WhatsApp
marketing integrations
CDN integrations
cache or optimisation plugins
production API connectors
```

---

## Implementation workflow

The default operating mode is implementation-focused.

```text
understand the current vertical slice
|> inspect only directly relevant files
|> identify the smallest viable change
|> implement the change
|> run the focused test
|> fix concrete failures
|> run mix quality.fast at slice completion
|> perform one relevant local integration check
|> create a coherent local commit
|> push when ready to share, review, back up, or merge
|> STOP
```

Priorities:

```text
1. Working local vertical slice
2. Focused automated tests
3. Local integration proof
4. Coherent local commit
5. GitHub checkpoint when ready to share or merge
```

Avoid:

```text
broad repository audits
rechecking settled architecture
speculative hardening
unrelated refactors
unnecessary abstractions
dependency upgrades without a concrete need
production infrastructure work
Railway or VPS work
public tunnels
rebuilding existing EventSales features
over-engineering the local environment
```

Use the least number of tools and commands needed to complete the task.

---

## Targeted verification

Verify only what is necessary for the current change.

Appropriate targeted checks include:

```text
reading the directly affected module
reading its focused tests
checking one required environment variable
checking one local service health endpoint
checking one relevant database record
checking one MCP target before a WordPress mutation
checking one local HTTP or catalogue request
```

Do not turn a focused implementation task into another architecture, security, infrastructure, WordPress, or repository audit.

---

## Local service rules

Run Phoenix natively on Kubuntu.

Use Docker Compose for local PostgreSQL and Redis.

Expected services:

```text
WordPress:  http://localhost:10059
Phoenix:    http://127.0.0.1:4000
PostgreSQL: 127.0.0.1:5432
Redis:      127.0.0.1:6379
```

PostgreSQL and Redis must bind to loopback only.

Do not add Phoenix or WordPress to Docker Compose during normal development.

Do not use:

```text
production databases
Railway databases
VPS databases
production secrets
production WordPress endpoints
remote staging endpoints during ordinary local work
```

---

## Architecture boundaries

### Durable truth

```text
Postgres and AshPostgres
|> durable source of truth
```

Redis, ETS, Cachex, and hot-state processes are not replacements for durable Postgres truth.

### WooCommerce access

```text
LiveView
components
controllers
MappingResolver
|> must not call WooCommerce REST
```

Only approved ingestion services and Oban workers may call `WooCommerceClient`.

WooCommerce REST maximum concurrency remains `2`.

REST is for:

```text
bounded catch-up
reconciliation
metadata recovery
repairing missed webhook changes
```

### Webhook intake

Webhook intake must:

```text
read exact raw request bytes
|> verify WooCommerce HMAC before JSON parsing
|> persist durable intake
|> enqueue asynchronous processing
|> return quickly
```

Do not verify signatures against decoded and re-encoded JSON.

Return success only after:

```text
Postgres persistence
or
explicitly authorised Redis degraded-mode acceptance
```

### Orders and revenue

```text
order and order-item writes must be idempotent
stale source updates must not regress current state
duplicate source events must not create duplicate orders
exact WooCommerce variation IDs must be preserved
completed WooCommerce orders recognise sales and revenue
non-completed states remain visible but unrecognised
```

### Real-time behaviour

Use:

```text
Phoenix PubSub
LiveView push updates
Oban for heavy asynchronous work
GenServers for appropriate hot aggregation
cached aggregates or materialised views for analytics
```

Avoid browser polling when PubSub or LiveView push is appropriate.

---

## Local configuration and secret safety

Local secrets belong in ignored files:

```text
.env
.env.local
```

Tracked example files may contain placeholders only:

```text
.env.example
.env.local.example
```

Never print, commit, paste into logs, or expose:

```text
catalogue signing secrets
WooCommerce webhook secrets
WordPress credentials
SFTP credentials
database passwords
API credentials
real customer information
```

The existing root `.env` may contain staging administration credentials.

During normal local EventSales development:

```text
do not source it
do not modify it
do not print its values
do not reuse its credentials
```

Catalogue auto-Apply must remain disabled unless a specific task explicitly enables and tests it.

Redis webhook degraded-mode buffering must remain disabled unless a specific durability task explicitly enables and tests it.

Catalogue change receivers, live cutover flags, and copied WordPress webhooks must remain disabled unless explicitly required by the current slice.

---

## Development and test sequence

During implementation, prefer:

```bash
mix test path/to/focused_test.exs
mix compile --warnings-as-errors
mix format
```

After UI or asset changes, run only the relevant checks:

```bash
mix format
mix compile --warnings-as-errors
mix assets.build
mix test test/event_sales/assets_pipeline_config_test.exs
mix test path/to/directly_affected_test.exs
```

At vertical-slice completion:

```bash
mix quality.fast
```

Before meaningful merge or review:

```bash
mix quality.pr
```

Use `mix quality.ci` only when required by:

```text
the release process
remote deployment
merge policy
an explicit user instruction
```

Do not run every expensive test or CI-equivalent gate after every small edit.

Do not claim checks passed unless they were actually run.

---

## Git and GitHub workflow

GitHub must support development rather than block the local implementation loop.

Preferred workflow:

```text
start from a known commit
|> create or use a focused feature branch
|> implement locally
|> run focused validation
|> commit a coherent working checkpoint
|> push when ready to share, review, back up, or merge
|> open or update a PR when preparing meaningful work for merge or review
```

A GitHub connection, PR, or remote CI result is not required before local implementation begins.

Do not stop merely because:

```text
the branch has unpushed commits
GitHub is not yet updated
a PR does not yet exist
remote CI has not yet run
```

A dirty working tree is not automatically a STOP condition.

Inspect changed paths:

```text
all changes belong to the current task
|> continue carefully

unrelated or unexplained changes are present
|> STOP before overwriting or committing them
```

Never:

```text
reset hard
clean untracked files
force push
rewrite shared history
auto-resolve conflicts
overwrite unrelated work
commit secrets
push directly to main without explicit authorisation
```

---

## Repository helper scripts

Use existing repository scripts only when they directly support the task.

Prefer:

```text
Architecture boundary check
|> bash scripts/check_no_web_woocommerce_refs.sh

Git hooks
|> bash scripts/install_git_hooks.sh

Broader local validation before meaningful merge or review
|> bash scripts/local_ci.sh
```

Local infrastructure:

```bash
docker compose up -d --wait
docker compose ps
docker compose down
```

Do not use `docker compose down -v` during normal development.

Do not require GitHub synchronisation before beginning local implementation.

Use `scripts/sync_with_origin_main.sh` only when intentionally synchronising with remote `main`.

Once root `compose.yaml` is established, use it as the canonical PostgreSQL and Redis workflow instead of `scripts/dev_postgres.sh`.

Do not use Railway smoke-test or deployment scripts during normal local development.

---

## UI, assets, and component rules

EventSales uses:

```text
Phoenix 1.8
LiveView
Tailwind v4
vendored DaisyUI
Mishka Chelekom
Chart.js
```

Canonical asset files:

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
Do not reintroduce Tailwind v3 configuration.
Do not install a second DaisyUI source.
Do not remove or reorder required Mishka CSS imports.
Do not replace the existing Mishka LiveView hook map.
Do not import Chart.js again when it is already loaded globally.
```

UI priority:

```text
1. Existing EventSales component
2. DaisyUI primitive
3. Mishka Chelekom component or hook
4. Small local Phoenix function component
5. Custom JavaScript only for browser-owned behaviour
```

When adding hooks:

```javascript
hooks: { ...MishkaComponents, ...NewHooks }
```

Chart.js components must:

```text
use a stable unique canvas ID
pass server data through data attributes as JSON
use phx-update="ignore"
destroy an existing chart before recreating it
avoid LiveView patching an active canvas
use cached aggregates rather than peak-time table scans
```

Use stable literal Tailwind classes where possible.

Add unavoidable dynamic classes to:

```text
assets/css/safelist.txt
```

---

## Performance and scaling guardrails

Preserve these design principles:

```text
Postgres is durable truth.
Redis is shared high-velocity state.
Oban performs asynchronous work.
PubSub and LiveView push updates.
GenServers aggregate appropriate hot state.
Critical writes are idempotent and concurrency-safe.
Exact variation IDs are never collapsed into product IDs.
Catalogue pages are fully aggregated before planning.
Large datasets are streamed or paginated.
Analytics avoid peak-time table scans.
```

Current targets:

```text
sub-100 ms common API latency
sub-5 second checkout p99
zero overselling
no duplicate order attribution
horizontal scalability
```

Do not add infrastructure merely to satisfy theoretical future scale when it is not required by the current slice.

---

## STOP conditions

Stop immediately when:

```text
the WordPress target is not confirmed as localhost:10059
a command would contact production WordPress
a command would contact Railway or the VPS without explicit authorisation
a database URL is not local
PostgreSQL or Redis is exposed beyond loopback
a production or staging secret is about to be used locally
a secret is about to be committed or printed
unrelated local changes would be overwritten
a destructive database command targets an unverified database
catalogue auto-Apply becomes enabled unintentionally
Redis webhook degraded buffering becomes enabled unintentionally
copied WordPress webhooks become active
payments, email, CRM, SMS, or marketing side effects could occur
Phoenix or WordPress is being containerised without a demonstrated need
the task expands beyond the current vertical slice
a focused test fails and the cause is not understood
the same failing operation has been attempted twice without new evidence
```

When a STOP condition occurs:

```text
1. Stop running commands.
2. State the exact failed command or unsafe target.
3. Preserve and show the relevant non-secret output.
4. Recommend only the smallest next diagnostic step.
5. Wait for explicit direction.
```

---

## Completion definition

A local vertical slice is complete when:

```text
scope implemented
|> focused tests pass
|> relevant local services are healthy
|> one local integration check passes
|> mix quality.fast passes
|> no architecture boundary is violated
|> no unrelated changes were introduced
|> no secrets or customer data were exposed
|> a coherent local commit exists
|> GitHub is updated when ready to share, review, or merge
|> the result is reported briefly
|> STOP
```

Report completion using:

```text
Done
|> what changed
|> tests and checks run
|> local integration result
|> remaining risks or blockers
```

Do not sugar-coat failures. If a test was not run or did not pass, state that plainly.
