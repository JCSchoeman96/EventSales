---
Plan ID: m5-05-deterministic-sales-velocity
Plan version: v2
Status: M5-05A complete; v2 owner authority locked (awaiting PR merge)
Scope: Deterministic sales velocity semantics, bounded read architecture, and M5-05 sub-phase map (no implementation until v2 merges)
Authority base SHA: 7d81d317886c38327a3a4fdb42c72f4ab8d688cb
Authority base tree: c5a001290977c553a8763c174c110c2862047dac
Programme: M5-01..M5-04 COMPLETE (PASS); M5-05 NEXT
Last updated: 2026-10-08
Change summary (v2): Owner semantic decisions locked; gross-ticket primary sales velocity; 15/30/60-minute windows; per-hour normalization; continuous + exact-sign trend; currency-scoped MVP; quantity visible under revenue redaction; performance gate before reader; 60-minute geometry correction.
---

### Revision log

- `v1` — M5-05A planning and conformance audit on `7d81d317` / tree `c5a00129`.
- `v2` — Owner semantic decisions locked; gross-ticket sales velocity primary; 15/30/60-minute windows; per-hour normalization; continuous + exact-sign trend; currency-scoped MVP; quantity visibility under revenue redaction; risk-first M5-05C performance gate before reader; 60-minute read-plan geometry correction.

# M5-05 — Deterministic sales velocity

> Planning artifact only. M5-05A produced v1; v2 records locked owner product semantics. No production code, migrations, tests, or dependency changes in this PR amendment.

**Active contract:** This file is the canonical M5-05 plan. `docs/development/m5-04-period-comparisons.plan.md` remains authority for period comparisons only. `docs/path-1/path-1-phase-breakdown.md` M5-05 row still says "Hot summaries"; that row is stale relative to this audit and must not override the architecture below.

**Implementation gate:** M5-05B and later code slices stay **not authorized** until this plan is **v2 or later** and **PR #304 v2 is merged** to `main`. Section 6 (velocity semantic matrix) and Section 17 (owner decision summary) contain the locked M5-05 product semantics. No unresolved `OWNER_DECISION` rows remain after v2.

```text
OWNER_DECISION_REQUIRED = NO
M5_05B_SEMANTIC_GATE = OPEN_AFTER_V2_MERGE
M5_05B_AUTHORIZED = PENDING_V2_MERGE
```

---

## 1. Ultimate outcome and backward plan

### 1.1 Operator outcome

Management needs a decision metric that answers, per event and currency:

```text
How quickly is this event selling right now (new ticket pace)?
How do refund-adjusted and net ticket movement compare?
Is recent gross-ticket pace faster, slower, or flat versus the immediately prior equal interval?
```

The answer must be computable from certified analytics projections without scanning raw `Order`, `OrderItem`, `Refund`, or `RefundLine` tables from dashboard reads.

### 1.2 Backward chain (outcome first)

```text
Operator presentation (M6 / VS-27B.3 UI — out of M5-05 scope)
  ← deterministic velocity read result (rates, deltas, direction, readiness)
  ← comparison / trend semantics (v2 locked)
  ← current and previous half-open UTC windows of equal duration
  ← additive primitives (gross/refund/net ticket qty and gross/refund/net ticket value)
  ← coverage and ANALYTICS_READY proof
  ← M5-04 durable EventPeriodAggregateSnapshot + AnalyticsContributionFact edges
  ← M5-01..M5-03 lifetime and dimensional aggregates (not primary for sub-hour windows)
  ← M4 reconciled sale/refund truth
```

M5-05 does not implement UI, targets, pacing alerts, or freshness banners (M5-06..M5-08, M6).

---

## 2. Authority hierarchy

| Priority | Source | Role for M5-05 |
| --- | --- | --- |
| 1 | `AGENTS.md` | Mandatory local-first slice rules; Postgres durable truth; no raw REST from LiveView |
| 2 | `docs/agent/01_PROJECT_WIDE_RULES.md` | Mandatory architecture and safety boundaries |
| 3 | Locked M1/M4/M5 contracts and certified M5-04 behaviour | Identity, recognition, financial primitives, timestamps, coverage, readiness, security |
| 4 | Explicit owner decisions in **this plan v2** | Win **only** for M5-05 product semantics that were unresolved in v1 (Section 6 / §17) |
| 5 | `docs/path-1/path-1-phase-breakdown.md` | Programme order; M5-05 is NEXT |
| 6 | `docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md` | "Recent velocity and comparisons"; bounded filters |
| 7 | `docs/roadmap/EVENTSALES_LIVE_SALES_PROGRAMME.md` | VS-27B.1 window list including 15/30/60 minutes; velocity and trend in dashboard |
| 8 | M5-01..M5-04 plans and certification evidence | Period buckets, contribution edges, `PeriodComparisonReader` pattern |
| 9 | Path-1 M5-05 roadmap row ("Hot summaries") | **Superseded** by this plan for velocity truth source |

Conflict rules:

```text
AGENTS.md and project-wide governance remain mandatory; owner decisions cannot override them.

Locked M1/M4/M5 contracts remain authoritative for already-decided semantics.
An owner decision in v2 cannot silently revise a locked M1 recognition, refund, or financial contract.

Locked M1 and certified M5-04 behaviour win over the Path-1 M5-05 table hint that velocity comes from hot summaries.

Owner decisions in v2 apply only to previously unsettled M5-05 velocity product semantics.
```

---

## 3. Repository conformance findings

### 3.1 Preflight (M5-05A)

```text
origin/main     = 7d81d317886c38327a3a4fdb42c72f4ab8d688cb
origin/main^{tree} = c5a001290977c553a8763c174c110c2862047dac
worktree        = clean at branch creation
PR_303          = merged (authority base matches)
```

### 3.2 Sales velocity implementation

```text
M5_05_EXISTING_IMPLEMENTATION = NONE under lib/event_sales/analytics for velocity/trend/pacing
```

Repository search hits for `velocity` in `lib/` are ingestion rate limiting (`RedisRateLimiter`, webhook intake), not sales metrics.

### 3.3 Certified foundations M5-05 can reuse

| Area | Module / resource | Conformance note |
| --- | --- | --- |
| Fixed buckets | `EventPeriodAggregateSnapshot`, `EventDimensionPeriodAggregateSnapshot` | `:utc_hour` and `:johannesburg_day`; zero current row is valid zero with coverage; missing row is not zero |
| Exact edges | `AnalyticsContributionFact` | Sale/refund effective_at; index `(event_id, currency, effective_at)` |
| Read plan | `PeriodReadPlan` | UTC-hour interior + up to 2 edge fragments per operand; max 4 edges per comparison read |
| Reader pattern | `PeriodComparisonReader` | Auth first, one `now`, `ANALYTICS_READY`, coherent transaction; monetary redaction only (quantities remain) |
| Time kernels | `TimeRules`, `TimeRules.ComparisonWindows` | Preset periods only today; minute windows added in M5-05B |
| Metric kernels | `MetricRules` | Primitives and comparison delta/state helpers |
| Legacy hot path | `EventAggregator.summary_for_event/2`, `HotStateAggregator` | Documented legacy; uses completed-only ex-tax scalars |

### 3.4 Legacy hot summary audit

```text
LEGACY_HOT_SUMMARY_CANONICAL_FOR_VELOCITY = NO
```

`EventAggregator.summary_for_event/2` moduledoc states legacy compatibility. It aggregates `status == completed` ticket lines and ex-tax `line_total` for revenue. Canonical financial and period semantics use `MetricRules.financial_summary/3`, sale-effective and refund-effective placement, and M5-04 projections. M5-05 must not derive velocity from hot ETS summaries or `summary_for_event/2` totals.

`HotStateAggregator` rebuilds from `EventAggregator` for dashboard snapshots. That path is acceleration only, not velocity truth.

### 3.5 M5-05 supplemental recent-duration contract (v2)

`EVENTSALES_LIVE_SALES_PROGRAMME.md` (VS-27B.1) lists **Last 15/30/60 minutes** alongside today, yesterday, and rolling days.

`m1-07-timestamp-johannesburg-period-and-freshness-contract.md` §14 locks Today, Yesterday, Last 7 Days, Last 30 Days, and Custom (T20–T23). It does **not** prohibit a later, explicitly authorized sub-hour velocity contract for a distinct use case.

M5-04 implements the M1-07 locked presets only. **M5-05 v2 adds a supplemental recent-duration contract** for velocity reads:

```text
{:rolling_minutes, 15}
{:rolling_minutes, 30}
{:rolling_minutes, 60}
```

This supplements M1-07 for M5-05 velocity only; it does not alter T20–T23 period definitions used by M5-04 comparison presets.

---

## 4. Domain and resource map

Domain: `EventSales.Analytics`

| Concept | Disposition | Notes |
| --- | --- | --- |
| `EventAggregateSnapshot` | REUSE | Not primary for sub-hour velocity |
| `EventDimensionAggregateSnapshot` | DEFER | Dimensional velocity deferred |
| `EventPeriodAggregateSnapshot` | REUSE | UTC-hour bucket for 60m operand when UTC-hour aligned; envelope for edges |
| `EventDimensionPeriodAggregateSnapshot` | DEFER | Dimensional velocity |
| `AnalyticsContributionFact` | REUSE | Partial window edges; flash-sale bound is per touched UTC hour |
| `MetricRules` | EXTEND | Velocity rate/delta/direction helpers; do not change primitive definitions |
| `TimeRules` | EXTEND | `velocity_windows/3` for locked minute set; one captured `now` |
| `PeriodReadPlan` | REUSE / EXTEND | Same decomposition strategy; 60m aligned case uses full hour bucket |
| `PeriodComparisonReader` | REUSE (pattern) | Template for auth, readiness, SQL shape; `(event_id, currency)` scope |
| `SnapshotReader` / dimension readers | NOT REQUIRED | Lifetime reads irrelevant for 15–60m |
| `VelocityWindow` (candidate) | NEW | Pure struct: duration, current/previous `Period.t()` |
| `VelocityOperand` (candidate) | NEW | Reuse `:current` / `:previous` from comparison |
| `VelocityMeasure` (candidate) | NEW | Locked measure set in Section 6 |
| `VelocityReadiness` (candidate) | NEW | Read-result envelope, not a durable resource |
| `SalesVelocityReader` (candidate) | NEW | M5-05D; projection-only after M5-05C pass |
| `VelocityRules` (candidate) | NEW | Pure rate, delta, direction math (M5-05B) |
| `HotStateAggregator` | NOT REQUIRED for truth | Optional mirror later |
| `DashboardCache` / Redis snapshot | DEFER to M5-08 | Optional warm cache of canonical read |
| `DashboardPubSub` | REUSE later | Same event topic; no new topic in M5-05 |

