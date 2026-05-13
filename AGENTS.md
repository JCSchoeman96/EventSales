# AGENTS.md — EventSales

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

## Stack

```text
Elixir / Phoenix / LiveView / Ash 3.x / AshPostgres
|> AshAuthentication / AshAdmin / AshStateMachine / AshPaperTrail
|> Oban / Bandit / PostgreSQL / Redis / ETS / Cachex
|> Tailwind / Mishka Chelekom
|> Railway / optional PgBouncer
```

## Work style

```text
Understand task
|> read canonical docs
|> inspect existing code
|> research official docs when unsure
|> make short plan
|> implement minimum useful code
|> add/adjust tests
|> run tests
|> report result plainly
```

## Git sync before work

Before starting any task:

```bash
scripts/sync_with_origin_main.sh --check
```

If the branch is clean and sync is safe:

```bash
scripts/sync_with_origin_main.sh --sync
```

Rules:

```text
Never reset hard.
Never clean files.
Never force push.
Never auto-resolve conflicts.
Never rebase pushed/shared branches without approval.
Stop if the working tree is dirty.
```

Never code from vibes. Use factual backing: existing code, canonical docs, official package docs, or explicit user direction.

If unsure:

```text
say unsure
|> explain risk
|> ask concise question
|> do not invent architecture
```

## Hard rules

```text
One vertical slice at a time.
Tests before or with implementation.
Task is not complete unless tests pass.
Use minimal code that solves the slice.
No over-engineering.
No hidden rewrites outside the slice.
No secrets in code, tests, logs, fixtures, or docs.
No real customer data in fixtures.
```

## Project-Wide Rules

Source of truth: [`01_PROJECT_WIDE_RULES.md`](docs/agent/01_PROJECT_WIDE_RULES.md)

Must obey:
|> build one vertical slice at a time
|> write/adjust tests before business logic
|> never call WooCommerce REST from LiveView, components, controllers, or MappingResolver
|> only Oban workers and approved ingestion services may call WooCommerceClient
|> webhook controller receives webhooks only; it must not call WooCommerce REST
|> Postgres/AshPostgres is durable truth
|> Redis/ETS/Cachex/HotStateAggregator are read models only
|> Oban orchestrates async work; Ash actions own durable mutations
|> AshAuthentication, AshStateMachine, AshPaperTrail, and AshAdmin are the default ecosystem choices
|> manual dashboard refresh must never call WooCommerce
|> WooCommerce REST max concurrency is 2
|> return 2xx for webhooks only after Postgres persistence or explicitly accepted Redis degraded-mode buffering

Required runtime config:
|> EVENTSALES_BUSINESS_TIMEZONE=Africa/Johannesburg
|> EVENTSALES_DEFAULT_CURRENCY=ZAR

## Architecture boundaries

```text
LiveView/components/controllers
|> must not call WooCommerce REST

WebhookController
|> may receive WooCommerce webhooks
|> must not call WooCommerce REST
|> validate raw-body signature
|> store/enqueue/return quickly

WooCommerceClient
|> lives under ingestion/clients
|> worker/service-module only
|> max REST concurrency = 2

MappingResolver
|> pure/local lookup only
|> must not call WooCommerce REST

Ash resources
|> durable domain records only
|> no Redis/ETS/Cachex Ash DataLayer

HotStateAggregator
|> hot read model only
|> not durable truth
|> update only after durable write commits

RedisWebhookBuffer
|> optional degraded-mode safety valve
|> not canonical truth
```

## Required sequence

Follow the canonical vertical slice order. Critical path summary:

```text
0.0 Bootstrap
|> 0.2 Repo/PgBouncer/Release topology
|> 0.4 Ash ecosystem
|> 0.8 Telemetry
|> 1.0 Domains
|> 1.5 E2E harness
|> 1.6 real payload verification
|> 2.0 Auth/roles/access
|> 3.0 Catalog/mapping
|> 4.0 Sales storage/state machines
|> 5.0 Webhook intake
|> 5.1 Raw-body signature/replay guard
|> 5.5 Flash-sale intake protection
|> 5.7 Oban/PgBouncer smoke test
|> 6.0 Idempotent/out-of-order processing
|> 7.0 Order normalization
|> 7.5 Woo REST client
|> 8.x Mapping/recovery/state/audit
|> 9.x Metrics/hot state/snapshots
|> 10.0 Admin dashboard
|> 11.0 PubSub/cache
|> 23.0 E2E acceptance
|> 24.0 Railway smoke test
|> 25.0 Launch hardening
```

## Domain map

```text
Accounts
|> User
|> Role
|> UserRole
|> EventAccessGrant
|> PIIPolicy

Catalog
|> SourceSystem
|> Event
|> TicketType
|> ProductMapping
|> EventDashboardSetting
|> MappingResolver
|> MissingCatalogResolver
|> ProductMetadataCache

Sales
|> Order
|> OrderItem
|> CouponSnapshot
|> OrderUpserter
|> SourceVersionGuard

Ingestion
|> WebhookEvent
|> WebhookDeliveryFailure
|> SyncRun
|> SyncCursor
|> CsvImportBatch
|> CsvImportRow
|> WooCommerceClient
|> RedisWebhookBuffer
|> REST rate limiter/circuit breaker

Analytics
|> MetricRules
|> AggregateEvent
|> HotStateAggregator
|> DashboardCache
|> EventAggregateSnapshot
|> DailySalesAggregateSnapshot

Audit
|> AuditLog
|> MetadataSanitizer
|> PaperTrail integration
```

