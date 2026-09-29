---
Plan ID: m5-02-ticket-product-variation-aggregates
Plan version: v2
Status: M5-02A planning / conformance audit (docs only)
Linear: JC-294
Scope: Ticket / product / variation dimensional aggregate architecture for Path 1 M5-02
Authority base SHA: c6a8708903d0d76eebc16024b6ff80b74a2161b2
Authority base tree: a122ab8655f21e793af494a2f81bf6c4d80fca84
Programme: M5-01 COMPLETE (PASS); B01–B23 CERTIFIED; next implementation programme = M5-02
Last updated: 2026-09-29
Change summary (v2): Correct ANALYTICS_READY vs projection maintenance (M5-01 B18); lock single normalized dimensional resource topology; lock same-event dimension-only B23 invalidation via `HistoricalOrderMutationDetector`; fix historical cardinality wording.
Change summary (v1): Initial M5-02A audit; architectural alternatives; grain and identity matrix; M5-03 boundary; mutation matrix; gap ledger; IMPLEMENTATION_REQUIRED with split M5-02B+ sequence.
---

### Naming note

```text
M5-02A is the current Ticket/Product/Variation aggregate planning slice.
It is NOT the historical PRE-M5-02A metrics-conformance slice.
```

Historical **PRE-M5-02A** remains `docs/development/pre-m5-02-metrics-foundation.plan.md` (metrics foundation; COMPLETE). Do not rename or rewrite PRE-M5-02A records.

### Revision log

- `v2` — Readiness separation corrected; one normalized projection locked; same-event dimension-only mutation invalidation locked; historical cardinality wording corrected (independent review JC-294).
- `v1` — M5-02A conformance audit on authority base `c6a87089` / tree `a122ab86`; terminal decision and M5-02B+ slice map.

# M5-02A — Ticket / Product / Variation aggregate planning and conformance audit

> Planning artifact only. No production code, tests, migrations, indexes, or dependency changes in M5-02A.

## 1. Backward planning: management outcome → MVP

### 1.1 Management outcome (target)

Operators need **event-scoped breakdowns** of recognised ticket sales by:

```text
internal TicketType (reportable category under the event)
source-scoped Woo product (logical product identity)
source-scoped Woo variation (parent product + variation id)
```

…without peak-time full-history scans, without confusing catalogue labels with financial identity, and without breaking certified M5-01 event+currency totals.

### 1.2 MVP (smallest shippable M5-02)

```text
For one event and one currency partition:
  durable cold derived rows for each historically represented dimensional grain
  gross_ticket_quantity + gross_ticket_value (tax-inclusive, M1-06 historical gross split)
  refreshed through existing B23 orchestration (same event enqueue, no second scheduler)
  management reads via snapshot-style reader (not LiveView → raw OrderItem scan)
  catalogue display names resolved at read time from TicketType / optional mapping metadata
```

Explicitly **out of MVP** (M5-03+ or later M5-02 extension):

```text
dimensional refund quantity/value
dimensional net quantity/value
dimensional ATV
dimensional recognised-order distinct counts
period-preset dimensional slices (M5-04)
Path 2 / acquisition analytics
new Catalog.Product resource
widening EventAggregateSnapshot uniqueness
```

### 1.3 Gap driving implementation

| Surface | Today | Problem |
| --- | --- | --- |
| `EventAggregateSnapshot` | Certified `(event_id, currency)` v2 financial totals | Correct event rollup; **no dimensional rows** |
| `EventAggregator` | `group_by: o.currency` only | Canonical event financials; **no dimensional GROUP BY** |
| `EventSales.Analytics.EventDetail` | Per-event `ticket_type_aggregate_rows/1` scans `sales_order_items` | **Peak raw scan**; uses `order.status == "completed"` and **ex-tax** `line_total` — **not** M1-06 / `EventAggregator` recognised-sale + tax-inclusive gross |
| Product / variation breakdown | No first-class reader | Operators infer from line exports or ad-hoc SQL |
| B23 refresh | `RefreshSnapshotWorker` → `SnapshotRefresh.refresh_event/1` | Rebuilds **event** snapshot only |

