Document:
Path 1 M1-08 Backfill Completeness, Financial Reconciliation and ANALYTICS_READY Contract

Baseline:
bce4cc07cf08521486d81c6aabba4621e0650fa3

origin/main:
bce4cc07cf08521486d81c6aabba4621e0650fa3

Contract date:
2026-08-09

Verdict:
PASS

Authority:
NEW CONTRACT DOCUMENTATION (no production code)

---

# Path 1 M1-08 — Backfill Completeness, Financial Reconciliation and ANALYTICS_READY Contract

| Field | Value |
| --- | --- |
| Document | Historical coverage, completeness watermarks, financial reconciliation, and ANALYTICS_READY certification contract |
| Plan ID | `m1-08-backfill-completeness-reconciliation-and-analytics-ready-contract` |
| Plan version | `v1` |
| Status | LOCKED for Path 1 completeness / financial reconciliation / ANALYTICS_READY gates — M1-08 COMPLETE (PASS) |
| Scope | Coverage bounds; watermarks; ORDER/REFUND completeness; attribution readiness; financial recon A≠B≠C; ANALYTICS_READY predicate; certified-through / invalidation; M2–M5 gates; C1–C36; gap ledger |
| Identity input | `docs/path-1/m1-02-source-scoped-external-identity-contract.md` (immutable) |
| Attribution input | `docs/path-1/m1-03-event-product-variation-orderline-attribution-contract.md` (immutable) |
| Lifecycle input | `docs/path-1/m1-04-order-lifecycle-and-recognised-sale-contract.md` (immutable) |
| Refund input | `docs/path-1/m1-05-refund-and-financial-adjustment-contract.md` (immutable) |
| Metric input | `docs/path-1/m1-06-financial-metric-dictionary.md` (immutable) |
| Timestamp / freshness input | `docs/path-1/m1-07-timestamp-johannesburg-period-and-freshness-contract.md` (immutable) |
| Repository truth | `docs/path-1/m1-01-current-repo-truth.md` |
| Product authority | `docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md` §§4, 6, 8 |
| Execution roadmap | `docs/path-1/path-1-phase-breakdown.md` |
| Strategy | NEW CONTRACT REQUIRED + REUSE Sync/Reconciliation foundations where appropriate — documentation only |

### Revision log

- `v1` — initial locked completeness / financial reconciliation / ANALYTICS_READY contract at baseline `bce4cc07cf08521486d81c6aabba4621e0650fa3`

### Conflict rule

```text
This contract wins for Path 1:
  historical coverage / completeness watermarks
  ORDER_COMPLETE / REFUND_COMPLETE predicates
  Path 1 financial reconciliation (concept C)
  ANALYTICS_READY derived certification
  readiness blocking reasons
  certified_through / invalidation / post-cert live data
  BACKFILL_PENDING / M3–M5 entry gates

M1-02 wins for identity tuples.
M1-03 wins for attribution / mapping_status (including G1 timing).
M1-04 wins for recognised-sale predicate.
M1-05 wins for refund identity / binding / completeness inputs (R24).
M1-06 wins for named Gross/Refund/Net formulas and MG1–MG8 timing.
M1-07 wins for effective clocks, Johannesburg periods, and freshness/stale operators.

This document does not revise M1-02..M1-07 locked predicates or formulas.
It does not create AnalyticsReady / certification physical resources.
```

---

## 1. Contract Metadata / Baseline

```text
branch: main
HEAD: bce4cc07cf08521486d81c6aabba4621e0650fa3
origin/main: bce4cc07cf08521486d81c6aabba4621e0650fa3
worktree at start: CLEAN
P1-00 / M1-01 / M1-01A / M1-02 / M1-03 / M1-04 / M1-05 / M1-06 / M1-07: COMPLETE
Path 2 / Phase 5E: PAUSED
```

Preflight evidence: `HEAD == origin/main`, clean worktree, on `main`, baseline matches authorized SHA.

M1-07 contract present and COMPLETE (PASS) at
`docs/path-1/m1-07-timestamp-johannesburg-period-and-freshness-contract.md`.

Evidence classes used below:

```text
REPOSITORY EVIDENCE
PRODUCT DECISION
CONTRACT DECISION
IMPLEMENTATION GAP (classified; not implemented here)
```

---

## 2. Executive Verdict

```text
M1-08 = PASS

Three reconciliation concepts A / B / C are separated and locked.
Initial historical coverage is bounded [BACKFILL_START, BACKFILL_CUTOFF]
  for selected currently-public events only.
ORDER_COMPLETE ≠ SyncRun.status == :completed alone.
REFUND_COMPLETE ≠ Order.status == :refunded alone.
Path 1 financial reconciliation compares equivalent ticket-scoped
  additive primitives under exact Decimal equality.
ANALYTICS_READY is derived from durable Postgres evidence — never a
  manual checkbox, cache rebuild, or PubSub delivery.
ANALYTICS_READY ≠ M1-07 freshness state.
Tickera attendee reconciliation is DIAGNOSTIC for Path 1 financial
  analytics (not a substitute for financial reconciliation).
Physical AnalyticsReady resource form remains TBD (M3/M4/M5).
```

---

## 3. Locked Inputs from M1-02..M1-07

Consumed unchanged:

| Contract | Locked inputs used by M1-08 |
| --- | --- |
| **M1-02** | Source-scoped Order/OrderItem/Event identity; unknown identity fails closed |
| **M1-03** | `mapping_status` vocabulary; unresolved potentially-ticket lines must not silently vanish; G1 TicketType variation-parent fail-closed = REQUIRED_BEFORE_M2 |
| **M1-04** | Recognised sale = completed + mapped ticket + qty > 0 |
| **M1-05** | Refund objects = financial truth; R24 REFUND_COMPLETE inputs; status `:refunded` insufficient |
| **M1-06** | Tax-inclusive Gross = `line_total + line_total_tax` (MG1); additive qty/value primitives; currency partition; ATV derived; MG2–MG8 before M5 |
| **M1-07** | Sale clock paid→completed→WITHHOLD; refund `date_created_gmt`; freshness `<5m` / `>10m`; refresh ≠ fresh; PubSub ≠ truth |

