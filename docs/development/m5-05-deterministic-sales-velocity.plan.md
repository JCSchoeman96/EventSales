---
Plan ID: m5-05-deterministic-sales-velocity
Plan version: v1
Status: M5-05A planning / conformance audit
Scope: Deterministic sales velocity semantics, bounded read architecture, and M5-05 sub-phase map (no implementation in M5-05A)
Authority base SHA: 7d81d317886c38327a3a4fdb42c72f4ab8d688cb
Authority base tree: c5a001290977c553a8763c174c110c2862047dac
Programme: M5-01..M5-04 COMPLETE (PASS); M5-05 NEXT
Last updated: 2026-10-08
Change summary (v1): M5-05A repository conformance audit; velocity semantic matrix; architecture recommendation; owner decision ledger; sub-phase acceptance gates.
---

### Revision log

- `v1` — M5-05A planning and conformance audit on `7d81d317` / tree `c5a00129`.

# M5-05 — Deterministic sales velocity

> Planning artifact only. M5-05A produced this document. No production code, migrations, tests, or dependency changes were made in M5-05A.

**Active contract:** This file is the canonical M5-05 plan. `docs/development/m5-04-period-comparisons.plan.md` remains historical authority for period comparisons only. `docs/path-1/path-1-phase-breakdown.md` M5-05 row still says "Hot summaries"; that row is stale relative to this audit and must not override the architecture below.

**Implementation gate:** M5-05B and later code slices stay **not authorized** until every row in Section 7 marked `OWNER_DECISION` is resolved and recorded in a plan version bump.

---

## 1. Ultimate outcome and backward plan

### 1.1 Operator outcome

Management needs a decision metric that answers, per event (and later optionally per dimension):

```text
How quickly is this event selling right now?
Is recent pace faster, slower, or flat versus the immediately prior equal interval?
```

The answer must be computable from certified analytics projections without scanning raw `Order`, `OrderItem`, `Refund`, or `RefundLine` tables from dashboard reads.

### 1.2 Backward chain (outcome first)