---

## 2. Authority and conflict rules

| Authority | Role |
| --- | --- |
| `docs/path-1/m1-02-source-scoped-external-identity-contract.md` | Source-scoped Woo product/variation tuples; OrderItem line identity |
| `docs/path-1/m1-03-event-product-variation-orderline-attribution-contract.md` | Historical immutability; mapping vs source evidence; correction boundary |
| `docs/path-1/m1-04-order-lifecycle-and-recognised-sale-contract.md` | Recognised sale filters (completed / `completed_at`) |
| `docs/path-1/m1-05-refund-and-financial-adjustment-contract.md` | Refund primitives; no gross mutation on refund |
| `docs/path-1/m1-06-financial-metric-dictionary.md` | Gross/Net/ATV; currency partitions; tax-inclusive gross value |
| `docs/development/pre-m5-02-metrics-foundation.plan.md` | PRE-M5-02A (historical); locked event snapshot v2 semantics |
| `docs/evidence/m5-01-base-event-aggregates-certification.md` | B01–B23; B23 mutation seams; **mapping-only does not enqueue refresh** |
| `docs/development/m5-01-base-event-aggregates.plan.md` | M5-01 COMPLETE; **do not widen** `EventAggregateSnapshot` grain without proof |
| `docs/path-1/path-1-phase-breakdown.md` M5 row | M5-02 EXTEND; no Product resource; M5-03 owns revenue/refund aggregate extensions |

Conflict rule: locked M1 + M5-01 + PRE-M5-02F evidence win over roadmap TBD cells.

---

## 3. Domain / resource map

```text
EventSales.Catalog
  Event
  TicketType          (internal reportable category; UUID PK)
  ProductMapping      (catalogue link; source-scoped Woo ids → event + ticket_type)
  SourceSystem

EventSales.Sales
  Order                 (source_system_id, currency, lifecycle timestamps)
  OrderItem             (historical line evidence + derived event_id / ticket_type_id)
  OrderUpserter / RefundUpserter / MissingCatalogResolver / OrderAttributionCorrection

EventSales.Analytics  (existing — extend, do not fork)
  EventAggregator           (bounded SQL; event + currency today)
  EventAggregateSnapshot    (certified event + currency v2)
  SnapshotRefresh           (refresh_event/2 transactional persist)
  SnapshotReader            (canonical financial reads)
  RefreshSnapshotWorker     (Oban; event scope)
  DashboardCache / HotStateAggregator
  EventDetail               (admin detail; legacy ticket_type scan — conformance debt)

Proposed (M5-02B+, not in M5-02A):
  EventDimensionAggregateSnapshot  (working name)
  DimensionAggregator              (bounded GROUP BY queries)
  DimensionSnapshotReader          (read boundary)
```

No new Ash domain. No `Catalog.Product` resource (Path-1 forbids convenience Product entity).

---

## 4. Relationships (attribution vs catalogue)

```text
Order (source_system_id, currency)
  └─ OrderItem (order_id, woo_line_item_id) unique
        ├─ SOURCE EVIDENCE: woo_product_id, woo_variation_id, source_tickera_event_id, name
        ├─ DERIVED: event_id, ticket_type_id, mapping_status, item_kind
        └─ FINANCIAL SNAPSHOT: quantity, line_total, line_total_tax

TicketType ──belongs_to── Event
ProductMapping ──belongs_to── SourceSystem, Event, TicketType
  active catalogue row for (source_system_id, woo_product_id [, woo_variation_id])
```

**Attribution flow (unchanged):** event-first Tickera meta, else ProductMapping fallback (`M1-03`). ProductMapping is **catalogue evidence**, not historical financial identity.

---

## 5. Canonical identity matrix