## Resource rules

```text
ProductMapping
|> variation-specific wins
|> product-level and variation-level unique indexes must handle NULL variation IDs correctly

Order
|> source_system_id + woo_order_id unique
|> last_source_updated_at prevents stale webhook regression
|> completed-only counts for sold/revenue

OrderItem
|> reporting unit for mixed-event orders
|> sale-line quantity must be > 0
|> zero/negative/refund-like rows never count as sold tickets

WebhookEvent
|> raw-body HMAC verification before JSON parsing
|> invalid signatures store metadata only
|> stale events do not mutate current sales state

AggregateEvent
|> must have idempotency key
|> duplicate events do not double-apply
```

## Auth and access

```text
Use AshAuthentication.
Use AshAdmin only as protected internal visibility.
Global roles: admin, staff.
Event-scoped roles: event_owner, event_staff via EventAccessGrant.
Event-scoped policies live in Ash, not routes.
PII hidden/masked by role.
Future client dashboards are aggregate-first and no-PII by default.
```

## Caching and state

```text
Postgres
|> durable truth

ETS/Cachex
|> hot state
|> 10s-5m TTL

Redis
|> warm snapshots / metadata / optional degraded buffer
|> 30m-24h TTL where appropriate

HotStateAggregator
|> Redis-first restore
|> warming state
|> async Postgres rebuild
|> anti-stampede lock
|> telemetry on rebuild/update
```

## Webhook rules

```text
RawBodyReader runs before JSON parsing.
Verify WooCommerce HMAC against exact raw bytes.
Do not verify against decoded/re-encoded JSON.
If valid:
  validate |> persist/buffer |> enqueue |> return quickly
If invalid:
  reject |> log metadata only |> no raw payload storage
If neither Postgres nor explicitly enabled Redis fallback accepts:
  return non-2xx so WooCommerce retries
```

## REST rules

```text
REST is fallback/reconciliation/metadata recovery only.
Max global WooCommerce REST concurrency = 2.
Use timeout + typed errors + telemetry.
Pause/open circuit on repeated 429/500/timeouts.
Never call REST from LiveView, controller, or MappingResolver.
```

## Database / Railway rules

```text
DATABASE_URL
|> normal app traffic

DIRECT_DATABASE_URL
|> migrations/session-sensitive maintenance when provided

PgBouncer transaction mode
|> explicit compatibility decision
|> test Ecto/Ash/Oban topology
|> do not assume LISTEN/NOTIFY works

Railway
|> primary deployment target
|> health route required
|> production smoke test required
```

## Code standards

```text
Prefer small modules with clear boundaries.
Use pattern matching and explicit result tuples.
Use Ash actions for durable mutations.
Use workers for async orchestration.
Use pure modules for rules/parsers where possible.
Keep LiveView thin.
```

Documentation:

```text
@moduledoc
|> required for public modules

@doc
|> required for public functions with non-obvious behavior

@spec
|> required for public functions and important pure functions

Private helpers
|> keep simple; docs optional
```

## Tests

Minimum before marking a slice done:

```bash
mix format --check-formatted
mix test
```

Run when available:

```bash
mix credo --strict
MIX_ENV=test mix ash.codegen --dry-run
```

Postgres-backed test baseline:

```text
Since Slice 0.2, mix test requires Postgres to be reachable.
Local: start Postgres, then run MIX_ENV=test mix ecto.create && MIX_ENV=test mix ecto.migrate before mix test when the test DB is not ready yet.
CI: only the test job gets a Postgres service.
Do not add Redis to CI until a slice explicitly requires it.
```

## Quality gates

Use [`docs/development/quality-gates.md`](docs/development/quality-gates.md) as the local and CI quality-gate reference.

```text
Before commit
|> mix quality.fast

Before push
|> mix quality.ci

Task is not complete unless required checks pass.
Do not add Ash-specific checks until Ash exists.
Do not add DB/Redis CI services until tests require them.
Postgres is now required for the CI test job because the Repo and Oban start in :test.
Keep Redis out of CI until a later slice requires it.
```

Mandatory coverage areas:

```text
webhook raw-body signature
invalid signature rejection
idempotent webhook processing
out-of-order/stale webhook protection
completed-only metrics
mapping resolution
missing catalog recovery
REST concurrency/circuit breaker
CSV dry-run/apply
Ash policies
PII masking
audit logging
HotStateAggregator rebuild safety
full webhook-to-dashboard E2E
```

## Feedback format to user

Use concise status updates.

```text
Done
|> what changed
|> tests run
|> result
|> risks/blockers
```

For problems, use /caveman style:

```text
Problem: <plain issue>
Why: <short reason>
Fix: <next action>
Test: <how to prove it>
```

Do not sugar-coat. Do not pretend. If tests fail, say so.

## Completion definition

A task is complete only when:

```text
slice scope implemented
|> relevant tests added
|> required commands pass
|> no architecture boundaries violated
|> no secrets/PII leaked
|> result reported clearly
```

If tests cannot be run, the task is not fully complete. State exactly what was not run and why.
