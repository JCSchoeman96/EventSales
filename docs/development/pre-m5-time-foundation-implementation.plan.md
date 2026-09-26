---
Plan ID: pre-m5-time-foundation-implementation
Plan version: v2
Status: active execution plan (PRE-M5-TIME-A docs-only baseline)
Scope: PRE-M5-TIME-B through PRE-M5-TIME-G sequencing; M1-07 physical conformance on certified main
Authority: M1-07 T1–T31 = semantic authority; this PRE-M5-TIME plan = current physical/repository implementation authority
Historical context: `docs/path-1/m1-07-timestamp-johannesburg-period-and-freshness-contract.md` (locked semantics; repository observations superseded here)
Last updated: 2026-09-26
Change summary (v2): Sync freshness from terminal catch-up `source_observed_at`; missing-anchor API consistency; M5 deferral typo; owner-decision gates before TIME-C/TIME-F
---

### Revision log

- v1 — PRE-M5-TIME-A current-repo reconciliation + physical implementation plan at merge `5746edb8a2c272b1e6c0ce16153f9063c8e78925`
- v2 — PR #254 review: separate sync source-observed watermark from historical coverage; remove fourth freshness enum; fix M5/M6 typo; lock owner-decision deadlines

# PRE-M5-TIME — Time, period and source-freshness foundation

> Planning artifact only. PRE-M5-TIME-A is docs-only. Do not implement production code, migrations, or tests from this document until the applicable sub-slice is explicitly authorized.

## Goal

Close `GAP-PRE-M5-TIME` so M5 may start without redefining time semantics:

```text
authoritative sale/refund effective clocks for period placement
deterministic Africa/Johannesburg [start, end) boundaries
durable multi-input source freshness distinct from read-model/cache age
NORMAL / AGING / STALE backend semantics per M1-07 T13–T15
bounded, indexable period/freshness queries
```

## Certified programme baseline

```text
Repository:     JCSchoeman96/EventSales
Required main:  5746edb8a2c272b1e6c0ce16153f9063c8e78925  (PR #253 merge)
Merge tree:       2fa63b1162859de506d3fffb2b38ffd87ed81217
Post-merge CI:    #657 / run 36232155520 (all six jobs PASS on merge SHA)

GAP-PRE-M5-READY-IX = CLOSED
GAP-PRE-M5-METRICS  = CLOSED
GAP-PRE-M5-TIME     = OPEN
PRE-M5-TIME         = AUTHORIZED (planning slice TIME-A complete when this doc merges)
M5                  = BLOCKED until GAP-PRE-M5-TIME CLOSED
```

Each implementation slice (TIME-B onward) starts from the verified post-merge `main` of its predecessor.

---

# 1. Current-repository reconciliation (M1-07 → main @ 5746edb)

Evidence class: **REPOSITORY EVIDENCE** at certified baseline unless noted as **CONTRACT DECISION** (M1-07 T1–T31).