| Concept | Authority tuple / key | Used for dimensional grain? | Notes |
| --- | --- | --- | --- |
| TicketType | `ticket_type.id` (UUID) | **Yes** — `ticket_type` dimension | Name/capacity/active are presentation/catalogue |
| Logical Woo product | `(source_system_id, woo_product_id)` | **Yes** — `source_product` dimension | `source_system_id` from **Order**, not OrderItem |
| Logical Woo variation | `(source_system_id, woo_product_id, woo_variation_id)` | **Yes** — `source_variation` dimension | Variation id **alone** is never global |
| OrderItem line | `(order_id, woo_line_item_id)` | **No** (too fine) | Source of facts for aggregation |
| OrderItem `woo_*` on line | Historical snapshot on line | **Yes** — product/variation grouping keys | Must not be replaced by current ProductMapping target |
| ProductMapping row | Catalogue link | **No** for historical membership | Changing mapping does not rewrite past lines (M1-03) |
| Ticket label / product name / SKU | NOT AUTHORITY | Display only at read time | Forbidden as join keys |

Physical partial uniques on `ProductMapping` (`product_mapping.ex`) certify variation requires parent product in catalogue layer; dimensional SQL must join `orders.source_system_id` when grouping by Woo ids.

---

## 6. Candidate aggregate grain matrix

All monetary metrics are **partitioned by `currency`** (order currency). Mixed-currency scalar collapse remains forbidden (M5-01 B11).

| Grain ID | Uniqueness key (per snapshot generation) | Row describes | Cardinality bound |
| --- | --- | --- | --- |
| `ticket_type` | `event_id` + `currency` + `ticket_type_id` | Recognised gross qty/value for mapped ticket lines attributed to that TicketType | ≤ distinct historically attributed `ticket_type_id` values on recognised ticket lines for the event (includes inactive TicketTypes) |
| `source_product` | `event_id` + `currency` + `source_system_id` + `woo_product_id` | Same metrics for lines with that product evidence (variation id may be null on line) | ≤ distinct `(source_system_id, woo_product_id)` pairs on qualifying lines |
| `source_variation` | `event_id` + `currency` + `source_system_id` + `woo_product_id` + `woo_variation_id` | Lines where `woo_variation_id` IS NOT NULL | ≤ distinct source-scoped variation tuples on qualifying lines |

**Lines with null `woo_variation_id`:** contribute to `source_product` only, not a variation row.

**Unmapped / non-ticket lines:** excluded via same `recognised_sale_item_filters` as `EventAggregator` (`mapped`, `item_kind == ticket`, quantity > 0, recognised order).

**No grain** uses ProductMapping id as a key.

---

## 7. Currency treatment

```text
Partition key: Order.currency (via join), identical to M5-01 event rollup.
Each grain row is per (event_id, currency, dimension keys).
Multi-currency events produce independent row sets per currency.
Readers must not sum across currencies without explicit operator action.
```

Dimensional rows must **reconcile upward**: for each currency, sum of `gross_ticket_quantity` across `ticket_type` rows should equal event-level `gross_ticket_quantity` from `EventAggregator` for that currency (certification target in M5-02F).

---

## 8. Metric ownership: M5-02 vs M5-03

| Metric | M5-01 event snapshot | M5-02 (this programme) | M5-03 (later) |
| --- | --- | --- | --- |
| `gross_ticket_quantity` (event) | Yes | — | — |
| `gross_ticket_quantity` (per dimension) | No | **OWN** | — |
| `gross_ticket_value` tax-inclusive (event) | Yes | — | — |
| `gross_ticket_value` tax-inclusive (per dimension) | No | **OWN** (historical gross **split**) | — |
| `refund_ticket_quantity` / `refund_ticket_value` (event) | Yes | — | Dimensional refund ownership |
| Net qty/value | Derived (event) | **Not in M5-02 MVP** | Dimensional net |
| ATV | Derived (event) | **Not in M5-02** | Dimensional ATV |
| `recognised_order_count` | Event | **Not in M5-02 MVP** | Optional later |
| Status breakdown | Event snapshot field | Out of scope | — |