```text
Operator presentation (M6 / VS-27B.3 UI — out of M5-05 scope)
  ← deterministic velocity read result (rates, deltas, readiness)
  ← comparison / trend semantics (owner-locked)
  ← current and previous half-open UTC windows of equal duration
  ← additive primitives (gross/refund/net ticket qty and optional money)
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
| 1 | Explicit owner decisions recorded in this plan (after M5-05A) | Locks velocity product semantics |
| 2 | `AGENTS.md` | Local-first slice rules; Postgres durable truth; no raw REST from LiveView |
| 3 | `docs/agent/01_PROJECT_WIDE_RULES.md` | Architecture boundaries |
| 4 | `docs/path-1/path-1-phase-breakdown.md` | Programme order; M5-05 is NEXT |
| 5 | M1-04..M1-08 path-1 contracts | Sale/refund recognition, metrics, time, readiness |
| 6 | `docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md` | "Recent velocity and comparisons"; bounded filters |
| 7 | `docs/roadmap/EVENTSALES_LIVE_SALES_PROGRAMME.md` | VS-27B.1 window list including 15/30/60 minutes; velocity and trend in dashboard |
| 8 | M5-01..M5-04 plans and certification evidence | Period buckets, contribution edges, `PeriodComparisonReader` pattern |
| 9 | Path-1 M5-05 roadmap row ("Hot summaries") | **Superseded** by this plan for velocity truth source |

Conflict rule: Locked M1 and certified M5-04 behaviour win over the Path-1 M5-05 table hint that velocity comes from hot summaries.

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
| Reader pattern | `PeriodComparisonReader` | Auth first, one `now`, `ANALYTICS_READY`, coherent transaction, revenue redaction |
| Time kernels | `TimeRules`, `TimeRules.ComparisonWindows` | Preset periods only today; no minute windows yet |
| Metric kernels | `MetricRules` | Primitives and comparison delta/state helpers |
| Legacy hot path | `EventAggregator.summary_for_event/2`, `HotStateAggregator` | Documented legacy; uses completed-only ex-tax scalars |

### 3.4 Legacy hot summary audit

```text
LEGACY_HOT_SUMMARY_CANONICAL_FOR_VELOCITY = NO
```

`EventAggregator.summary_for_event/2` moduledoc states legacy compatibility. It aggregates `status == completed` ticket lines and ex-tax `line_total` for revenue. Canonical financial and period semantics use `MetricRules.financial_summary/3`, sale-effective and refund-effective placement, and M5-04 projections. M5-05 must not derive velocity from hot ETS summaries or `summary_for_event/2` totals.

`HotStateAggregator` rebuilds from `EventAggregator` for dashboard snapshots. That path is acceleration only, not velocity truth.

### 3.5 Programme vs locked period contract gap

`EVENTSALES_LIVE_SALES_PROGRAMME.md` (VS-27B.1) lists **Last 15/30/60 minutes** alongside today, yesterday, and rolling days.

`m1-07-timestamp-johannesburg-period-and-freshness-contract.md` §14 records those minutes as programme input but **locks** only Today, Yesterday, Last 7 Days, Last 30 Days, and Custom (T20–T23). Minute windows are not T20–T23 decisions.

M5-04 implements the locked presets only. Minute velocity windows require an owner lock or a new M1-07 revision before implementation.

---

## 4. Domain and resource map

Domain: `EventSales.Analytics`

| Concept | Disposition | Notes |
| --- | --- | --- |
| `EventAggregateSnapshot` | REUSE | Not primary for sub-hour velocity |
| `EventDimensionAggregateSnapshot` | DEFER | Dimensional velocity not in M5-05 MVP unless owner expands scope |
| `EventPeriodAggregateSnapshot` | REUSE | UTC-hour interiors for windows > 1 hour; envelope for edges |
| `EventDimensionPeriodAggregateSnapshot` | DEFER | Same as dimensional velocity |
| `AnalyticsContributionFact` | REUSE | Partial window edges; flash-sale bound is per touched UTC hour |
| `MetricRules` | EXTEND | Add velocity rate/comparison helpers after semantics lock; do not change primitive definitions |
| `TimeRules` | EXTEND | Add minute rolling window bounds (proposed API in §9); one captured `now` |
| `PeriodReadPlan` | REUSE / EXTEND | `decompose_period/2` already handles sub-hour-only windows (edge-only, no interior) |
| `PeriodComparisonReader` | REUSE (pattern) | Template for auth, readiness, SQL shape; not the velocity API |
| `SnapshotReader` / dimension readers | NOT REQUIRED | Lifetime reads irrelevant for 15–60m |
| `VelocityWindow` (candidate) | NEW | Pure struct: duration, current/previous `Period.t()` |
| `VelocityOperand` (candidate) | NEW | Alias or reuse `:current` / `:previous` from comparison |
| `VelocityMeasure` (candidate) | NEW | Enum of exposed metrics after owner lock |
| `VelocityComparison` (candidate) | NEW | Prior equal window vs baseline (owner) |
| `VelocityReadiness` (candidate) | NEW | Read-result envelope, not a durable resource |
| `SalesVelocityReader` (candidate) | NEW | Projection-only reader module |
| `VelocityRules` (candidate) | NEW | Pure deterministic rate and delta math |
| `HotStateAggregator` | NOT REQUIRED for truth | Optional mirror later |
| `DashboardCache` / Redis snapshot | DEFER to M5-08 | Optional warm cache of canonical read |
| `DashboardPubSub` | REUSE later | Same event topic; no new topic in M5-05 |

```text
NEW_DURABLE_RESOURCE_REQUIRED = NO (Option A hypothesis)
NEW_BUCKET_KIND_REQUIRED = NO (defer until M5-05D evidence)
NEW_INDEX_REQUIRED = NO (hypothesis; prove in M5-05D before claiming)
```

---

## 5. Relationships and ownership

```text
M4 sale/refund writes
  → contribution facts and period bucket materializers (M5-04D/E/G)
  → period snapshots and coverage envelopes
  → velocity reader (M5-05C) reads snapshots + bounded contribution aggregates
  → optional hot/warm mirror (M5-08)
  → PubSub notifies UI to re-fetch (existing DashboardPubSub)