```text
NEW_DURABLE_RESOURCE_REQUIRED = NO (Option A hypothesis pending M5-05C)
NEW_BUCKET_KIND_REQUIRED = NO (defer until post–M5-05C NO_GO only)
NEW_INDEX_REQUIRED = NO_PENDING_EVIDENCE
```

---

## 5. Relationships and ownership

```text
M4 sale/refund writes
  → contribution facts and period bucket materializers (M5-04D/E/G)
  → period snapshots and coverage envelopes
  → M5-05C proves intended SQL geometry (before reader)
  → M5-05D SalesVelocityReader reads snapshots + bounded contribution aggregates
  → optional hot/warm mirror (M5-08)
  → PubSub notifies UI to re-fetch (existing DashboardPubSub)
```

Oban refresh and coverage maintenance remain owned by M5-04 workers. M5-05 does not add materializers unless M5-05C returns NO_GO and a reviewed corrective plan authorizes finer buckets or proven index change.

Velocity has no write path of its own. It does not enqueue separate durable rows for "velocity state."

---

## 6. Velocity semantic matrix

| Question | Authority status | M5-05 v2 resolution |
| --- | --- | --- |
| What is velocity measuring? | Programme + v2 owner lock | **LOCKED** — parallel quantity and monetary rates; **primary sales-velocity KPI = gross ticket quantity rate** (selling pace). Refund and net rates are separate signals. |
| Ticket primitives | M1-06 | **LOCKED** — gross, refund, net ticket quantity per window; definitions inherited from `MetricRules` / M5-04 |
| Monetary velocity | v2 owner lock | **LOCKED** — gross, refund, net ticket-value rates; currency-scoped; Decimal arithmetic |
| Window set | v2 supplemental contract | **LOCKED** — `15m`, `30m`, `60m` as `{:rolling_minutes, 15 \| 30 \| 60}` |
| Window geometry | M5-04 comparison pattern | **LOCKED** — UTC absolute duration; current `[now − w, now)`; previous `[now − 2w, now − w)`; half-open; one captured `now` |
| Rate normalization | v2 owner lock | **LOCKED** — quantities → **tickets per hour**; money → **currency units per hour**; also expose raw window quantity/value and `window_duration_seconds`. Factors: 15m ×4, 30m ×2, 60m ×1 |
| Comparison | Programme + M5-04 | **LOCKED** — equal immediately preceding window |
| Trend output | v2 owner lock | **LOCKED** — per measure: `current_rate`, `previous_rate`, `absolute_delta`, `percentage_delta`, `direction` (`:faster` / `:flat` / `:slower` from sign of delta; no tolerance band) |
| Trend thresholds | v2 owner lock | **LOCKED** — `TREND_THRESHOLD = NONE` |
| Average ticket value | v2 owner lock | **EXCLUDED** — not a velocity rate; no `average_ticket_value_per_hour` |
| Zero activity | M5-04 | **LOCKED** — valid zero only when operand coverage is ready and primitives sum to zero |
| Missing coverage | M5-04 | **LOCKED** — fail closed; `MISSING_COVERAGE_IS_ZERO = NO`; direction nil when not ready |
| Refund placement | M1-07 T24 | **LOCKED** — refund effective time |
| Sale placement | M1-04 / M1-07 | **LOCKED** — sale-effective `COALESCE(paid_at, completed_at)` |
| `now` | M5-04 reader | **LOCKED** — capture once per request |
| Cross-currency ticket quantity | v2 owner lock | **LOCKED** — `CROSS_CURRENCY_AGGREGATION = NO`; reader `(event_id, currency)` scoped like M5-04 |
| Revenue velocity | M1-06 | **LOCKED** — always per `currency`; never collapse currencies |
| Dimensions | v2 owner lock | **LOCKED** — event-level only for M5-05 v1 |
| All-event velocity | Product programme | **DEFER** — separate management aggregation contract |
| Authorization | `PeriodComparisonReader` | **LOCKED** — `Policies.can_access_event_dashboard?/2` before work |
| Monetary redaction | M5-04 pattern + v2 lock | **LOCKED** — `TICKET_VELOCITY_VISIBLE_WHEN_REVENUE_REDACTED = YES`; all monetary rates/deltas/directions redacted when revenue hidden |
| ANALYTICS_READY | M1-08 | **LOCKED** — required; fail closed; no partial ticket-only exception |
| PII | Programme | **LOCKED** — none |