**M1-06 authority (gross split):** Gross Ticket Sales scope explicitly includes Event / TicketType / Product / Variation; Product / Ticket-Type Revenue uses the same gross/refund/net formulas by durable historical attribution. M5-02 therefore **owns the additive gross dimensional split** (`gross_ticket_quantity`, tax-inclusive `gross_ticket_value`).

**Refund boundary:** M5-01 refund aggregates join refund lines to **current** mapped ticket items in the event (`event_ticket_items_subquery`). Dimensional **refund** allocation requires explicit line→dimension binding and risks double-count if refund lines are joined to multiple dimension tables. **Defer to M5-03:** `refund_ticket_quantity`, `refund_ticket_value`, net qty/value, and ATV at dimensional grain. M5-02 MVP stores **gross-only** dimensional facts.

---

## 9. Historical identity invariants

| Transition | Historical membership | Aggregate effect |
| --- | --- | --- |
| ProductMapping active → inactive | OrderItem evidence unchanged | No B23 enqueue (mapping-only); aggregates unchanged until line membership changes |
| ProductMapping target A → B | Existing mapped lines keep prior `event_id`/`ticket_type_id` | No automatic rewrite; new lines use new mapping |
| TicketType active → inactive | Past lines retain `ticket_type_id` | Rows remain in `ticket_type` grain; display may show inactive |
| TicketType renamed | Display only | Refresh does not change grain keys |
| Woo display metadata changes | OrderItem `name` is not authority | Optional display refresh only |
| OrderItem pending → mapped | Membership change | **B23 enqueue** (MissingCatalogResolver) |
| Audited attribution correction | Membership change | **B23 enqueue** with before/after events |
| Mapped → unresolved / remap | Membership change | **B23 enqueue** when event scope changes |
| ProductMapping-only admin edit | Catalogue | **No** snapshot enqueue per M5-01C |

Aggregation reads **durable OrderItem attribution + line financial fields**, not live ProductMapping joins for historical facts.

---

## 10. ProductMapping / TicketType mutation classification

| Writer / action | Changes historical membership? | Display/catalogue only? | B23 snapshot refresh? | Dimension projection |
| --- | --- | --- | --- | --- |
| `OrderUpserter` | Yes — any `HistoricalOrderMutationDetector` certificate-truth change on items (see §10.1) | No | Yes when detector reports `changed?` | Recompute **all candidate events** (before + after) |
| `RefundUpserter` | Refund facts | No | When aggregate-qualified | Event-level today; dimensional gross only in M5-02 |
| `MissingCatalogResolver` pending→mapped | Yes | No | Yes | Recompute |
| `OrderAttributionCorrection` | Yes | No | Yes | Recompute |
| `ManualMappingCreator` / ProductMapping create | Catalogue | No | **No** (unless coupled item remap) | No |
| ProductMapping deactivate / retarget | Catalogue | No | **No** | No |
| TicketType update name/capacity/active | Catalogue | Yes | **No** | No — does not alter historical grain keys on lines |
| Tickera catalogue apply (bulk) | May change mappings | Mixed | Only via order/item seams | Follow B23 rules |

Reject broad “refresh on every mapping change” — contradicted by M5-01C certification.

### 10.1 Dimension-only invalidation (B23 / `HistoricalOrderMutationDetector`)

Production: `EventSales.Ingestion.HistoricalOrderMutationDetector` captures per-line certificate truth including:

```text
event_id, ticket_type_id, woo_product_id, woo_variation_id,
quantity, line_subtotal, line_total, line_total_tax, discount_total,
item_kind, mapping_status, source_tickera_event_id, attribution_status_reason
```

`compare/2` uses full snapshot inequality; `candidate_event_ids/2` unions `event_id` from before and after item rows.

**Locked rule (M5-02):** Any accepted detector change affecting **dimensional membership** or **M5-02 gross primitives** on a line MUST enqueue refresh for every candidate event (including **same event** when `event_id` is unchanged).