```

Oban refresh and coverage maintenance remain owned by M5-04 workers. M5-05 does not add materializers unless M5-05D proves finer buckets are required.

Velocity has no write path of its own. It does not enqueue separate durable rows for "velocity state."

---

## 6. Velocity semantic matrix

| Question | Authority status | M5-05A resolution |
| --- | --- | --- |
| What is velocity measuring? | Programme: tickets and revenue context; no single "velocity" formula | **OWNER_DECISION** — options: (A) net tickets only, (B) gross tickets only, (C) parallel measures (qty + optional revenue), (D) orders/minute. Recommend (C) with **primary operator default = net_ticket_quantity** aligned to M5-04 comparison metrics. |
| Ticket primitive | M1-06 locked gross/refund/net qty | **LOCKED** — use same primitives as M5-04; net = gross − refund in window |
| Monetary velocity | Programme mentions revenue; M5-04 exposes money metrics | **OWNER_DECISION** — required in MVP vs phase-2. Recommend **ship ticket velocity first**; add `net_ticket_value` rate when revenue visibility policy is clear. |
| Window set | Programme 15/30/60m; M1-07 T20–T23 excludes minutes | **OWNER_DECISION** — lock `{:rolling_minutes, 15 \| 30 \| 60}` or subset. Recommend all three for parity with VS-27B.1 once owner confirms. |
| Rate normalization | Not in M1/M5 contracts | **OWNER_DECISION** — options: tickets per minute, tickets per hour, raw count per window. Recommend **tickets per minute** (integer or fixed decimal) with **raw window count** also exposed for UI flexibility. |
| Comparison | Programme "previous equivalent"; M5-04 JC-310 pattern for presets | **LOCKED pattern** for equal duration: previous = `[now − 2w, now − w)`, current = `[now − w, now)` where `w` is window duration. Same as rolling-day comparison geometry. |
| Trend output | Programme "trend"; no thresholds | **OWNER_DECISION** — (A) continuous delta and % only (reuse `MetricRules` comparison deltas), (B) categorical rising/stable/falling. Recommend **(A)** unless product supplies thresholds. |
| Trend thresholds | None locked | **NOT REQUIRED** if trend is continuous only; else **OWNER_DECISION** |
| Zero activity | M5-04 zero buckets with coverage | **LOCKED** — valid zero only when operand coverage is `:ready` and primitives sum to zero |
| Missing coverage | M5-04 / contribution moduledocs | **LOCKED** — fail closed; never coerce missing to zero |
| Refund placement | M1-07 T24 | **LOCKED** — refund effective time |
| Sale placement | M1-04 / M1-07 | **LOCKED** — sale-effective `COALESCE(paid_at, completed_at)` |
| `now` | M5-04 reader | **LOCKED** — capture once per request |
| Cross-currency ticket quantity | M1-06 partitions money by currency; qty additive at event grain | **OWNER_DECISION** — sum qty across currencies at event level vs require single reporting currency for qty display. Recommend **event-level sum across currencies** only if product confirms tickets are comparable across order currencies. |
| Revenue velocity | M1-06 | **LOCKED** — always per `currency`; never collapse currencies |
| Dimensions | Programme ticket-type performance later | **DEFER** — event-level only for M5-05 MVP |
| All-event velocity | Product all-event reporting | **DEFER** — management aggregation across events is not M5-05; no unbounded multi-event scan contract here |
| Authorization | `PeriodComparisonReader` | **LOCKED** — `Policies.can_access_event_dashboard?/2` before work |
| Monetary redaction | `Policies.can_view_revenue?/2` | **LOCKED** for money fields; **OWNER_DECISION** whether ticket-only velocity is visible when revenue is redacted (policy silent today) |
| ANALYTICS_READY | M1-08 | **LOCKED** — gate like M5-04; ticket-only partial result while not ready is **not** authorized without owner exception |
| PII | Programme | **LOCKED** — none |

```text
OWNER_DECISION_REQUIRED = YES
```

```text
OWNER_DECISION_TOPICS =
  primary velocity measure(s) and MVP scope (tickets vs revenue rates)
  locked minute window set (15/30/60)
  rate normalization unit
  categorical trend vs continuous delta only
  cross-currency ticket quantity at event level
  ticket velocity visibility under revenue redaction
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
| `:operand_not_ready` | Missing or non-current coverage for current or previous window | Per-operand; map to `MetricRules` `:current_missing` / `:comparison_missing` |
| `:ready_zero` | Coverage ready; primitives zero both sides | Valid zero velocity |
| `:ready_non_zero` | Coverage ready; at least one non-zero primitive | Rate and delta defined |
| `:revenue_redacted` | Money fields stripped | Policy; qty may still show if owner allows |

