Document:
Path 1 M1-09 M1 Certification and PRE-M2 Implementation Gate

Baseline:
b86f4c81d53e638d4dca2f188b979d1a06cd30dc

origin/main:
b86f4c81d53e638d4dca2f188b979d1a06cd30dc

Contract date:
2026-08-09

Verdict:
PASS_WITH_PRE_M2_IMPLEMENTATION_GATE

Authority:
CERTIFY + SEQUENCE (documentation only; no production code)

---

# Path 1 M1-09 — M1 Certification and PRE-M2 Implementation Gate

| Field | Value |
| --- | --- |
| Document | M1 certification pack + deduplicated implementation-gap ledger + PRE-M2 gate |
| Plan ID | `m1-09-m1-certification-and-pre-m2-gate` |
| Plan version | `v1` |
| Status | LOCKED — M1 contract certification COMPLETE; M2 blocked pending M1-C |
| Scope | Cross-contract consistency; end-to-end truth chain; canonical gap ledger; M1-C PRE-M2 gate; M2–M6 sequencing |
| Strategy | CERTIFY M1-02..M1-08 as one programme contract; invent no new domain truth; implement nothing |
| Path 2 / Phase 5E | PAUSED |

### Revision log

- `v1` — initial M1 certification at baseline `b86f4c81d53e638d4dca2f188b979d1a06cd30dc`; sole REQUIRED_BEFORE_M2 gap confirmed as M1-03 G1; M1-C named

### Conflict rule

```text
This document wins for Path 1 M1 closeout certification, gap timing,
PRE-M2 gate identity, and M2 authorization conditions.

Individual M1-02..M1-08 contracts win for their locked domain semantics.
This document does not revise those contracts.

If a later implementation task disagrees with a locked M1 contract,
stop and escalate — do not silently prefer convenience.
```

---

## 1. Certification Metadata / Baseline

```text
branch: main
HEAD: b86f4c81d53e638d4dca2f188b979d1a06cd30dc
origin/main: b86f4c81d53e638d4dca2f188b979d1a06cd30dc
worktree at start: CLEAN
P1-00 / M1-01 / M1-01A / M1-02..M1-08: COMPLETE (PASS)
Path 2 / Phase 5E: PAUSED
No Apply / AutoApply / WordPress mutation
```

Preflight: `HEAD == origin/main`, on `main`, clean worktree, matches authorized M1-09 baseline.

Primary evidence (contracts only; no re-audit):

```text
docs/path-1/m1-02-source-scoped-external-identity-contract.md
docs/path-1/m1-03-event-product-variation-orderline-attribution-contract.md
docs/path-1/m1-04-order-lifecycle-and-recognised-sale-contract.md
docs/path-1/m1-05-refund-and-financial-adjustment-contract.md
docs/path-1/m1-06-financial-metric-dictionary.md
docs/path-1/m1-07-timestamp-johannesburg-period-and-freshness-contract.md
docs/path-1/m1-08-backfill-completeness-reconciliation-and-analytics-ready-contract.md
```

Supporting programme context:

```text
AGENTS.md
docs/agent/01_PROJECT_WIDE_RULES.md
docs/roadmap/current-state-and-path-handoff.md
docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md
docs/path-1/path-1-phase-breakdown.md
docs/path-1/m1-01-current-repo-truth.md
```

Source inspection used only to confirm the known G1 omission cited by M1-03:

```text
lib/event_sales/sales/order_attribution_resolver.ex:76-89
  ticket_type/3 binds _woo_product_id and filters by event_id + variation id only
```

---

## 2. Executive Verdict

```text
M1 CONTRACT CERTIFICATION = PASS
M1-09 PROGRAMME VERDICT     = PASS_WITH_PRE_M2_IMPLEMENTATION_GATE
CROSS-CONTRACT CONTRADICTIONS = NONE
REQUIRED_BEFORE_M2 GAPS     = 1 (GAP-PRE-M2-01 / M1-03 G1)
M2 AUTHORIZATION            = BLOCKED_PENDING_PRE_M2_GATE
```

Reasons:

```text
M1-02..M1-08 are present, COMPLETE (PASS), and mutually consistent.
Every material relationship is CONSISTENT or REFINED_BY_LATER_CONTRACT
  or IMPLEMENTATION_GAP_ONLY — never CONTRADICTION.
One production behaviour still violates a locked M1-03 contract:
  event-first TicketType variation-parent fail-closed (G1).
That gap blocks M2 because onboarding creates TicketType parent mirrors
  that attribution must enforce before structural certification / backfill.
All other known gaps have deterministic owners in M3–M6 / later / optional.
M1 may close as a contract phase while M1-C corrects production conformance.
```

