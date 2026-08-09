# EventSales Path 1 — Repository-Native Phase Breakdown

| Field | Value |
| --- | --- |
| Document | Canonical Path 1 execution roadmap |
| Plan ID | `path-1-phase-breakdown` |
| Plan version | `v7` |
| Status | ACTIVE — repository-native execution contract |
| Scope | Path 1 M1–M7 gated implementation sequence |
| Authority | This file wins for Path 1 task sequencing and physical ownership assumptions |
| Programme handoff | `docs/roadmap/current-state-and-path-handoff.md` |
| Product decisions | `docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md` |
| Repository truth | `docs/path-1/m1-01-current-repo-truth.md` |
| Attribution contract | `docs/path-1/m1-03-event-product-variation-orderline-attribution-contract.md` |
| Lifecycle / recognised-sale contract | `docs/path-1/m1-04-order-lifecycle-and-recognised-sale-contract.md` |
| Refund / financial-adjustment contract | `docs/path-1/m1-05-refund-and-financial-adjustment-contract.md` |
| Financial metric dictionary | `docs/path-1/m1-06-financial-metric-dictionary.md` |
| Historical planning source | Supplied `EVENTSALES_PATH_1_UPDATED_PHASE_BREAKDOWN.md` (v1 conceptual plan; superseded for physical assumptions) |
| Path 2 / Phase 5E | PAUSED |
| Prepared | 2026-08-09 |
| Audit base HEAD | `0bd0526a383a0d7faa1e61472f8551f779773223` |

### Revision log

- `v1` — conceptual Path 1 phase breakdown (external / Downloads copy)
- `v2` — M1-01A repository-native reconciliation against `m1-01-current-repo-truth.md`
- `v3` — M1-02 closeout: mark M1-01A/M1-02 COMPLETE; next task M1-03 (requires owner authorization)
- `v4` — M1-03 closeout: COMPLETE (PASS); next task M1-04 (requires owner authorization); record REQUIRED_BEFORE_M2 TicketType variation-parent fail-closed gap for M1-09 PRE-M2 gate
- `v5` — M1-04 closeout: COMPLETE (PASS); next task M1-05 (requires owner authorization); lock recognised-sale predicate for refund contract design
- `v6` — M1-05 closeout: COMPLETE (PASS); next task M1-06 (requires owner authorization); carry refund implementation gaps unresolved (M3/M4/M5 timing; MetricRules IMPLEMENTATION_CHANGE_REQUIRED)
- `v7` — M1-06 closeout: COMPLETE (PASS); next task M1-07 (requires owner authorization); lock tax-inclusive Gross as `line_total + line_total_tax` (MG1 REQUIRED_DURING_M3; MG2–MG8 REQUIRED_BEFORE_M5)

### Conflict rule

```text
M1-01 repository truth
  wins over speculative physical architecture in v1 plan

Product / programme decisions
  win over implementation convenience

This file
  wins for Path 1 task sequencing and REUSE/EXTEND/NEW strategy
```

---

## 1. Purpose

Working execution plan for Path 1 — Trusted Management Analytics.

Business outcome is unchanged:

```text
trusted source identity
→ trusted event / product / variation identity
→ trusted historical sales
→ trusted refunds / corrections
→ financial reconciliation
→ ANALYTICS_READY
→ bounded analytics read models
→ read-only management dashboard
→ production certification
```

Physical implementation assumptions are updated to match the certified M1-01 audit.

Strategy vocabulary for later tasks:

```text
REUSE                    — keep current module/resource/path as-is
EXTEND                   — add behaviour/fields/indexes on existing foundation
NEW                      — net-new capability (contract first; physical form TBD)
CERTIFY                  — prove / lock current behaviour without redesign
REMOVE_AS_ALREADY_PRESENT — drop greenfield work that already exists
```

Where a concept is missing, mark **NEW CONTRACT REQUIRED**, not **NEW RESOURCE REQUIRED**, until the owning M1 task decides physical form.

---

## 2. Authoritative References

```text
docs/roadmap/current-state-and-path-handoff.md
docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md
docs/path-1/m1-01-current-repo-truth.md
docs/phase-5d/native-v3-e2e-run-report.md
AGENTS.md
docs/agent/01_PROJECT_WIDE_RULES.md
```

Verified programme state:

```text
Phase 5C / 5D: COMPLETE
Path 1: ACTIVE
Path 2 / Phase 5E: PAUSED
P1-00: COMPLETE
M1-01: COMPLETE (PASS)
M1-01A: COMPLETE (PASS)
M1-02: COMPLETE (PASS)
M1-03: COMPLETE (PASS)
M1-03 contract: docs/path-1/m1-03-event-product-variation-orderline-attribution-contract.md
M1-04: COMPLETE (PASS)
M1-04 contract: docs/path-1/m1-04-order-lifecycle-and-recognised-sale-contract.md
M1-05: COMPLETE (PASS)
M1-05 contract: docs/path-1/m1-05-refund-and-financial-adjustment-contract.md
M1-06: COMPLETE (PASS)
M1-06 contract: docs/path-1/m1-06-financial-metric-dictionary.md
TAX-INCLUSIVE REVENUE CONTRACT: IMPLEMENTATION_CHANGE_REQUIRED
Known REQUIRED_BEFORE_M2 gap: TicketType variation-parent fail-closed enforcement (unresolved; defer to M1-09 PRE-M2 gate)
Known M1-05/M1-06 carry-forward gaps (unresolved):
  MG1 persist OrderItem.line_total_tax REQUIRED_DURING_M3 (before authoritative Gross Ticket Sales; not M2)
  MG2–MG8 refund-aware Gross/Net, distinct Order Count, ATV, currency partitioning, MetricRules/snapshot changes REQUIRED_BEFORE_M5
  refund persistence/import REQUIRED_DURING_M3; refund completeness BEFORE_M4
Current Path 1 task: M1-07 — Timestamp, Johannesburg Period and Freshness Contract
M1-07: REQUIRES OWNER AUTHORIZATION
```

