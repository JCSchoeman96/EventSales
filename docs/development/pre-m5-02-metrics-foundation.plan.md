---
Plan ID: pre-m5-02-metrics-foundation
Plan version: v2
Status: design approved — conformance specification (PRE-M5-02A)
Scope: Authoritative metrics foundation for PRE-M5 and M5 read models
Authority: This file is the active contract for metric semantics and invariants
Execution sequencing: `docs/development/pre-m5-02-metrics-foundation-implementation.plan.md` (does not override this contract)
Historical context: Path 1 roadmap and M1-05/M1-06/M1-08 where not superseded here
Last updated: 2026-09-22
Change summary (v2): Align narrative with Path 1 handoff v22 READY-IX CLOSED documentation closeout
---

### Revision log

- v1 — initial design approved conformance specification from specification review
- v2 — note Path 1 handoff v22 records READY-IX CLOSED (no metric semantic change)

# EventSales PRE-M5-02A — Authoritative Metrics Foundation Design

## 1. Document status

| Field                     | Value                                      |
| ------------------------- | ------------------------------------------ |
| Plan ID                   | `pre-m5-02-metrics-foundation`             |
| Slice                     | `PRE-M5-02A`                               |
| Type                      | Architecture / conformance specification   |
| Repository baseline       | `a90f4a6d991510684dde80a538c0847635de2ee9` |
| Programme                 | Path 1 — Trusted Management Analytics      |
| Status                    | DESIGN APPROVED — SPECIFICATION REVIEW     |
| Production implementation | NOT AUTHORIZED BY THIS DOCUMENT            |
| Primary gap               | `GAP-PRE-M5-METRICS`                       |
| Remaining independent gap | `GAP-PRE-M5-TIME`                          |
| M5                        | BLOCKED                                    |

The verified PRE-M5 READY-IX work is complete through PR #244 and post-merge CI #621. Path 1 handoff `v22` and the phase breakdown record `GAP-PRE-M5-READY-IX` as CLOSED. That documentation closeout must not reopen the already-certified READY-IX implementation. The roadmap remains authoritative for overall sequencing and states that the PRE-M5 conformance gate precedes M5.

---

## 2. Ultimate goal and backward plan

### Ultimate goal

Provide management-facing EventSales analytics whose financial and ticket metrics are:

- historically correct;
- tax-inclusive;
- refund-aware;
- currency-safe;
- deterministic;
- bounded under load;
- safe for use as the durable basis of M5 dashboard read models;
- protected by the existing `ANALYTICS_READY` authority gate.

The final M5 dashboard must never reconstruct financial truth from arbitrary order scans at request time.

### Backward dependencies

```text
Trusted M5 dashboard
        ↓
Authoritative bounded snapshot reads
        ↓
Currency-partitioned durable aggregate snapshots
        ↓
Canonical event-level financial aggregation
        ↓
Locked financial metric rules
        ↓
Durable Order / OrderItem / Refund / RefundLine facts
        ↓
M3 completeness + M4 reconciliation + ANALYTICS_READY
```

PRE-M5-02 closes only the **metric-semantic and aggregate-model gap**.

It must not absorb the separate PRE-M5-TIME responsibilities for effective timestamps, Johannesburg period boundaries, source freshness or the `paid_at` query/index work.

---

## 3. Authority and existing foundations

The implementation must obey repository authority precedence and the repository rule to inspect and extend existing functionality rather than create parallel systems.

### Existing modules to REUSE / EXTEND

| Existing component                                         | Role                                                  |
| ---------------------------------------------------------- | ----------------------------------------------------- |
| `EventSales.Sales.FinancialPrimitives`                     | Canonical primitive arithmetic                        |
| `EventSales.Analytics.MetricRules`                         | Analytics metric-rule facade                          |
| `EventSales.Analytics.Aggregators.EventAggregator`         | Event-scoped aggregate boundary                       |
| `EventSales.Analytics.Resources.EventAggregateSnapshot`    | Durable event aggregate projection                    |
| `EventSales.Analytics.SnapshotRefresh`                     | Snapshot write/refresh boundary                       |
| `EventSales.Analytics.SnapshotReader`                      | Snapshot-only durable read boundary                   |
| `EventSales.Ingestion.AnalyticsReadinessResolver`          | Existing authority/readiness composition              |
| `EventSales.Ingestion.FinancialReconciliation.LocalTotals` | Certified semantic/query reference, not dashboard API |