Rising/stable/falling, if ever added, are **derived classifications** from two rates or deltas, not durable lifecycle states.

### 7.2 Underlying bucket transitions (reference only)

Owned by M5-04 materializers. Velocity reader must treat non-`:current` projection states as not ready for that bucket identity, consistent with `PeriodComparisonReader`.

---

## 8. Permissions and policy

Reuse `PeriodComparisonReader` ordering:

1. Cast and validate `event_id`, currency (when money involved), window request.
2. `authorize(actor, event_id)` via `can_access_event_dashboard?/2`.
3. `AnalyticsReadinessResolver.resolve/1` — fail closed on not ready unless owner later authorizes partial ticket-only reads.
4. Capture `now` once; build windows.
5. Compute operands; apply `can_view_revenue?/2` to monetary fields only.

No cross-event reads. No PII. Revenue never mixed across currencies.

---

## 9. Time and window contract

M5-05A does **not** implement `TimeRules` changes. Proposed API for M5-05B:

```elixir
@spec velocity_windows(DateTime.t(), {:rolling_minutes, pos_integer()}) ::
        {:ok, ComparisonWindows.t()} | {:error, :unsupported_velocity_window}
```

Rules:

```text
capture now once per read (pass via opts like PeriodComparisonReader)
windows are UTC absolute half-open [start, end)
current  = [now - w, now)
previous = [now - 2w, now - w)
w ∈ owner-locked set (candidate 15, 30, 60 minutes)
no DateTime.utc_now/0 inside decomposition or SQL assembly after capture
no Johannesburg civil semantics inside pure minute windows
sale and refund effective timestamps unchanged from M1-07 / M5-04
```

`PeriodReadPlan.decompose_period(period, :utc_hour_interior_and_edges)` already yields **edge-only** plans for sub-hour windows (no interior buckets). For 15–60m windows, each operand is typically one contribution edge per touched UTC hour (at most two hours if window spans hour boundary).

Extend `PeriodReadPlan.build/1` or add `VelocityReadPlan.build/1` that accepts two-operand `ComparisonWindows` without changing max edge fragment policy. **Verify:** two operands × up to 2 edges each = 4 fragments (at hour-boundary worst case). Sub-hour-only operands use 1 edge each → 2 total. M5-05B must prove fragment count stays ≤ 4 or raise `:too_many_edge_fragments`.

---

## 10. Architecture options

### Option A — M5-04 UTC-hour buckets + contribution edges (preferred hypothesis)

Use `EventPeriodAggregateSnapshot` for any full hours enclosed in longer windows (not applicable for 15–60m-only operands) and `AnalyticsContributionFact` for all sub-hour window mass.

Advantages: no new durable resource; certified zero/missing semantics; same reader transaction pattern as M5-04F; existing index.

Risks: flash-sale hour may contain many contribution rows in edge SQL; 15/30/60m reads are **mostly edge-heavy**; must certify latency under concurrency 20.

### Option B — Finer durable buckets (e.g. five-minute)

Evaluate only if Option A fails M5-05D probes.

Costs: write amplification, coverage cardinality, materializer complexity, backfill, storage, invalidation coupling.

```text
Recommendation: DEFER unless M5-05D evidence fails sub-100ms targets at 50 viewers with realistic flash-sale fixtures.
```

### Option C — ETS/Redis/GenServer counters as canonical velocity