| Topic | Classification | Current repository evidence |
| --- | --- | --- |
| Sale `paid_at` persistence | **ALREADY_IMPLEMENTED** | `Order.paid_at` attribute; `sales_orders.paid_at` via `priv/repo/migrations/20260817152402_m3_04a_financial_source_primitives.exs`; accepted on `:sync_from_normalized` / `:hydrate_paid_at` in `lib/event_sales/sales/resources/order.ex`; Woo `date_paid_gmt` parsed in `lib/event_sales/ingestion/parsers/woocommerce_order_parser.ex` |
| `completed_at` persistence / fallback field | **ALREADY_IMPLEMENTED** (field); **IMPLEMENTATION_REQUIRED** (as sale-effective fallback in analytics) | Indexed `completed_at` on `Order`; set via `SyncStatusFromSource`; M1-07 fallback not used in period queries yet |
| Refund `source_created_at` persistence | **ALREADY_IMPLEMENTED** | `Refund.source_created_at`; migration `20260817170000_m3_05a_refund_facts.exs`; parser `woocommerce_refund_parser.ex`; reconciliation uses it in `local_totals.ex` / `source_extractor.ex` |
| Sale effective-time selection (`paid_at` → `completed_at` → withhold) | **IMPLEMENTATION_REQUIRED** | No `TimeRules` / coalesce helper; `EventAggregator` SQL uses `o.completed_at` only for gross paths (`event_aggregator.ex`); `MetricRules.summarize/2` buckets Today on `order.completed_at` (`metric_rules.ex:224`) |
| Refund effective-time selection | **PARTIALLY_IMPLEMENTED** | Field persisted; financial aggregation joins refunds without period predicates today; recon validates `source_created_at` at coverage boundaries |
| Johannesburg named-zone conversion | **IMPLEMENTATION_REQUIRED** | `MetricRules.business_date/2` special-cases `"Africa/Johannesburg"` with `DateTime.add(2, :hour)` (`metric_rules.ex:48-52`); other zones use `DateTime.shift_zone/2` |
| Half-open `[start, end)` bounds | **IMPLEMENTATION_REQUIRED** | Contract locked in M1-07; no shared period-bound module; rolling/custom bounds not implemented in code |
| Today (Johannesburg calendar day) | **PARTIALLY_IMPLEMENTED** | Calendar intent via `same_business_date?/3` but wrong clock (`completed_at`) and wrong zone path for Johannesburg |
| Yesterday | **IMPLEMENTATION_REQUIRED** | No first-class API; must derive from `today_bounds/2` minus one day |
| Last 7 Days | **IMPLEMENTATION_REQUIRED** | Not implemented as rolling `[now−7d, now)` |
| Last 30 Days | **IMPLEMENTATION_REQUIRED** | Not implemented as rolling `[now−30d, now)` |
| Custom ranges | **IMPLEMENTATION_REQUIRED** + **OWNER_DECISION_REQUIRED** (max duration) | Product requires max cardinality (`EVENTSALES_PRODUCT_DECISIONS.md:117`); no numeric cap locked |
| Period placement of Gross | **IMPLEMENTATION_REQUIRED** | All-time/event totals ignore effective-time windows; daily snapshot uses `completed_at` only |
| Period placement of refunds | **IMPLEMENTATION_REQUIRED** | Refunds aggregated without `source_created_at` window predicates in `EventAggregator` |
| Missing sale effective time | **PARTIALLY_IMPLEMENTED** | M1-07 T25 withhold semantics not wired into period aggregation; historical certifier touches `paid_at` completeness |
| Missing refund effective time | **PARTIALLY_IMPLEMENTED** | Reconciliation fails closed (`{:timestamp_incomplete, %{field: :source_created_at}}`); analytics period path not yet |
| Source freshness inputs (multi-component) | **IMPLEMENTATION_REQUIRED** | No durable event-level projection; `EventAggregateSnapshot.source_watermark_at` = max `Order.updated_at_source` in refresh scope only (`snapshot_refresh.ex:443-447`); excludes refunds and sync coverage |
| Read-model age | **ALREADY_IMPLEMENTED** (wrong role) | `HotStateAggregator.last_fresh_at`, summary `:updated_at`, snapshot `refreshed_at` |
| NORMAL / AGING / STALE thresholds | **IMPLEMENTATION_REQUIRED** | Product + M1-07 T13–T15 locked; code uses 5m on read-model age (`hot_state_aggregator.ex:27,421-422`; `config/config.exs` stale_after_ms) |
| Future-clock handling | **IMPLEMENTATION_REQUIRED** | Not implemented in classification kernel |
| Manual-refresh semantics | **PARTIALLY_IMPLEMENTED** | Rebuild advances `last_fresh_at` (`hot_state_aggregator.ex:345-349`); M1-07 T27 requires rebuild ≠ source fresh |
| PubSub boundary | **ALREADY_IMPLEMENTED** | Notification after cache write (`hot_state_aggregator.ex:485`); not freshness truth (M1-07 T28) |
| `paid_at` / sale-effective indexing | **IMPLEMENTATION_REQUIRED** | No index on `paid_at`; only `completed_at_idx` on `Order` |
| Refund-time indexing | **IMPLEMENTATION_REQUIRED** | No index on `Refund.source_created_at`; only `order_id_idx` |
| Durable source-freshness projection | **IMPLEMENTATION_REQUIRED** | See §4 |
| HotStateAggregator stale semantics | **IMPLEMENTATION_REQUIRED** | `lifecycle_for_fresh_at/2` and `stale_fresh_at?/1` measure rebuild/restore age, not source anchor |
| Dashboard freshness read path | **IMPLEMENTATION_REQUIRED** | `StaleDataBanner` keys off `hot_state[:state]` (`stale_data_banner.ex`); `AdminDashboard` passes `HotStateAggregator.status/0` |

### M1-07 audit corrections (do not copy stale M1-07 §5.5)

M1-07 at `8b0d82c` stated `date_paid_gmt` was absent. **Current main disproves that.** PRE-M5-TIME treats paid/refund effective field persistence as **done**; remaining work is selection, bucketing, freshness projection, indexes, and dashboard semantics.

### Certification-only items

