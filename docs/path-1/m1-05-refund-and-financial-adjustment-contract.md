Document:
Path 1 M1-05 Refund and Financial Adjustment Contract

Baseline:
81d65c6582ca83da117db1d22e1e8b38647b3d3e

origin/main:
81d65c6582ca83da117db1d22e1e8b38647b3d3e

Contract date:
2026-08-09

Verdict:
PASS

Authority:
NEW CONTRACT DOCUMENTATION (no production code)

---

# Path 1 M1-05 — Refund and Financial Adjustment Contract

| Field | Value |
| --- | --- |
| Document | Refund and post-sale financial-adjustment contract |
| Plan ID | `m1-05-refund-and-financial-adjustment-contract` |
| Plan version | `v1` |
| Status | LOCKED for Path 1 refund / financial-adjustment semantics — M1-05 COMPLETE (PASS) |
| Scope | Woo refund identity; refund-line binding; full/partial/value-only semantics; quantity vs money; sign/currency; gross preservation; idempotency/convergence; MetricRules gap; M1-06/07/08 handoffs |
| Identity input | `docs/path-1/m1-02-source-scoped-external-identity-contract.md` (immutable) |
| Attribution input | `docs/path-1/m1-03-event-product-variation-orderline-attribution-contract.md` (immutable) |
| Lifecycle input | `docs/path-1/m1-04-order-lifecycle-and-recognised-sale-contract.md` (immutable for recognition) |
| Repository truth | `docs/path-1/m1-01-current-repo-truth.md` |
| Product authority | `docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md` §3 |
| Execution roadmap | `docs/path-1/path-1-phase-breakdown.md` |
| Strategy | NEW CONTRACT REQUIRED — physical Ash resources TBD |

### Revision log

- `v1` — initial locked refund / financial-adjustment contract at baseline `81d65c6582ca83da117db1d22e1e8b38647b3d3e`

### Conflict rule

```text
This contract wins for Path 1 REFUND FINANCIAL TRUTH and POST-SALE ADJUSTMENT semantics.

M1-02 wins for Order / OrderItem identity tuples.
M1-03 wins for historical attribution / mapping_status.
M1-04 wins for Order.status lifecycle and recognised-sale prerequisite.
M1-06 wins for named management metric dictionary.
M1-07 wins for period / payment / freshness timestamp authority.
M1-08 wins for BACKFILL_COMPLETE / RECONCILED / ANALYTICS_READY gates.

This document consumes M1-02..M1-04; it does not revise them.
Physical Refund / RefundLine Ash resources are NOT decided here.
```

---

## 1. Contract Metadata / Baseline

```text
branch: main
HEAD: 81d65c6582ca83da117db1d22e1e8b38647b3d3e
origin/main: 81d65c6582ca83da117db1d22e1e8b38647b3d3e
worktree at start: CLEAN
P1-00 / M1-01 / M1-01A / M1-02 / M1-03 / M1-04: COMPLETE
Path 2 / Phase 5E: PAUSED
```

Preflight evidence: `HEAD == origin/main`, clean worktree, on `main`, baseline matches authorized SHA.

M1-04 contract present and COMPLETE (PASS) at
`docs/path-1/m1-04-order-lifecycle-and-recognised-sale-contract.md`.

Evidence classes used below:

```text
REPOSITORY EVIDENCE
OFFICIAL SOURCE CONTRACT EVIDENCE
CONTRACT DECISION
```

---

## 2. Executive Verdict

```text
M1-05 = PASS
```

Reasons:

```text
Original recognised completed sale is preserved; refunds are separate adjustments.
Order.status == :refunded is lifecycle context, never complete financial truth.
Stable Woo refund ID exists and is source-scoped with parent Order.
Refund lines bind to original OrderItem via Woo _refunded_item_id (fail-closed otherwise).
Quantity and money may move independently when source says so.
Sign convention, currency inheritance, idempotency, and convergence are locked.
Current MetricRules is IMPLEMENTATION_CHANGE_REQUIRED vs this model.
Physical Ash resources remain TBD; implementation primarily M3, before M4.
No production code required to lock this contract.
```

Production code changes: **NONE**.

Migration authorized: **NO**.

---

## 3. Locked Inputs from M1-02 / M1-03 / M1-04

### 3.1 M1-02 (identity — consumed)

| Concept | Identity |
| --- | --- |
| Order | `(source_system_id, woo_order_id)` |
| OrderItem | `(order_id, woo_line_item_id)` conceptually source-scoped through the parent Order |

Refund processing must not create a second Order identity namespace.

### 3.2 M1-03 (attribution — consumed)

Historical `OrderItem.event_id` / `ticket_type_id` / source product/variation identity remain immutable under refund processing.

Refund metadata must not reattribute the original sale.

### 3.3 M1-04 (recognised sale — consumed)

Recognised ticket sale prerequisite (locked):

```text
Order.status == :completed
+
OrderItem.mapping_status == :mapped
+
OrderItem.item_kind == :ticket
+
OrderItem.quantity > 0
```