`FinancialPrimitives` already provides historical recognition and exact Gross/Refund/Net primitive arithmetic without clamping. It remains the arithmetic authority.

`LocalTotals` already implements certified historical-recognition, integrity validation, refund qualification and currency-partitioned Postgres aggregation for financial reconciliation. Its semantics should inform PRE-M5 analytics, but Analytics must not simply make M4 reconciliation machinery its runtime dashboard dependency.

---

## 4. Current gap

Current `MetricRules` remains legacy-compatible rather than M1-06 authoritative:

```text
current Order.status == :completed
+ mapped ticket
+ positive quantity
```

and current revenue uses only `OrderItem.line_total`.

This violates the locked PRE-M5 target because:

```text
Gross recognition must survive later refund/status mutation.
Gross Ticket Sales must be tax-inclusive.
Refund facts must independently reduce Net.
Recognised Order Count must be distinct.
ATV must derive from Net value / Net quantity.
Money must remain currency-partitioned.
```

The canonical M1 gap ledger explicitly identifies tax-inclusive Gross, Gross preservation + Net, distinct Order Count, ATV, currency partition and snapshot fields as `GAP-PRE-M5-METRICS`.

---

## 5. Domain resource map

### Sales durable truth

```text
Order
 ├── source_system_id
 ├── woo_order_id
 ├── currency
 ├── status
 ├── completed_at
 └── paid_at

OrderItem
 ├── order_id
 ├── event_id
 ├── ticket_type_id
 ├── mapping_status
 ├── item_kind
 ├── quantity
 ├── line_total
 └── line_total_tax

Refund
 ├── order_id
 ├── source_state
 ├── detail_status
 ├── currency
 └── source_created_at

RefundLine
 ├── refund_id
 ├── bound ticket/order-line identity
 ├── quantity
 ├── total
 └── tax
```

Postgres remains durable authority.

### Analytics projection

```text
EventAggregateSnapshot
        ↓
one row per:
(event_id, currency)
```

No new Ash domain is required.

No new financial-truth resource is justified unless later implementation proves the existing aggregate resource cannot safely be extended.

---

## 6. Canonical financial metric model

The following names are canonical for PRE-M5/M5 financial aggregation.

| Metric                 | Rule                                                                | Persistence                 |
| ---------------------- | ------------------------------------------------------------------- | --------------------------- |
| Gross Ticket Quantity  | Historical recognised original ticket quantity                      | Base primitive              |
| Refund Ticket Quantity | Qualifying bound ticket-refund quantity magnitude                   | Base primitive              |
| Net Ticket Quantity    | Gross − Refund                                                      | Derived                     |
| Gross Ticket Value     | `line_total + line_total_tax`                                       | Base primitive              |
| Refund Ticket Value    | Qualifying tax-inclusive refund magnitude                           | Base primitive              |
| Net Ticket Value       | Gross − Refund                                                      | Derived                     |
| Recognised Order Count | Distinct historically recognised source-scoped orders for the scope | Base aggregate              |
| Average Ticket Value   | Net Ticket Value ÷ Net Ticket Quantity                              | Derived                     |
| Status Breakdown       | Current operational lifecycle context                               | Separate operational metric |

The M1-06 contract explicitly requires tax-inclusive Gross and identifies `MetricRules` as requiring implementation changes.

### Derived-metric rule

Do not persist or add together:

```text
Net Ticket Quantity
Net Ticket Value
Average Ticket Value
```

when they can be deterministically derived from additive primitives.

ATV must always be recomputed from its components.

---

## 7. Required invariants

### Historical recognition

A ticket line contributes to Gross when the underlying order has durable historical evidence that it became recognised.

A later state such as:

```text
completed → refunded
```

must not remove its Gross contribution.

### Refund independence

Refunds are adjustment facts.

They do not rewrite original Gross facts.

```text
Gross − Refund = Net
```

### No negative clamping

If refunds exceed Gross:

```text
Net Ticket Quantity < 0
or
Net Ticket Value < 0
```

must remain visible as negative.

Do not silently clamp to zero.