Rationale for gross primary KPI:

```text
Gross ticket quantity measures actual new-ticket selling pace.
Refund rate is a separate contemporaneous adjustment signal.
Net rate describes net ticket movement and may legitimately become negative
(for example a refund spike without matching gross sales in the same window).
```

```text
OWNER_DECISION_REQUIRED = NO
```

---

## 7. State and readiness model

```text
VELOCITY_HAS_DURABLE_LIFECYCLE = NO
```

Velocity is derived per read. Lifecycle authority stays on period snapshots (`:current`, `:stale`, `:refresh_pending`, `:rebuilding`, `:unavailable`) and ANALYTICS_READY.

### 7.1 Read-result readiness (not a state machine resource)

| State | Meaning | Guard |
| --- | --- | --- |
| `:forbidden` | Actor lacks event dashboard access | Before projection |
| `:analytics_not_ready` | `AnalyticsReadinessResolver` false | No velocity claims |
| `:operand_not_ready` | Missing or non-current coverage for current or previous window | Per-operand; map to `MetricRules` not-ready comparison semantics; `direction = nil` |
| `:ready_zero` | Coverage ready; primitives zero both sides | Valid zero velocity; direction `:flat` when rates defined |
| `:ready_non_zero` | Coverage ready; at least one non-zero primitive | Rate and delta defined |
| `:revenue_redacted` | Monetary fields stripped | Quantities and quantity rates/deltas/direction remain visible |

`:faster`, `:flat`, and `:slower` are **derived classifications** from numeric delta sign, not durable lifecycle states.

### 7.2 Underlying bucket transitions (reference only)

Owned by M5-04 materializers. Velocity reader must treat non-`:current` projection states as not ready for that bucket identity, consistent with `PeriodComparisonReader`.

---

## 8. Permissions and policy

Reuse `PeriodComparisonReader` ordering:

1. Cast and validate `event_id`, `currency`, window request (`{:rolling_minutes, 15 | 30 | 60}`).
2. `authorize(actor, event_id)` via `can_access_event_dashboard?/2`.
3. `AnalyticsReadinessResolver.resolve/1` — fail closed when not ready.
4. Capture `now` once; build windows.
5. Apply `can_view_revenue?/2` to all monetary fields (values, rates, deltas, percentage deltas, direction on money). Quantity velocity remains visible when revenue is redacted.

No cross-event reads. No PII. Revenue never mixed across currencies. Ticket quantities are not summed across currencies in M5-05 v1.

---

## 9. Time and window contract

M5-05A/v2 does **not** implement `TimeRules` changes. Proposed API for M5-05B:

```elixir
@spec velocity_windows(DateTime.t(), {:rolling_minutes, 15 | 30 | 60}) ::
        {:ok, ComparisonWindows.t()} | {:error, :unsupported_velocity_window}
```

Rules:

```text
VELOCITY_WINDOW_CLOCK = UTC_ABSOLUTE_DURATION
capture now once per read (pass via opts like PeriodComparisonReader)
windows are UTC absolute half-open [start, end)
current  = [now - w, now)
previous = [now - 2w, now - w)
w ∈ {15, 30, 60} minutes only
no DateTime.utc_now/0 inside decomposition or SQL assembly after capture
no Johannesburg civil-day arithmetic inside pure minute windows
sale and refund effective timestamps unchanged from M1-07 / M5-04
```

### 9.1 Read-plan geometry (15m, 30m, 60m)

**15m and 30m operands:**

```text
0 complete UTC-hour interiors
1 edge fragment normally
2 edge fragments when the window crosses a UTC hour boundary
```

**60m operand:**

```text
if window is exactly UTC-hour aligned (duration 3600s, start at UTC hour boundary):
  1 complete :utc_hour bucket
  0 edge fragments

otherwise:
  0 complete-hour interiors
  up to 2 edge fragments (leading + trailing partial hours)
```

**Full current + previous comparison (worst case, unaligned 60m):**

```text
MAX_EDGE_FRAGMENTS = 4 (two operands × up to 2 edges each)
MAX_DISTINCT_UTC_HOUR_ENVELOPES = 3 (not four wall-clock hours)
ALIGNED_60M_USES_FULL_BUCKET = YES
```

Extend `PeriodReadPlan.build/1` or add `VelocityReadPlan.build/1` for minute `ComparisonWindows`. M5-05B must prove fragment count stays ≤ 4 or return `:too_many_edge_fragments`. M5-05B acceptance tests must cover both UTC-hour-aligned and unaligned 60-minute anchors.