Refresh-relevant examples (event-level gross total may be unchanged):

```text
same event + ticket_type_id changed
same event + woo_product_id changed
same event + woo_variation_id changed
same event + quantity or gross financial primitive changed (line_total / line_total_tax / etc.)
event_id changed (A → B or removal)
mapping_status / item_kind changes that alter recognised-sale membership
```

**Not refresh-relevant (preserve M5-01C):**

```text
ProductMapping-only catalogue mutation (no OrderItem certificate change)
TicketType rename, capacity, or active flag (no OrderItem mutation)
```

`OrderUpserter` must **not** be documented as “event_id / mapping only”; it is **detector-governed** historical truth on order items.

---

## 11. Architectural alternatives (required comparison)

### A. Extend `EventAggregateSnapshot`

```text
Add ticket_type_id / woo_* columns to existing table.
```

| Criterion | Assessment |
| --- | --- |
| Uniqueness | **Breaks** certified `unique_event_currency` (`event_id`, `currency`) |
| SnapshotRefresh / Reader | Requires multi-row-per-event redesign; breaks B12–B16 contracts |
| HotStateAggregator / DashboardCache | Keys assume one canonical financial row per currency |
| Verdict | **REJECT** without multi-year migration and re-certification; convenience-driven |

### B. New normalized dimensional projection (locked for M5-02)

```text
ONE durable Analytics resource/table with dimension_kind + grain keys.
One event refresh persists event v2 rows AND replaces the full dimensional set per currency.
```

| Criterion | Assessment |
| --- | --- |
| Compatibility | **Preserves** M5-01 snapshot grain |
| Orchestration | Extend `SnapshotRefresh.refresh_event/2` inside same fence/transaction pattern |
| Verdict | **SELECTED** — implementation authority for M5-02B |

```text
RESOURCE_STRATEGY = NEW normalized dimensional projection
RESOURCE_COUNT = ONE
DIMENSION_KINDS = ticket_type | source_product | source_variation
```

Working module name: `EventDimensionAggregateSnapshot` (table name finalized in M5-02B; spelling is not an owner decision).

### C. Multiple specialized projections

```text
Separate snapshot tables per dimension kind.
```

| Criterion | Assessment |
| --- | --- |
| Operations | Three refresh/purge paths; higher drift risk |
| Verdict | **STOP / REPLAN only** — if M5-02B/C produces concrete evidence (impossible integrity, failed query plans, pathological row width, unsafe Ash/Postgres representation). Do not switch topology silently during implementation. |

### D. Bounded on-demand aggregation only

```text
Extend EventAggregator with dimensional queries; no durable projection.
```

| Criterion | Assessment |
| --- | --- |
| Reads | Every admin detail view hits Postgres aggregate |
| Path-1 M5-02 | Expects **durable** bounded projection reuse |
| Verdict | **Insufficient** for programme MVP; acceptable as **fallback reader** behind flag during M5-02C bring-up only |

---

## 12. Projection lifecycle (recommended durable path)

Reuse M5-01 lifecycle vocabulary; **no second scheduler**.

### 12.1 ANALYTICS_READY separation (M5-01 B18)

```text
ANALYTICS_READY does NOT guard projection refresh.

Projection maintenance MUST continue while ANALYTICS_READY is false.

ANALYTICS_READY gates management exposure / read eligibility only.

It MUST NOT suppress, defer, or cancel durable dimensional projection refresh.
```

Authority: `EventSales.Analytics.SnapshotRefresh.refresh_event/2` does **not** consult `AnalyticsReadinessResolver`. M4 readiness and derived snapshot maintenance are intentionally separate (certified B18).

```text
source mutation → B23 refresh intent → projection refresh (independent of ANALYTICS_READY)
ANALYTICS_READY → management facade / dashboard eligibility (separate path)
```