---

## 4. Reconciliation Vocabulary — A/B/C

**CONTRACT DECISION (C1)**

| Concept | Question | Existing foundation | Role in ANALYTICS_READY |
| --- | --- | --- | --- |
| **A. Woo Order Catch-Up / Transport Completeness** | Have all relevant Woo order/refund source records for the certified scope/boundary been durably discovered and processed? | `SyncRun`, `SyncCursor`, `OrderReconciliation`, `ReconcileOrdersWorker`, `OrderUpserter` | Required input to ORDER_COMPLETE / coverage watermark — **not** financial equality |
| **B. Tickera Attendee Reconciliation** | How do local ticket-sale facts compare with Tickera attendee/check-in evidence? | `TickeraReconciliationRun`, findings, attendee snapshots | **DIAGNOSTIC** for Path 1 financial analytics — see §17 |
| **C. Path 1 Financial Reconciliation** | For one exact source/event/currency/coverage boundary, do EventSales certified financial primitives agree with authoritative Woo source financial facts? | **MISSING** as first-class capability today | May **PASS** or **FAIL** ANALYTICS_READY |

### 4.1 Repository evidence — A

```text
SyncRun tracks scoped Woo order sync: source_system_id, event_id, date_from/date_to,
status, counts (sync_run.ex:1-4,153-158,211-220,165-205)
SyncCursor: per-run page, modified_after/before, status active|done|failed
  (sync_cursor.ex:1-4,82-109); unique sync_run_id (sync_cursor.ex:23-26,78-79)
OrderReconciliation: one page per step; modified window; OrderUpserter
  (order_reconciliation.ex:1-7,64-73,224-232)
ReconcileOrdersWorker: Oban unique per sync_run_id (reconcile_orders_worker.ex:6-14)
```

### 4.2 Repository evidence — B

```text
TickeraReconciliationRun with critical/warning/info counts
  (tickera_reconciliation_run.ex:1-4,24-34,47-58)
Findings compare woo paid qty vs Tickera snapshot qty
  (tickera_reconciliation.ex:354-418) — operational/diagnostic, not money
```

### 4.3 Repository evidence — C

```text
No Path 1 financial reconciliation module / resource found under Analytics or Ingestion.
m1-01-current-repo-truth.md marks Path 1 financial reconciliation MISSING.
TickeraReconciliation* must not be overloaded as financial reconciliation
  (path-1-phase-breakdown.md:631-649).
```

**Hard rule:** Do not substitute A or B for C.

---

## 5. Historical Coverage Scope

**PRODUCT DECISION** — `EVENTSALES_PRODUCT_DECISIONS.md:182-185`:

```text
Initial launch backfill: currently public events only
Backfill starts from each selected event's creation date
Private events excluded from initial launch backfill
```

**CONTRACT DECISION (C2)**

Initial Path 1 certified historical range is:

```text
scope =
  exact SourceSystem
  + exact Event (verified M1-02 identity)
  + currently public / selected for launch
  + currency partition(s) under C15

coverage =
  [BACKFILL_START, BACKFILL_CUTOFF]
```

Rules:

```text
Private / draft / non-selected events → EXCLUDED from initial launch certification
Historical source/Event identity must already be verified (M2 structural cert)
Do not automatically choose unbounded Woo history
Do not treat “all orders ever for the store” as the Path 1 launch scope
```

Programme confirmation that local EventSales insert time is **not** sales-truth start:
`current-state-and-path-handoff.md:373-379`.

---

## 6. Backfill Start / Cutoff Contract

### 6.1 Backfill start authority (C3)

**CONTRACT DECISION (C3)**

```text
BACKFILL_START authority =
  selected Tickera event source creation instant
  = WordPress tc_events post post_date_gmt
  for Event.external_event_id under the certified SourceSystem
```

Forbidden silent substitutes:

```text
Event.inserted_at
first EventSales Order created_at / completed_at
first ProductMapping timestamp
Event.starts_at / ends_at (event schedule, not creation)
current wall-clock date
event_source_updated_at / post_modified_gmt alone
```

**REPOSITORY EVIDENCE — persistence gap**

```text
Event attributes: starts_at, ends_at, source_updated_at, last_synced_at, inserted_at
  — no Tickera creation / post_date_gmt field (event.ex:88-143)
Catalog feed events listing selects post_modified_gmt as event_source_updated_at,
  not post_date_gmt (eventsales-tickera-catalog-feed.php:1311-1317,1374)
m1-01 notes missing “backfill from Tickera event creation date” orchestration
  (m1-01-current-repo-truth.md:539)
```

**IMPLEMENTATION GAP (CG1):** Persist durable Tickera event creation instant (`post_date_gmt` or equivalent source-proven field) on Event (or adjacent durable source metadata) before M3 may claim a certified BACKFILL_START. Classification: **REQUIRED_DURING_M3** (must exist before historical range certification; not required for M2 structural onboarding, but required before M3 completeness watermark). M2 may record the intended start once discovered, but must not invent it from local insert time.

### 6.2 Backfill cutoff / high-water (C4)

**CONTRACT DECISION (C4)**

```text
BACKFILL_CUTOFF =
  explicit durable import cutoff instant for the SyncRun / historical import
  (= SyncRun.date_to / SyncCursor.modified_before for transport A)

“Historical backfill complete through X” means:
  all relevant source pages in the modified/created window reaching X
  were processed under ORDER_COMPLETE / REFUND_COMPLETE rules
  AND a completeness watermark records X
```

Replayable boundary options (source-safe):