Current quantity / revenue primitives (locked until M1-06 renames):

```text
quantity: OrderItem.quantity
current revenue basis: OrderItem.line_total
```

`:refunded` is lifecycle only in M1-04. M1-05 owns post-sale financial truth.

---

## 4. Current Repository Refund Truth

**REPOSITORY EVIDENCE**

| Fact | Verdict | Citation |
| --- | --- | --- |
| Order status `:refunded` exists | EXISTS | `lib/event_sales/sales/resources/order.ex:14-22`, `:211` |
| Parser maps Woo `"refunded"` → `:refunded` | EXISTS | `lib/event_sales/ingestion/parsers/woocommerce_order_parser.ex:59` |
| Parser reads `"refunds"` array | MISSING | `woocommerce_order_parser.ex:13-48` — no refunds field in normalized map |
| Independent refund transaction persistence | MISSING | no Refund Ash module under `lib/` |
| Independent refund-line persistence | MISSING | — |
| Partial refund durable truth | MISSING | `docs/path-1/m1-01-current-repo-truth.md:462-483` |
| Synthetic fixture includes summary refunds | PRESENT unused | `test/fixtures/woocommerce/order_refunded.json:64-70` |
| WooCommerceClient refund detail endpoints | MISSING | `lib/event_sales/ingestion/clients/woocommerce_client.ex:24-49` — order fetch/list only |
| Webhook topics include refund-specific topic | MISSING | `lib/event_sales/ingestion/webhook_processor.ex:19` — `order.created` / `order.updated` / `product.updated` only |
| OrderItem quantity must be positive | EXISTS | `order_item.ex:87`, `:213-217` |
| Money stored as Decimal | EXISTS | `order.ex:148-163`; `order_item.ex:219-233`; parser Decimal helpers |
| Order currency required | EXISTS | `order.ex:121-124`; parser `:17` |
| MetricRules excludes non-`:completed` | EXISTS | `metric_rules.ex:72-77`; `metric_rules_test.exs:33-40` |

Fixture summary refund shape (unused by parser):

```json
"refunds": [
  {
    "id": 91003,
    "reason": "Synthetic refund",
    "total": "-450.00"
  }
]
```

Citation: `test/fixtures/woocommerce/order_refunded.json:64-70`.

---

## 5. Source Refund Evidence

### 5.1 Embedded order summary (discovery index)

**OFFICIAL SOURCE CONTRACT EVIDENCE**

WooCommerce Orders API exposes READ-ONLY `refunds` on the order:

| Attribute | Meaning |
| --- | --- |
| `id` | Refund ID |
| `reason` | Refund reason (property table) |
| `total` | Refund total |