| Topic | Classification |
| --- | --- |
| M1-07 T1–T31 semantic table | **NOT_APPLICABLE** to implement (locked); referenced everywhere |
| M5 hourly/daily aggregate tables | **DEFERRED_TO_M5** (T30 handoff; M6 owns dashboard UX only) |
| Stale banner UX copy | **DEFERRED_TO_M6** (M6-06); backend classification owned here |
| Corrected effective-time audit history | **DEFERRED** (`GAP-OPT-TIME-AUDIT`) |

---

# 2. Domain / resource map before phases

## Effective time (UTC instants)

```text
Sale effective:     COALESCE(paid_at, completed_at) when recognised historically → else withhold
Refund effective:   Refund.source_created_at → else withhold
```

TIME chooses **when** facts belong in a reporting period. PRE-M5-METRICS / M1-04 / M1-06 still own **whether** and **how much** they count financially.

## Reporting period

```text
Timezone:   Africa/Johannesburg (IANA)
Boundary:   [start_utc, end_utc)   membership: start <= t < end
Types:      Today, Yesterday, rolling 7d, rolling 30d, custom Johannesburg civil range
Excluded:   ISO week semantics (not authorized)
```

## Source freshness (durable, multi-input)

Per M1-07 T10, per event scope:

```text
order_source_watermark_at      ← max durable Order.updated_at_source applied for event’s orders
refund_source_watermark_at     ← max Refund.source_created_at applied for event’s refunds (active facts)
sync_source_observed_at        ← terminal bounded catch-up source high-water (see below; TIME-E)
```

**Anchor (derived, recommended):**

```text
source_freshness_anchor_at = max(order_wm, refund_wm, sync_observed_wm)
  -- component-wise max of present components
```

### Sync freshness vs historical coverage (locked)

Repository evidence shows **historical completeness boundaries** and **catch-up source observation** are different clocks:

```text
HistoricalCoverageCertifier summary (certified run):
  sales_covered_through   = SyncRun.date_to          -- historical coverage boundary
  refunds_covered_through = catchup.source_observed_at   -- aliases catch-up high-water in that summary only
```

Catch-up machinery durably carries source high-water separately:

```text
HistoricalCatchupEvidence.source_observed_at
  -- terminal bounded catch-up source-observed timestamp (lib/event_sales/ingestion/historical_catchup_evidence.ex)
```

M1-07 T10 requires freshness from **successful bounded catch-up source-modified / source-observed progress**, not from BACKFILL coverage bounds.

**Locked TIME-E rule:** a successful bounded catch-up may advance `sync_source_observed_at` only from explicit durable **terminal** catch-up source high-water (`HistoricalCatchupEvidence.source_observed_at` after successful terminal completion, or an equivalently named freshness watermark persisted at that boundary).

**Do NOT derive source freshness from:**

```text
SyncRun.date_to
sales_covered_through
refunds_covered_through   (as a coverage field — even when it currently equals catchup.source_observed_at in certifier output)
historical coverage_start / coverage_certified_at
SyncRun.finished_at or job wall-clock completion
```

Do not treat incidental equality between `refunds_covered_through` and `source_observed_at` in today's certifier summary as the freshness contract. Consume explicit terminal catch-up evidence (or a dedicated freshness watermark written at terminal catch-up success).

Do **not** substitute: snapshot `refreshed_at`, Redis/ETS `updated_at`, `HotStateAggregator.last_fresh_at`, `inserted_at`, PubSub delivery time.

## Read-model health (separate vocabulary)

```text
warming | ready | degraded (rebuild failed / timeout)
generated_at / refreshed_at age
rebuild_in_flight?
```

Never label read-model age as SOURCE STALE.

---

# 3. Lifecycle / state machines

## Source-freshness classification (derived, not persisted)

Locked operators (M1-07 T13–T15):

```text
age = now - source_freshness_anchor_at   (when anchor present)

age < 5m              → NORMAL
5m <= age <= 10m      → AGING
age > 10m             → STALE

age == 5m   → AGING
age == 10m  → AGING
age > 10m   → STALE
```

Future anchor (`anchor > now`): clamp age to 0 → NORMAL + low-cardinality telemetry (T15).

### Missing anchor

M1-07 does **not** authorize a fourth persisted programme state such as `UNKNOWN`.

**Plan decision (single API contract):** backend source-freshness classification is exactly `:normal | :aging | :stale` when an anchor exists. Missing anchor is a typed absence, not a fourth programme classification:

```text
{:ok,
 %{
   classification: :normal | :aging | :stale,
   anchor_at: DateTime.t(),
   age_ms: non_neg_integer()
 }}

{:error, :missing_source_freshness_anchor}
```