| Option | Role |
| --- | --- |
| Explicit import cutoff instant | Primary `BACKFILL_CUTOFF` |
| Source modified-time high-water inside the window | Transport progress evidence (`modified_after` advancement / covered-through) |
| Terminal bounded pagination | Page exhausted (`length(orders) < per_page`) + cursor `:done` |

Forbidden as sole proof:

```text
worker completion wall-clock (SyncRun.finished_at alone)
Oban job :ok alone
manual operator assertion
```

Existing catch-up window shape:
`order_reconciliation.ex:224-232` (`modified_after` / `modified_before`, `orderby=modified`).

Terminal page evidence today:
`order_reconciliation.ex:177-183` (deep: page_limit or short page; shallow: one page then done).

---

## 7. Completeness Watermark Contract

**CONTRACT DECISION (C5)**

A historical-completeness watermark is conceptual durable evidence proving **what range** is certified — not that a job once returned `:ok`.

Minimum conceptual fields:

```text
source_system_id
event_id
coverage_start          (= BACKFILL_START)
sales_covered_through   (= sales BACKFILL_CUTOFF / high-water)
refunds_covered_through (= refund coverage boundary; may equal or trail sales)
run / certification identity
terminal cursor / page condition evidence
order_coverage_status   (ORDER_COMPLETE | incomplete | failed)
refund_coverage_status  (REFUND_COMPLETE | incomplete | failed | not_started)
known_unresolved_counts + reasons
certified_at            (certification wall time; audit only — not coverage proof)
ANALYTICS_READY derived flag / blocking reason (projection; see §18–§19)
```

Physical table / Ash resource form: **TBD** (prefer EXTEND SyncRun/SyncCursor + certification projection; do not invent `AnalyticsReady` resource here).

Truth layer: **Postgres**. Redis/ETS may cache a readiness summary later; never authorise it.

---

## 8. Cursor / Retry Safety

**PRODUCT / PROGRAMME RULE** — `EVENTSALES_PRODUCT_DECISIONS.md:194`:

```text
Cursor/progress advances only after durable success
```

**CONTRACT DECISION (C6)**

| Scenario | Required outcome |
| --- | --- |
| Page fetch succeeds, durable writes fail | Do **not** advance cursor; leave run retryable / failed-closed; no skip |
| Some rows succeed, one row fails | Do **not** advance past the failed page until every matched durable write succeeds or is explicitly classified as a blocking failure with inventory; no silent skip |
| Refund details fail after order persistence | Order may remain; refund coverage incomplete; cursor for refund discovery must not claim REFUND_COMPLETE |
| Worker crashes between persistence and checkpoint | Retry-safe: replay same page; OrderUpserter / refund identity prevent duplicate facts |
| Retry after crash | Resume from last durable cursor; no skipped modified range |
| Same page replayed | Idempotent upserts; counts may re-observe but durable facts do not duplicate |

Required outcome class:

```text
retry-safe
no skipped source range
no duplicate durable facts
```

**REPOSITORY EVIDENCE — current gap**

Today `OrderReconciliation.process_order/6` increments `orders_failed_count` on upsert error and continues; `finalize_step/4` still advances page / may complete the run (`order_reconciliation.ex:130-175`). That **violates** the programme cursor-after-success rule for Path 1 historical completeness.

**IMPLEMENTATION GAP (CG2):** Fail-closed page checkpointing for historical / deep backfill — do not advance cursor or mark ORDER_COMPLETE while `orders_failed_count` (or equivalent) indicates unresolved durable write failures on the page. Classification: **REQUIRED_DURING_M3**.

Fetch failures already pause/fail without advancing (`order_reconciliation.ex:185-212`) — certify that pattern for transport errors.

---

## 9. Order Completeness

**CONTRACT DECISION (C7) — ORDER_COMPLETE**

`ORDER_COMPLETE` for a certified scope means **all** of:

```text
1. Exact source + event identity verified
2. Bounded coverage [BACKFILL_START, sales_covered_through] recorded
3. All bounded relevant Woo order pages/ranges for that window processed
4. Terminal cursor reached with source-safe terminal condition
   (short page and/or contracted page bound + cursor status :done)
5. Every relevant Order resolved to locked source identity (M1-02)
   or explicitly classified as a blocking failure with durable inventory
6. All OrderItems processed idempotently through OrderUpserter
7. No silent page/range skips
8. No open write-failure backlog for matched in-scope orders
```

Explicit non-equivalence:

```text
SyncRun.status == :completed
≠
ORDER_COMPLETE
```

Shallow one-page catch-up (`sync_mode: :shallow` → `done_page?` always true — `order_reconciliation.ex:177`) is **not** historical ORDER_COMPLETE for Path 1 launch certification.

---

## 10. Attribution Completeness

**CONTRACT DECISION (C8, C9)** — consume M1-03; do not reopen attribution logic.

| `mapping_status` | Effect on ANALYTICS_READY for selected event scope |
| --- | --- |
| `:mapped` | Non-blocking for attribution completeness (review reasons may remain visible) |
| `:pending_mapping_resolution` | **BLOCKING** if line is potentially ticket / not yet proven non-ticket |
| `:unmapped` | **BLOCKING** for potentially-ticket unresolved inventory |
| `:non_ticket` | Non-blocking for ticket financial analytics when explicitly classified |
| `:ignored` | Non-blocking when intentionally ignored under M1-03 |

Principle:

```text
Known unresolved potentially-ticket sale
must not silently disappear from authoritative financial totals.
```

If a line cannot yet be proven ticket vs non-ticket for the selected event:

```text
treat as blocking unresolved attribution (ATTRIBUTION_INCOMPLETE)
```

### 10.1 Known M1-03 G1 (carry-forward)

```text
TicketType variation-parent fail-closed enforcement
REQUIRED_BEFORE_M2 (m1-03 G1)
```

**CONTRACT DECISION:** A certification claiming **exact** historical variation-parent attribution integrity is **not valid** until G1 is corrected. M1-08 does not fix G1. M1-09 must keep G1 visible in the PRE-M2 implementation ledger. ANALYTICS_READY that asserts exact attribution integrity inherits this dependency (via IDENTITY/ATTRIBUTION readiness), but G1 remains timed **BEFORE_M2**, not as a new M1-08-only gap name.