---

## 3. Physical Ownership (M1-01 certified)

### 3.1 Conceptual responsibilities → Ash domains

| Conceptual label | Physical Ash domain | Notes |
| --- | --- | --- |
| Sources | `EventSales.Catalog` | `SourceSystem` |
| Catalog | `EventSales.Catalog` | Event, TicketType, ProductMapping |
| Sales / Ingestion | `EventSales.Sales` + `EventSales.Ingestion` | Order/OrderItem; webhooks/SyncRun |
| Reconciliation (attendee / catch-up) | `EventSales.Ingestion` | Do **not** create `EventSales.Reconciliation` |
| Path 1 financial reconciliation | TBD under Ingestion patterns | NEW CONTRACT in M1-08 / M4 — no new domain by default |
| Analytics | `EventSales.Analytics` | Snapshots + HotStateAggregator |
| Management | `EventSales.Accounts` + LiveView | Policies; no `EventSales.Management` domain |

Do **not** plan new Ash domains named Sources, Reconciliation, or Management unless a later explicit design proves necessity.

### 3.2 Resources — starting point

| Concept | Physical starting point | Classification |
| --- | --- | --- |
| SourceSystem | `Catalog.Resources.SourceSystem` | REUSE |
| Event | `Catalog.Resources.Event` | REUSE / EXTEND (Ash external identity) |
| TicketType | `Catalog.Resources.TicketType` | REUSE |
| Product / ProductVariation | **No first-class resource** — IDs on ProductMapping / TicketType / OrderItem | REMOVE_AS_ALREADY_PRESENT (as resource creation) |
| EventProductLink / EventVariationLink | `ProductMapping` | REUSE |
| Order / OrderItem | `Sales.Resources.Order` / `OrderItem` | REUSE |
| SaleFact | Order + OrderItem | REMOVE_AS_ALREADY_PRESENT (as separate resource) |
| Refund / RefundLine | Status `:refunded` only; contract locked | NEW CONTRACT LOCKED (M1-05) — physical form TBD |
| SalesImportRun | Prefer EXTEND `SyncRun` / `SyncCursor` | EXTEND / TBD |
| Analytics aggregates | Event/Daily snapshots + hot state | REUSE / EXTEND |
| Attendee reconciliation | TickeraReconciliation* | REUSE (not financial) |

### 3.3 Source identity layers (do not collapse)

```text
1. internal_source_pk
   SourceSystem.id (UUID) / FK source_system_id

2. canonical_source_key
   SourceSystem.kind + SourceSystem.base_url
   (persisted unique identity)

3. producer_source_system_id
   wordpress_tickera:<sha256_hex>
   wire/discovery only; verified against base_url; not SourceSystem PK
```

M1-02 owns the final locked contract.

### 3.4 Durable sales writer

All durable order writes converge on:

```text
WoocommerceOrderParser
→ EventSales.Sales.OrderUpserter
→ Ash Order / OrderItem actions
```

Paths: webhook, Woo catch-up (`OrderReconciliation`), CSV apply.

**No parallel order writer.** M3 must EXTEND/REUSE this path.

### 3.5 Idempotency keys (repository field names)

```text
Order:
  (source_system_id, woo_order_id)

OrderItem:
  (order_id, woo_line_item_id)
```

Do not invent a second identity system. M1-02 may express conceptual order-item identity as source-scoped Woo IDs resolved through the order FK.

### 3.6 Attribution (current behaviour to CERTIFY)

```text
source_tickera_event_id present
  → OrderAttributionResolver (event-first)
  → ProductMapping as review context (not override)

else
  → MappingResolver ProductMapping fallback

mapped historical rows:
  protect_mapped_source_identity (no silent rewrite)
```

On-hold orders defer automatic mapping.

M1-03 certifies and locks this architecture; it does not design an unrelated bridge from scratch.

### 3.7 Analytics / cache layers

```text
Hot:  ETS via DashboardCache / HotStateAggregator
Warm: Redis (RedixAdapter)
Cold: Postgres (Order/OrderItem + aggregate snapshots)
```

**Cachex is absent.** Remove Cachex as a mandatory Path 1 requirement. Do not add a dependency merely to satisfy the v1 conceptual plan.

Preserve outcomes: bounded reads, single-flight rebuild, targeted invalidation, hot/warm/cold separation, PubSub updates, no peak full-table scans.

### 3.8 OPEN M1-07 CONTRACT CONFLICT

```text
programme contract:
  expected visibility < 5 minutes
  stale > 10 minutes

current implementation:
  HotStateAggregator default stale_after_ms = 300_000 (5 minutes)

status:
  OPEN M1-07 CONTRACT CONFLICT
```

Do **not** resolve here. M1-07 decides; later implementation conforms.

### 3.9 Refund truth (current)