### Tax-inclusive value

```text
Gross Ticket Value
=
line_total
+
line_total_tax
```

No inferred tax rate.

No allocation from order-level totals.

### Currency

Money aggregation is allowed only inside one currency.

```text
ZAR + ZAR → valid
USD + USD → valid
ZAR + USD → forbidden aggregate
```

No FX conversion belongs in PRE-M5.

### Order count

Recognised Order Count is distinct by the canonical source-scoped order identity.

It must never be produced by summing counts from overlapping event/product scopes.

### ATV

```text
Net Ticket Quantity == 0
→ ATV = N/A / nil / undefined
```

Never report monetary zero as the semantic replacement for an undefined ratio.

### Status context

Current `Order.status` may be reported as operational context.

It must not become the authority for historical Gross/Net financial calculation.

Operational `status_breakdown` retains its current legacy semantics during PRE-M5-02 unless a separate contract changes it.

---

## 8. Snapshot grain

Current `EventAggregateSnapshot` has a single-event identity despite also storing `currency`.

That is insufficient for MG7.

### Target identity

```text
(event_id, currency)
```

Each currency partition receives its own durable snapshot row.

Example:

```text
event A / ZAR
event A / USD
```

must produce two independent projections.

### Canonical persisted fields

Target canonical financial fields:

```text
gross_ticket_quantity
refund_ticket_quantity

gross_ticket_value
refund_ticket_value

recognised_order_count

currency
```

Existing projection metadata remains available where appropriate:

```text
event_id
business_timezone
refreshed_at
source_watermark_at
source_row_count
snapshot_version
status_breakdown
```

### Snapshot version

Canonical financial snapshots must increment the snapshot version.

Existing version-1 rows must not silently acquire the meaning of the new metric contract.

Old projection rows may remain physically present during migration, but canonical readers must fail closed rather than expose stale-version financial semantics as current truth.

Canonical financial snapshots use version `2`.

---

## 9. Compatibility strategy

Do not rename `total_sold` or `total_revenue` and silently change their meaning.

That would create an undocumented semantic migration.

Instead:

```text
1. Add canonical financial fields.
2. Produce canonical projections.
3. Add canonical reader APIs.
4. Migrate consumers deliberately.
5. Retain legacy fields/functions only as compatibility surfaces.
6. Retire ambiguous legacy names in a later explicit cleanup.
```

Current dashboards expect scalar `total_sold`, `total_revenue` and one `currency`.

Therefore mixed-currency events must fail closed through legacy APIs rather than selecting an arbitrary snapshot.

---

## 10. Reader contract

`SnapshotReader.summary_for_event/1` currently performs a single snapshot read and assumes event-level uniqueness.

The canonical model needs currency-aware APIs.

Target conceptual API:

```text
financial_summaries_for_event(event_id)
→ currency-partitioned summaries

financial_summary_for_event(event_id, currency)
→ exactly one financial summary
```

Exact function names may follow repository naming conventions during implementation planning, but semantics are fixed.

Legacy event-summary reads may operate only when:

```text
exactly one compatible currency projection exists
```

Mixed currency must not be resolved by:

```text
LIMIT 1
first row
default currency
alphabetical currency
latest refreshed row
```

---

## 11. Calculation vs authority

Keep calculation and authority separate.

### Calculation layer

Answers:

```text
What are the deterministic financial primitives and derived metrics?
```

### Authority layer

Answers:

```text
May management rely on these metrics?
```

The existing `AnalyticsReadinessResolver` remains responsible for the second question.

Do not add:

```text
AnalyticsReady resource
analytics_ready boolean column
cached readiness flag
```

without a separate contract revision.

### Presentation requirement

When refund completeness / reconciliation is not authoritative:

```text
Refund
Net
ATV
```

must be withheld or explicitly non-authoritative.

The M1-06 contract explicitly forbids pretending Net equals Gross merely because refund facts are incomplete.

---

## 12. Projection lifecycle

`EventAggregateSnapshot` is a derived projection, not a financial source-of-truth lifecycle entity.

Its lifecycle is:

```text
MISSING
   │ successful refresh
   ▼
CURRENT
   │ relevant durable fact changes / invalidation
   ▼
STALE
   │ successful refresh
   └──────────────────────► CURRENT
```