---

## 11. Refund Completeness

**CONTRACT DECISION (C10)** — compose M1-05 R24:

`REFUND_COMPLETE` for a certified scope means **all** of:

```text
all refund references on in-scope Orders discovered
all refund detail records fetched/processed (pages exhausted)
source refund identities durably represented (M1-05 identity)
all refund lines deterministically bound OR explicitly unresolved
void/delete/correction semantics processed (M1-05)
no pending refund-detail backlog for the certified refund boundary
no duplicate adjustment facts
coverage reaches the certified refunds_covered_through boundary
idempotent replay changes nothing material
```

Non-equivalence:

```text
Order.status == :refunded
≠
REFUND_COMPLETE
```

### 11.1 Refund coverage boundary (C11, C12)

**CONTRACT DECISION (C11, C12)**

```text
sales_covered_through  ≠ forever-final refund cutoff
```

Certification must express separately when needed:

```text
sales covered through X
refund adjustments covered through Y
```

Late / post-cutoff behaviour:

| Case | Effect |
| --- | --- |
| Refund created after original sale cutoff, adjusting an in-scope Order | Extends / requires refund coverage update; financial recon must include it before ANALYTICS_READY remains true |
| Refund discovered after initial backfill | Refund coverage incomplete until processed; may invalidate prior financial PASS |
| Late refund against old Order inside certified sales range | Invalidates refund completeness + financial reconciliation for affected scope until re-certified |
| Refund mutation/void after certification | Invalidates certification for affected period (see §22) |

Do not invent physical schema here.

---

## 12. Timestamp Completeness

**CONTRACT DECISION (C13)** — consume M1-07:

```text
Sale effective: date_paid_gmt → date_completed_gmt → otherwise WITHHOLD
Refund effective: refund date_created_gmt → otherwise WITHHOLD
```

For Path 1 ANALYTICS_READY on a certified scope:

```text
Any relevant recognised sale or refund adjustment inside the certified
coverage range that lacks its authoritative effective timestamp
→ EFFECTIVE_TIME_INCOMPLETE
→ ANALYTICS_READY = false for that scope
```

Do not use insertion/update/ingestion time as substitute (M1-07 T6/T8/T25).

Narrower period displays may withhold individual periods without claiming full-scope ANALYTICS_READY; they must not present incomplete scopes as authoritative management totals.

---

## 13. Financial Primitive Completeness

**CONTRACT DECISION (C14)** — consume M1-06:

Before financial reconciliation may **PASS**, required primitives must exist for the scope:

```text
gross ticket quantity
refund ticket quantity
tax-inclusive gross ticket value   (= line_total + line_total_tax)
ticket refund value
currency
historical attribution (M1-03)
sale effective time (M1-07)
refund effective time (M1-07)
```

Known MG1:

```text
line_total_tax persistence — REQUIRED_DURING_M3
```

Without the tax-inclusive value primitive:

```text
do not certify authoritative Gross/Net financial reconciliation PASS
→ FINANCIAL_PRIMITIVE_INCOMPLETE
```

---

## 14. Currency Partition

**CONTRACT DECISION (C15)**

```text
Financial reconciliation and ANALYTICS_READY financial PASS
are partitioned by currency.
Never reconcile ZAR + USD as one scalar.
No FX conversion is authorized.
Currency mismatch / unknown currency → fail closed
  (CURRENCY_CONFLICT) for affected financial certification.
```

---

## 15. Financial Reconciliation Contract

**CONTRACT DECISION (C16, C17, C18)**

### 15.1 Scope key (C16)

Conceptual reconciliation key:

```text
source_system_id
+ event_id
+ currency
+ coverage_start
+ coverage_cutoff (sales / refunds per §11)
+ ticket-scoped financial primitive set
```

Must compare **equivalent** scopes:

```text
FORBIDDEN: whole Woo order total vs EventSales ticket-only revenue
REQUIRED: isolate ticket facts on both sides (M1-06 exclusions)
```

### 15.2 Primitive set (C17)

Reconcile additive primitives only:

```text
gross ticket quantity
gross tax-inclusive ticket value
refunded ticket quantity
ticket refund value
net ticket quantity   (= gross qty − refunded qty)
net ticket value      (= gross value − refund value)
```

Do **not** use as primary reconciliation primitives:

```text
Average Ticket Value (derived)
summed distinct Order Count across overlapping scopes
```

### 15.3 Exact equality (C18)

```text
same authoritative primitive
same currency
same scope
→ exact Decimal / numeric equality
```

Do not invent fuzzy financial tolerances to force PASS.

If Woo representation/rounding requires a normalization rule, it must be **explicitly source-proven** in a later implementation contract. Until then:

```text
unexplained financial difference → FINANCIAL_RECONCILIATION_FAILED
→ ANALYTICS_READY = false
```

---

## 16. Reconciliation Difference Matrix

**CONTRACT DECISION (C19)**

Conceptual mismatch categories (stable diagnostic atoms; physical enums TBD):

| Category | Meaning |
| --- | --- |
| `MISSING_SOURCE_FACT` | Expected Woo ticket financial fact absent from source extraction |
| `MISSING_LOCAL_FACT` | Source fact present; durable EventSales fact absent |
| `UNRESOLVED_ATTRIBUTION` | Local line cannot enter ticket totals (M1-03 blocking) |
| `MISSING_REFUND_DETAIL` | Refund reference without processed detail |
| `TIMESTAMP_INCOMPLETE` | Missing authoritative effective time |
| `CURRENCY_CONFLICT` | Mixed/unknown/mismatched currency |
| `GROSS_QUANTITY_MISMATCH` | Gross qty inequality |
| `GROSS_VALUE_MISMATCH` | Gross tax-inclusive value inequality |
| `REFUND_QUANTITY_MISMATCH` | Refunded qty inequality |
| `REFUND_VALUE_MISMATCH` | Ticket refund value inequality |
| `NET_QUANTITY_MISMATCH` | Net qty inequality |
| `NET_VALUE_MISMATCH` | Net value inequality |