---

## 10. Architecture options

### Option A — M5-04 UTC-hour buckets + contribution edges (preferred hypothesis; pending M5-05C)

Use `EventPeriodAggregateSnapshot` for UTC-hour-aligned 60m operands and `AnalyticsContributionFact` for partial edges.

Advantages: no new durable resource; certified zero/missing semantics; same reader transaction pattern as M5-04F; existing `(event_id, currency, effective_at)` index.

Risks: flash-sale hour may contain many contribution rows in edge SQL; 15m/30m and unaligned 60m reads are edge-heavy; must certify latency at **concurrency 1, 20, and 50**.

### Option B — Finer durable buckets (e.g. five-minute)

Evaluate only if M5-05C returns `OPTION_A = NO_GO`.

Costs: write amplification, coverage cardinality, materializer complexity, backfill, storage, invalidation coupling.

Never add five-minute buckets because a probe is scheduled; only after failed performance gate and reviewed corrective plan.

### Option C — ETS/Redis/GenServer counters as canonical velocity

Reject as durable truth. Hot/warm may cache **already computed** canonical velocity snapshots later (M5-08).

---

## 11. Recommended architecture

```text
RECOMMENDED_ARCHITECTURE = OPTION_A_PENDING_M5_05C_PERFORMANCE_GATE
  POSTGRES_M5_04_PROJECTIONS + bounded AnalyticsContributionFact edge aggregates
  pure VelocityRules kernel (M5-05B)
  M5-05C performance gate on intended SQL shape before reader integration
  projection-only SalesVelocityReader (M5-05D) only after C pass
  optional hot/warm mirror deferred to M5-08
```

Do not add minute or five-minute bucket **resources** in M5-05B or before M5-05C evidence.

---

## 12. Query and data-source matrix

| Operand window | Fixed buckets | Edge contributions | Notes |
| --- | --- | --- | --- |
| 15m | 0 interiors | 1–2 edges | Edge-only |
| 30m | 0 interiors | 1–2 edges | Edge-only |
| 60m aligned | 1 `:utc_hour` bucket | 0 edges | Full bucket read |
| 60m unaligned | 0 interiors | up to 2 edges | Partial hours only |

Query count target per `compare_velocity` read (`event_id`, `currency`):

```text
1 coherent transaction
1 readiness resolve (per M5-04 pattern)
envelope / bucket reads: O(operands × touched hours) small constant (≤ 3 distinct hour envelopes worst case)
bounded edge aggregate queries (reuse M5-04F batching pattern)
0 raw order/refund scans
```

```text
RAW_ORDER_SCAN = NO
RAW_REFUND_SCAN = NO
QUERY_BOUND = constant small integer queries per read; edge row count scales with sales/refunds in touched UTC hour envelope(s), not event lifetime
```

Index: `analytics_contribution_facts_event_currency_effective_at_idx` serves `event_id = ? AND currency = ? AND effective_at >= ? AND effective_at < ?`. No new index unless M5-05C EXPLAIN proves a different required shape.

Proposed reader entry point (M5-05D):

```text
compare_event(event_id, currency, {:rolling_minutes, w}, opts)
```

---

## 13. Performance and scaling review

| Question | Answer |
| --- | --- |
| Hot/warm/cold ownership | **Cold** = Postgres snapshots + facts; **warm** = Redis snapshot TTL 1h (existing); **hot** = ETS via `DashboardCache` (existing). Canonical velocity = cold composition. |
| Max rows read | Edge: contributions in hour envelope(s); buckets: ≤ few envelope rows per hour touched |
| Grows with event lifetime? | No for a single read |
| Grows with total orders? | No except sales density in current UTC hour(s) |
| Grows with refunds? | Same hour window |
| Grows with currencies? | One currency per read in M5-05 v1 |
| Flash sale safe? | **RISK** — edge scan scales with hour throughput; M5-05C mandatory |
| Postgres query count | Bounded small constant |
| Full-hour buckets replace edges? | Yes for UTC-hour-aligned 60m operand only |
| Finer buckets reduce bound? | Evidence-driven only after NO_GO |
| SQL aggregation vs BEAM | Prefer SQL `SUM` like `PeriodComparisonReader` edge query |

Targets (design; certified only after M5-05C/E):

```text
NORMAL_P99_TARGET_MS = 100 at concurrency 50 for representative normal density
PERFORMANCE_CONCURRENCY_COHORTS = 1, 20, 50
flash-sale p99 reported separately (may exceed normal target; drives NO_GO decision)
50 concurrent dashboard viewers = programme VS-27B.3 (must test concurrency 50, not 20 alone)
architecture must not require raw-history scans
100K_CONCURRENT_USERS_CERTIFIED = NO
```

```text
FLASH_SALE_RISK = MEDIUM until M5-05C load and EXPLAIN evidence
PERFORMANCE_PROBE_REQUIRED = YES (M5-05C mandatory before M5-05D)
M5_05C_IS_PRE_READER_PERFORMANCE_GATE = YES
```