Exact public result structs may be finalized in TIME-D/F, but the plan **prohibits** `:anchor_missing`, `:unknown`, or equivalent as backend source-freshness classifications. M6 presentation may show “no source freshness available” using read-model metadata or error handling without extending the three-state contract.

## Freshness projection lifecycle (durable row)

```text
MISSING  →  CURRENT   (first monotonic component write creates row)
CURRENT  →  CURRENT   (component watermarks advance; never regress)
```

No terminal state. Out-of-order/replay must not lower a component watermark.

Do **not** persist NORMAL/AGING/STALE on the row.

## Read-model lifecycle (HotStateAggregator)

Keep existing `:warming | :ready | :stale` as **read-model health**, renamed in API docs to avoid overloading “stale” with M1-07 STALE. Target shape:

```text
read_model: %{lifecycle: :warming | :ready | :degraded, generated_at: ..., rebuild_in_flight?: ...}
source_freshness:
  {:ok, %{classification: :normal | :aging | :stale, anchor_at: ..., age_ms: ...}}
  | {:error, :missing_source_freshness_anchor}
```

## Refresh job lifecycle

Reuse Oban queued/running/completed/failed. Manual hot rebuild updates read-model generated time only (T27).

---

# 4. Physical ownership — durable source freshness

## Option A — extend `EventAggregateSnapshot`

**Reject** as canonical event freshness owner.

- Grain `(event_id, currency)` duplicates one freshness value per currency.
- Canonical financial row may be absent while orders exist.
- Existing `source_watermark_at` is order-only max in refresh scope, not M1-07 anchor.

May remain as **financial snapshot metadata** (order rows touched in refresh), not programme freshness truth.

## Option B — `SyncRun` / `SyncCursor` only

**Reject** as sole owner.

- Webhook order applies and refund applies also advance freshness.
- Catch-up is one input, not the whole anchor.

`SyncRun.date_to`, `sales_covered_through`, and coverage certifier fields are **historical completeness**, not sync freshness inputs. Only terminal catch-up **source_observed_at** (or equivalent terminal freshness watermark) may advance `sync_source_observed_at`.

## Option C — dedicated event freshness projection (recommended)

**Accept:** new Analytics resource (name proposal):

```text
EventSales.Analytics.Resources.EventSourceFreshnessSnapshot
lib/event_sales/analytics/resources/event_source_freshness_snapshot.ex
table: analytics_event_source_freshness_snapshots
grain: one row per event_id (unique index on event_id)
```

Durable fields (proposal):

```text
event_id
order_source_watermark_at        :utc_datetime_usec | nil
refund_source_watermark_at       :utc_datetime_usec | nil
sync_source_observed_at          :utc_datetime_usec | nil   -- monotonic; TIME-E from terminal catch-up evidence only
projection_version               :integer
projection_refreshed_at          :utc_datetime_usec          -- row metadata, not source anchor
```

**Persist components, derive anchor on read** in `EventSales.Analytics.SourceFreshness` (reader module). Optional cached `source_freshness_anchor_at` column only if proven necessary for SQL; default **derive** to avoid drift.

Update invariants:

```text
monotonic per component: new >= old when both present
NULL + first write allowed
concurrent writers: single-row UPDATE ... WHERE event_id = $1 AND (component IS NULL OR component < $incoming)
  or Ash atomic action with conditional guards
```

PubSub: broadcast `:source_freshness_updated` after durable commit (notification only). Cache: optional mirror in Redis **after** Postgres write; never authoritative.

### All-events scope tension (explicit)

M1-07 anchor for a scope is **max** of latest applies (portfolio “when did we last touch source anywhere”). That can read NORMAL while one event has not received updates for 20 minutes.

**Plan requirement:**

- Event-scoped dashboards use **that event’s** projection row.
- All-events management view must not hide per-event STALE behind a global max without an explicit rule.

**ALL_EVENTS_FRESHNESS_POLICY — OWNER_DECISION_REQUIRED** (must be locked **before TIME-F** changes `AdminDashboard` all-events freshness behavior):

```text
Options (owners choose one; TIME-F must STOP rather than pick):
  (a) worst event classification across in-scope events with readiness
  (b) max anchor only (portfolio “last apply” — may hide per-event STALE)
  (c) combined signals (e.g. worst for STALE banner, max for telemetry)
```

TIME-D/E may implement per-event durable projection independently. TIME-G **certifies** the chosen rule; TIME-G must not be where the policy is first selected.

---

# 5. Freshness advancement paths