Every mismatch must remain diagnosable (scope key + category + magnitude + identities). Prefer repository naming when physical findings are designed; do not pre-design Ash enums here.

---

## 17. Tickera Attendee Reconciliation Role

**CONTRACT DECISION (C20)**

```text
ATTENDEE RECONCILIATION ROLE FOR PATH 1 FINANCIAL ANALYTICS:
DIAGNOSTIC
```

Locked rules:

```text
Attendee/check-in counts are not inherently equal to sold ticket quantity.
Concept B must not substitute for concept C.
Concept B findings do not automatically hard-block ANALYTICS_READY
  merely because severity is :critical in TickeraReconciliation.
```

Exception path (still not “attendee equality gates money”):

```text
If a Tickera finding demonstrates unresolved attribution / missing local
sale identity that already falls under M1-03 blocking states
(e.g. unmapped potentially-ticket inventory),
those gaps block via ATTRIBUTION_INCOMPLETE (C8/C9) — not via attendee equality.
```

Severity mapping for Path 1 financial readiness display:

```text
attendee quantity / check-in mismatches → WARNING or INFORMATIONAL UX
attribution incompleteness proven by any path → BLOCKING (M1-03)
financial mismatch (C) → BLOCKING
```

---

## 18. ANALYTICS_READY Predicate

**CONTRACT DECISION (C21)**

`ANALYTICS_READY` is a **derived** certification from durable evidence for an exact scope:

```text
ANALYTICS_READY(scope) = true iff ALL of:
  exact source/event identity verified
  required M1-03 attribution invariants satisfied for the scope
    (including no blocking unresolved potentially-ticket inventory;
     G1 satisfied before any claim of exact variation-parent integrity)
  historical ORDER_COMPLETE for [BACKFILL_START, sales_covered_through]
  REFUND_COMPLETE for refunds_covered_through
  required effective timestamps complete (C13)
  required financial primitives present (C14), including MG1 composition inputs
  financial reconciliation PASS (C) for each currency partition
  no blocking unresolved findings for the scope
  certified coverage boundaries recorded on a durable watermark
```

If any required component is false:

```text
ANALYTICS_READY = false
with an explicit blocking reason (C22)
```

Forbidden definitions:

```text
operator manually checked a box
cache rebuild succeeded
PubSub delivered
SyncRun finished
attendee recon completed
freshness NORMAL
```

---

## 19. Readiness Blocking Reasons

**CONTRACT DECISION (C22)**

Stable conceptual blocking reasons (atoms may map to repository names later):

| Reason | Meaning |
| --- | --- |
| `IDENTITY_NOT_READY` | Source/Event identity not verified |
| `ATTRIBUTION_INCOMPLETE` | Blocking unresolved potentially-ticket attribution |
| `BACKFILL_NOT_STARTED` | Historical import not begun |
| `BACKFILL_IN_PROGRESS` | Historical import running |
| `BACKFILL_FAILED` | Historical import failed closed |
| `ORDER_COVERAGE_INCOMPLETE` | ORDER_COMPLETE false |
| `REFUND_COVERAGE_INCOMPLETE` | REFUND_COMPLETE false |
| `EFFECTIVE_TIME_INCOMPLETE` | Missing paid/completed or refund created-gmt authority |
| `FINANCIAL_PRIMITIVE_INCOMPLETE` | Required M1-06 primitives missing (incl. tax) |
| `FINANCIAL_RECONCILIATION_PENDING` | Recon not yet run / in progress |
| `FINANCIAL_RECONCILIATION_FAILED` | Recon mismatch or unexplained difference |
| `CURRENCY_CONFLICT` | Currency partition failure |

Goal: a manager/operator can see **why** an event is not ready without re-running full reconciliation.

---

## 20. Readiness vs Freshness

**CONTRACT DECISION (C23)**

M1-07 owns:

```text
NORMAL: source age < 5m
AGING:  5m ≤ source age ≤ 10m
STALE:  source age > 10m
```

M1-08 locks:

```text
ANALYTICS_READY ≠ freshness state
```

Example:

```text
historical coverage certified
financial reconciliation PASS
source age 14m

ANALYTICS_READY = true
FRESHNESS = STALE
```

unless a separately proven **active completeness failure** exists (missed range, failed catch-up that leaves coverage incomplete, etc.).

Stale cache/source clock must not erase historical certification.

---

## 21. Certified-Through Boundary

**CONTRACT DECISION (C24)**

```text
certified_through =
  latest financial/reconciliation coverage boundary recorded on the watermark
  (sales_covered_through and refunds_covered_through as applicable)
```

`ANALYTICS_READY` does **not** imply infinite future completeness.

Dashboard may show:

```text
historical certification through X
+ newer live / catch-up data after X
```

Freshness (M1-07) and subsequent catch-up determine how current post-watermark data is. Post-watermark webhook data is **not** historically reconciled merely by arriving live.

---

## 22. Certification Invalidation

**CONTRACT DECISION (C25)**

Events that invalidate readiness or require re-certification:

```text
new blocking source-identity conflict
new unresolved historical attribution in certified range
discovered missed source page/range
refund discovered/mutated inside previously certified period
financial reconciliation later fails
required historical fact corrected in a way that changes certified totals
currency conflict introduced
```

Do **not** invalidate solely because:

```text
source age > 10m
```

Freshness handles that (C23).

---

## 23. Incremental Data After Certification

**CONTRACT DECISION (C26)**

```text
baseline historical certification
+ ongoing incremental ingestion (webhooks)
+ bounded catch-up / reconciliation (concept A)
```

Rules:

```text
Do not require complete historical backfill again for each new webhook.
Do not let successful historical certification permanently hide later
  ingestion / catch-up failures.
A known ongoing gap after certified_through must surface
  (freshness and/or post-watermark completeness signals).
New live sales/refunds after certified_through do not automatically
  inherit historical financial reconciliation PASS for the new interval
  until included in a later bounded recon / extended certification.
```

---

## 24. BACKFILL_PENDING / M3 Completion

### 24.1 BACKFILL_PENDING (C27)

**CONTRACT DECISION (C27)** — M2 target outcome:

```text
BACKFILL_PENDING means ALL of:
  exact SourceSystem selected
  exact Event selected
  required mappings / onboarding structurally certified (M2)
  historical backfill not yet certified ORDER_COMPLETE / REFUND_COMPLETE
```

M2 must **not** perform historical sales ingestion.

### 24.2 M3 completion evidence (C28)

**CONTRACT DECISION (C28)** — M3 must produce before M4 may start:

```text
durable bounded order history for [BACKFILL_START, sales_covered_through]
required tax-inclusive line primitives (MG1)
durable refund history through refunds_covered_through
idempotent refund/order writes
terminal historical coverage evidence (cursor + watermark)
refund completeness evidence
effective sale/refund timestamps persisted
blocking unresolved-item inventory (empty or explicit)
coverage watermark durable in Postgres
```

M3 is not complete merely because a worker finished.

---

## 25. M4 Entry Gate

**CONTRACT DECISION (C29)**

M4 financial reconciliation may begin only when:

```text
historical sales coverage ORDER_COMPLETE
refund coverage REFUND_COMPLETE through required boundary
financial primitives present (incl. MG1)
timestamp primitives present
source/event identity certified
```

If those are false:

```text
M4 reconciliation cannot claim PASS
→ FINANCIAL_RECONCILIATION_PENDING or earlier blocking reason
```

---

## 26. M5 Entry Gate

**CONTRACT DECISION (C30)**

M5 may build **authoritative** financial read models only when:

```text
ANALYTICS_READY is certified for the required event/scope
AND M1-06 MG2–MG8 implementation gaps required for authoritative outputs
  are implemented
```

Do not let M5 build “temporary authoritative” metrics from incomplete refund/tax data.

Non-authoritative operational views remain allowed when clearly labelled (M1-06 refund-incomplete authority).

---

## 27. Refresh / Failure / Retry Boundary

### 27.1 Manual refresh (C31)

**CONTRACT DECISION (C31)**

A manual refresh request:

```text
does not advance completeness
does not advance financial reconciliation
does not make ANALYTICS_READY true
```

Only durable successful work advances evidence. M1-07 freshness rules remain separate (`refresh request ≠ fresh`).

### 27.2 Failure / retry (C32)

**CONTRACT DECISION (C32)**

| Failure | Certification effect |
| --- | --- |
| Source page fetch fails | Pause/retry or fail run; do not advance completeness |
| One page persist fails | Fail-closed checkpoint (C6); no ORDER_COMPLETE |
| Refund detail fetch fails | REFUND_COVERAGE_INCOMPLETE |
| Worker crashes | Retry-safe resume; no duplicate facts |
| Retry succeeds | May advance evidence only after durable success |
| Reconciliation mismatch | FINANCIAL_RECONCILIATION_FAILED; ANALYTICS_READY false |
| Reconciliation infrastructure error | Pending/failed; fail closed — do not invent PASS |
| PubSub delivery fails | Delivery issue only; durable state unchanged |
| Redis unavailable | Display/cache degrade; Postgres truth remains; do not fabricate readiness |

Principle:

```text
Durable certification state remains fail-closed.
Cache/PubSub failure must not fabricate readiness.
```

---

## 28. Performance & Scaling Review

**CONTRACT DECISION (C33, C34, C35)**

```text
expensive verification → async / bounded / Oban
durable certification evidence → Postgres
dashboard readiness lookup → small bounded indexed read
hot display → ETS if useful
warm display → Redis if useful
truth → never Redis/ETS
```

### 28.1 Required indexes (proof-backed)

Existing relevant indexes:

| Path | Evidence |
| --- | --- |
| SyncRun by source / event / status | `sync_run.ex:36-42` (separate indexes) |
| SyncCursor by sync_run_id (unique) | `sync_cursor.ex:23-26` |
| Tickera recon by event+status | `tickera_reconciliation_run.ex:54-55` |
| OrderItem attribution review | `order_item.ex:62-77` event/mapping_status indexes |

Proof-backed gaps / EXTEND needs:

| Gap | Timing | Notes |
| --- | --- | --- |
| One-active historical SyncRun uniqueness per source+event | REQUIRED_DURING_M3 | Roadmap already notes missing one-active-run guard (`path-1-phase-breakdown.md:602`) |
| Composite current-certification lookup `(source_system_id, event_id)` (and status) on future watermark / readiness projection | REQUIRED_BEFORE_M5 | Dashboard must not scan history; exact physical table TBD |
| No speculative blanket indexes beyond proven lookup paths | — | — |

### 28.2 Caching / TTL / invalidation / PubSub (C35)

If a later readiness summary is cached:

```text
Hot ETS: 10s–5m acceptable display cache
Warm Redis: ≤30m maximum only if invalidation guarantees correctness
Prefer event-driven invalidation over waiting for TTL
```

Invalidate on at least:

```text
backfill completion/failure
refund completeness change
financial reconciliation result
certification invalidation
new blocking finding
re-certification
```

PubSub should eventually broadcast event-scoped readiness transitions so open LiveViews update without polling. **PubSub is not truth.**

### 28.3 100k-concurrency review

Certification is control-plane work, not per-ticket hot-path state.

Required:

```text
no full historical readiness recomputation per dashboard request
no Woo source call from dashboard / LiveView
no global scans
no polling
no single global GenServer readiness bottleneck
```

Horizontal safety comes from durable Postgres evidence.