### States

| State     | Meaning                                                                  |
| --------- | ------------------------------------------------------------------------ |
| `MISSING` | No compatible canonical projection exists                                |
| `CURRENT` | Projection represents its declared durable source state                  |
| `STALE`   | Underlying durable facts have changed or projection has been invalidated |

### Guards

`MISSING → CURRENT`

Requires successful bounded calculation and successful durable snapshot write.

`CURRENT → STALE`

Triggered by relevant source changes or explicit cache/projection invalidation.

`STALE → CURRENT`

Requires a successful recalculation and snapshot write.

### Side effects

Successful refresh:

```text
persist Postgres projection
invalidate event cache
```

### Terminal states

None.

Projection failure must leave the previous durable projection distinguishable from newly certified data; failure must not falsely promote stale data.

---

## 13. EventAggregator responsibility

The roadmap requires reuse/extension of `EventAggregator`, not a parallel analytics hierarchy.

Current `EventAggregator` loads all event `OrderItem` rows and delegates to `MetricRules`.

The authoritative M5 path must instead support bounded Postgres aggregation.

Therefore:

```text
REUSE EventAggregator public boundary.
EXTEND/refactor its authoritative financial path.
DO NOT introduce a parallel EventFinancialAggregator unless implementation proves a hard boundary requires it.
```

Legacy compatibility functions may continue temporarily.

Canonical aggregation must not rely on loading arbitrary event history into BEAM memory.

---

## 14. SnapshotRefresh responsibility

Current `SnapshotRefresh` reads all event order rows into memory and chooses currency from the first appropriate order row.

That must not remain the authoritative financial refresh algorithm.

Target:

```text
SnapshotRefresh
→ request bounded canonical aggregation
→ receive currency partitions
→ upsert one EventAggregateSnapshot per event+currency
→ invalidate DashboardCache after successful write
```

Do not add Redis or Cachex writes here as part of PRE-M5-02.

---

## 15. Daily snapshot boundary

`DailySalesAggregateSnapshot` currently has identity:

```text
event_id
business_date
business_timezone
```

while also carrying a currency field.

Its eventual authoritative grain must account for currency.

However, PRE-M5-02 must **not** redesign daily financial bucketing because PRE-M5-TIME still owns:

```text
paid_at → completed_at sale effective time
refund source_created_at
Africa/Johannesburg timezone shifting
[start, end) period semantics
source freshness
```

PRE-M5-02 may document the future daily currency requirement but must not prematurely implement the time contract.

---

## 16. Folder and naming boundaries

Prefer existing structure:

```text
lib/event_sales/analytics/
├── metric_rules.ex
├── aggregators/
│   └── event_aggregator.ex
├── resources/
│   └── event_aggregate_snapshot.ex
├── snapshot_refresh.ex
├── snapshot_reader.ex
├── event_scoped_dashboard.ex
└── ...

lib/event_sales/sales/
└── financial_primitives.ex
```

Tests should mirror these boundaries:

```text
test/event_sales/analytics/
├── metric_rules_test.exs
├── aggregators/
│   └── event_aggregator_test.exs
├── snapshot_refresh_test.exs
├── snapshot_reader_test.exs
└── event_scoped_dashboard_test.exs
```

Do not create:

```text
EventSales.Finance
EventSales.Reporting
EventSales.Management
EventSales.Reconciliation
```

for this slice.

---

## 17. Performance and scaling review

### Data-layer classification

| Data                                        | Layer                                 |
| ------------------------------------------- | ------------------------------------- |
| Orders / OrderItems / Refunds / RefundLines | Cold durable Postgres                 |
| EventAggregateSnapshot                      | Cold durable Postgres read model      |
| DashboardCache                              | Existing hot ETS/cache boundary       |
| Shared future M5 cache                      | Redis warm layer under M5-08          |
| Static assets                               | CDN/browser — unrelated to this slice |

### Peak-safety requirements

The authoritative dashboard request path must not:

```text
scan OrderItem history
scan Refund history
load event history into BEAM
perform N+1 refund lookups
calculate distinct order counts from overlapping child aggregates
```

The refresh path may perform bounded Postgres aggregation because it is not the dashboard request path.

Critical aggregate paths require appropriate indexes on their filter/join keys.