M5-04 certification reference: rolling 7 p99 90ms at concurrency 20; rolling 30 p99 292ms. Concurrency 20 may be retained for comparability with M5-04 evidence but **does not** satisfy the programme 50-viewer gate alone.

M5-05C must not use `SET enable_seqscan=off`.

---

## 14. Cache / Redis / PubSub boundary

```text
CANONICAL_VELOCITY_SOURCE = POSTGRES_M5_04_PROJECTIONS (+ contribution edges)
HOT_CACHE_ROLE = OPTIONAL_DERIVED_ACCELERATION (M5-08)
WARM_REDIS_ROLE = OPTIONAL_DERIVED_SNAPSHOT (M5-08)
REDIS_STRUCTURE = REUSE_EXISTING_SNAPSHOT_MODEL_OR_DEFER
REDIS_TTL = default 1 hour (existing snapshot_ttl_ms) if mirrored later
INVALIDATION_TRIGGER = same as hot rebuild on aggregate events (OrderProcessedNotifier path); no new global flush
PUBSUB_TRIGGER = REUSE DashboardPubSub event topic; velocity UI refetch on {:hot_state_updated, ...} or dedicated payload later in M6
CACHE_STAMPEDE_PROTECTION = defer to M5-08; reader must remain safe without cache
NEW_REDIS_STRUCTURE = NO
NEW_CACHE_LAYER = NO
```

M5-05 does not own general hot/warm/cold architecture (M5-08).

---

## 15. Concurrency, failure, and security risks

| Risk | Mitigation |
| --- | --- |
| Missing coverage → zero | Fail closed; readiness states |
| Stale/rebuilding bucket | Treat operand as not ready |
| Generation mismatch | Reuse M5-04 semantic_version / coverage_identity checks where applicable |
| Late correction | Contribution facts and bucket refresh eventually consistent; coherent read transaction |
| Duplicate source delivery | Idempotent facts; no double-count in aggregates |
| Boundary sale/refund | Half-open `[start, end)` membership tests |
| Refund-only window | Net qty/value may be negative; gross still measures pace separately |
| Both windows zero | Direction `:flat` when ready |
| High sales in one hour | M5-05C load test + EXPLAIN |
| `now` on UTC hour boundary | M5-05B tests for aligned 60m bucket path |
| Unauthorized actor | `:forbidden` |
| Revenue-redacted actor | Strip money; quantities remain |
| Pool stampede | Single coherent read; no per-row LiveView queries |
| Cross-currency revenue or qty collapse | Forbidden in M5-05 v1 |

---

## 16. Gap ledger

| ID | Gap | Slice |
| --- | --- | --- |
| G1 | No `TimeRules.velocity_windows` / `VelocityRules` / read-plan extension | M5-05B |
| G2 | Option A SQL performance unproven at 1/20/50 concurrency | M5-05C |
| G3 | No `SalesVelocityReader` | M5-05D (after C pass) |
| G4 | Final reconciliation and certification doc | M5-05E |
| G5 | Path-1 M5-05 row says hot summaries | Optional docs hygiene later |
| G6 | Dimensional velocity | DEFER |
| G7 | All-event / cross-currency ticket velocity | DEFER |

---

## 17. Owner decisions (v2 locked summary)

All M5-05 product semantics previously open in v1 are locked in Section 6. Implementation code slices remain blocked until **this v2 plan merges** to `main`.

Locked summary:

```text
VELOCITY_WINDOWS = 15m, 30m, 60m
PRIMARY_SALES_VELOCITY_MEASURE = gross_ticket_quantity
QUANTITY_VELOCITY_MEASURES = gross_ticket_quantity, refund_ticket_quantity, net_ticket_quantity
MONETARY_VELOCITY_MEASURES = gross_ticket_value, refund_ticket_value, net_ticket_value
VELOCITY_RATE_UNIT_QUANTITY = tickets_per_hour
VELOCITY_RATE_UNIT_MONEY = currency_units_per_hour
RAW_WINDOW_VALUES_INCLUDED = YES
VELOCITY_TREND = absolute_delta, percentage_delta, exact_sign_direction
TREND_THRESHOLD = NONE
VELOCITY_SCOPE = event_and_currency
TICKET_VELOCITY_VISIBLE_WHEN_REVENUE_REDACTED = YES
MONETARY_VELOCITY_REDACTED_WITH_REVENUE = YES
```

---

## 18. M5-05 sub-phase map

```text
M5_05_SEQUENCE = A, B, C_PERFORMANCE, D_READER, E_CERTIFICATION
```