| Producer | Current behavior | Planned owner (TIME-E) |
| --- | --- | --- |
| Order webhook apply | `OrderProcessedNotifier` → `HotStateAggregator.apply_event` with `source_updated_at`; GenServer `latest_source_updated_at` map only | Post-commit: `SourceFreshness.advance_order/2` with `order.updated_at_source` for each affected `event_id` |
| Order reconciliation apply | Same via `notify_order_reconciled/4` | Post-commit `advance_order/2` on `order.updated_at_source`; sync component only when same flow completes with terminal catch-up evidence (below) |
| Refund upsert | `RefundUpserter.finalize_refund_mutation/2` → coverage invalidation only; **no** analytics notifier | New `RefundProcessedNotifier` (or extend Sales post-commit hook) calling `SourceFreshness.advance_refund/2` with `refund.source_created_at` mapped to event(s) via order items |
| Bounded catch-up terminal success | `HistoricalCatchupEvidence` terminal metadata + `source_observed_at` on successful bounded catch-up | Post-commit `SourceFreshness.advance_sync_source_observed/2` with terminal `HistoricalCatchupEvidence.source_observed_at` for the event scope — **never** from `SyncRun.date_to` or `sales_covered_through` |
| CSV import finalize | `finalize_csv_import_hot_state/4` — no `source_updated_at` on aggregate event | **OWNER_DECISION_REQUIRED:** exclude CSV from source anchor unless batch carries authoritative Woo modified time; default **exclude** from freshness anchor (read-model recompute only) until product says otherwise |
| Manual hot rebuild | `RebuildHotStateWorker` → `last_fresh_at = now` | Must **not** call freshness advance |
| Snapshot refresh | Updates `source_watermark_at` on currency rows | Does not replace projection; may optionally reconcile order component max as audit-only compare |

Refund path must run **after** refund transaction commits. Do not put Analytics SQL inside Sales transaction.

---

# 6. Pure time-rule boundary

Introduce **`EventSales.Analytics.TimeRules`** (name aligned with `MetricRules`):

```text
sale_effective_at(%Order{})
refund_effective_at(%Refund{})
business_date/2          → delegates Johannesburg to DateTime.shift_zone/2
today_bounds/2, yesterday_bounds/2
rolling_bounds/3         → 7d, 30d, arbitrary Duration
custom_bounds/4          → local start/end in timezone → UTC half-open
period_contains?/2
freshness_age_ms/2
freshness_classification/2
```

`MetricRules.business_date/2` eventually delegates Johannesburg path to `TimeRules` (TIME-B). Legacy `summarize/2` Today bucketing migrates to `sale_effective_at/1` in TIME-C or a dedicated compatibility slice.

No custom timezone engine. No hardcoded UTC+2.

---

# 7. Period aggregation / query boundary

Preserve **`EventSales.Analytics.Aggregators.EventAggregator`** as the financial aggregation authority (PRE-M5-METRICS). Extend with period-scoped entry point (name proposal):

```text
financial_summaries_for_event_period(event_id, period) :: {:ok, map()} | {:error, term()}
```

Where `period` is a struct from `TimeRules` carrying `start_utc`, `end_utc`, and metadata.

Query rules:

```text
Gross / recognised orders:  sale effective COALESCE(paid_at, completed_at) in [start, end)
Refunds:                    source_created_at in [start, end)
Independent placement (T24)
Currency partitions preserved
Net derived via MetricRules / FinancialPrimitives
UTC predicates only; no per-row TZ conversion
Distinct recognised order count preserved
No full history load into BEAM
```

Do not rewrite `FinancialPrimitives`. Do not make `MetricRules.summarize/2` the canonical period engine.

---

# 8. Index and performance plan

Current indexes (verified):

```text
sales_orders: completed_at_idx, updated_at_source_idx (no paid_at_idx)
sales_refunds: order_id_idx only (no source_created_at_idx)
```

**Query-plan-first certification (TIME-C)** before locking migrations:

1. Seed representative volume via existing fixture patterns (`test/support/analytics/event_aggregator_query_plan_fixture.ex`).
2. Run `EXPLAIN (FORMAT JSON)` for:
   - event-scoped period gross query (coalesce predicate)
   - event-scoped refund period query
   - all-events bounded window (if authorized)
3. Compare candidates:
   - expression index on `(COALESCE(paid_at, completed_at))`
   - plain `paid_at` + existing `completed_at`
   - composite with `event_id` via order_items join path
   - `refunds.source_created_at` with event join

No `enable_seqscan = off`.

Performance rule unchanged:

```text
dashboard request → aggregate / snapshot / hot read model → never peak-time unbounded fact scan
```