---

## 29. Required Implementation Gaps

Deduplicated ledger for M1-09 (carry-forward + M1-08 discoveries):

### REQUIRED_BEFORE_M2

| ID | Gap | Origin |
| --- | --- | --- |
| G1 | TicketType variation-parent fail-closed on event-first path | M1-03 |

### REQUIRED_DURING_M3

| ID | Gap | Origin |
| --- | --- | --- |
| MG1 | Persist `OrderItem.line_total_tax` (tax-inclusive Gross input) | M1-06 |
| R-G1..G6,G9..G12,G14..G15 | Refund discovery/persistence/idempotency/binding/void/sign/residuals | M1-05 |
| TG1 | Persist sale `date_paid_gmt` | M1-07 |
| TG2 | Persist refund `date_created_gmt` | M1-07 |
| **CG1** | Persist Tickera event creation instant (`post_date_gmt`) for BACKFILL_START | M1-08 |
| **CG2** | Cursor advances only after durable page success (fail-closed checkpoint) | M1-08 |
| **CG3** | Historical deep backfill mode producing ORDER_COMPLETE evidence + watermark fields | M1-08 |
| **CG4** | Refund completeness processing through `refunds_covered_through` | M1-05/M1-08 |
| **CG5** | One-active historical SyncRun guard per source+event | M1-08 / roadmap |

### REQUIRED_BEFORE_M4

| ID | Gap | Origin |
| --- | --- | --- |
| R-G8 / **CG6** | Refund completeness watermark + ORDER/REFUND complete gates | M1-05/M1-08 |
| **CG7** | Durable completeness watermark projection (conceptual fields §7) | M1-08 |

### REQUIRED_DURING_M4

| ID | Gap | Origin |
| --- | --- | --- |
| **CG8** | Path 1 financial reconciliation worker/run/findings (concept C) | M1-08 |
| **CG9** | Exact equality comparison for C17 primitives + difference categories | M1-08 |
| **CG10** | ANALYTICS_READY derived projection + blocking reasons | M1-08 |

### REQUIRED_BEFORE_M5

| ID | Gap | Origin |
| --- | --- | --- |
| MG2–MG8 | Refund-aware Gross/Net, Order Count, ATV, currency partitions, MetricRules/snapshots | M1-06 |
| TG3–TG* | Sale/refund bucketing; 10m source-stale projection; Johannesburg shift_zone; paid_at index strategy; source-freshness watermark projection | M1-07 |
| **CG11** | Indexed readiness current-status lookup for dashboards | M1-08 |

### REQUIRED_BEFORE_M6

| ID | Gap | Origin |
| --- | --- | --- |
| UX stale banner / copy alignment | M1-07 |

### REQUIRED_LATER / OPTIONAL_HARDENING

| ID | Gap | Origin |
| --- | --- | --- |
| M1-03 G2–G4 | Product-level fallback review; `:remap` surface; generalise correction | M1-03 |
| MG9 | Tax/Fees/Discount source contracts | M1-06 |
| M1-05 G13 | Real sanitized refund fixtures | M1-05 |
| Audit history of corrected effective timestamps | M1-07 |
| Attendee recon UX as WARNING/INFORMATIONAL panels | M1-08 |

Do not implement in M1-08. Do not duplicate the same gap under multiple competing names in M1-09 — use this ledger as the consolidation input.

---

## 30. Explicit Non-Goals

M1-08 does **not**:

```text
implement historical backfill
implement refund persistence
implement MG1–MG8
implement date_paid / refund timestamps
build financial reconciliation worker
create AnalyticsReady resource / certification tables
modify MetricRules / HotStateAggregator
build M5 aggregates / dashboard UI
fix M1-03 parent-product gap G1
perform Path 2 / Phase 5E work
Apply / AutoApply
mutate WordPress
begin M1-09
```

---

## 31. Decisions C1–C36

| ID | Decision |
| --- | --- |
| **C1** | Separate A transport completeness, B attendee diagnostic, C financial reconciliation |
| **C2** | Initial scope = selected currently-public events; private excluded; verified identity required |
| **C3** | BACKFILL_START = Tickera `tc_events.post_date_gmt` (persist gap CG1) |
| **C4** | BACKFILL_CUTOFF = explicit durable cutoff + terminal cursor evidence; not finished_at alone |
| **C5** | Completeness watermark proves range + statuses + unresolved inventory |
| **C6** | Cursor advances only after durable success; current code gap = CG2 |
| **C7** | ORDER_COMPLETE defined; SyncRun completed ≠ complete |
| **C8** | Attribution completeness consumes M1-03 statuses |
| **C9** | Pending/unmapped potentially-ticket → blocking; non_ticket/ignored non-blocking when classified |
| **C10** | REFUND_COMPLETE composes M1-05 R24; status `:refunded` insufficient |
| **C11** | Separate sales_covered_through and refunds_covered_through when needed |
| **C12** | Late refunds invalidate/require re-cert of refund + financial PASS |
| **C13** | Missing authoritative effective times block ANALYTICS_READY for scope |
| **C14** | Required financial primitives include tax-inclusive Gross inputs |
| **C15** | Currency-partitioned reconciliation; no FX; mismatch fail-closed |
| **C16** | Recon scope = source+event+currency+coverage+ticket primitives |
| **C17** | Reconcile additive qty/value primitives; not ATV / unsafe Order Count sums |
| **C18** | Exact Decimal equality; no unexplained tolerance |
| **C19** | Difference categories matrix §16 |
| **C20** | Attendee recon = DIAGNOSTIC for financial ANALYTICS_READY |
| **C21** | ANALYTICS_READY derived predicate §18 |
| **C22** | Blocking-reason contract §19 |
| **C23** | Readiness ≠ freshness |
| **C24** | certified_through = latest certified coverage boundary |
| **C25** | Invalidation rules §22; stale age alone does not invalidate |
| **C26** | Post-cert live data incremental; gaps must still surface |
| **C27** | BACKFILL_PENDING definition for M2 |
| **C28** | M3 completion evidence list |
| **C29** | M4 entry gate |
| **C30** | M5 entry requires ANALYTICS_READY + MG2–MG8 |
| **C31** | Manual refresh non-authority |
| **C32** | Failure/retry fail-closed semantics |
| **C33** | Durable certification source of truth = Postgres |
| **C34** | Dashboard readiness = bounded indexed read; no history scan |
| **C35** | Cache/invalidation/PubSub boundary §28.2 |
| **C36** | M1-09 receives consolidated gap ledger §29 / §32 |