| Sub-phase | Responsibility | Implementation authorized after |
| --- | --- | --- |
| **M5-05A** | Plan / conformance authority (v1 audit + v2 owner lock) | v2 PR merged for semantic gate |
| **M5-05B** | Pure velocity/time/read-plan kernel; rate/delta/direction arithmetic; focused tests | **v2 merged to main** |
| **M5-05C** | **Option A performance gate** — EXPLAIN JSON, aggregate SQL, normal + flash-sale fixtures, 15/30/60m aligned/unaligned 60m, concurrency 1/20/50 | M5-05B merged |
| **M5-05D** | `SalesVelocityReader`; auth, readiness, redaction, coherent transaction; query shape accepted by C | M5-05C PASS |
| **M5-05E** | Oracle reconciliation, certification markdown, M5-05 programme closeout | M5-05D pass |

If M5-05C returns `OPTION_A = NO_GO`, **STOP before M5-05D**. Produce a separate reviewed corrective architecture plan (proven index/query correction first; finer buckets only if insufficient). Optional **M5-05F** schema/materialization slice if finer buckets are authorized.

### M5-05B scope

```text
velocity window geometry
rate arithmetic (per-hour + raw window values)
delta/direction arithmetic (reuse M5-04 zero-safe percentage semantics)
read-plan decomposition and fragment bounds
pure focused tests (including aligned/unaligned 60m)
no reader, Redis, migrations, or Ash resources
```

### M5-05C scope (mandatory before reader)

```text
prove intended M5-04 contribution-edge SQL shape is safe enough
EXPLAIN (FORMAT JSON) without enable_seqscan=off
actual aggregate query execution
normal and high-density flash-sale fixtures with sales and refunds
15m / 30m / 60m; aligned and unaligned 60m
concurrency cohorts 1, 20, 50 — p50/p95/p99, query count, rows scanned
normal representative reads: p99 <= 100ms at concurrency 50
if unacceptable: OPTION_A = NO_GO, STOP before M5-05D
```

### M5-05D scope

```text
SalesVelocityReader only after M5-05C pass
uses query shape accepted by M5-05C; material change repeats relevant performance evidence
authorization before projection; ANALYTICS_READY fail closed
(event_id, currency) scope; coverage semantics; revenue redaction
no raw Order/Refund reads
```

### M5-05E scope

```text
oracle reconciliation and boundary cases
correction/refund reconciliation
carry forward performance evidence
docs/evidence/m5-05-deterministic-sales-velocity-certification.md
M5-05 durable closeout; do not advance M5-06 before E merges
```

---

## 19. Acceptance gates

### M5-05A + v2 authority amendment

- [x] Plan file with sections 1–20
- [x] v2 owner semantics locked; no stale `OWNER_DECISION` labels
- [x] No `lib/`, `test/`, `priv/` changes in this PR
- [ ] PR CI green after v2 commit
- [ ] v2 merged (required before M5-05B code)

### M5-05B

- [ ] Plan v2 merged on main
- [ ] Pure modules only; no Ash resources
- [ ] Window math tests including UTC boundaries and aligned/unaligned 60m anchors
- [ ] Read-plan fragment count ≤ 4; distinct hour envelopes ≤ 3 for full compare

### M5-05C

- [ ] EXPLAIN (FORMAT JSON); no `enable_seqscan=off`
- [ ] Load harness concurrency **1, 20, and 50**; document p50/p95/p99
- [ ] Normal and flash-sale contribution density scenarios
- [ ] Explicit GO/NO-GO on Option A; STOP before D on NO_GO

### M5-05D

- [ ] No raw order/refund queries
- [ ] Auth before work; ANALYTICS_READY gate
- [ ] Missing coverage never returns zero velocity
- [ ] Revenue redaction: quantities visible; money stripped

### M5-05E

- [ ] Oracle reconciliation for locked windows and measures
- [ ] `docs/evidence/m5-05-deterministic-sales-velocity-certification.md`
- [ ] Path-1 M5-05 marked COMPLETE only after E pass

---

## 20. TOON micro-prompts (next authorized slices)

### M5-05B — Velocity kernel and time windows

```text
Task: Implement pure TimeRules.velocity_windows/3 and VelocityRules rate/delta/direction helpers for locked {:rolling_minutes, 15|30|60}.
Objective: Deterministic half-open windows, per-hour rates, raw window values, exact-sign direction; no I/O.
Forbidden: Ash resources, readers, Redis, migrations, revising locked M1 primitives.
Preflight: Plan v2 merged on main; M5_05B_AUTHORIZED = YES.
Tests: boundary instants, equal previous window, aligned/unaligned 60m read-plan, fragment/envelope bounds.
Done: mix quality.fast.
```

### M5-05C — Option A performance gate (before reader)

```text
Task: Certification harness and EXPLAIN suite for velocity edge/bucket SQL shape from M5-05B read plan.
Objective: Prove Option A meets NORMAL_P99_TARGET_MS=100 at concurrency 50 for normal density or return NO_GO.
Forbidden: enable_seqscan=off; declaring new indexes without query proof; SalesVelocityReader.
Depends: M5-05B merged.
Output: performance evidence in repo (test suite and/or evidence doc section).
```

### M5-05D — Sales velocity reader