Reject as durable truth. Hot/warm may cache **already computed** canonical velocity snapshots later (M5-08).

---

## 11. Recommended architecture

```text
RECOMMENDED_ARCHITECTURE = OPTION_A
  POSTGRES_M5_04_PROJECTIONS + bounded AnalyticsContributionFact edge aggregates
  pure VelocityRules kernel
  projection-only SalesVelocityReader (new)
  optional hot/warm mirror deferred to M5-08
```

Do not add minute or five-minute bucket **resources** in the first implementation slice.

---

## 12. Query and data-source matrix

| Operand window | Fixed buckets | Edge contributions | Max bucket rows | Max contribution rows |
| --- | --- | --- | --- | --- |
| 15m current | 0 | 1–2 hour envelopes | 0–2 envelope lookups | O(sales in touched UTC hours) |
| 15m previous | 0 | 1–2 | same | same |
| 30m / 60m | 0 | 1–2 per operand | same | same |

Query count target per `compare_velocity` read (event, currency if money):

```text
1 coherent transaction
1 readiness resolve (outside or inside per M5-04 pattern)
envelope / bucket reads: O(operands × touched hours) small constant
1–2 edge aggregate queries (M5-04F may batch; velocity should reuse batching pattern)
0 raw order/refund scans
```

```text
RAW_ORDER_SCAN = NO
RAW_REFUND_SCAN = NO
QUERY_BOUND = constant small integer queries per read; edge row count bounded by event sales in ≤2 UTC hours per operand (≤4 hours wall clock per full compare at boundary worst case)
```

Index: `analytics_contribution_facts_event_currency_effective_at_idx` serves `event_id = ? AND currency = ? AND effective_at >= ? AND effective_at < ?`. No new index unless M5-05D EXPLAIN shows a different required shape.

---

## 13. Performance and scaling review

| Question | Answer |
| --- | --- |
| Hot/warm/cold ownership | **Cold** = Postgres snapshots + facts; **warm** = Redis snapshot TTL 1h (existing); **hot** = ETS via `DashboardCache` (existing). Canonical velocity = cold composition. |
| Max rows read | Edge: contributions in hour envelope(s); buckets: ≤ few envelope rows per hour touched |
| Grows with event lifetime? | No for a single read |
| Grows with total orders? | No except sales density in current UTC hour(s) |
| Grows with refunds? | Same hour window |
| Grows with currencies? | Linear in currencies **only if** money metrics requested per currency |
| Flash sale safe? | **RISK** — edge scan scales with hour throughput; needs M5-05D probe with high contribution density |
| Postgres query count | Bounded small constant |
| Full-hour buckets replace edges? | For 15–60m windows, interiors empty; edges mandatory |
| Finer buckets reduce bound? | Would reduce per-edge row count but increase durable cardinality; evidence-driven only |
| SQL aggregation vs BEAM | Prefer SQL `SUM` like `PeriodComparisonReader` edge query |

Targets (design, not certified for M5-05):

```text
sub-100ms normal velocity read at programme fixture scale
50 concurrent dashboard viewers (programme VS-27B.3)
architecture must not require raw-history scans
100k concurrency = not claimed
```

```text
FLASH_SALE_RISK = MEDIUM on contribution edge path until M5-05D load and EXPLAIN evidence
PERFORMANCE_PROBE_REQUIRED = YES (M5-05D mandatory before calling Option A final)
```

M5-04 certification reference: rolling 7 p99 90ms at concurrency 20; rolling 30 p99 292ms. Minute windows use fewer bucket rows but potentially dense edge scans. Do not extrapolate pass without measurement.

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
| Refund-only window | Net qty/value may be negative; rate still deterministic |
| Both windows zero | `:flat_zero` comparison state |
| High sales in one hour | M5-05D load test + EXPLAIN |
| `now` on UTC hour boundary | Covered by `PeriodReadPlan` decomposition tests pattern |
| Unauthorized actor | `:forbidden` |
| Revenue-redacted actor | Strip money; owner decides ticket visibility |
| Pool stampede | Single coherent read; no per-row LiveView queries |
| Cross-currency revenue collapse | Forbidden |