```text
order status :refunded — EXISTS
independent refund objects — MISSING (implementation)
M1-05 refund / financial-adjustment contract — LOCKED (PASS)
```

M1-05 contract: `docs/path-1/m1-05-refund-and-financial-adjustment-contract.md`.
M3 implements only the physical model M1-05 authorizes. Do not invent Refund/RefundLine resources ahead of that contract’s physical-ownership decision.

---

## 4. Path 1 Governing Rule

An agent may work only inside the current phase. Verify the previous phase is complete. Do not start the next phase. STOP if the current phase exposes a defect belonging to an earlier phase.

Path 2 / Phase 5E remain paused. No Apply / AutoApply. No WordPress mutation for Path 1 analytics work.

---

## 5. Locked Programme Invariants

Preserved from programme decisions / handoff (not reinterpreted by M1-01A):

```text
source-scoped external identity required
raw Woo/Tickera IDs not globally unique
names/titles/SKUs not relationship authority
variation identity preserves exact source + exact parent
historical source identities immutable
unknown identity fails closed
only completed Woo orders count as recognised sales
other states ingested and operationally visible
money uses Decimal / numeric — never float
historical sales may predate local EventSales Event
initial backfill begins at selected source/Tickera event creation date
backfill reuses parser + OrderUpserter
financial mismatch blocks ANALYTICS_READY
management remains read-only
Apply/AutoApply independent of Path 1 analytics
LiveView/controllers must not call WooCommerce inline
```

Freshness numeric thresholds: see §3.8 (open conflict for M1-07).

---

## 6. Phase Map

| Phase | Name | Outcome |
| --- | --- | --- |
| P1-00 | Path 1 Activation Gate | COMPLETE |
| M1 | Truth & Identity Contract | Contracts locked |
| M2 | Operator Event Onboarding | BACKFILL_PENDING for exact event |
| M3 | Historical Sales Backfill | Durable history via OrderUpserter |
| M4 | Financial Reconciliation | Source vs EventSales money match |
| M5 | Analytics Read Model | Trusted bounded projections |
| M6 | Management Dashboard | Read-only management UX |
| M7 | Production Certification | Pilot-ready gate |

---

## 7. P1-00 — Path 1 Activation Gate

```text
Status: COMPLETE
Strategy: CERTIFY
```

Activation checkpoint `0bd0526…` is historical. Current work uses then-current `main` + M1-01 truth.

---

## 8. M1 — Truth & Identity Contract

### Objective

Lock identity, sales, refunds, metrics, timestamps, freshness, completeness, reconciliation, and `ANALYTICS_READY` **before** dashboards or backfill implementation.

### Sequence

```text
M1-01   COMPLETE — repository truth
M1-01A  COMPLETE — roadmap reconciliation
M1-02   COMPLETE — source identity
M1-03   COMPLETE — attribution contract
M1-04   COMPLETE — order lifecycle / recognised sale
M1-05   COMPLETE — refund / financial adjustment
M1-06   COMPLETE — financial metric dictionary
M1-07   time / period / freshness (requires owner authorization)
M1-08   completeness / reconciliation / ANALYTICS_READY
M1-09   certification
```

---

### M1-01 — Repository Identity and Writer Audit

| Field | Value |
| --- | --- |
| Status | **COMPLETE (PASS)** |
| Strategy | CERTIFY |
| Existing foundation | Full audit in `docs/path-1/m1-01-current-repo-truth.md` |
| Expected change | None (documentation delivered) |
| New resource expected | NO |
| Migration expected | NO |
| Performance impact | None |

---

### M1-01A — Repository-Native Roadmap Reconciliation

| Field | Value |
| --- | --- |
| Status | **COMPLETE (PASS)** |
| Strategy | CERTIFY / REMOVE_AS_ALREADY_PRESENT (greenfield assumptions) |
| Existing foundation | M1-01 truth + v1 phase plan |
| Expected change | Canonical `docs/path-1/path-1-phase-breakdown.md` + minimal handoff update |
| New resource expected | NO |
| Migration expected | NO |
| Performance impact | None |
| Deliverable | `docs/path-1/path-1-phase-breakdown.md` |

---

### M1-02 — Source-Scoped External Identity Contract

| Field | Value |
| --- | --- |
| Status | **COMPLETE (PASS)** |
| Strategy | CERTIFY + EXTEND (contract lock) |
| Existing foundation | SourceSystem; Event external DB unique; ProductMapping uniques; Order `unique_source_order`; OrderItem `unique_order_line`; DiscoveryIntegrity producer verify |
| Expected change | Lock vocabulary for three source layers + external IDs; document lookup paths; Ash identity for Event external ID if required; webhook multi-source routing policy note |
| New resource expected | NO |
| Migration expected | NO (contract only; implementation gaps deferred) |
| Performance impact | Index review only — no speculative indexes |
| Deliverable | `docs/path-1/m1-02-source-scoped-external-identity-contract.md` |

Must lock (using repository field names):

```text
internal_source_pk / canonical_source_key / producer_source_system_id

Event:
  (source_system_id, external_event_kind, external_event_id)

Product (logical):
  (source_system_id, woo_product_id) via ProductMapping / TicketType

Variation (logical):
  (source_system_id, woo_product_id, woo_variation_id)

Order:
  (source_system_id, woo_order_id)

OrderItem:
  (order_id, woo_line_item_id)
  — conceptually source-scoped through Order.source_system_id
```