Production code changes in M1-09: **NONE**.  
Migration authorized: **NO**.

---

## 3. M1 Contract Inventory

| ID | Document | Status | Core lock |
| --- | --- | --- | --- |
| M1-02 | `m1-02-source-scoped-external-identity-contract.md` | COMPLETE (PASS) | Source layers; Event/product/variation/order identities; fail-closed lookups |
| M1-03 | `m1-03-event-product-variation-orderline-attribution-contract.md` | COMPLETE (PASS) | Event-first + ProductMapping fallback; mapping statuses; historical immutability; G1 BEFORE_M2 |
| M1-04 | `m1-04-order-lifecycle-and-recognised-sale-contract.md` | COMPLETE (PASS) | Completed-only original recognition; mapped ticket + qty > 0; `:refunded` lifecycle-only |
| M1-05 | `m1-05-refund-and-financial-adjustment-contract.md` | COMPLETE (PASS) | Refunds as independent adjustments; identity/idempotency/binding/sign; no BEFORE_M2 gaps |
| M1-06 | `m1-06-financial-metric-dictionary.md` | COMPLETE (PASS) | Tax-inclusive Gross; Gross/Refund/Net; distinct Order Count; ATV; MG1 DURING_M3; MG2–MG8 BEFORE_M5 |
| M1-07 | `m1-07-timestamp-johannesburg-period-and-freshness-contract.md` | COMPLETE (PASS) | Paid→completed sale clock; refund `date_created_gmt`; JHB periods; NORMAL/AGING/STALE |
| M1-08 | `m1-08-backfill-completeness-reconciliation-and-analytics-ready-contract.md` | COMPLETE (PASS) | A≠B≠C; ORDER/REFUND completeness; exact financial recon; ANALYTICS_READY ≠ freshness |

Prior foundations (not reopened):

| ID | Role |
| --- | --- |
| P1-00 | Path 1 activation |
| M1-01 | Repository truth |
| M1-01A | Roadmap reconciliation |

---

## 4. Cross-Contract Consistency Matrix

Classification key:

```text
CONSISTENT                 — same locked meaning across contracts
REFINED_BY_LATER_CONTRACT  — later contract adds authority without overturning earlier lock
IMPLEMENTATION_GAP_ONLY    — contracts agree; production/code lags
CONTRADICTION              — unresolved conflict → M1-09 BLOCKED
```

| Topic | Contracts | Classification | Notes / citations |
| --- | --- | --- | --- |
| Source identity layers | M1-02 → all | CONSISTENT | M1-02 §3–§5; consumed by M1-03 §3, M1-08 §3 |
| Event / product / variation identity | M1-02 → M1-03 | CONSISTENT | Variation requires parent product (M1-02 D7; M1-03 §9.1) |
| Variation parent integrity | M1-02 / M1-03 / M1-08 | IMPLEMENTATION_GAP_ONLY | Contract requires fail-closed; G1 production omission (M1-03 §20 G1; M1-08 §10.1) |
| Order / OrderItem identity | M1-02 → M1-05 | CONSISTENT | `(source, woo_order_id)`; line via `(order_id, woo_line_item_id)` |
| Attribution precedence | M1-03 → M1-04/M1-08 | CONSISTENT | Event-first; ProductMapping never overrides resolved Tickera event (M1-03 §2) |
| Historical attribution immutability | M1-03 → M1-05 | CONSISTENT | Refunds must not remap (M1-05 I7); status change ≠ remap (M1-04) |
| Completed-only original sale | M1-04 → M1-05/M1-06 | CONSISTENT | Predicate = completed + mapped ticket + qty > 0 (M1-04; M1-06 §3.1) |
| Refunds as independent adjustments | M1-05 → M1-06/M1-08 | CONSISTENT | Gross preserved; net derived (M1-05; M1-06 F2–F8) |
| Gross / Refund / Net formulas | M1-06 → M1-08 | CONSISTENT | Additive primitives; C17 reconciles those, not ATV (M1-08 §15) |
| Tax-inclusive Gross | M1-06 → M1-08 | IMPLEMENTATION_GAP_ONLY | Formula locked; MG1 persist `line_total_tax` DURING_M3 |
| Distinct Order Count | M1-06 | CONSISTENT | Distinct historically recognised ticket Orders; non-additive across overlaps |
| ATV | M1-06 | CONSISTENT | Net Sales ÷ Net Tickets; N/A on zero denom |
| Sale effective timestamp | M1-07 → M1-04/M1-08 | REFINED_BY_LATER_CONTRACT | M1-04 deferred clocks; M1-07 locks paid→completed coalesce |
| Refund effective timestamp | M1-05 need → M1-07 | REFINED_BY_LATER_CONTRACT | `date_created_gmt` (M1-07 §8) |
| Johannesburg reporting periods | M1-07 | CONSISTENT | Named zone; `[start,end)` (M1-07 §12–§13) |
| NORMAL / AGING / STALE | M1-07 → M1-08 | CONSISTENT | Source age; readiness ≠ freshness (M1-08 §20 / C23) |
| Historical coverage | M1-08 | CONSISTENT | BACKFILL_START/CUTOFF; ORDER_COMPLETE ≠ SyncRun completed |
| Refund completeness | M1-05 R24 → M1-08 | CONSISTENT | REFUND_COMPLETE ≠ `:refunded` status |
| Financial reconciliation | M1-08 C | CONSISTENT | Exact Decimal; ticket-scoped; DURING_M4 |
| ANALYTICS_READY | M1-08 | CONSISTENT | Derived durable predicate |
| ANALYTICS_READY vs freshness | M1-07 / M1-08 | CONSISTENT | Explicitly distinct (M1-08 §20) |