`DimensionSnapshotReader` remains a **pure cold derived reader** (like `SnapshotReader`). Where readiness applies: **management facade** (`EventDetail`, `EventScopedDashboard`, admin LiveView eligibility) — not inside `SnapshotRefresh` or `RefreshSnapshotWorker`. Do not invent a second readiness mechanism.

### 12.2 Lifecycle states

Driven by source mutation and B23 orchestration only:

```text
ABSENT → REFRESH_PENDING → REFRESHING → CURRENT
         ↘ failure/retry ↗
         STALE (served until refresh completes)
```

| State | Meaning | Trigger | Guard | Durable effect | Cache | PubSub | Recovery |
| --- | --- | --- | --- | --- | --- | --- | --- |
| absent | No rows for event/currency/dimension | First successful `refresh_event` after qualifying source truth | Event snapshot fence lock only | Insert on refresh | Miss → cold read | After invalidate | B23 enqueue from mutation |
| current | Rows match last successful refresh | `SnapshotRefresh.refresh_event` success | Fence held | Replace full dimension set per currency (mirror B13 purge obsolete currencies) | `DashboardCache.invalidate_event` | Same as M5-01 | — |
| stale | Source mutated; job pending or running | B23 enqueue / worker start | Coalesced Oban unique job | Prior rows until transactional replace | May serve stale until refresh | HotState rebuild age (M5-07) | Worker retry |
| refresh pending | Job enqueued | `RefreshSnapshotWorker` | Unique keys | None yet | — | — | — |
| refreshing | Worker running | `perform/1` | Advisory fence | Transactional replace | Invalidate after commit | — | Rollback preserves prior rows (mirror B15) |
| failure / retry | Aggregator or persist error | Oban retry | max_attempts | Prior rows preserved | No partial publish | — | Oban backoff |

**Extension point:** `SnapshotRefresh.refresh_event/2` calls `DimensionAggregator` after `EventAggregator.financial_summaries_for_event/1` inside the same transactional replace strategy (M5-02D design detail).

---

## 13. Mutation / invalidation matrix (summary)

| Seam | Event `EventAggregateSnapshot` | Dimension projection | DashboardCache |
| --- | --- | --- | --- |
| OrderUpserter | Refresh when detector `changed?` | Recompute **all candidate events**; includes same-event `ticket_type_id` / `woo_product_id` / `woo_variation_id` / gross primitive changes | Invalidate on success |
| RefundUpserter | Refresh when certified | **Gross dimensional only**; refund dims deferred M5-03 | Same |
| MissingCatalogResolver mapped recovery | Refresh | Recompute | Same |
| OrderAttributionCorrection | Refresh | Recompute (including A→B) | Same |
| ProductMapping-only catalogue | **No enqueue** | **No** | No |
| TicketType display/catalogue-only | **No enqueue** | **No** | No |

---

## 14. Bounded read API strategy

```text
EventSales.Analytics.DimensionSnapshotReader (proposed)
  list_for_event(event_id, opts)
    → rows grouped by currency and dimension_kind
    → optional filter: ticket_type | source_product | source_variation
  join display:
    TicketType.name / capacity via Catalog read (not stored in grain)
    woo ids displayed as stable integers + source system label

Authorization: same admin/policy boundary as EventDetail / SnapshotReader (no LiveView Woo REST).

**Readiness:** `DimensionSnapshotReader` does not check ANALYTICS_READY. Management surfaces that expose dimensional breakdowns must apply `AnalyticsReadinessResolver` (or existing dashboard eligibility) **before** calling the reader — same boundary as other certified management reads (B18).

Fail-closed: if v2 event snapshot missing for currency, dimensional reader returns {:error, :snapshot_not_ready} or empty with explicit freshness signal — exact behaviour fixed in M5-02E (must not invent financial totals).
```

**Conformance:** migrate `EventDetail.ticket_type_breakdown/1` to reader in M5-02F (align filters with `recognised_sale_item_filters` and tax-inclusive gross).

---

## 15. Existing index / query audit