**STOP** if a proposed unique constraint would invalidate legitimate existing data without an explicit migration plan.

---

### M1-03 — Event → Product → Variation → OrderLine Attribution Contract

| Field | Value |
| --- | --- |
| Status | **COMPLETE (PASS)** |
| Strategy | CERTIFY (primary) / EXTEND (documentation gaps only) |
| Contract | `docs/path-1/m1-03-event-product-variation-orderline-attribution-contract.md` |
| Existing foundation | OrderAttributionResolver, MappingResolver, OrderItemMapper, AutomaticMappingPolicy, protect_mapped_source_identity, ProductMapping, TicketType |
| Expected change | Lock event-first + ProductMapping fallback + immutability + conflict reasons as the Path 1 contract; clarify TicketType vs ProductMapping dual fields |
| New resource expected | NO (do not invent Product / Event*Link) |
| Migration expected | NO |
| Performance impact | None at contract stage |
| Known REQUIRED_BEFORE_M2 gap | TicketType variation-parent fail-closed enforcement (G1) — **not resolved**; inventory at M1-09 |

Locks current bridge:

```text
OrderItem
  → source_tickera_event_id → Event (event-first)
  → TicketType within event
  → ProductMapping review context
else
  → ProductMapping fallback
```

---

### M1-04 — Order Lifecycle and Recognised-Sale Contract

| Field | Value |
| --- | --- |
| Status | **COMPLETE (PASS)** |
| Strategy | CERTIFY |
| Contract | `docs/path-1/m1-04-order-lifecycle-and-recognised-sale-contract.md` |
| Existing foundation | WoocommerceOrderParser statuses; Order status atoms; MetricRules.counts_as_sold?; AutomaticMappingPolicy |
| Expected change | Lock status matrix (recognised sale/revenue/visibility/mapping eligibility) matching current MetricRules |
| New resource expected | NO |
| Migration expected | NO |
| Performance impact | None |

Recognised sale locked: completed + mapped + ticket + qty > 0 → revenue from `OrderItem.line_total`.

---

### M1-05 — Refund and Financial Adjustment Contract

| Field | Value |
| --- | --- |
| Status | **COMPLETE (PASS)** |
| Strategy | NEW CONTRACT REQUIRED |
| Contract | `docs/path-1/m1-05-refund-and-financial-adjustment-contract.md` |
| Existing foundation | Order status `:refunded` only; no Refund/RefundLine resources; parser ignores Woo `refunds` array |
| Expected change | Design refund/partial-refund/adjustment semantics, idempotency, timestamps, and analytics impact — **without pre-deciding Ash resources** |
| New resource expected | TBD (contract first) |
| Migration expected | TBD after contract |
| Performance impact | Contract must keep money Decimal/numeric; no float |

Gross preserved + independent refund adjustments locked. MetricRules IMPLEMENTATION_CHANGE_REQUIRED (carry forward; do not fix in M1-06 documentation alone). M3 implements only what this contract authorizes.

---

### M1-06 — Financial Metric Dictionary

| Field | Value |
| --- | --- |
| Status | **COMPLETE (PASS)** |
| Strategy | CERTIFY + EXTEND METRIC CONTRACT |
| Contract | `docs/path-1/m1-06-financial-metric-dictionary.md` |
| Existing foundation | MetricRules; Order.raw_*; OrderItem.line_*; Decimal types; M1-05 refund primitives |
| Expected change | Lock named Gross/Refund/Net qty & value, Order Count, ATV, exclusions, currency, additivity |
| New resource expected | NO |
| Migration expected | NO in M1-06; MG1 `line_total_tax` persistence during M3 |
| Performance impact | Metrics must remain computable from bounded aggregates later |

TAX-INCLUSIVE REVENUE CONTRACT: IMPLEMENTATION_CHANGE_REQUIRED (`line_total + line_total_tax`; current `line_total` alone is tax-exclusive). MetricRules IMPLEMENTATION_CHANGE_REQUIRED. Do not implement MG1–MG8 in M1-07.

---

### M1-07 — Timestamp, Johannesburg Period and Freshness Contract

| Field | Value |
| --- | --- |
| Status | **REQUIRES OWNER AUTHORIZATION** |
| Strategy | NEW CONTRACT REQUIRED (resolve open conflict) |
| Existing foundation | created_at_source, updated_at_source, completed_at; MetricRules uses completed_at for “today”; HotStateAggregator 5‑min stale clock; programme 10‑min stale |
| Expected change | Lock payment vs completion vs freshness clocks; **resolve OPEN M1-07 CONTRACT CONFLICT** (5m vs 10m); no `date_paid` field exists today |
| New resource expected | NO |
| Migration expected | TBD if new timestamp fields authorized |
| Performance impact | Freshness must not require Woo REST from LiveView |

---

### M1-08 — Backfill Completeness, Reconciliation and ANALYTICS_READY Contract

| Field | Value |
| --- | --- |
| Strategy | NEW CONTRACT REQUIRED |
| Existing foundation | SyncRun/SyncCursor catch-up; Tickera attendee reconciliation (not financial); no Path 1 financial reconcile module |
| Expected change | Lock completeness watermark, distinguish Woo catch-up vs Tickera attendee vs Path 1 financial reconciliation, define ANALYTICS_READY gate |
| New resource expected | TBD |
| Migration expected | TBD |
| Performance impact | Completeness checks must be bounded / indexed |