**Unresolved CONTRADICTION count: 0.**

---

## 5. Canonical End-to-End Truth Chain

Physical ownership only (no new domains):

```text
Catalog.SourceSystem
   ↓ exact source scope (internal_source_pk / canonical_source_key)

Catalog.Event
   ↓ (source_system_id, :tickera_event, external_event_id)

Sales.Order + Sales.OrderItem
   ↓ source-scoped Order identity; line identity via Order FK

Ingestion/Sales attribution
   ↓ event-first (source_tickera_event_id → Event → TicketType)
   ↓ ProductMapping fallback only when event-first does not resolve
   ↓ historical mapped rows immutable under normal ingestion

Recognised original ticket sale (M1-04)
   ↓ Order.status == :completed
   ↓ OrderItem.mapping_status == :mapped
   ↓ ticket classification
   ↓ quantity > 0

Original recognised ticket value (M1-06)
   ↓ tax-inclusive = OrderItem.line_total + OrderItem.line_total_tax

Independent refund adjustments (M1-05)
   ↓ durable refund + refund-line facts (physical form TBD in M3)
   ↓ do not erase original sale facts

Named metrics (M1-06)
   ↓ Gross / Refund / Net qty & money
   ↓ distinct Recognised Order Count
   ↓ ATV = Net Sales / Net Tickets (N/A if denom 0)

Effective timestamps (M1-07)
   ↓ sale: paid → completed coalesce (withhold if neither)
   ↓ refund: date_created_gmt
   ↓ Johannesburg [start, end) periods

Historical completeness (M1-08)
   ↓ ORDER_COMPLETE + REFUND_COMPLETE watermarks
   ↓ attribution readiness (M1-03 statuses)

Financial reconciliation concept C (M1-08 / M4)
   ↓ exact Decimal equality on additive ticket primitives

ANALYTICS_READY (M1-08)
   ↓ derived from durable Postgres evidence
   ↓ ≠ M1-07 freshness NORMAL/AGING/STALE

Bounded M5 read models
   ↓ Postgres cold truth + snapshots
   ↓ ETS hot / Redis warm derived only
   ↓ PubSub notification only
   ↓ Accounts / LiveView read-only management (M6)
```

Durable Order write path (unchanged):

```text
WoocommerceOrderParser → EventSales.Sales.OrderUpserter → Ash Order / OrderItem
```

No parallel Sales writer (M1-01 / path-1-phase-breakdown §3.4).

---

## 6. Domain Ownership Certification

| Concern | Owning domain / surface | Forbidden |
| --- | --- | --- |
| SourceSystem / Event / TicketType / ProductMapping | `EventSales.Catalog` | New `EventSales.Sources` |
| Order / OrderItem / OrderUpserter / attribution | `EventSales.Sales` (+ Ingestion callers) | Parallel order writer |
| Webhooks / SyncRun / SyncCursor / catch-up / financial recon runs | `EventSales.Ingestion` patterns | New `EventSales.Reconciliation` by default |
| Snapshots / HotStateAggregator / MetricRules | `EventSales.Analytics` | Cache as financial truth; adding Cachex for conformity |
| Management UX / policies | `EventSales.Accounts` + LiveView | New `EventSales.Management` domain |
| Woo REST | Approved Ingestion workers / clients only | LiveView / controllers / MappingResolver |