All C1–C36 deterministic → **not BLOCKED**.

---

## 32. M1-09 Handoff

Provide consolidated inputs (do not implement):

```text
REQUIRED_BEFORE_M2:
  M1-03 G1 TicketType variation-parent fail-closed

REQUIRED_DURING_M3:
  MG1; M1-05 refund G1–G6/G9–G12/G14–G15; date_paid + refund created-gmt;
  CG1 event creation instant; CG2 cursor durability; CG3 historical ORDER_COMPLETE + watermark fields;
  CG4 refund completeness processing; CG5 one-active SyncRun guard

REQUIRED_BEFORE_M4:
  CG6/R-G8 refund completeness watermark; CG7 durable completeness watermark projection

REQUIRED_DURING_M4:
  CG8–CG10 financial recon + ANALYTICS_READY projection

REQUIRED_BEFORE_M5:
  MG2–MG8; M1-07 bucketing/stale projection/indexes; CG11 readiness lookup index

REQUIRED_BEFORE_M6:
  UX stale banner alignment

OPTIONAL / LATER:
  M1-03 G2–G4; MG9; refund fixtures; timestamp audit history; attendee UX panels
```

M1-09 decides the final certification pack and PRE-M2 corrective implementation gate (M1-C if required).

**M1-09 AUTHORIZATION: NOT GRANTED BY THIS TASK.**

---

## 33. M2 / M3 / M4 / M5 Handoffs

| Phase | Must assume from M1-08 |
| --- | --- |
| **M2** | Produce BACKFILL_PENDING only; no historical sales import; identity/mappings certified |
| **M3** | Implement CG1–CG5 + refund/time/tax primitives; emit ORDER/REFUND completeness evidence + watermark |
| **M4** | Enter only when C29 true; implement concept C recon; derive ANALYTICS_READY |
| **M5** | Authoritative financial read models only when ANALYTICS_READY + MG2–MG8 |

---

## 34. Open Questions

| Item | Status |
| --- | --- |
| Physical Ash resource name for readiness watermark | TBD in M3/M4 — conceptual fields locked |
| Whether sales and refund cutoffs may permanently diverge by policy | Allowed conceptually (C11); product may choose equal cutoffs at import time |
| Source-proven Woo rounding normalization (if any) | UNKNOWN until source-proven; until then exact equality only — does **not** block C18 |
| Exact composite index DDL for readiness projection | Deferred to physical design; requirement locked (C34/CG11) |

No UNKNOWN that blocks C1–C36.

---

## 35. M1-08 Verdict

```text
M1-08 = PASS

Baseline: bce4cc07cf08521486d81c6aabba4621e0650fa3
Document: docs/path-1/m1-08-backfill-completeness-reconciliation-and-analytics-ready-contract.md
Production code changes: NONE
Migration authorized: NO
Financial reconciliation contract: LOCKED
ANALYTICS_READY contract: LOCKED
Attendee reconciliation role: DIAGNOSTIC
M1-09 authorization: NOT GRANTED BY THIS TASK
```

### Quick answers for a fresh M1-09 / M3 / M4 / M5 agent

```text
What exact historical range is certified?
  [BACKFILL_START, BACKFILL_CUTOFF] for selected public source+event (+ currency partitions)

What proves its beginning?
  Tickera tc_events post_date_gmt (persist CG1) — not local inserted_at

What proves its cutoff?
  Explicit durable cutoff + terminal cursor/page evidence — not finished_at alone

What makes a backfill run complete rather than merely finished?
  ORDER_COMPLETE + REFUND_COMPLETE + watermark range evidence

What makes Order coverage complete?
  C7 — all pages processed, identities resolved, no silent skips, terminal cursor, no open write failures

What unresolved attribution blocks readiness?
  pending_mapping_resolution / unmapped potentially-ticket (and G1 before exact parent integrity claims)

What makes refunds complete?
  C10 / M1-05 R24 — not Order.status == :refunded

How are late refunds handled?
  Separate refunds_covered_through; invalidate/re-cert refund + financial PASS

Which effective timestamps are mandatory?
  paid→completed for sales; refund date_created_gmt for refunds

Which financial primitives must exist?
  C14 including tax-inclusive Gross inputs (MG1)

How are currencies partitioned?
  Per-currency recon; no FX; mismatch fail-closed

What exactly does financial reconciliation compare?
  Equivalent ticket-scoped additive qty/value primitives under C16/C17

Is reconciliation exact or tolerant?
  Exact Decimal equality (C18)

Does attendee reconciliation gate financial analytics?
  No — DIAGNOSTIC (C20)

What exactly makes ANALYTICS_READY true?
  C21 derived predicate

Why is ANALYTICS_READY not the same as FRESH?
  C23 — stale age does not erase historical certification

What does certified_through mean?
  Latest certified coverage boundary (C24)

What invalidates certification?
  C25 (not mere source age > 10m)

What happens to new live data after certification?
  Incremental ingestion + catch-up; does not auto-extend historical financial PASS (C26)

What must M3 produce?
  C28 evidence list

When may M4 start?
  C29

When may M5 expose authoritative financial analytics?
  ANALYTICS_READY + MG2–MG8 (C30)

What durable evidence lets dashboards check readiness without scanning history?
  Postgres watermark / readiness projection; bounded indexed read (C33–C35)
```