Clearly separate:

```text
A. Woo order catch-up / SyncRun reconciliation
B. Tickera attendee vs local-order reconciliation
C. Path 1 financial source-vs-EventSales reconciliation (MISSING today)
```

---

### M1-09 — M1 Certification Pack

| Field | Value |
| --- | --- |
| Strategy | CERTIFY |
| Existing foundation | M1-02..M1-08 contract docs + tests as required |
| Expected change | Pack proving all M1 contracts locked; consolidate evidence-backed implementation gaps into a mandatory **PRE-M2 CONTRACT IMPLEMENTATION GATE**; no dashboard/backfill implementation |
| New resource expected | NO |
| Migration expected | NO |
| Performance impact | None |

M1-09 must inventory unresolved REQUIRED_BEFORE_M2 gaps (including M1-03 G1 TicketType variation-parent fail-closed). If required gaps remain, authorise a small **M1-C** corrective implementation gate before M2 — do not bounce into implementation during each contract task.

### M1 MUST NOT implement

Dashboards, historical backfill workers as production features, Apply/AutoApply, Phase 5E, parallel order writers, Cachex, Refund resources before M1-05 contract. Do not implement M1-03 G1 during M1-04..M1-08.

### M1 Completion Gate

All M1-02..M1-09 contracts locked and certified. REQUIRED_BEFORE_M2 gaps inventoried; M1-C completed if required. M2 unauthorized until then.

---

## 9. M2 — Operator Event / Product / Variation Onboarding

### Objective (unchanged)

```text
one exact existing Tickera event
→ exact relevant product mappings
→ exact variations
→ zero cross-contamination
→ BACKFILL_PENDING
```

Rewrite as **extension/certification of Catalog foundations**, not a replacement catalogue domain.

| Task | Strategy | Existing foundation | Expected change | New resource | Migration | Performance |
| --- | --- | --- | --- | --- | --- | --- |
| M2-01 Exact Source/Event Resolution | CERTIFY / EXTEND | SourceSystem, Event external identity, DiscoveryIntegrity | Operator selection of exact source+event; use three source layers | NO | NO | Bounded lookup by source+external id |
| M2-02 Idempotent Local Event Import/Link | REUSE / EXTEND | Event create/update; DB unique external event | Idempotent link/import without fuzzy match | NO | TBD | Unique index already present |
| M2-03 Authoritative Event-Product Discovery | REUSE / EXTEND | ProductMapping, TicketType, native-v3 evidence patterns | Onboard only exact products for selected event | NO | TBD | Bounded discovery; no Apply automation required |
| M2-04 Parent Product Identity Protection | CERTIFY / EXTEND | ProductMapping woo_product_id; TicketType external_product_id | Fail closed on parent mismatch | NO | NO | Local validation only |
| M2-05 Variation Discovery | REUSE / EXTEND | ProductMapping with woo_variation_id; TicketType :woo_variation | Exact variations for selected parents | NO | TBD | Bounded |
| M2-06 Variation-Parent Validation | CERTIFY / EXTEND | Existing variation-parent integrity work | Lock fail-closed validation for Path 1 onboarding | NO | NO | Local |
| M2-07 Event Onboarding State Machine | NEW / EXTEND | Event.status; dashboard settings | BACKFILL_PENDING and related states as contracted | TBD | TBD | State transitions local |
| M2-08 Structural Certification | CERTIFY | Onboarded event+mappings | Prove zero cross-contamination | NO | NO | — |

### M2 Performance & Scaling Review

Postgres owns identity truth. Do not use Redis/ETS/Cachex/GenServer as identity authority. LiveView must not call WooCommerce REST inline.

### M2 STOP

Fuzzy name matching as authority; creating Product/ProductVariation resources without M1 authorization; Apply/AutoApply; cross-event contamination.

---

## 10. M3 — Historical Sales Backfill

### Objective

Import durable historical orders for onboarded events using **existing parser + OrderUpserter**.

| Task | Strategy | Existing foundation | Expected change | New resource | Migration | Performance |
| --- | --- | --- | --- | --- | --- | --- |
| M3-01 Bounded Historical Range | EXTEND | Product decisions (event creation date bound); SyncRun date_from/to | Operator-previewed bounds per event | NO | NO | Bounded Woo pages |
| M3-02 Durable SalesImportRun | EXTEND / REMOVE_AS_ALREADY_PRESENT | **SyncRun + SyncCursor** already track source, event, dates, cursor, status, counts | Prefer extending SyncRun over new SalesImportRun unless M1-08 requires distinct semantics | TBD | TBD | One-active-run guard missing today — EXTEND |
| M3-03 Idempotent Woo Order Import | REUSE | WoocommerceOrderParser, OrderUpserter, Order identity | Wire backfill pages through same writer | NO | NO | Oban unique per run; DB unique order |
| M3-04 Order-Line Import | REUSE | OrderItem upsert in OrderUpserter | Preserve woo product/variation IDs, money, source_tickera_event_id | NO | NO | Line unique (order_id, woo_line_item_id) |
| M3-05 Refund / Cancellation Import | NEW (after M1-05) | Status `:refunded` only | Implement **only** M1-05 authorized model | TBD | TBD | Idempotent; Decimal money |
| M3-06 Deterministic Event Attribution | REUSE | OrderItemMapper pipeline post-upsert | Ensure backfill runs mapper; no parallel attribution writer | NO | NO | Local catalog lookups |
| M3-07 Oban Backfill / Checkpoint / Retry | REUSE / EXTEND | ReconcileOrdersWorker, OrderReconciliation, ManualSync | Historical mode / watermark advancement | TBD | TBD | Paged; Oban unique sync_run_id |
| M3-08 Backfill Completeness Certification | NEW | — | Completeness watermark for ANALYTICS_READY / targets | TBD | TBD | Durable watermark read |