M1-05 physical Refund ownership remains TBD inside Sales/Ingestion adjacency — choose in M3 (GAP-M3-REFUND pack); do not invent a new Ash domain for refunds without authorization.

---

## 7. Deduplicated Implementation Gap Ledger

Canonical IDs below supersede scattered G/MG/CG/R-G labels for sequencing. Origin IDs retained for traceability.

### 7.1 REQUIRED_BEFORE_M2

#### GAP-PRE-M2-01 — TicketType variation-parent fail-closed (event-first)

| Field | Value |
| --- | --- |
| Canonical Gap ID | `GAP-PRE-M2-01` |
| Origin | M1-03 G1; carried by M1-06 MG10, M1-08 §10.1 / §29 G1 |
| Description | On event-first TicketType variation resolution, if `TicketType.external_product_id` is present and ≠ `OrderItem.woo_product_id`, fail closed (do not map as if parent matched). |
| Why required | M1-02 locks variation identity as `(source, parent woo_product_id, woo_variation_id)`. Matching variation while accepting the wrong parent weakens locked parent integrity (M1-03 §9 / A9 / §20 G1). |
| Implementation phase/gate | **REQUIRED_BEFORE_M2** via **M1-C** |
| Blocks what? | M2 authorization; any claim of exact variation-parent attribution integrity; ANALYTICS_READY claims that assert that integrity (M1-08 §10.1) |
| Production code? | YES — `OrderAttributionResolver` event-first TicketType path |
| Migration likely? | NO |
| Performance/index concern | None beyond existing `limit(1)` source-scoped lookup |
| Dependency gaps | None |
| Acceptance evidence | Focused test: present mismatched `external_product_id` → fail closed; matching parent still maps; ProductMapping path unchanged |

**Independent confirmation this is REQUIRED_BEFORE_M2 (not merely “nice before M3”):**

1. M1-03 §20 / verdict explicitly classifies G1 as **REQUIRED_BEFORE_M2 (BLOCKING BEFORE M2)** and defers fix to M1-09 / M1-C.
2. M1-08 §29 lists **only** G1 under REQUIRED_BEFORE_M2; M1-05 §24 states nothing refund-related is BEFORE_M2.
3. Path 1 M2 objective includes parent-product protection and variation-parent validation for onboarding (`path-1-phase-breakdown.md` M2-04 / M2-06). M2 creates `TicketType.external_product_id` mirrors that the event-first resolver must honour; otherwise structural “zero cross-contamination” certification is false under live attribution.
4. No other M1 gap is classified BEFORE_M2 by contract evidence. M1-02 identity hardening, refunds, tax, clocks, watermarks, MetricRules, and readiness are explicitly later.

**Sole member of REQUIRED_BEFORE_M2 set.**

---

### 7.2 REQUIRED_DURING_M3 (dependency packs)

See §10 for grouped packs. Canonical members:

| Canonical ID | Merges | Summary |
| --- | --- | --- |
| `GAP-M3-TAX-01` | M1-06 MG1 | Persist `OrderItem.line_total_tax` (+ likely `subtotal_tax`) via parser→OrderUpserter |
| `GAP-M3-REFUND` | M1-05 G1–G6,G9–G12,G14–G15; M1-06 MG3 persistence half | Refund discovery/fetch/persist/idempotency/binding/void/sign/residuals; preserve original sale facts |
| `GAP-M3-TIME-01` | M1-07 TG1 | Persist Woo `date_paid_gmt` on Order |
| `GAP-M3-TIME-02` | M1-07 TG2 | Persist refund `date_created_gmt` with refund facts |
| `GAP-M3-COV-01` | M1-08 CG1 | Persist Tickera event creation instant (`post_date_gmt`) for BACKFILL_START |
| `GAP-M3-COV-02` | M1-08 CG2 | Cursor advances only after durable page success |
| `GAP-M3-COV-03` | M1-08 CG3 | Historical deep backfill producing ORDER_COMPLETE + watermark fields |
| `GAP-M3-COV-04` | M1-08 CG4 (+ M1-05 refund completeness processing) | Refund completeness processing through `refunds_covered_through` |
| `GAP-M3-COV-05` | M1-08 CG5 | One-active historical SyncRun guard per source+event |

---