Index migrations live in **their own slice** when EXPLAIN proves need.

---

# 9. Daily snapshot boundary

**Decision: B — do not migrate Daily v1 to canonical effective-time in PRE-M5-TIME.**

Rationale:

- `DailySalesAggregateSnapshot` remains version 1, scalar metrics, `refresh_daily/3` buckets on `completed_at` (`snapshot_refresh.ex:68-84,455-467`).
- M5 owns canonical day/hour aggregates per M1-07 T30.
- PRE-M5-TIME must prevent silent promotion of Daily v1 to M5 period authority.

PRE-M5-TIME actions:

- Document Daily v1 as **legacy read model** in snapshot reader docs.
- New period reporting for M5 uses `EventAggregator` + `TimeRules` + future M5 tables, not Daily v1 refresh.

Optional TIME-G doc note in `snapshot_refresh.ex` moduledoc only (no behavior change required in TIME-A).

---

# 10. Hot-state / dashboard separation

Target contracts:

### `HotStateAggregator.status/0`

Return a map with **separate** keys (exact names finalized in TIME-F):

```text
read_model: %{
  lifecycle: :warming | :ready | :degraded,
  generated_at: DateTime.t() | nil,
  rebuild_in_flight?: boolean,
  last_rebuild_finished_at: DateTime.t() | nil
}
```

Remove use of read-model age for programme STALE. Deprecate overloading `state: :stale` as source stale; migrate consumers in TIME-F.

### `AdminDashboard.snapshot/1` / `EventScopedDashboard`

Attach `source_freshness` from `SourceFreshness` reader using the `{:ok, map()} | {:error, :missing_source_freshness_anchor}` contract (never `:anchor_missing` as classification). Keep `refreshed_at` / summary `updated_at` as read-model metadata.

### `StaleDataBanner`

M6 owns copy; TIME-F passes structured fields so banner can bind when `{:ok, %{classification: c}}` and `c in [:aging, :stale]` without reading `HotStateAggregator` lifecycle.

**Invariant:** manual rebuild from old Postgres → read-model `ready` while source classification remains `STALE`.

---

# 11. Owner decisions — unresolved values and deadlines

## 11.1 Custom-range maximum (`CUSTOM_RANGE_MAX`)

**OWNER_DECISION_REQUIRED** — no numeric cap in M1-07 or product decisions today.

**Gate (locked sequencing):**

```text
CUSTOM_RANGE_MAX owner decision:
  does NOT block TIME-B (pure bounds / classification kernel)
  MUST be resolved before TIME-C exposes custom-range financial querying
  until resolved, TIME-C may implement and test only locked presets:
    Today, Yesterday, rolling 7d, rolling 30d
  custom-range querying stays unavailable or returns {:error, :custom_range_max_undecided}
```

Do not authorize unlimited custom periods merely because start/end timestamps are finite.

Options for owners (do not implement until chosen):

| Option | Implication |
| --- | --- |
| Cap at 90 Johannesburg civil days | Matches common quarter-style reporting; bounded index range scans |
| Cap at 365 days | Year-style management reports; heavier worst-case queries |
| Cap at max(rolling presets) = 30 days until M5 | Smallest backend surface; may block some custom reports until owner extends cap |

May block PRE-M5-TIME **closeout** if backend API requires hard validation before M5.

## 11.2 All-events freshness policy

See §4 **ALL_EVENTS_FRESHNESS_POLICY** — must be locked before TIME-F integrates all-events `AdminDashboard` freshness. Does not block TIME-B/C/D/E per-event work.

---

# 12. Recommended implementation slices

Challenge to linear TIME-A..G: split **TIME-C** (SQL + EXPLAIN) from **TIME-C2** (migration) if plan proof requires schema change. Split **TIME-E** into order vs refund vs sync PRs if review size demands.

## PRE-M5-TIME-A — Current-repo reconciliation + this plan

```text
Outcome:   this document on main via reviewed PR
Files:     docs/development/pre-m5-time-foundation-implementation.plan.md
Tests:     none
STOP:      origin/main moves off 5746edb; any lib/ change
```

## PRE-M5-TIME-B — Pure time / effective / freshness rule kernel

```text
Outcome:   TimeRules module + tests; MetricRules Johannesburg delegates; no DB
Files:     lib/event_sales/analytics/time_rules.ex
           test/event_sales/analytics/time_rules_test.exs
           metric_rules.ex (delegation only)
Guards:    boundary tests at 5m, 10m, 10m+1ms; future anchor clamp
Side:      none durable
STOP:      invent custom range max; persist freshness classification
```