### M3 Performance & Scaling Review

```text
Truth: cold Postgres via OrderUpserter
Overlap: Oban unique on sync_run_id; add active SyncRun uniqueness if contracted
Pagination: existing modified_after/before + orderby=modified
Do not bypass OrderUpserter
```

### M3 STOP

Parallel sales writer; unbounded Woo history; implementing refunds beyond M1-05; Apply/AutoApply.

---

## 11. M4 — Financial Reconciliation

### Objective

Prove source financial totals match EventSales before ANALYTICS_READY.

**Do not automatically create `EventSales.Reconciliation`.** Prefer Ingestion patterns + new contract resources only if M1-08 requires them.

| Task | Strategy | Existing foundation | Expected change | New resource | Migration | Performance |
| --- | --- | --- | --- | --- | --- | --- |
| M4-01 Authoritative Source Totals | NEW | WooCommerceClient (worker-only) | Bounded source total extraction per contract | TBD | TBD | Max concurrency 2 |
| M4-02 EventSales Totals | REUSE / EXTEND | Order/OrderItem decimals; MetricRules | Deterministic platform totals from durable rows | NO | TBD | Indexed event/date paths |
| M4-03 Deterministic Comparison | NEW | — | Compare source vs platform per M1-06/M1-08 | TBD | TBD | Bounded |
| M4-04 Mismatch Diagnostics | NEW | — | Fail closed with actionable diagnostics | TBD | TBD | — |
| M4-05 Reconciliation Audit Record | NEW / EXTEND | TickeraReconciliation* is **not** financial — do not overload it | Durable financial reconcile run/finding if contracted | TBD | TBD | Distinct from attendee recon |
| M4-06 ANALYTICS_READY Gate | NEW | — | Block analytics trust on mismatch | TBD | TBD | Gate read is cheap |
| M4-07 Reconciliation Certification | CERTIFY | — | Prove gate behaviour | NO | NO | — |

Distinguish always:

```text
A. Woo catch-up (SyncRun) — ingestion completeness
B. Tickera attendee reconciliation — quantity/data-quality
C. Path 1 financial reconciliation — money truth (this phase)
```

### M4 STOP

Silent mismatch clearance; treating attendee recon as financial recon; LiveView Woo calls.

---

## 12. M5 — Analytics Read Model

### Objective

Trusted bounded projections for management — **reuse current Analytics infrastructure**.

| Task | Strategy | Existing foundation | Expected change | New resource | Migration | Performance |
| --- | --- | --- | --- | --- | --- | --- |
| M5-01 Base Event Aggregates | REUSE / EXTEND | EventAggregateSnapshot, EventAggregator, MetricRules | Align with M1-06/M4 truth | TBD | TBD | Event-scoped |
| M5-02 Ticket/Product/Variation Aggregates | EXTEND | OrderItem event/ticket fields; ProductMapping IDs | Dimension aggregates without Product resources | TBD | TBD | Bounded cardinality |
| M5-03 Revenue / Refund Aggregates | EXTEND | MetricRules completed revenue; refund model per M1-05 | Include authorized refund adjustments | TBD | TBD | Decimal only |
| M5-04 Period Comparisons | EXTEND | DailySalesAggregateSnapshot; business timezone | Johannesburg periods per M1-07 | TBD | TBD | Pre-aggregated |
| M5-05 Deterministic Sales Velocity | NEW / EXTEND | Hot summaries | Velocity metrics from aggregates/hot state | TBD | TBD | No raw scans |
| M5-06 Capacity / Occupancy | NEW / EXTEND | Event capacity fields if present | Occupancy from sold vs capacity | TBD | TBD | Event-scoped |
| M5-07 Freshness and Data-Quality Projection | EXTEND | HotStateAggregator lifecycle; stale banner | Conform to **M1-07 decision** (open 5m vs 10m conflict) | NO | TBD | PubSub |
| M5-08 Hot/Warm/Cold Caching | REUSE / EXTEND / REMOVE_AS_ALREADY_PRESENT | **ETS DashboardCache + Redis warm + Postgres cold**; RebuildHotStateWorker; single-flight; OrderProcessedNotifier; DashboardPubSub | Extend TTLs/keys as needed; **do not add Cachex** | NO | NO | Preserve stampede protection |
| M5-09 Analytics Certification | CERTIFY | — | Projections match M4 reconciled totals | NO | NO | — |

### M5-08 rename note

v1 title “Cachex / ETS / Redis Caching” → **Hot/Warm/Cold Caching (ETS + Redis)**. Cachex is not a Path 1 dependency.

### M5 Performance & Scaling Review

Target sub-100ms common management reads from hot/warm where practical. Rebuild SoT remains Postgres. Invalidate by event (and contracted windows), not global flush.

### M5 STOP

Cachex dependency; peak full-table scans; analytics diverging from M4; resolving freshness conflict without M1-07.

---

## 13. M6 — Management Dashboard

### Objective