### 15.1 OrderItem (`order_item.ex` custom_indexes)

| Index | Supports |
| --- | --- |
| `sales_order_items_event_mapping_status_idx` (`event_id`, `mapping_status`) | Event-scoped mapped ticket filter |
| `sales_order_items_ticket_type_id_idx` | TicketType dimension GROUP BY |
| `sales_order_items_woo_product_id_woo_variation_id_idx` | Product/variation grouping |
| `sales_order_items_source_tickera_event_id_woo_product_id_woo_variation_id_idx` | Attribution resolver (not aggregate grain) |

### 15.2 Order

| Index | Supports |
| --- | --- |
| `sales_orders` FK / typical `source_system_id` | Join for source-scoped product grain |

### 15.3 Proposed dimensional aggregate query (M5-02C proof target)

```text
FROM sales_order_items oi
JOIN sales_orders o ON oi.order_id = o.id
WHERE recognised_sale_item_filters(event_id)
GROUP BY o.currency, oi.ticket_type_id
-- analogous GROUP BY for (o.source_system_id, oi.woo_product_id)
-- and (o.source_system_id, oi.woo_product_id, oi.woo_variation_id) WITH variation NOT NULL
```

**New indexes:** none required in M5-02A audit; M5-02C must run `EXPLAIN` like PRE-M5-02F. Request new indexes only with failing plan evidence.

### 15.4 Speculative indexes

**Reject** until query-plan proof shows seq scan on hot events.

---

## 16. Hot / warm / cold placement

| Tier | M5-02 ownership |
| --- | --- |
| HOT | Optional denormalized top-N ticket types in `HotStateAggregator` **after** cold rows exist (M5-02F+); not required for MVP |
| WARM | Redis only if existing dashboard warm keys extended — **justify per key**; no duplicate financial truth |
| COLD truth | `sales_orders` / `sales_order_items` |
| COLD derived | `EventDimensionAggregateSnapshot` (proposed) alongside `EventAggregateSnapshot` |
| Async | Reuse `RefreshSnapshotWorker` / Oban `analytics_rebuilds` |
| Realtime | Existing PubSub after cache invalidate — **no polling** |

**Prohibited:** Cachex; global flush; per-dimension N+1 queries in reader (batch fetch all rows for event); unbounded BEAM full-table aggregation.

**Batch fetch:** one query per dimension kind per refresh (3 aggregates), not one DB call per output row.

---

## 17. Performance and scaling review

```text
Cardinality: bounded by distinct historically attributed identities on recognised lines (not “active catalogue” row counts).
Refresh cost: O(lines for event) with indexed filter — same order class as EventAggregator today.
Read cost: O(dimension rows) per event — typically hundreds, not 100k users scanning history.
100k users: management read model is event-scoped projection, not fan-out per user; safety argument = bounded event cardinality + cold snapshot read, not vague scale hand-waving.
```

Peak risk today: `EventDetail` scans — M5-02F retires that path for ticket breakdown.

---

## 18. Failure modes and concurrency

| Risk | Mitigation |
| --- | --- |
| Partial dimension persist | Same transactional replace as B13/B15 |
| Concurrent refresh | `EventSnapshotRefreshFence` (B14) |
| Ticket type deleted with historical FK | `on_delete: :restrict` on OrderItem — rows retain id; aggregate still counts |
| Multi-currency | Separate row sets; no cross-currency sums |
| Semantic drift EventDetail vs EventAggregator | M5-02F certification closes gap |

---

## 19. Permissions / read boundary

```text
Management/admin readers only (mirror SnapshotReader / EventDetail policies).
No WooCommerce REST from LiveView/components.
Dimensional rows are derived read models, not source truth.
```

---

## 20. Gap ledger