### 7.3 REQUIRED_BEFORE_M4

| Canonical ID | Merges | Summary |
| --- | --- | --- |
| `GAP-PRE-M4-01` | M1-05 G8 / M1-08 CG6 | Refund completeness watermark + ORDER/REFUND complete gates satisfied as **inputs** |
| `GAP-PRE-M4-02` | M1-08 CG7 | Durable completeness watermark projection (conceptual fields M1-08 §7) |

M4 cannot legitimately run financial reconciliation without durable ORDER/REFUND coverage evidence and watermark projection for the certified scope.

---

### 7.4 REQUIRED_DURING_M4

| Canonical ID | Merges | Summary |
| --- | --- | --- |
| `GAP-M4-RECON-01` | M1-08 CG8 | Path 1 financial reconciliation worker/run/findings (concept C) |
| `GAP-M4-RECON-02` | M1-08 CG9 | Exact Decimal equality + difference categories |
| `GAP-M4-READY-01` | M1-08 CG10 | ANALYTICS_READY derived projection + blocking reasons |

---

### 7.5 REQUIRED_BEFORE_M5

| Canonical ID | Merges | Summary |
| --- | --- | --- |
| `GAP-PRE-M5-METRICS` | M1-06 MG2,MG4–MG8; M1-05 G7 | Refund-aware MetricRules; tax-inclusive Gross; Gross preserve + Net; distinct Order Count; ATV; currency partition; snapshot fields |
| `GAP-PRE-M5-TIME` | M1-07 TG3–TG* | Sale/refund effective-time bucketing; 10m source-stale projection; Johannesburg `shift_zone`; paid_at index strategy; source-freshness watermark projection |
| `GAP-PRE-M5-READY-IX` | M1-08 CG11 | Indexed current readiness lookup for dashboards |

---

### 7.6 REQUIRED_BEFORE_M6

| Canonical ID | Merges | Summary |
| --- | --- | --- |
| `GAP-PRE-M6-UX-01` | M1-07 UX stale banner | NORMAL / AGING / STALE UX/banner copy alignment |
| `GAP-PRE-M6-UX-02` | M1-07 custom-range note (UI half) | Bounded custom-range UX enforcement/copy if M6 owns UI; backend bound remains BEFORE_M5 |

---

### 7.7 REQUIRED_LATER / OPTIONAL_HARDENING

| Canonical ID | Merges | Timing |
| --- | --- | --- |
| `GAP-OPT-ATTR-01` | M1-03 G2 | OPTIONAL_HARDENING — product-level fallback for variation lines |
| `GAP-OPT-ATTR-02` | M1-03 G3 | OPTIONAL_HARDENING — unused `:remap` surface review |
| `GAP-LATER-ATTR-01` | M1-03 G4 | REQUIRED_LATER — do not generalise order-113834 correction |
| `GAP-OPT-ID-01` | M1-02 Ash Event identity | OPTIONAL_HARDENING |
| `GAP-OPT-ID-02` | M1-02 NormalizeBaseUrl ↔ DiscoveryIntegrity uniqueness alignment | REQUIRED_LATER / non-blocking |
| `GAP-OPT-ID-03` | M1-02 identity-field accept hardening | REQUIRED_LATER / non-blocking |
| `GAP-OPT-ID-04` | M1-02 multi-source webhook routing | REQUIRED_LATER (second site) |
| `GAP-OPT-REFUND-FIX` | M1-05 G13 | OPTIONAL_HARDENING — sanitized real refund fixtures |
| `GAP-OPT-TIME-AUDIT` | M1-07 corrected-timestamp audit history | REQUIRED_LATER |
| `GAP-OPT-ATTENDEE-UX` | M1-08 attendee diagnostic UX | OPTIONAL_HARDENING |
| `GAP-LATER-FEES` | M1-06 MG9 | REQUIRED_LATER — Tax/Fees/Discount source contracts deferred |

---

## 8. REQUIRED_BEFORE_M2 Gap Set

```text
Count: 1

GAP-PRE-M2-01
  = M1-03 G1
  = TicketType variation-parent fail-closed on event-first path
```

No other known M1 gap is promoted into this set.

Explicit non-promotions (remain later despite appearing “foundational”):