## PRE-M5-TIME-C — Bounded period financial aggregation

```text
Outcome:   EventAggregator.financial_summaries_for_event_period/2
Files:     event_aggregator.ex, tests, query plan fixture extensions
Predicates: COALESCE(paid_at, completed_at), refund source_created_at, [start,end)
Presets:   Today, Yesterday, rolling 7d, rolling 30d only until CUSTOM_RANGE_MAX is locked
STOP:      unbounded scans; peak-time LiveView queries; custom-range API without owner max
```

## PRE-M5-TIME-C-IDX — Index migration (conditional)

```text
Outcome:   migration only after EXPLAIN proof from TIME-C
Files:     priv/repo/migrations/*, order.ex / refund.ex custom_indexes
STOP:      index without EXPLAIN artifact checked into test/support or docs/evidence
```

## PRE-M5-TIME-D — Durable freshness projection + reader

```text
Outcome:   EventSourceFreshnessSnapshot resource, SourceFreshness reader
Files:     new resource, domain registration, reader module, read tests
Concurrency: monotonic update tests
PubSub:    notify only after commit
STOP:      Redis-only truth; EventAggregateSnapshot as sole owner; coverage bounds as sync freshness
```

## PRE-M5-TIME-E — Advancement paths

```text
Outcome:   post-commit order/refund/sync advances; idempotent replay tests
Files:     order_processed_notifier.ex (or sibling), new refund notifier, catch-up terminal hook
           source_freshness.ex (advance_order, advance_refund, advance_sync_source_observed)
STOP:      advance before commit; refund path missing; SyncRun.date_to or sales_covered_through as sync clock
Sub-PRs:   E1 orders, E2 refunds, E3 terminal catch-up source_observed_at
```

## PRE-M5-TIME-F — Hot-state / dashboard integration

```text
Outcome:   separated read_model vs source_freshness in status/snapshot APIs
Files:     hot_state_aggregator.ex, admin_dashboard.ex, event_scoped_dashboard.ex
           stale_data_banner.ex (assigns only; copy still M6)
Config:    remove programme stale binding to stale_after_ms for source (may retain for read-model degraded)
STOP:      manual rebuild clears source STALE; all-events policy undecided; fourth freshness enum
           TIME-F must not choose ALL_EVENTS_FRESHNESS_POLICY — owner decision required first
```

## PRE-M5-TIME-G — Certification + programme closeout

```text
Outcome:   GAP-PRE-M5-TIME CLOSED; handoff doc updates; evidence bundle
Tests:     integration tests crossing order+refund+sync freshness; period + classification
Docs:      current-state-and-path-handoff.md revision (v24+) when authorized
STOP:      M5 aggregate work; numeric custom max without owner sign-off; certifying undecided ALL_EVENTS_FRESHNESS_POLICY
```

---

# 13. Performance and scaling review (by slice)

| Slice | Layer | Postgres truth? | Dashboard hits raw facts? | Index | Bounded | Incremental | Redis value |
| --- | --- | --- | --- | --- | --- | --- | --- |
| B | cold (pure) | n/a | no | no | yes | n/a | no |
| C | cold SQL | yes | no (via aggregator) | proof-driven | yes | n/a | no |
| C-IDX | cold | yes | no | yes | yes | n/a | no |
| D | cold projection | yes | no | event_id unique | yes | yes | mirror optional |
| E | cold writes | yes | no | uses D row | yes | yes | no |
| F | hot/warm read | yes for source | no | n/a | yes | yes | existing warm summary only |
| G | cert | yes | no | verified | yes | yes | no |

Repo stack unchanged: Hot ETS, warm Redis optional, cold Postgres, PubSub notify only, no Cachex, no Redis lock.

---

# 14. Concurrency and invariants

| Scenario | Required behavior |
| --- | --- |
| Older `updated_at_source` after newer | Order upsert stale noop; freshness component must not regress |
| Duplicate order notification | Idempotent aggregate event; freshness advance `new >= old` |
| Refund replay | Same refund identity; watermark monotonic on `source_created_at` |
| Conflicting refund `source_created_at` | Source version / upsert rules; do not lower watermark without durable correction policy |
| Concurrent order + refund same event | Row-level atomic monotonic updates on separate columns |
| Concurrent catch-up terminal writes | Monotonic `sync_source_observed_at`; never from coverage certifier fields |
| Transaction rollback | No freshness advance |
| Process restart | Postgres projection survives; hot state restores read model only |
| Redis loss | Source freshness from Postgres |
| HotState restart | Does not reset source anchor |
| Manual refresh during source STALE | Read-model may become ready; classification unchanged |
| Clock skew / future anchor | age clamp 0 → NORMAL + telemetry |
| Event with no financial rows | Anchor missing → `{:error, :missing_source_freshness_anchor}` |
| Multi-currency event | One freshness row per event (currency-independent) |
| All-events with mixed ages | See §4 owner decision on worst vs max |