```text
Task: Add projection-only SalesVelocityReader mirroring PeriodComparisonReader coherence.
Objective: compare_event(event_id, currency, window, opts) for locked measures.
Forbidden: EventAggregator.summary_for_event/2; raw order scans; query shape change without re-proving C.
Depends: M5-05C PASS.
Tests: readiness, redaction, coverage missing, refund boundary, analytics not ready, gross/refund/net measures.
```

---

## Appendix A — M5-05 boundary (do not absorb)

```text
M5-06 Capacity / Occupancy
M5-07 Freshness / data-quality projection (programme stale >10m on source age)
M5-08 Hot/warm/cold caching architecture
M5-09 Final analytics certification umbrella
M6 dashboard UI
VS-27D targets, pacing, notifications
```

---

## Appendix B — Machine-readable authority (v2)

```text
START_MAIN_SHA = 7d81d317886c38327a3a4fdb42c72f4ab8d688cb
START_MAIN_TREE = c5a001290977c553a8763c174c110c2862047dac
PLAN_VERSION = v2
M5_05_CANONICAL_NEXT = YES
M5_05_EXISTING_IMPLEMENTATION = NONE
LEGACY_HOT_SUMMARY_CANONICAL_FOR_VELOCITY = NO

OWNER_DECISION_REQUIRED = NO
M5_05B_AUTHORIZED = PENDING_V2_MERGE
M5_05B_SEMANTIC_GATE = OPEN_AFTER_V2_MERGE

VELOCITY_WINDOWS = 15m,30m,60m
VELOCITY_WINDOW_CLOCK = UTC_ABSOLUTE_DURATION

PRIMARY_SALES_VELOCITY_MEASURE = gross_ticket_quantity
QUANTITY_VELOCITY_MEASURES = gross_ticket_quantity,refund_ticket_quantity,net_ticket_quantity
MONETARY_VELOCITY_MEASURES = gross_ticket_value,refund_ticket_value,net_ticket_value

VELOCITY_RATE_UNIT_QUANTITY = tickets_per_hour
VELOCITY_RATE_UNIT_MONEY = currency_units_per_hour
RAW_WINDOW_VALUES_INCLUDED = YES

VELOCITY_COMPARISON = equal_immediately_preceding_window
VELOCITY_TREND = absolute_delta,percentage_delta,exact_sign_direction
VELOCITY_DIRECTION = faster,flat,slower
TREND_THRESHOLD = NONE

VELOCITY_SCOPE = event_and_currency
CROSS_CURRENCY_AGGREGATION = NO

TICKET_VELOCITY_VISIBLE_WHEN_REVENUE_REDACTED = YES
MONETARY_VELOCITY_REDACTED_WITH_REVENUE = YES

ANALYTICS_READY_REQUIRED = YES
MISSING_COVERAGE_IS_ZERO = NO

MAX_EDGE_FRAGMENTS = 4
MAX_DISTINCT_UTC_HOUR_ENVELOPES = 3
ALIGNED_60M_USES_FULL_BUCKET = YES

RECOMMENDED_ARCHITECTURE = OPTION_A_PENDING_M5_05C_PERFORMANCE_GATE
NEW_DURABLE_RESOURCE_REQUIRED = NO
NEW_BUCKET_KIND_REQUIRED = NO
NEW_INDEX_REQUIRED = NO_PENDING_EVIDENCE

M5_05_SEQUENCE = A,B,C_PERFORMANCE,D_READER,E_CERTIFICATION
M5_05C_IS_PRE_READER_PERFORMANCE_GATE = YES
PERFORMANCE_CONCURRENCY_COHORTS = 1,20,50
NORMAL_P99_TARGET_MS = 100
100K_CONCURRENT_USERS_CERTIFIED = NO

CANONICAL_VELOCITY_SOURCE = POSTGRES_M5_04_PROJECTIONS
HOT_CACHE_ROLE = OPTIONAL_DERIVED_ACCELERATION
WARM_REDIS_ROLE = OPTIONAL_DERIVED_SNAPSHOT
REDIS_STRUCTURE = REUSE_EXISTING_OR_DEFER
REDIS_TTL = 1h if mirrored (existing default)
INVALIDATION_TRIGGER = event_aggregate_refresh_path
PUBSUB_TRIGGER = REUSE_DASHBOARD_PUBSUB_EVENT_TOPIC

RAW_ORDER_SCAN = NO
RAW_REFUND_SCAN = NO
QUERY_BOUND = constant_queries; edge_rows scale with sales in touched UTC hour envelope(s)
FLASH_SALE_RISK = MEDIUM until M5-05C
PERFORMANCE_PROBE_REQUIRED = YES

VELOCITY_HAS_DURABLE_LIFECYCLE = NO
READINESS_STATES = forbidden, analytics_not_ready, operand_not_ready, ready_zero, ready_non_zero, revenue_redacted

PLAN_FILE = docs/development/m5-05-deterministic-sales-velocity.plan.md
PRODUCTION_CODE_CHANGE = NONE
STOP_CONDITION_TRIGGERED = NO
```