| Gap class | Why not BEFORE_M2 |
| --- | --- |
| Refund persistence | M1-05 §24: M2 does not depend on refunds |
| `line_total_tax` | M1-06 MG1: DURING_M3; needed before authoritative Gross, not onboarding |
| `date_paid` / refund clocks | M1-07: DURING_M3 / BEFORE_M5 |
| Completeness watermarks | M1-08: DURING_M3 / BEFORE_M4 |
| Financial recon / ANALYTICS_READY | M1-08: DURING_M4 |
| MetricRules / snapshots / stale UX | BEFORE_M5 / BEFORE_M6 |
| M1-02 normalization / Ash Event identity | Explicitly non-blocking for later phases |

---

## 9. M1-C PRE-M2 Contract Conformance Gate

| Field | Value |
| --- | --- |
| Gate name | **M1-C — PRE-M2 Contract Conformance Gate** |
| Nature | Production-code correction gate (not an M1 contract investigation) |
| Authorization | Required before M2; not started by M1-09 |
| Branch policy | Fresh implementation agent → short-lived branch → PR → diff review → merge (see §18) |
| Direct-to-main production code | **FORBIDDEN** for this gate |

### Initial scope (sole blocker)

```text
ONE production behaviour correction:
  Event-first TicketType variation resolution must fail closed when
    TicketType.external_product_id is present
    AND TicketType.external_product_id != OrderItem.woo_product_id

Focused tests proving fail-closed + happy path + no ProductMapping redesign

No unrelated attribution redesign
No refunds / tax / timestamps / SyncRun / MetricRules / dashboard work
```

### Expected touch surface

```text
lib/event_sales/sales/order_attribution_resolver.ex  (event-first ticket_type/3 path)
focused tests under test/event_sales/sales/ (or existing attribution test module)
```

### Exit criteria

```text
GAP-PRE-M2-01 acceptance evidence PASS
focused tests PASS
mix compile --warnings-as-errors (or quality.fast if slice requires)
PR merged to main
main clean and synchronized with origin/main
→ M2 AUTHORIZED (subject to §16)
```

M1-09 documents M1-C. **M1-09 does not implement M1-C.**

---

## 10. M3 Implementation Dependency Pack

M3 owns historical ingestion through **parser → OrderUpserter** plus refund/completeness durability.

### Pack M3-A — Order financial & time primitives

```text
GAP-M3-TAX-01   persist line_total_tax
GAP-M3-TIME-01  persist date_paid_gmt
```

Extend existing Order/OrderItem upsert accepts. No parallel writer.

### Pack M3-B — Refund truth

```text
GAP-M3-REFUND   full M1-05 persistence/idempotency/binding/void/sign/residuals
GAP-M3-TIME-02  refund date_created_gmt with refund facts
GAP-M3-COV-04   refund completeness processing toward refunds_covered_through
```

Physical Refund resource form chosen here (extend OrderUpserter vs adjacent RefundUpserter) — M1-05 G15.

### Pack M3-C — Historical coverage engine

```text
GAP-M3-COV-01   Tickera event creation instant for BACKFILL_START
GAP-M3-COV-02   fail-closed cursor checkpoint
GAP-M3-COV-03   historical ORDER_COMPLETE + watermark fields
GAP-M3-COV-05   one-active SyncRun guard per source+event
```

### M3 completion evidence (from M1-08 §24.2)

```text
ORDER completeness evidence for scoped events
required tax-inclusive line primitives (MG1)
refund processing path producing completeness inputs
paid/refund effective timestamps persisted where authoritative
cursor/watermark safety
```

Do not design M3 code in this document.

---

## 11. M4 Entry / Implementation Dependency Pack

### Before M4 may start (inputs)

```text
GAP-PRE-M4-01  refund completeness watermark + ORDER/REFUND complete gates
GAP-PRE-M4-02  durable completeness watermark projection
```

Plus M3 packs producing those inputs (tax primitives, refund facts, coverage engine).

### During M4 (M4 builds)

```text
GAP-M4-RECON-01  financial reconciliation worker/path (concept C)
GAP-M4-RECON-02  exact equality + difference categories
GAP-M4-READY-01  ANALYTICS_READY projection + blocking reasons
```

Separation rule:

```text
BEFORE_M4 = durable coverage / watermark inputs exist
DURING_M4 = compare money and certify ANALYTICS_READY
```

Attendee reconciliation remains DIAGNOSTIC (M1-08 C20) — not a substitute for concept C.

---

## 12. M5 Entry / Implementation Dependency Pack

M5 may start only when ANALYTICS_READY machinery and financial primitives exist for scoped events, and the following read-model gaps are addressed:

```text
GAP-PRE-M5-METRICS
  refund-aware MetricRules
  Gross / Refund / Net calculations
  tax-inclusive revenue composition
  distinct Order Count
  ATV
  currency partitioning
  snapshot / aggregate fields beyond total_sold / total_revenue

GAP-PRE-M5-TIME
  sale/refund effective-time bucketing
  NORMAL / AGING / STALE source-freshness projection (backend)
  Johannesburg shift_zone conformance
  index strategy for paid/coalesced sale queries
  source-freshness watermark projection inputs

GAP-PRE-M5-READY-IX
  indexed bounded readiness current-status lookup
```

Hot / warm / cold preservation:

```text
ETS   = hot derived
Redis = warm derived
Postgres = durable financial / certification truth
PubSub = notification only
Cachex = do not add for conformity
```

Caches are never financial truth (M1-05 I15; M1-06 §23).

---

## 13. M6 Entry Dependency Pack

```text
GAP-PRE-M6-UX-01  NORMAL / AGING / STALE banner and copy alignment
GAP-PRE-M6-UX-02  custom-range UX enforcement/copy (UI half)
```

Separate:

```text
backend query bounds / max duration   → REQUIRED_BEFORE_M5 (with aggregate design)
UI enforcement and operator copy      → REQUIRED_BEFORE_M6
```

M6 remains read-only management; no Woo REST from LiveView.

---

## 14. Optional / Later Hardening

Non-blocking; do not serialize M2–M6 behind these:

```text
GAP-OPT-ATTR-01..02
GAP-LATER-ATTR-01
GAP-OPT-ID-01..04
GAP-OPT-REFUND-FIX
GAP-OPT-TIME-AUDIT
GAP-OPT-ATTENDEE-UX
GAP-LATER-FEES
```

Do not promote for aesthetics.

---

## 15. Performance & Scaling Certification

Future implementation of the gap ledger must preserve:

```text
bounded reads; no peak historical full scans
Postgres durable financial / certification truth
ETS hot derived state; Redis warm derived state
PubSub notification only
Oban for heavy / background work
no LiveView / controller Woo REST calls
exact indexed source-scoped lookups
idempotent / restartable M3 ingestion
small bounded readiness reads
no Cachex addition merely for conformity
Woo REST max concurrency 2
parser → OrderUpserter sole durable Order writer
```

Flash-sale concurrency constraints apply primarily to ingestion paths. Do not add seat-map / seat-hold architecture for management analytics.

---

## 16. M2 Entry Contract

M2 becomes **AUTHORIZED** only when all of the following are true:

```text
M1 contracts certified (this document PASS_WITH_PRE_M2… or later PASS after M1-C)
AND all REQUIRED_BEFORE_M2 gaps implemented (GAP-PRE-M2-01)
AND their PR(s) merged
AND focused tests / required checks PASS
AND main synchronized / clean with origin/main
→ M2 AUTHORIZED
```

Until then:

```text
M2 = BLOCKED BY PRE-M2 IMPLEMENTATION GATE (M1-C)
```

M2 objective (unchanged from roadmap):

```text
one exact existing Tickera event
→ exact relevant product mappings
→ exact variations
→ zero cross-contamination
→ BACKFILL_PENDING
```

---

## 17. M2 Non-Dependencies

M2 does **not** require these implemented first:

```text
refund persistence
line_total_tax
date_paid / refund date_created_gmt
financial reconciliation worker
ANALYTICS_READY projection
refund-aware MetricRules
analytics snapshots
stale banner UX
completeness watermarks beyond what M2 records as intended BACKFILL_START discovery
M1-02 NormalizeBaseUrl uniqueness alignment
Ash Event external identity
multi-source webhook routing
```

Evidence: M1-05 §24; M1-06 MG1 timing; M1-07/M1-08 phase tables; M2 scope = operator event onboarding (`path-1-phase-breakdown.md` §9).

Do not serialize the entire product behind future financial implementation.

---

## 18. PR / Review Workflow for Production Code

Applies to **M1-C** and all subsequent Path 1 production gates:

```text
fresh implementation agent
→ dedicated short-lived branch
→ implementation
→ focused tests / checks
→ commit
→ PR
→ actual diff review
→ fixes on same branch / agent
→ re-review
→ merge
→ clean synchronized main
```

```text
Direct-to-main production-code implementation: NOT AUTHORIZED for M1-C
Documentation-only M1 closeout: may commit on main when owner authorizes
```

---

## 19. Certification Matrix