No global GenServer lock for freshness persistence.

---

# 15. What NOT to do

Do not reopen PRE-M5-METRICS, alter `FinancialPrimitives` formulas, persist Net/ATV, add Cachex, make Redis authoritative, use PubSub or rebuild time as source anchor, extend `EventAggregateSnapshot` as freshness owner, treat sync alone as anchor, invent custom-range numeric caps, invent fourth freshness state, or start M5 aggregates in this programme.

---

# 16. Global constraints

1. `GAP-PRE-M5-METRICS` stays **CLOSED**.
2. M1-07 T1–T31 stay **locked**; this plan supersedes M1-07 **repository** gap text only.
3. M5 stays **BLOCKED** until `GAP-PRE-M5-TIME` closes.
4. Each slice: focused tests → `mix quality.fast` at slice end → `mix quality.pr` before meaningful review.
5. STOP if `origin/main` ≠ `5746edb8a2c272b1e6c0ce16153f9063c8e78925` at slice start (re-verify; update plan baseline if a new certified merge replaces it).

---

# 17. Focused test map (implementation slices)

| Slice | Minimum tests |
| --- | --- |
| B | `time_rules_test.exs` — bounds, rolling, custom (without max), classification boundaries, future anchor |
| C | `event_aggregator_test.exs` — period gross/refund placement, missing effective withhold |
| C-IDX | EXPLAIN artifact + migration smoke |
| D | resource monotonic update, missing row create |
| E | notifier post-commit, replay idempotency, rollback does not advance |
| F | hot_state_aggregator_test, admin/event dashboard tests, rebuild does not clear STALE |
| G | cross-path integration + programme doc checkpoint |

Existing references: `historical_reporting_snapshots_test.exs`, `hot_state_aggregator_test.exs`, `event_scoped_dashboard_test.exs`.

---

# 18. Programme sequence

```text
PRE-M5-TIME-A   docs-only plan (this document)
      ↓
PRE-M5-TIME-B   TimeRules kernel
      ↓
PRE-M5-TIME-C   period EventAggregator (+ EXPLAIN proof)
      ↓
PRE-M5-TIME-C-IDX (conditional index migration)
      ↓
PRE-M5-TIME-D   EventSourceFreshnessSnapshot + reader
      ↓
PRE-M5-TIME-E   order / refund / sync advancement
      ↓
PRE-M5-TIME-F   hot-state vs source separation
      ↓
PRE-M5-TIME-G   certification → GAP-PRE-M5-TIME CLOSED
      ↓
M5 authorized (time semantics frozen)
```

Do not combine D + E + F into one PR.

---

# 19. Success criteria (programme closeout)

```text
TimeRules is the sole effective-time and period-bound authority
EventSourceFreshnessSnapshot holds durable monotonic components (including sync_source_observed_at from terminal catch-up evidence)
Source NORMAL/AGING/STALE derived from anchor; missing anchor returns :missing_source_freshness_anchor error, not a fourth enum
EventAggregator period queries use sale/refund effective clocks with [start,end)
Index strategy backed by EXPLAIN evidence
Daily v1 explicitly non-canonical for M5 periods
HotState status exposes read_model vs source_freshness separately
CUSTOM_RANGE_MAX locked before custom-range TIME-C API; ALL_EVENTS_FRESHNESS_POLICY locked before TIME-F
M1-07 T1–T31 unchanged; physical gaps closed
```

---

# 20. Risks and edge cases

- **Portfolio max vs per-event STALE** can mislead all-events operators unless worst-event rule is chosen (§4).
- **CSV imports** may leave freshness anchor stale if excluded; operators rely on webhooks/recon.
- **Coalesce index** vs separate `paid_at` index: wrong choice hurts M5 period queries at scale.
- **Refund notifier absence today** is the highest regression risk for anchor completeness.
- **MetricRules Today** on hot summaries may disagree with period API until TIME-F unifies legacy scalar fields.

---

# 21. STOP findings (TIME-A audit)

None. Baseline SHA matches; no M1-07 semantic conflict with product decisions; `paid_at` and refund `source_created_at` verified present; plan rejects GenServer/Redis-only freshness and EventAggregateSnapshot ownership.

---

# 22. Linear

Linear update unavailable — no writable PRE-M5 tracking target (legacy EventSales issues archived).