---

## 16. Gap ledger

| ID | Gap | Owner / slice |
| --- | --- | --- |
| G1 | Minute window set not in M1-07 T20–T23 | Owner + plan v2 |
| G2 | Velocity measure and rate unit | Owner + plan v2 |
| G3 | Trend categorical thresholds | Owner or continuous-only |
| G4 | Ticket velocity under revenue redaction | Owner / policy doc |
| G5 | No `SalesVelocityReader` | M5-05C |
| G6 | No `TimeRules.velocity_windows` | M5-05B |
| G7 | Flash-sale edge cost unproven | M5-05D |
| G8 | Path-1 M5-05 row says hot summaries | Update path-1 in a later docs hygiene PR optional |
| G9 | Dimensional velocity | Post-MVP |
| G10 | All-event velocity | Later management aggregation |

---

## 17. Owner decisions required (summary)

Implementation **must not** start until G1–G4 are decided and recorded in this plan with a version bump.

Smallest decision batch for unblocking M5-05B:

1. Lock window set: 15, 30, 60 minutes (or subset).
2. Lock primary measure: recommend `net_ticket_quantity` with optional parallel `net_ticket_value` per currency.
3. Lock rate display: tickets per minute plus raw window counts.
4. Lock trend: continuous delta only for v1.
5. Lock ticket-only visibility when revenue redacted.

---

## 18. M5-05 sub-phase map

| Sub-phase | Responsibility | Implementation authorized after |
| --- | --- | --- |
| **M5-05A** | This audit and plan | N/A (complete when PR merges) |
| **M5-05B** | Pure `VelocityRules` + `TimeRules.velocity_windows` + read-plan extension; focused tests | Owner semantics locked (Section 17) |
| **M5-05C** | `SalesVelocityReader` projection-only; auth, readiness, redaction; mirrors M5-04F patterns | M5-05B merged |
| **M5-05D** | Query-plan, concurrency, flash-sale fixture, EXPLAIN; evidence doc | M5-05C or parallel if probe needed earlier |
| **M5-05E** | Reconciliation vs oracle window sums, certification markdown, programme closeout | M5-05C+D pass |

If Option B (finer buckets) is required, add **M5-05F** schema/materialization slice separate from reader work.

```text
M5_05_SUBPHASES = M5-05A (plan), M5-05B (kernel), M5-05C (reader), M5-05D (performance evidence), M5-05E (certification)
```

---

## 19. Acceptance gates

### M5-05A (this slice)

- [x] Plan file with sections 1–20
- [x] No `lib/`, `test/`, `priv/` changes
- [x] Semantic gaps explicit; no invented thresholds
- [ ] PR CI green
- [ ] PR merged (not required for A completion report; remains open per task)

### M5-05B

- [ ] Owner decisions recorded in plan v2+
- [ ] Pure modules only; no Ash resources
- [ ] Window math tests including boundaries and DST-neutral UTC
- [ ] Read-plan fragment count ≤ 4 for all locked windows

### M5-05C

- [ ] No raw order/refund queries
- [ ] Auth before work; ANALYTICS_READY gate
- [ ] Missing coverage never returns zero velocity
- [ ] Revenue redaction tests

### M5-05D

- [ ] EXPLAIN JSON for edge queries
- [ ] Load harness concurrency 20; document p50/p95/p99
- [ ] Flash-sale contribution density scenario
- [ ] Explicit GO/NO-GO on Option A vs finer buckets

### M5-05E

- [ ] Oracle reconciliation for locked windows
- [ ] `docs/evidence/m5-05-deterministic-sales-velocity-certification.md`
- [ ] Path-1 M5-05 marked COMPLETE only after E pass

---

## 20. TOON micro-prompts (next authorized slices)

### M5-05B — Velocity kernel and time windows (blocked on owner decisions)