Read-only management product. Treat existing admin / event / event-scoped dashboards as foundations.

| Task | Strategy | Existing foundation | Expected change | New resource | Migration | Performance |
| --- | --- | --- | --- | --- | --- | --- |
| M6-01 Read-Only Management Role / Policy | REUSE / EXTEND | Accounts.Policies, roles, EventAccessGrant, EventDashboardSetting | Harden read-only management posture; no catalogue mutation | TBD | TBD | Policy checks local |
| M6-02 Executive Dashboard | EXTEND | AdminDashboard LiveView foundations | Trusted cards from analytics projections | NO | NO | Hot/warm reads |
| M6-03 Event Performance Table | EXTEND | Existing event tables/components | Bounded event list metrics | NO | NO | Aggregates only |
| M6-04 Event Drill-Down | EXTEND | EventDetail / EventScopedDashboard | Freshness + quality + metrics | NO | NO | Event-scoped PubSub |
| M6-05 Bounded Filters | EXTEND | Existing filter patterns | Enforce max ranges/cardinality | NO | NO | Reject unbounded scans |
| M6-06 Freshness / Stale UX | EXTEND | stale_data_banner; manual refresh rate limiter | Align UX copy/thresholds to M1-07 | NO | NO | Manual refresh queues Oban, not Woo |
| M6-07 PubSub / LiveView Updates | REUSE / EXTEND | DashboardPubSub | Keep auto-update on hot_state_updated | NO | NO | Event topics |
| M6-08 Read-Only Certification | CERTIFY | — | Prove no Apply/PII/catalogue mutation | NO | NO | — |

Preserve:

```text
read-only management
no catalogue mutation
no Apply / AutoApply
no unnecessary PII
```

### M6 STOP

Inline WooCommerce from LiveView; treating stale as live; catalogue Apply from management UI.

---

## 14. M7 — Production Certification & Pilot

### Objective

Distinct release gate. Failure tests must match **actual** ETS/DashboardCache/Redis architecture (not Cachex).

| Task | Strategy | Existing foundation | Expected change | New resource | Migration | Performance |
| --- | --- | --- | --- | --- | --- | --- |
| M7-01 Production Source Certification | CERTIFY | Source identity contracts | Production source binding proof | NO | NO | — |
| M7-02 Production Event Backfill Certification | CERTIFY | M3 watermarks | Selected public events certified | NO | NO | — |
| M7-03 Production Source/Platform/Dashboard Reconciliation | CERTIFY | M4 + M5 + M6 | End-to-end number trust | NO | NO | — |
| M7-04 Production RBAC Certification | CERTIFY | Accounts policies | Role/grant proof | NO | NO | — |
| M7-05 Failure / Recovery Certification | CERTIFY / EXTEND | HotStateAggregator restore, Redis warm, Oban workers | Test ETS loss, Redis miss, rebuild, stale source — **not Cachex loss** | NO | NO | Recovery bounded |
| M7-06 Analytics Performance Certification | CERTIFY | Aggregates + caches | Sub-100ms / no peak scans where contracted | NO | NO | — |
| M7-07 Limited Management Pilot | CERTIFY | M6 | Controlled pilot | NO | NO | — |
| M7-08 Path 1 Production Certification Record | CERTIFY | — | Durable certification doc | NO | NO | — |

### M7 STOP

Pilot while ANALYTICS_READY false; Cachex-centric tests; Path 2 Apply during pilot.

---

## 15. Path 1 Performance & Scaling Rules (repository-native)

### Data layers

```text
Hot:  ETS / DashboardCache / HotStateAggregator
Warm: Redis
Cold: Postgres
```

Cachex is **not** part of Path 1.

### High-concurrency safety

Evaluate optimistic locking, worker uniqueness, DB uniqueness, bounded retries, idempotency, critical indexes on write paths. Do not force seat-hold infrastructure into analytics.

### Real-time

Phoenix PubSub + LiveView push; Oban for heavy work; no browser polling as primary; no LiveView Woo REST.

### Analytics

Prefer aggregates / hot summaries; avoid peak-time table scans; filters must be bounded.

### Cache safety

Namespaced keys (`CacheKeys`); targeted invalidation; single-flight rebuild; define stale behaviour per M1-07.

---

## 16. Updated TOON Sequence (execution order)

### M1 — Truth & Identity

| ID | Task |
| --- | --- |
| M1-01 | Repository identity and writer audit — **COMPLETE** |
| M1-01A | Repository-native roadmap reconciliation — **COMPLETE** |
| M1-02 | Source-scoped external identity contract — **COMPLETE** |
| M1-03 | Attribution contract (certify current architecture) — **COMPLETE** |
| M1-04 | Order lifecycle / recognised-sale contract — **COMPLETE** |
| M1-05 | Refund / financial adjustment contract — **COMPLETE** |
| M1-06 | Financial metric dictionary — **COMPLETE** |
| M1-07 | Timestamp / Johannesburg period / freshness (resolve 5m vs 10m) — **REQUIRES OWNER AUTHORIZATION** |
| M1-08 | Completeness / reconciliation / ANALYTICS_READY |
| M1-09 | M1 certification pack |

### M2 — Event Onboarding

| ID | Task |
| --- | --- |
| M2-01..M2-08 | Extend/certify Catalog foundations through structural certification |

### M3 — Historical Sales