| Contract | Status | Core Truth Locked | Remaining Production Gaps | Blocks |
| --- | --- | --- | --- | --- |
| M1-02 | PASS | Source-scoped identities; fail-closed lookups | Optional/later ID hardening | Nothing for M2 |
| M1-03 | PASS | Event-first + fallback; immutability; statuses | **G1 BEFORE_M2**; G2–G4 opt/later | **M2 via G1** |
| M1-04 | PASS | Completed-only original sale predicate | None unique (handoffs consumed) | Nothing for M2 |
| M1-05 | PASS | Independent refund adjustments | DURING_M3 / BEFORE_M4 / BEFORE_M5 | M3–M5 financial path |
| M1-06 | PASS | Gross/Refund/Net; tax-inclusive; OC; ATV | MG1 DURING_M3; MG2–MG8 BEFORE_M5; MG9 later | M3/M5 metrics |
| M1-07 | PASS | Sale/refund clocks; JHB periods; freshness bands | DURING_M3 persist; BEFORE_M5 bucketing/stale; BEFORE_M6 UX | M3/M5/M6 time UX |
| M1-08 | PASS | Completeness; A≠B≠C; ANALYTICS_READY ≠ freshness | DURING_M3 coverage; BEFORE_M4 watermarks; DURING_M4 recon/ready; BEFORE_M5 index | M3–M5 readiness |

---

## 20. Remaining Risks

```text
R1  M1-C under-scoped or over-scoped (must stay fail-closed parent check only)
R2  Agents treat M1 PASS as “implementation complete” and skip M1-C
R3  Agents start M2 while G1 remains open
R4  Duplicate gap naming causes M3 to re-implement the same change twice
R5  Financial work pulled forward into M2 “while onboarding”
R6  Attendee recon mistaken for financial ANALYTICS_READY gate
R7  Path 2 / Phase 5E accidentally resumed during Path 1
```

---

## 21. Explicit Non-Goals

M1-09 did **not**:

```text
fix G1 / start M1-C
modify attribution code
implement refunds
persist total_tax / date_paid / refund timestamps
implement SyncRun / watermark / financial reconciliation / ANALYTICS_READY
modify MetricRules / snapshots / HotStateAggregator
build dashboard UX
start M2 or M3
perform Path 2 work
Apply / AutoApply
mutate WordPress
re-audit the repository from scratch
revise locked M1-02..M1-08 semantics
```

---

## 22. M1 Final Verdict

```text
M1-09 VERDICT:
PASS_WITH_PRE_M2_IMPLEMENTATION_GATE

M1 CONTRACT CERTIFICATION:
PASS

CROSS-CONTRACT CONTRADICTIONS:
NONE

REQUIRED_BEFORE_M2 GAPS:
1 (GAP-PRE-M2-01)

PRE-M2 GATE:
M1-C — PRE-M2 Contract Conformance Gate
(event-first TicketType variation-parent fail-closed only)

M2 AUTHORIZATION:
BLOCKED_PENDING_PRE_M2_GATE
```

M1 contract work is complete. Implementation must conform on G1 before M2.

---

## 23. Immediate Next Action

```text
Authorize a fresh agent to execute M1-C on a short-lived branch + PR:
implement GAP-PRE-M2-01 fail-closed parent check with focused tests;
merge; synchronize clean main; then authorize M2.
```

Do not start M2, M3, or Path 2.

---

## 24. M2 Handoff

After M1-C merges, M2 agents may assume:

```text
M1-02..M1-09 contracts locked and certified
GAP-PRE-M2-01 closed in production
identity / attribution / recognised-sale / refund / metric / time / readiness
  contracts are the source of truth for later phases
parser → OrderUpserter remains sole durable Order writer
Catalog / Sales / Ingestion / Analytics / Accounts boundaries stand
Path 2 / Phase 5E remains PAUSED
No Apply / AutoApply
```

M2 must still implement its own onboarding tasks (M2-01..M2-08), including onboarding-time parent validation (M2-04 / M2-06). Those are **M2 work**, not substitutes for M1-C’s runtime attribution fix.

M2 must **not** implement refund persistence, MetricRules overhaul, financial reconciliation, or ANALYTICS_READY workers.

---

## Appendix A — Timing Vocabulary (locked)

```text
REQUIRED_BEFORE_M2
REQUIRED_DURING_M3
REQUIRED_BEFORE_M4
REQUIRED_DURING_M4
REQUIRED_BEFORE_M5
REQUIRED_BEFORE_M6
REQUIRED_LATER
OPTIONAL_HARDENING
```

No other urgency classes invented by M1-09.