```text
Task: Implement pure TimeRules.velocity_windows/3 and VelocityRules rate/delta helpers for owner-locked {:rolling_minutes, _} set.
Objective: Deterministic half-open windows and arithmetic with no I/O.
Forbidden: Ash resources, readers, Redis, migrations, inventing owner semantics.
Preflight: Plan version ≥ v2 with OWNER_DECISION rows resolved.
Tests: boundary instants, equal previous window, zero-safe math, fragment count via VelocityReadPlan.
Done: mix quality.fast; no implementation if plan still v1.
```

### M5-05C — Sales velocity reader

```text
Task: Add projection-only SalesVelocityReader mirroring PeriodComparisonReader coherence.
Objective: Event-level velocity compare for locked windows and measures.
Forbidden: EventAggregator.summary_for_event/2 as source; raw order scans.
Depends: M5-05B merged.
Tests: readiness, redaction, coverage missing, refund boundary, analytics not ready.
```

### M5-05D — Performance and architecture proof

```text
Task: Certification harness and EXPLAIN suite for velocity edge reads.
Objective: Prove Option A meets sub-100ms normal target at concurrency 20 or document bucket escalation.
Forbidden: Declaring new indexes without query shape proof.
Output: evidence doc section or standalone m5-05 evidence markdown.
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

## Appendix B — M5-05A return block (machine-readable)

```text
START_MAIN_SHA = 7d81d317886c38327a3a4fdb42c72f4ab8d688cb
START_MAIN_TREE = c5a001290977c553a8763c174c110c2862047dac
M5_05_CANONICAL_NEXT = YES
M5_05_EXISTING_IMPLEMENTATION = NONE
LEGACY_HOT_SUMMARY_CANONICAL_FOR_VELOCITY = NO
VELOCITY_PRIMARY_MEASURE = OWNER_DECISION (recommend net_ticket_quantity)
VELOCITY_WINDOWS = OWNER_DECISION (programme 15/30/60; not M1-07-locked)
VELOCITY_RATE_UNIT = OWNER_DECISION (recommend tickets_per_minute + raw_window_count)
VELOCITY_COMPARISON = LOCKED_PATTERN equal_immediately_preceding_window
VELOCITY_TREND_CONTRACT = OWNER_DECISION (recommend continuous_delta_only)
REFUND_TREATMENT = LOCKED refund_effective_time per M1-07 T24
CROSS_CURRENCY_RULE = money per currency LOCKED; ticket sum OWNER_DECISION
OWNER_DECISION_REQUIRED = YES
RECOMMENDED_ARCHITECTURE = OPTION_A_M5_04_BUCKETS_AND_CONTRIBUTION_EDGES
NEW_DURABLE_RESOURCE_REQUIRED = NO
NEW_BUCKET_KIND_REQUIRED = NO
NEW_INDEX_REQUIRED = NO (pending M5-05D)
CANONICAL_VELOCITY_SOURCE = POSTGRES_M5_04_PROJECTIONS
HOT_CACHE_ROLE = OPTIONAL_DERIVED_ACCELERATION
WARM_REDIS_ROLE = OPTIONAL_DERIVED_SNAPSHOT
REDIS_STRUCTURE = REUSE_EXISTING_OR_DEFER
REDIS_TTL = 1h if mirrored (existing default)
INVALIDATION_TRIGGER = event_aggregate_refresh_path
PUBSUB_TRIGGER = REUSE_DASHBOARD_PUBSUB_EVENT_TOPIC
RAW_ORDER_SCAN = NO
RAW_REFUND_SCAN = NO
QUERY_BOUND = constant_queries; edge_rows ~ sales in <=2 UTC hours per operand typical
FLASH_SALE_RISK = MEDIUM until M5-05D
PERFORMANCE_PROBE_REQUIRED = YES
VELOCITY_HAS_DURABLE_LIFECYCLE = NO
READINESS_STATES = forbidden, analytics_not_ready, operand_not_ready, ready_zero, ready_non_zero, revenue_redacted
M5_05_SUBPHASES = A, B, C, D, E
PLAN_FILE = docs/development/m5-05-deterministic-sales-velocity.plan.md
PRODUCTION_CODE_CHANGE = NONE
STOP_CONDITION_TRIGGERED = NO (owner decisions required before implementation; not a STOP halt for M5-05A)
```