| ID | Task |
| --- | --- |
| M3-01 | Bounded historical range |
| M3-02 | Durable import run (prefer SyncRun EXTEND) |
| M3-03 | Idempotent Woo order import via OrderUpserter |
| M3-04 | Order-line import via existing upsert |
| M3-05 | Refund/cancellation import per M1-05 |
| M3-06 | Deterministic attribution via existing mapper |
| M3-07 | Oban checkpoint/retry EXTEND |
| M3-08 | Completeness certification |

### M4 — Reconciliation

| ID | Task |
| --- | --- |
| M4-01..M4-07 | Path 1 **financial** reconciliation (not attendee recon; no new domain by default) |

### M5 — Analytics

| ID | Task |
| --- | --- |
| M5-01..M5-07 | Aggregates / velocity / occupancy / freshness projection |
| M5-08 | ETS + Redis hot/warm (no Cachex) |
| M5-09 | Analytics certification |

### M6 — Management Product

| ID | Task |
| --- | --- |
| M6-01..M6-08 | Extend existing dashboards; read-only certification |

### M7 — Production Certification

| ID | Task |
| --- | --- |
| M7-01..M7-08 | Production gates; failure tests for ETS/Redis/Oban recovery |

---

## 17. Path 1 Definition of Done (updated checks)

```text
[x] M1-01 repository truth exists
[x] Roadmap is repository-native (this file)
[x] M1-02 source-scoped external identity contract locked
[x] M1-03 attribution contract locked
[x] M1-04 order lifecycle / recognised-sale contract locked
[x] M1-05 refund / financial-adjustment contract locked
[x] M1-06 financial metric dictionary locked
[ ] M1-07..M1-09 contracts locked
[ ] Existing Catalog/Sales/Ingestion/Analytics/Accounts reused
[ ] Existing parser/OrderUpserter reused (no parallel writer)
[x] Attribution certifies event-first + ProductMapping fallback
[x] Refund contract exists before refund object implementation
[ ] Financial reconciliation distinct from Tickera attendee recon
[ ] Hot/warm/cold = ETS + Redis + Postgres (no mandatory Cachex)
[ ] Freshness contract resolves OPEN M1-07 CONFLICT
[ ] Management read-only; no Apply/AutoApply
[ ] ANALYTICS_READY blocks on financial mismatch
[ ] Production certification recorded
```

---

## 18. Final Execution Order

```text
P1-00 COMPLETE
→ M1-01 COMPLETE
→ M1-01A COMPLETE
→ M1-02 COMPLETE
→ M1-03 COMPLETE
→ M1-04 COMPLETE
→ M1-05 COMPLETE
→ M1-06 COMPLETE
→ M1-07 (requires owner authorization) … M1-09
→ M1-C (only if M1-09 PRE-M2 gate requires corrective implementation)
→ M2
→ M3
→ M4
→ M5
→ M6
→ M7
```

```text
Path 2 / Phase 5E remain PAUSED unless explicitly authorized.
```

---

## 19. Phase Status Closeout

```text
P1-00:
COMPLETE

M1-01:
COMPLETE (PASS)

M1-01A:
COMPLETE (PASS)

M1-02:
COMPLETE (PASS)

M1-03:
COMPLETE (PASS)

M1-03 contract:
docs/path-1/m1-03-event-product-variation-orderline-attribution-contract.md

M1-04:
COMPLETE (PASS)

M1-04 contract:
docs/path-1/m1-04-order-lifecycle-and-recognised-sale-contract.md

M1-05:
COMPLETE (PASS)

M1-05 contract:
docs/path-1/m1-05-refund-and-financial-adjustment-contract.md

M1-06:
COMPLETE (PASS)

M1-06 contract:
docs/path-1/m1-06-financial-metric-dictionary.md

TAX-INCLUSIVE REVENUE CONTRACT:
IMPLEMENTATION_CHANGE_REQUIRED

Known REQUIRED_BEFORE_M2 gap:
TicketType variation-parent fail-closed enforcement (unresolved; defer to M1-09 PRE-M2 gate)

Known M1-05/M1-06 carry-forward gaps (unresolved):
MG1 persist OrderItem.line_total_tax REQUIRED_DURING_M3 (before authoritative Gross Ticket Sales; not M2)
MG2–MG8 refund-aware Gross/Net, distinct Order Count, ATV, currency partitioning, MetricRules/snapshot changes REQUIRED_BEFORE_M5
refund persistence/import REQUIRED_DURING_M3; refund completeness BEFORE_M4

Current Path 1 task:
M1-07 — Timestamp, Johannesburg Period and Freshness Contract

M1-07:
REQUIRES OWNER AUTHORIZATION

Path 2:
PAUSED

Phase 5E:
PAUSED

Identity contract:
docs/path-1/m1-02-source-scoped-external-identity-contract.md

Attribution contract:
docs/path-1/m1-03-event-product-variation-orderline-attribution-contract.md

Lifecycle / recognised-sale contract:
docs/path-1/m1-04-order-lifecycle-and-recognised-sale-contract.md

Refund / financial-adjustment contract:
docs/path-1/m1-05-refund-and-financial-adjustment-contract.md

Financial metric dictionary:
docs/path-1/m1-06-financial-metric-dictionary.md

DO NOT START M1-07 WITHOUT OWNER AUTHORIZATION.
USE A FRESH AGENT FOR M1-07.
DO NOT IMPLEMENT line_total_tax, MetricRules, snapshots, or refunds in M1-07.
```