The implementation plan must explicitly inspect query plans for:

```text
event
historical recognition
order/refund joins
currency grouping
distinct recognised order identity
```

No new Cachex requirement is introduced here.

The later M5 caching contract remains responsible for the hot/warm/cold read architecture.

### Target behavior

```text
dashboard request:
bounded indexed snapshot/cache lookup

snapshot refresh:
bounded Postgres aggregation

no peak-time full history scans
```

---

## 18. Concurrency

Financial snapshot refresh must tolerate two refresh attempts for the same event.

Required outcome:

```text
no duplicate event+currency snapshot rows
no mixed partial currency set exposed as authoritative
no lost snapshot identity
```

The unique `(event_id, currency)` identity is the primary database guard.

If multi-row currency refresh cannot be made transactionally safe with the existing flow, implementation must stop and elevate that design issue before inventing distributed locking.

Do not introduce Redis locks unless a concrete race proves the database/transaction design insufficient.

---

## 19. Security and access

The metric kernel and snapshot resources contain aggregate financial data, not PII.

Existing dashboard authorization remains mandatory.

`EventScopedDashboard` currently authorizes event access before revealing event existence and separately applies revenue visibility. That privacy ordering must remain intact.

PRE-M5-02 must not weaken:

```text
event assignment authorization
revenue visibility policy
PII visibility
```

Currency partitioning must not accidentally bypass revenue access controls.

---

## 20. Failure modes

Implementation must explicitly test or fail closed for:

| Failure                                            | Required response                                                                 |
| -------------------------------------------------- | --------------------------------------------------------------------------------- |
| Missing `line_total`                               | Do not certify Gross money                                                        |
| Missing `line_total_tax`                           | Do not certify Gross money                                                        |
| Missing currency                                   | Reject/withhold monetary projection                                               |
| Mixed currency                                     | Separate projection rows                                                          |
| Incomplete refund evidence                         | Refund/Net/ATV non-authoritative                                                  |
| Current status no longer completed                 | Preserve historically recognised Gross                                            |
| Refund exceeds Gross                               | Preserve negative Net                                                             |
| Net quantity = 0                                   | ATV N/A                                                                           |
| Duplicate order lines                              | Respect durable identity/integrity contract                                       |
| Multiple ticket lines in one order                 | Recognised Order Count remains 1 per event scope                                  |
| One order attributed to multiple events            | Distinct count evaluated independently per event; never sum event counts globally |
| Snapshot version mismatch                          | Fail closed / refresh required                                                    |
| Concurrent refresh                                 | No duplicate `(event,currency)` rows                                              |
| Snapshot write failure                             | Do not advertise failed refresh as current                                        |
| Cache invalidation failure                         | Must not corrupt Postgres truth                                                   |
| Legacy single-currency API on mixed-currency event | Explicit mixed-currency failure, not arbitrary row selection                      |

---

## 21. Regression matrix

At minimum the eventual implementation must prove:

```text
1. Historical Gross survives completed → refunded status change.

2. Gross money includes line_total_tax.

3. Refund quantity reduces only Net quantity.

4. Refund money reduces only Net value.

5. Gross is unchanged by refunds.

6. Over-refund produces negative Net and is not clamped.

7. Two qualifying lines from one order count as one Recognised Order.

8. Distinct Recognised Order Count cannot be reconstructed by summing overlapping scopes.

9. Net quantity zero produces undefined/N/A ATV.

10. ZAR + USD generate separate financial projections.

11. Legacy single-currency reads do not arbitrarily choose one mixed-currency row.

12. Operational status breakdown does not alter financial Gross/Net.

13. Snapshot version 1 is not silently treated as canonical v2 financial truth.

14. Dashboard reads use projection/cache paths rather than sales/refund table scans.

15. Existing M4 financial reconciliation behavior remains unchanged.
```

---

## 22. Implementation sequence

### PRE-M5-02A — Metrics architecture / conformance specification

This document.

No production code.

### PRE-M5-02B — Canonical metric kernel

Purpose:

```text
lock canonical financial calculations and compatibility behavior
```

Primary ownership:

```text
MetricRules
FinancialPrimitives reuse
focused unit tests
```

No snapshot migration yet.

### PRE-M5-02C — Bounded event/currency aggregation