| ID | Gap | Severity | Slice |
| --- | --- | --- | --- |
| G-M5-02-01 | No durable dimensional projection | BLOCKING | M5-02B |
| G-M5-02-02 | `EventDetail` raw scan + non-canonical filters/revenue | HIGH | M5-02F |
| G-M5-02-03 | No product/variation management breakdown | MEDIUM | M5-02E/F |
| G-M5-02-04 | Dimensional refund/net/ATV undefined | EXPECTED | M5-03 |
| G-M5-02-05 | Period-dimensional aggregates | EXPECTED | M5-04 |
| G-M5-02-06 | Hot cache optional acceleration | LOW | Post-M5-02F |

---

## 21. Smallest M5-02B+ implementation sequence

| Slice | Deliverable | Out of scope |
| --- | --- | --- |
| **M5-02B** | Ash resource + migration + grain identities + changeset validations; no aggregator | Reader, UI, worker |
| **M5-02C** | `DimensionAggregator` bounded SQL + query-plan tests; parity lemma vs event gross | SnapshotRefresh wiring |
| **M5-02D** | `SnapshotRefresh` extension; purge obsolete currencies/dimensions; rollback tests; **focused B23/dimension invalidation tests** (§21.1) | EventDetail |
| **M5-02E** | `DimensionSnapshotReader` + policy tests | UI |
| **M5-02F** | `EventDetail` conformance; certification evidence doc; reconciliation tests event ↔ sum(dimensions) | M5-03 metrics |

Each slice: independent PR, focused tests, `mix quality.fast` at slice end.

### 21.1 M5-02D acceptance tests (requirements only — not implemented in M5-02A)

Focused tests must cover at least:

```text
same-event ticket_type_id membership change triggers dimensional refresh
same-event woo_product_id change triggers dimensional refresh
same-event woo_variation_id change triggers dimensional refresh
before/after event correction A → B refreshes both events
pending → mapped recovery refreshes affected event
ProductMapping-only mutation does NOT enqueue dimensional refresh
TicketType rename or active-state change does NOT alter historical grain / does NOT enqueue refresh
```

---

## 22. M5-02A conformance checklist

| Check | Result |
| --- | --- |
| Identity tuples match M1-02/M1-03 | PASS |
| No Product resource invented | PASS |
| EventAggregateSnapshot grain preserved | PASS (option B) |
| M5-03 refund-dimensional deferred | PASS |
| B23 mapping-only refresh rule respected | PASS |
| ANALYTICS_READY separate from refresh (B18) | PASS (v2 §12.1) |
| Same-event dimension-only invalidation locked | PASS (v2 §10.1) |
| Single normalized resource topology locked | PASS (v2 §11B, §23) |
| No Cachex / no Path 2 | PASS |
| Terminal decision stated | PASS (below) |

---

## 23. Terminal decision

```text
M5_02A_DECISION = IMPLEMENTATION_REQUIRED
RESOURCE_STRATEGY = ONE NORMALIZED DIMENSIONAL PROJECTION
RESOURCE_COUNT = ONE
DIMENSION_KINDS = ticket_type | source_product | source_variation
```

Rationale: Path-1 M5-02 requires dimensional aggregates without Product resources; certified M5-01 infrastructure explicitly excluded ticket-type snapshots (B22); `EventDetail` demonstrates an unscanned conformance debt and peak-history read pattern that a planning-only certification cannot close.

**Implementation authority (locked):** one normalized `EventDimensionAggregateSnapshot` (working name) with `dimension_kind`; all three dimension kinds in M5-02C SQL together. Split tables are a **STOP / REPLAN** trigger only (§11C).

**Non-blocking naming detail:** final Postgres table name / Ash module spelling may be chosen in M5-02B without owner escalation.

**NEXT_SLICE:** M5-02B — resource + migration for the single normalized projection.

---

## 24. M5-02A preflight record

```text
Repository:     JCSchoeman96/EventSales
Base SHA:       c6a8708903d0d76eebc16024b6ff80b74a2161b2
Base tree:      a122ab8655f21e793af494a2f81bf6c4d80fca84
M5-01:          COMPLETE (PASS); B01–B23 CERTIFIED
Production diff: NONE (this slice)
```