Source: [WooCommerce REST API v3 Orders — Order Refunds properties](https://developer.woocommerce.com/docs/apis/rest-api/v3/orders/).

Official example totals are **negative** strings (e.g. `"-10.00"`).

**CONTRACT DECISION**

```text
order.refunds[] is a discovery/index of refund references
— not complete refund-line financial truth.
```

### 5.2 Full refund object (financial truth)

**OFFICIAL SOURCE CONTRACT EVIDENCE**

Endpoints:

```text
GET    /wp-json/wc/v3/orders/<order_id>/refunds
GET    /wp-json/wc/v3/orders/<order_id>/refunds/<refund_id>
POST   /wp-json/wc/v3/orders/<order_id>/refunds
DELETE /wp-json/wc/v3/orders/<order_id>/refunds/<refund_id>
```

No UPDATE/PATCH endpoint is documented.

Refund properties include: `id`, `date_created`, `date_created_gmt`, `amount`, `reason`, `refunded_by`, `refunded_payment`, `meta_data`, `line_items`, `tax_lines`, `shipping_lines`, `fee_lines`.

Source: [WooCommerce REST API v3 Order Refunds](https://developer.woocommerce.com/docs/apis/rest-api/v3/order-refunds/).

### 5.3 Refund-line binding evidence

**OFFICIAL SOURCE CONTRACT EVIDENCE**

Create-time line parameter:

```text
line_items[].id = The ID of the line item in the order
```

Retrieve/list response example binds via meta:

```text
meta_data key: _refunded_item_id
meta_data value: original order line item id (string)
```

Refund line item `id` in the response is the **refund line's own item ID**, not the original OrderItem Woo line id.

Quantity on refunded lines appears as a **negative integer** (example: `-1`).
Line `total` / `subtotal` appear as **negative** money strings.

`amount` on the refund header is a **positive** magnitude string and may take precedence over line-item totals even when they disagree.

Empty `line_items` with non-zero `amount` is a documented response shape (value-only / amount-only refund).

### 5.4 Partial refund vs order status

**OFFICIAL SOURCE CONTRACT EVIDENCE**

From [WooCommerce Refunds documentation](https://woocommerce.com/document/woocommerce-refunds/):

```text
If the full order value is not refunded,
the order status will not change to Refunded.
```

From [Order Statuses](https://woocommerce.com/document/managing-orders/order-statuses/):

```text
Refunded = admin/shop manager has fully refunded the order’s value after payment.
```

Also from refunds merchant docs: money may be refunded **without** adjusting product quantity (value-only line refund when quantity is not entered).

### 5.5 Repository vs official gap

```text
Repository proves: status-only refund lifecycle + unused summary fixture.
Official Woo proves: independent refund objects, line binding, partial/full,
                     quantity-optional money refunds, delete-without-update.
```

No live production Woo request was performed.

---

## 6. Lifecycle vs Financial Truth

| Concern | Owner | Role |
| --- | --- | --- |
| `pending` / `processing` / `on_hold` / `completed` / `failed` / `cancelled` / `refunded` | M1-04 | Order lifecycle |
| Refund transaction | M1-05 | Financial truth |
| Refund line / adjustment | M1-05 | Financial truth |
| Refunded quantity / money | M1-05 | Financial truth |
| Full / partial / value-only | M1-05 | Financial truth |

**CONTRACT DECISION (R1)**

```text
Order.status == :refunded
  = lifecycle / context evidence only

refund object history
  = financial truth

Never equate :refunded status with complete refund history.
A completed order may carry partial refund adjustments while remaining :completed.
```

---

## 7. Refund Identity Contract

**CONTRACT DECISION (R3, R4)**

Conceptual source-scoped refund identity:

```text
(source_system_id, woo_order_id, woo_refund_id)
```

Properties:

```text
globally safe under source namespace
stable across retries
bound to exactly one Order via (source_system_id, woo_order_id)
not inferred from amount / date / reason / array position
```

Parent binding:

```text
Refund.woo_order_id must equal the parent Order.woo_order_id
within the same source_system_id
```

Cross-source binding is forbidden.

Discovery may start from `order.refunds[].id`, but durable financial identity is the full refund object’s `id` under that parent order.

---

## 8. Refund-Line Binding Contract

**CONTRACT DECISION (R5)**

Refund-line → original OrderItem binding:

```text
REQUIRED binder:
  refund_line.meta_data[_refunded_item_id]
  → OrderItem.woo_line_item_id
  within the same parent Order

OPTIONAL validation evidence (never sole binder):
  product_id / variation_id on the refund line
  compared to historical OrderItem source IDs
```

Refund line conceptual identity (for idempotency of one adjustment row):

```text
(source_system_id, woo_order_id, woo_refund_id, woo_refund_line_item_id)
```

where `woo_refund_line_item_id` is the refund line’s own `id`.

| Case | Behaviour |
| --- | --- |
| `_refunded_item_id` matches known OrderItem on parent Order | Bind; apply ticket/non-ticket classification from historical OrderItem |
| `_refunded_item_id` unknown / missing OrderItem | Persist unresolved refund-line evidence; no ticket qty/money attribution; review |
| `_refunded_item_id` belongs to another order | Fail closed / review; do not rebind |
| product/variation disagrees with historical OrderItem | Keep historical binding; flag validation conflict; do not remap sale |
| No ticket lines on refund | Capture non-ticket / shipping / fee / manual components only |
| Mixed ticket + non-ticket lines | Attribute each line independently from historical OrderItem.item_kind / mapping_status |
| Empty line_items + amount only | Order-level / manual value adjustment; ticket quantity = 0 |

Forbidden:

```text
name / SKU similarity matching
guessing allocation across lines
using product_id alone when multiple lines share a product
```

---

## 9. Full / Partial / Value-Only Refund Semantics

**CONTRACT DECISION (R6, R7, R8, R9)**

| Concept | Meaning | Source support |
| --- | --- | --- |
| FULL ORDER REFUND | Cumulative refund money covers full order value; Woo typically sets status `refunded` | Official refunds + status docs |
| PARTIAL ORDER REFUND | Some but not all order value refunded; status often remains `completed` | Official refunds docs |
| FULL LINE REFUND | Refund line reverses entire original line quantity (and typically its money) | Refund line qty/totals |
| PARTIAL LINE QUANTITY REFUND | Refund line quantity < original sold quantity | Negative qty on refund lines |
| PARTIAL VALUE REFUND | Money refunded against a line without full quantity reverse | Official: amount without qty |
| MANUAL VALUE-ONLY REFUND | Header `amount` with empty / non-ticket-binding lines | Official API empty line_items + amount precedence |

```text
money refund does not automatically imply ticket quantity refund
unless source refund-line quantity evidence says so.
```

Do not invent quantity from amount.

---

## 10. Quantity Adjustment Contract

**CONTRACT DECISION (R8, R10)**

Source quantity on refund lines is typically **negative**. Durable EventSales refunded quantity is the **non-negative absolute magnitude**.

Rules:

```text
ticket quantity reversed only when:
  refund line binds to a historical ticket OrderItem
  AND source refund-line quantity magnitude > 0

value-only / amount-only / shipping / fee / unbound residual:
  ticket quantity adjustment = 0
```

Cumulative invariant (Path 1 enforcement):

```text
sum(qualifying refunded ticket qty for OrderItem)
  must not exceed original OrderItem.quantity
```

If source ever exceeds that bound:

```text
do not silently clamp
persist evidence
mark REVIEW / over-refund detected
```

Multiple partial refunds against the same OrderItem accumulate by summing distinct refund-line facts (idempotent by refund-line identity).

Duplicate delivery of the same refund-line identity must not double quantity.

---

## 11. Money Adjustment / Sign Contract

**CONTRACT DECISION (R11, R12)**

### 11.1 Exact money

All durable authoritative money:

```text
Decimal / database numeric
Never binary float
```

### 11.2 Source sign map

| Source field | Observed source sign | Durable EventSales meaning |
| --- | --- | --- |
| Refund detail `amount` | Positive magnitude | Positive refund money magnitude |
| Order embedded `refunds[].total` | Negative string (official example / fixture) | Normalize via absolute value to positive magnitude for discovery only |
| Refund line `total` / `subtotal` / tax totals | Typically negative | Positive money magnitude after abs |
| Refund line `quantity` | Typically negative | Positive qty magnitude after abs |

**One internal convention:**

```text
durable refund money = non-negative Decimal magnitude of money returned
durable refunded quantity = non-negative integer magnitude reversed
```

Never store `100` in one path and `-100` in another for the same semantic.

### 11.3 Header vs line money

Capture separately:

```text
refund_header_amount
line_money_adjustments (per bound refund line)
shipping_line adjustments
fee_line adjustments
tax components where present
unallocated_header_residual
  = max(0, header_amount - sum(attributed line/shipping/fee money))
  when header amount is authoritative / larger
```

`amount` precedence over line totals is an official Woo behaviour; EventSales must retain both header and line primitives so M1-06 can decide metric inclusion without guessing.

---

## 12. Gross Preservation and Net Derivation Primitive

**CONTRACT DECISION (R2)**

```text
ORIGINAL RECOGNISED COMPLETED SALE
must remain historically preserved

LATER REFUND
is a separate financial adjustment

therefore:

original recognised sale
-
qualifying refund adjustments
=
net sale
```

Do **not**:

```text
mutate historical OrderItem.line_total merely to produce net
delete the historical sale because status became :refunded
treat :refunded status alone as zeroing financial history without adjustment facts
```

Primitive algebra handed to M1-06 (unnamed):

```text
original_recognised_ticket_qty   = OrderItem.quantity when M1-04 predicate held historically for that sale fact
original_recognised_ticket_money = OrderItem.line_total under same historical recognition

refunded_ticket_qty              = sum(bound ticket refund-line qty magnitudes)
refunded_ticket_money            = sum(bound ticket refund-line money magnitudes)
                                   (+ only those residuals M1-06 later classifies as ticket-applicable)

net_ticket_qty                   = original_recognised_ticket_qty - refunded_ticket_qty
net_ticket_money                 = original_recognised_ticket_money - refunded_ticket_money
```

Historical preservation means the original sale facts remain durable even if current `Order.status` is no longer `:completed`.

---

## 13. Ticket vs Non-Ticket Adjustment Boundary

**CONTRACT DECISION (R13, R14)**

Classify each adjustment component:

| Component | Classification |
| --- | --- |
| Bound refund line whose historical OrderItem is ticket | Ticket refund adjustment |
| Bound refund line whose historical OrderItem is non-ticket / ignored / unknown | Non-ticket product refund |
| Shipping lines on refund | Shipping refund |
| Fee lines on refund | Fee refund |
| Header residual / empty-line amount | Manual / unallocated order-level refund |

```text
Do not count an entire order refund as ticket refund
simply because the order contains tickets.
```

M1-05 captures the raw categories. M1-06 decides which enter named management metrics.

---

## 14. Currency Contract

**CONTRACT DECISION (R15)**

```text
Refund currency inherits parent Order.currency.
Woo refund resource does not document an independent currency field.
```

If a future source payload presents an explicit mismatched currency:

```text
fail closed / review
no FX conversion (Path 1 unauthorized)
```

---

## 15. Out-of-Order / Retry / Convergence Contract

**CONTRACT DECISION (R16, R17, R18)**

| Arrival pattern | Required behaviour |
| --- | --- |
| Order first, refund later | Upsert refund under parent Order; converge |
| Refund reference before detail | Persist pending/unresolved refund reference conceptually; fetch detail; do not invent lines |
| Refund before local Order (backfill) | Hold unresolved-parent refund; bind when Order appears; no cross-order guess |
| Same refund delivered multiple times | Idempotent upsert by refund identity |
| Older Order snapshot after refund | Must not erase refund facts; Order stale guards remain M1-02/OrderUpserter |
| Newer Order snapshot updates `refunds[]` refs | Discover new IDs; reconcile deletions (see §16) |
| Webhook + backfill same refund | One durable adjustment |
| Historical replay | Converges to same durable facts |

```text
Arrival order must not change final financial truth.
```

Physical pending/unresolved storage form is TBD; the **need** for unresolved parent/detail/line states is locked.

Supported webhook discovery path today:

```text
order.updated (and order.created)
→ inspect order.refunds[] references
→ fetch refund detail via order-refunds API
```

Citation: `webhook_processor.ex:19,84`.

---

## 16. Mutation / Correction Contract

**CONTRACT DECISION (R19)**

Official Woo refund API supports create / retrieve / list / **delete**, not update.

```text
Source refunds are effectively immutable after creation,
except deletion (force delete; no trash).
```

EventSales behaviour:

```text
same refund external identity on retry
  → upsert/correct same durable financial event (idempotent)

source deletion of a refund
  → do NOT silently hard-delete EventSales audit history
  → mark source-deleted / voided and retain original ingested evidence
  → net aggregates treat voided refund as inactive

source recreate after delete
  → new woo_refund_id = new durable event
```

Never invent an in-place content mutation path that Woo does not expose.

---

## 17. Historical Attribution Integrity

**CONTRACT DECISION (R20, R21)**

Refund processing must not change:

```text
Order identity
OrderItem.event_id
OrderItem.ticket_type_id
historical woo_product_id / woo_variation_id
```

| Historical OrderItem state | Refund behaviour |
| --- | --- |
| `:mapped` ticket | Ticket financial adjustment follows historical mapped line |
| pending / unmapped / non_ticket / ignored | Persist adjustment evidence; do not invent event attribution; ticket-metric contribution blocked / review as unresolved for event analytics |
| Missing parent OrderItem | Unresolved line; review |

ProductMapping changes after the sale do not rebind historical refund attribution.

---

## 18. Timestamp Requirements for M1-07

**CONTRACT DECISION (R22)**

Required concepts (M1-05 locks *need*, not period authority):

| Clock | Required? | Source evidence |
| --- | --- | --- |
| Refund source-created (`date_created_gmt`) | REQUIRED | Official refund properties |
| Refund source-updated | NOT AVAILABLE on official refund resource | No `date_modified` on refund docs |
| Refund ingestion / local inserted/updated | REQUIRED | EventSales intake audit |
| Parent order completion timestamp | REQUIRED context | Existing `Order.completed_at` |
| Source-deletion / void observation time | REQUIRED if deletion supported | Local when delete discovered |

M1-07 decides UTC persistence, Johannesburg day-bucketing, and whether refund period uses created-at vs other clocks.

---

## 19. Refund Completeness Inputs for M1-08

**CONTRACT DECISION (R24)**

Conceptual `REFUND_COMPLETE` inputs (gate composition owned by M1-08):

```text
all refund IDs referenced on in-scope Orders discovered
all refund detail records fetched and processed (pages exhausted)
all refund lines resolved OR explicitly unresolved
no missing refund list pages/ranges
idempotent replay complete (re-run changes nothing material)
all refunds bound to parent Orders OR explicitly unresolved-parent
known attribution / binding gaps surfaced for review
source-deleted refunds reconciled to void state
```

Do not design `ANALYTICS_READY` here.

---

## 20. Current MetricRules Compatibility Review

**REPOSITORY EVIDENCE**

```text
counts_as_sold?/2 requires Order.status == :completed
sold_quantity/2 and completed_revenue/2 return 0 otherwise
```

Citations: `metric_rules.ex:72-93`; `metric_rules_test.exs:19-40`.

Implications vs M1-05 model:

| Scenario | Current MetricRules | Locked M1-05 model |
| --- | --- | --- |
| `:completed` + no refunds | Counts full qty + `line_total` | Same gross; net = gross |
| `:completed` + partial refund | Still counts full gross; ignores refund money/qty | Preserve gross; subtract adjustments → net |
| `:refunded` after full refund | Drops entire sale from sold/revenue | Preserve original gross; subtract full qualifying refunds → net ≈ 0 |
| Status `:refunded` without refund objects | Shows as zero sold | Lifecycle only; financial incomplete until refund facts exist |

**CONTRACT DECISION (R23)**

```text
CURRENT METRICRULES COMPATIBILITY:
IMPLEMENTATION_CHANGE_REQUIRED
```

Do **not** change MetricRules in M1-05.
Hand to M1-06 (metric dictionary) and M1-09 / M3–M5 implementation sequencing.

---

## 21. Financial Invariants

**CONTRACT DECISION**

```text
I1  Refund belongs to exactly one source-scoped Order.
I2  Refund line belongs to exactly one parent Refund.
I3  Ticket/non-ticket line adjustment binds to at most one original OrderItem.
I4  Same (source, order, refund) identity cannot duplicate refund value.
I5  Same refund-line identity cannot reverse quantity twice.
I6  Refund processing cannot change Order identity.
I7  Refund processing cannot change historical event/ticket attribution.
I8  Unknown Order / OrderItem cannot be guessed.
I9  Money uses exact Decimal/numeric representation.
I10 Cross-currency adjustment fails closed / review.
I11 Cross-source refund binding is forbidden.
I12 Arrival order cannot change final financial truth.
I13 Order.status is never sole financial truth.
I14 Original recognised sale facts are preserved; net is derived.
I15 Caches (Redis/ETS) are never authoritative for refund money/qty.
I16 Cumulative refunded ticket qty must not exceed original sold qty without review.
I17 Ticket money attribution requires line binding or explicit M1-06 residual rule — never name/SKU allocation.
```

---

## 22. Scenario Matrix

| # | Scenario | Durable financial evidence | Ticket qty adj | Ticket money adj | Lifecycle effect | Analytics readiness / gap | Auto vs review |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Completed 2-ticket line, no refund | None | 0 | 0 | stays `:completed` | ready if otherwise complete | Auto |
| 2 | Completed 2-ticket, refund 1 ticket | Refund + bound line qty=1 | 1 | line money magnitude | often stays `:completed` | needs refund facts | Auto if bound |
| 3 | Completed 2-ticket, refund both | Refund(s) reversing qty 2 | 2 | line money | often `:refunded` | needs refund facts | Auto if bound |
| 4 | Completed ticket line, value-only partial | Refund amount / line money with qty 0 | 0 | money only | usually `:completed` | needs refund facts | Auto if classified value-only |
| 5 | Mixed order, ticket refund only | Bound ticket line only | ticket lines only | ticket lines only | status per Woo | non-ticket ignored for ticket metrics | Auto |
| 6 | Mixed order, non-ticket refund only | Non-ticket adjustment | 0 | 0 ticket | status per Woo | ticket net unchanged | Auto |
| 7 | Multiple partials same ticket line | Multiple refund-line facts | sum qty | sum money | status per Woo | cumulative | Auto |
| 8 | Duplicate same refund delivery | One durable refund | no double | no double | unchanged | converge | Auto |
| 9 | Webhook + backfill same refund | One durable refund | no double | no double | converge | converge | Auto |
| 10 | Unknown parent Order | Unresolved-parent refund | none until bound | none until bound | n/a | gap until Order exists | Review / pending |
| 11 | Unknown OrderItem | Unresolved line | 0 ticket | 0 ticket | n/a | unresolved line gap | Review |
| 12 | Unmapped ticket OrderItem refunded | Bound to unmapped line | raw qty may store | raw money may store | n/a | event analytics blocked / review | Review |
| 13 | Mapped line refunded after ProductMapping change | Follow historical mapped OrderItem | as source | as source | n/a | no remap | Auto |
| 14 | Status `:refunded` before refund details | Lifecycle only | unknown until details | unknown until details | `:refunded` | REFUND incomplete | Pending detail |
| 15 | Refund details while still `:completed` | Full financial truth | as lines | as lines | remains `:completed` | ok | Auto |
| 16 | Same woo_refund_id across sources | Distinct by source_system_id | independent | independent | independent | no cross bind | Auto |
| 17 | Refund currency ≠ parent | Reject / review | none applied | none applied | n/a | blocked | Review / fail closed |

---

## 23. Performance / Concurrency Review

**CONTRACT DECISION (R25)**

```text
Durable refund truth = Postgres
Redis / ETS = derived cache / invalidation only
Heavy recovery = Oban
Woo REST concurrency remains bounded (max 2)
```

Risks and required mitigations:

| Risk | Mitigation |
| --- | --- |
| Refund detail N+1 | Prefer list-by-order with pagination; bound pages; Oban for backfill |
| Unbounded in-memory refund history | Stream/page; do not load full history into one process heap |
| Concurrent webhook + backfill | DB uniqueness on refund identity; idempotent upsert |
| Concurrent partials on same OrderItem | Prefer immutable adjustment facts + deterministic aggregate; no unprotected read-modify-write of cumulative totals |
| Parent / line lookup | Indexed identity lookups via existing Order / OrderItem uniques |
| Aggregate invalidation | Later analytics invalidate derived caches after durable commit |

Avoid:

```text
read cumulative refund total → calculate → write
without concurrency protection
```

---

## 24. Required Future Implementation Gaps

| ID | Gap | Classification |
| --- | --- | --- |
| G1 | Parse/discover `order.refunds[]` references | REQUIRED_DURING_M3 |
| G2 | Fetch/persist full refund detail via order-refunds API | REQUIRED_DURING_M3 |
| G3 | Durable refund + refund-line (or equivalent) financial facts — physical form TBD | REQUIRED_DURING_M3 |
| G4 | Idempotent refund upsert by `(source, woo_order_id, woo_refund_id)` | REQUIRED_DURING_M3 |
| G5 | Bind refund lines via `_refunded_item_id`; unresolved states | REQUIRED_DURING_M3 |
| G6 | Preserve original recognised sale facts after status leaves `:completed` | REQUIRED_DURING_M3 (analytics-correctness prerequisite) |
| G7 | MetricRules / aggregates: gross preserve + subtract qualifying refunds | REQUIRED_BEFORE_M5 (design in M1-06; implement with refund-aware metrics) |
| G8 | Refund completeness watermark inputs for ANALYTICS_READY | REQUIRED_BEFORE_M4 (contracted in M1-08; implemented with M4) |
| G9 | WooCommerceClient refund list/get methods | REQUIRED_DURING_M3 |
| G10 | Source-delete / void handling without destroying audit history | REQUIRED_DURING_M3 |
| G11 | Sign normalization (embedded negative totals vs positive `amount`) | REQUIRED_DURING_M3 |
| G12 | Shipping/fee/manual residual capture primitives | REQUIRED_DURING_M3 |
| G13 | Real sanitized refund payload fixtures (replace synthetic summary-only) | REQUIRED_DURING_M3 / OPTIONAL_HARDENING for tests |
| G14 | Concurrent cumulative-safe aggregation patterns | REQUIRED_DURING_M3 |
| G15 | Physical ownership choice (extend OrderUpserter vs adjacent RefundUpserter) | REQUIRED_DURING_M3 design step — not BEFORE_M2 |

```text
Nothing above is REQUIRED_BEFORE_M2.
M2 is structural event onboarding and does not depend on refund persistence.
Refund implementation belongs primarily to M3 and must be complete before M4 financial reconciliation.
```

---

## 25. Explicit Non-Goals

M1-05 does **not**:

```text
create Refund / RefundLine Ash resources
choose migrations
modify OrderUpserter
modify MetricRules
change recognised-sale lifecycle (M1-04)
change M1-03 attribution
fix M1-03 parent-product gap
define final named financial metrics
define Average Ticket Value
finalize tax reporting
finalize discount reporting
resolve payment/completion timestamp authority
resolve Johannesburg period boundaries
resolve 5m vs 10m freshness
implement historical backfill
implement financial reconciliation
implement ANALYTICS_READY
build analytics aggregates
change dashboard/cache code
implement Path 2
Apply / AutoApply
mutate WordPress
```

---

## 26. Decisions R1–R27

| ID | Decision | Locked value |
| --- | --- | --- |
| **R1** | Refund financial truth vs Order.status | Refund objects/history = financial truth; `:refunded` = lifecycle context only |
| **R2** | Preserve original recognised completed sale | Yes — never mutate historical sale merely to produce net |
| **R3** | Source-scoped refund identity | `(source_system_id, woo_order_id, woo_refund_id)` |
| **R4** | Refund → parent Order binding | Same source + matching `woo_order_id`; no cross-source |
| **R5** | Refund-line → OrderItem binding | `_refunded_item_id` only; else unresolved; no fuzzy match |
| **R6** | Full refund semantics | Full value reversed via refund facts; status often `:refunded` but status alone insufficient |
| **R7** | Partial refund semantics | Independent adjustments while order may remain `:completed` |
| **R8** | Quantity-refund semantics | Non-negative abs of source refund-line quantity; money≠qty |
| **R9** | Value-only refund semantics | Money without qty reverse; empty lines / amount-only supported |
| **R10** | Multiple refunds one line | Accumulate distinct refund-line facts; idempotent by line identity |
| **R11** | Sign convention | Durable positive magnitudes; normalize source negatives/positives explicitly |
| **R12** | Exact money | Decimal/numeric only |
| **R13** | Ticket vs non-ticket separation | Per bound historical OrderItem; never whole-order ticket assumption |
| **R14** | Shipping/fee/manual boundary | Capture as distinct raw categories for M1-06 |
| **R15** | Currency | Inherit parent Order.currency; mismatch → fail closed / review; no FX |
| **R16** | Duplicate/replay idempotency | Unique refund (+ refund-line) identity; no amount/date/reason keys |
| **R17** | Webhook/backfill convergence | Same identity → one durable fact |
| **R18** | Out-of-order arrival | Unresolved-parent/detail/line states allowed; converge; arrival order irrelevant |
| **R19** | Mutation/correction | Create/idempotent upsert; delete → void+retain audit; no silent hard-delete |
| **R20** | Historical attribution immutability | Refunds never remap event/ticket/source product identity |
| **R21** | Unresolved parent/line | Persist unresolved; block ticket attribution; review |
| **R22** | Timestamps for M1-07 | Require `date_created_gmt` + ingestion clocks; no refund source-updated field |
| **R23** | MetricRules compatibility | IMPLEMENTATION_CHANGE_REQUIRED |
| **R24** | Completeness inputs for M1-08 | Discovery+detail+resolve/unresolved+replay+parent bind+gaps |
| **R25** | Performance/concurrency | Postgres truth; Oban recovery; unique indexes; immutable facts; bounded REST |
| **R26** | Minimum audit evidence | source, parent Order, refund id, payload/ref, money/qty primitives, source created, reason, ingested/updated, void evidence |
| **R27** | Implementation timing | Contract now; implement primarily M3; complete before M4; MetricRules/net naming via M1-06; not BEFORE_M2 |

No R1–R27 decision is UNKNOWN.

---

## 27. M1-06 Handoff Inputs

M1-06 receives these **unnamed primitives** (do not rename authoritatively here):

```text
original_recognised_ticket_quantity
original_recognised_ticket_money_basis          # OrderItem.line_total under M1-04 recognition history
refunded_ticket_quantity
refund_money_applicable_to_qualifying_ticket_lines
non_ticket_refund_value
shipping_refund_value
fee_refund_value
manual_or_unallocated_refund_value
gross_preservation_rule                         # original gross persists
net_derivation_algebra                          # gross - qualifying refunds
currency_rule                                   # inherit Order.currency; no FX
```

M1-06 may assign names such as Gross Ticket Sales / Refunds / Net Ticket Sales / Refunded Quantity / Net Tickets.

M1-06 must also account for MetricRules IMPLEMENTATION_CHANGE_REQUIRED (R23).

---

## 28. M1-07 Handoff Inputs

```text
required: refund date_created_gmt (source-created)
not available: refund source-updated timestamp on official refund resource
required: EventSales ingestion / local updated timestamps
required if delete observed: void/discovery timestamp
context: parent Order.completed_at remains available
```

M1-07 decides authoritative field choice, UTC persistence, Johannesburg period placement, and refund period semantics.

---

## 29. M1-08 Handoff Inputs

```text
REFUND_COMPLETE inputs:
  refund reference discovery complete
  refund detail fetch/process complete
  refund lines resolved or explicitly unresolved
  financial adjustment replay idempotent
  parent Orders bound or unresolved-parent surfaced
  source coverage boundary for in-scope Orders
  known unresolved refund / missing detail / unresolved line inventories
```

M1-08 decides how these contribute to BACKFILL_COMPLETE / RECONCILED / ANALYTICS_READY.

---

## 30. Open Questions

| Question | Blocks M1-05? |
| --- | --- |
| Exact Ash resource / table names for refund facts | NO — physical form TBD in M3 |
| Whether refund writer lives inside OrderUpserter or adjacent module | NO — ownership selected later from this contract |
| Final named metric dictionary | NO — M1-06 |
| Johannesburg / payment timestamp authority | NO — M1-07 |
| ANALYTICS_READY composition | NO — M1-08 |
| Whether residual header amount ever counts as ticket money | NO — M1-06 inclusion rule |
| Real payload fixture replacement timing | NO — M3 test hardening |

No open question leaves R1–R27 ambiguous.

---

## 31. M1-05 Verdict

```text
M1-05 VERDICT:
PASS

BASELINE:
81d65c6582ca83da117db1d22e1e8b38647b3d3e

DOCUMENT:
docs/path-1/m1-05-refund-and-financial-adjustment-contract.md

PRODUCTION CODE CHANGES:
NONE

MIGRATION AUTHORIZED:
NO

REFUND IMPLEMENTATION GAPS:
1) REQUIRED_DURING_M3 — G1..G6, G9..G12, G14 refund discovery/detail/persistence/idempotency/binding/sign/void
2) REQUIRED_DURING_M3 — G15 physical writer ownership choice
3) REQUIRED_BEFORE_M4 — G8 refund completeness watermark (via M1-08/M4)
4) REQUIRED_BEFORE_M5 — G7 MetricRules/net aggregates after M1-06 names
5) OPTIONAL_HARDENING — G13 real sanitized refund fixtures

CURRENT METRICRULES COMPATIBILITY:
IMPLEMENTATION_CHANGE_REQUIRED

M1-06 AUTHORIZATION:
NOT GRANTED BY THIS TASK

NEXT RECOMMENDED ACTION:
Close out M1-05 on main when authorized, then start M1-06 with a FRESH agent using m1-01..m1-05 primitives — without implementing refund resources or renaming metrics here.
```

### Quick answers for a fresh M1-06 agent

```text
Refund vs status?
  Refund objects = financial truth; Order.status = lifecycle context.

Original sale preserved?
  Yes. Net = original recognised sale − qualifying refund adjustments.

Identify one Woo refund?
  (source_system_id, woo_order_id, woo_refund_id)

Bind to Order?
  Same source + parent woo_order_id.

Bind refund line to OrderItem?
  meta _refunded_item_id → woo_line_item_id; else unresolved.

Partial quantity?
  Abs(source refund-line quantity) on bound ticket line.

Value-only?
  Money without qty reverse; empty lines / amount-only allowed.

Money without qty?
  Yes, when source provides money without quantity evidence.

Multiple partials?
  Sum distinct refund-line facts.

Duplicate prevention?
  Identity uniqueness — not amount/date/reason.

Webhook + backfill?
  Converge to one durable fact.

Refund before Order?
  Unresolved-parent until Order exists.

Unresolved OrderItem?
  Persist unresolved; no invented ticket attribution.

Ticket vs non-ticket?
  Per historical OrderItem / shipping / fee / manual categories.

Sign?
  Durable positive magnitudes; normalize source signs.

Currency?
  Inherit Order.currency; mismatch fail closed; no FX.

Timestamps?
  date_created_gmt + ingestion; no official refund updated-at.

MetricRules vs future?
  IMPLEMENTATION_CHANGE_REQUIRED — currently drops :refunded sales entirely and ignores partials.

M1-06 calculates?
  Named metrics from locked primitives above.

M1-07 timestamps?
  Refund created (+ ingestion/void); period authority later.

M1-08 proves?
  REFUND_COMPLETE inputs listed in §19/§29.
```