Purpose:

```text
produce canonical event+currency primitives using bounded Postgres queries
```

Primary ownership:

```text
EventAggregator
query-plan tests / integration tests
```

No dashboard consumer migration yet.

### PRE-M5-02D — EventAggregateSnapshot v2

Purpose:

```text
change projection grain to event+currency
persist canonical additive primitives
version the snapshot contract
```

Primary ownership:

```text
EventAggregateSnapshot
migration
Ash resource snapshot
schema tests
```

### PRE-M5-02E — Refresh / reader integration

Purpose:

```text
write canonical currency projections
read them deterministically
preserve legacy compatibility fail-closed
```

Primary ownership:

```text
SnapshotRefresh
SnapshotReader
EventScopedDashboard only where required
```

### PRE-M5-02F — Metrics certification

Purpose:

```text
prove MG2 + MG4–MG8 closed
prove M4 unchanged
prove bounded authoritative read path
```

Only after 02F can:

```text
GAP-PRE-M5-METRICS = CLOSED
```

Detailed TOON tasks and branch policy live in `docs/development/pre-m5-02-metrics-foundation-implementation.plan.md`.

---

## 23. Explicit non-goals

PRE-M5-02 must not implement:

```text
M5 dashboard UX
period comparisons
sales velocity
capacity / occupancy
analytics caching architecture
new Redis structures
new Cachex dependency
source freshness UI
Johannesburg effective-time bucketing
paid_at index work
refund-time period bucketing
FX conversion
Tax Amount reporting
Ticket Fee reporting
Discount reporting
new analytics-ready persistence
```

Those belong to other contracts/slices.

---

## 24. Linear / governance

Before each implementation sub-slice begins:

```text
Linear issue must match the exact PRE-M5 sub-slice.
Issue must record authority docs and baseline.
Issue must remain IN PROGRESS until merge + post-merge CI.
Issue must not be marked complete from local tests alone.
```

Repository roadmap/status documentation should be updated during appropriate closeout work so that READY-IX is no longer shown as open and the active PRE-M5 slice is unambiguous.

Do not mix roadmap cleanup into production-code commits unless the slice explicitly owns that documentation.

---

## 25. STOP conditions

The coding agent must STOP immediately if any of these occurs:

```text
origin/main moves from the authorized baseline before branch creation

required semantics conflict with M1-05/M1-06/M1-08

implementation would duplicate FinancialPrimitives formulas

implementation would make LocalTotals the dashboard runtime API

event/currency grain cannot be represented without losing current projection data semantics

Recognised Order Count is being summed across overlapping scopes

mixed currencies would be collapsed

ATV would be persisted or summed as an aggregate primitive

negative Net would be clamped

legacy total_revenue is being silently redefined

PRE-M5-TIME behavior is required to complete the current metric slice

dashboard request path requires unbounded OrderItem/Refund scans

concurrent refresh cannot be made safe with transaction + DB identity rules

unrelated migration/codegen drift appears

existing M4 reconciliation tests regress

focused tests fail

mix quality.fast fails

mix quality.pr fails before review/merge
```

At a STOP condition, report the exact blocker and do not invent a workaround.

---

## 26. Success criteria

PRE-M5 metrics is complete only when all of the following are true:

```text
Tax-inclusive Gross = PASS
Historical Gross preservation = PASS
Refund-aware Net = PASS
Distinct Recognised Order Count = PASS
ATV zero-denominator semantics = PASS
Currency partition = PASS
EventAggregateSnapshot canonical fields = PASS
Event+currency identity = PASS
Mixed-currency fail-closed compatibility = PASS
Bounded Postgres aggregation = PASS
No peak dashboard sales/refund scan = PASS
M4 financial reconciliation regression = PASS
Post-merge CI = PASS
```

Programme result after PRE-M5-02F:

```text
GAP-PRE-M5-READY-IX     CLOSED (UNCHANGED)
GAP-PRE-M5-METRICS      CLOSED
GAP-PRE-M5-TIME         OPEN

M5                      BLOCKED
NEXT                    PRE-M5-TIME
```

Only after the separate time/freshness conformance work also passes may the programme perform the final PRE-M5 certification required to authorize M5.

PRE-M5 metrics completion does **not** authorize M5 by itself.
