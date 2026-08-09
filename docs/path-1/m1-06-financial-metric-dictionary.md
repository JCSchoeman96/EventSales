Document:
Path 1 M1-06 Financial Metric Dictionary

Baseline:
78002a143148e98fc49fb80f1351f7a16bf67dba

origin/main:
78002a143148e98fc49fb80f1351f7a16bf67dba

Contract date:
2026-08-09

Verdict:
PASS

Authority:
NEW CONTRACT DOCUMENTATION (no production code)

---

# Path 1 M1-06 — Financial Metric Dictionary

| Field | Value |
| --- | --- |
| Document | Financial and ticket metric dictionary |
| Plan ID | `m1-06-financial-metric-dictionary` |
| Plan version | `v1` |
| Status | LOCKED for Path 1 management-facing financial / ticket metric meaning — M1-06 COMPLETE (PASS) |
| Scope | Gross/Refund/Net qty & value; Order Count; Average Ticket Value; exclusions; currency; tax/fee/discount authority; additivity; MetricRules gap; M1-07/08/M5 handoffs |
| Identity input | `docs/path-1/m1-02-source-scoped-external-identity-contract.md` (immutable) |
| Attribution input | `docs/path-1/m1-03-event-product-variation-orderline-attribution-contract.md` (immutable) |
| Lifecycle input | `docs/path-1/m1-04-order-lifecycle-and-recognised-sale-contract.md` (immutable for original recognition predicate) |
| Refund input | `docs/path-1/m1-05-refund-and-financial-adjustment-contract.md` (immutable for refund primitives) |
| Repository truth | `docs/path-1/m1-01-current-repo-truth.md` |
| Product authority | `docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md` §3 |
| Execution roadmap | `docs/path-1/path-1-phase-breakdown.md` |
| Strategy | CERTIFY + EXTEND METRIC CONTRACT — formulas and naming only; no implementation |

### Revision log

- `v1` — initial locked financial metric dictionary at baseline `78002a143148e98fc49fb80f1351f7a16bf67dba`

### Conflict rule

```text
This contract wins for Path 1 NAMED MANAGEMENT METRIC definitions and formulas.

M1-02 wins for Order / OrderItem identity tuples.
M1-03 wins for historical attribution / mapping_status.
M1-04 wins for original recognised-sale predicate (completed + mapped + ticket + qty > 0).
M1-05 wins for refund identity, binding, quantity-vs-money, sign/currency, gross preservation.
M1-07 wins for sale/refund/freshness timestamp field selection and Johannesburg period boundaries.
M1-08 wins for BACKFILL_COMPLETE / RECONCILED / ANALYTICS_READY display authority.

This document consumes M1-02..M1-05; it does not revise their locked predicates.
It supersedes M1-05's interim unnamed money label where Gross Ticket Sales
requires tax-inclusive composition rather than raw OrderItem.line_total alone.
```

---

## 1. Contract Metadata / Baseline

```text
branch: main
HEAD: 78002a143148e98fc49fb80f1351f7a16bf67dba
origin/main: 78002a143148e98fc49fb80f1351f7a16bf67dba
worktree at start: CLEAN
P1-00 / M1-01 / M1-01A / M1-02 / M1-03 / M1-04 / M1-05: COMPLETE
Path 2 / Phase 5E: PAUSED
```

Preflight evidence: `HEAD == origin/main`, clean worktree, on `main`, baseline matches authorized SHA.

M1-05 contract present and COMPLETE (PASS) at
`docs/path-1/m1-05-refund-and-financial-adjustment-contract.md`.

Evidence classes used below:

```text
REPOSITORY EVIDENCE
OFFICIAL SOURCE CONTRACT EVIDENCE
PRODUCT DECISION
CONTRACT DECISION
```

---

## 2. Executive Verdict

```text
M1-06 = PASS
```

Reasons:

```text
Gross / Refunded / Net ticket quantity and value formulas are deterministic from M1-04 + M1-05.
Original recognised sales remain historically preserved; refunds are independent adjustments.
Authoritative Gross Ticket Sales money is tax-inclusive composition:
  Woo line total (tax-exclusive) + Woo line total_tax.
Current OrderItem.line_total alone is NOT tax-inclusive → IMPLEMENTATION_CHANGE_REQUIRED.
Recognised Order Count is historical, distinct, and non-additive across overlapping scopes.
Average Ticket Value = Net Ticket Sales / Net Tickets Sold; zero denominator → undefined.
Tax Amount / Ticket Fees / Discount Amount are DEFERRED (source contract incomplete).
Shipping and non-ticket product value are excluded from ticket metrics.
Currency aggregation is same-currency only; no FX.
Current MetricRules is IMPLEMENTATION_CHANGE_REQUIRED (status-gated gross + no refund netting + tax-exclusive basis).
No production code required to lock this dictionary.
```

Production code changes: **NONE**.

Migration authorized: **NO**.

---

## 3. Locked Inputs from M1-04 / M1-05

### 3.1 M1-04 — original recognised ticket-sale predicate

**CONTRACT DECISION (consumed)**

```text
Order.status == :completed
AND
OrderItem.mapping_status == :mapped
AND
OrderItem.item_kind == :ticket
AND
OrderItem.quantity > 0
```

Evidence: `docs/path-1/m1-04-order-lifecycle-and-recognised-sale-contract.md`;
`lib/event_sales/analytics/metric_rules.ex:72-77`.

M1-06 does **not** reopen completed-only original recognition.

Historical preservation (M1-05): once a line satisfied that predicate as a recognised original sale, later `Order.status` change to `:refunded` must **not** erase Gross facts. Metric evaluation after refund persistence therefore uses **historical recognition**, not “current status still `:completed`”.

### 3.2 M1-05 — independent refund-adjustment primitives

**CONTRACT DECISION (consumed)**

| Primitive (M1-05 name) | Meaning |
| --- | --- |
| `original_recognised_ticket_qty` | `OrderItem.quantity` when M1-04 predicate held historically |
| `original_recognised_ticket_money_basis` | Interim: `OrderItem.line_total` — **superseded for Gross Ticket Sales by F5/F6 tax-inclusive composition** |
| `refunded_ticket_quantity` | Sum of bound ticket refund-line quantity magnitudes |
| `refunded_ticket_money` | Sum of bound ticket refund-line money magnitudes (positive) |
| Sign convention | Durable positive magnitudes; net = original − refund |
| Currency | Inherit `Order.currency`; no FX |
| Over-quantity | Do not silently clamp; REVIEW / over-refund |

Evidence: `docs/path-1/m1-05-refund-and-financial-adjustment-contract.md` §10–§14, §12 algebra.

### 3.3 Accounting model (locked)

```text
ORIGINAL TICKET QUANTITY − QUALIFYING REFUNDED TICKET QUANTITY = NET TICKET QUANTITY
ORIGINAL RECOGNISED TICKET VALUE − QUALIFYING TICKET REFUND VALUE = NET TICKET VALUE
```

Do not derive quantity from money. Do not derive money from quantity. Do not silently clamp negatives (M1-05 I16 / R8).

---

## 4. Metric Terminology

| Term | Meaning |
| --- | --- |
| **CANONICAL NAME** | Unique Path 1 dictionary name (this document) |
| **SHORT UI LABEL** | Allowed dashboard abbreviation; must map 1:1 to a canonical name |
| **ORIGINAL RECOGNISED SALE** | Line that historically satisfied M1-04 predicate |
| **GROSS** | Original recognised facts before refund adjustments |
| **REFUND ADJUSTMENT** | Independent M1-05 qualifying ticket refund fact |
| **NET** | Gross − qualifying refund adjustments |
| **AUTHORITATIVE** | Eligible for management reliance once M1-08 completeness gates allow |
| **OPERATIONAL STATUS METRIC** | Current `Order.status` counts; not financial Gross/Net |
| **ADDITIVE** | Safe to sum across disjoint partitions of the same grain |
| **NON-ADDITIVE / DERIVED** | Must recompute from additive components or preserve distinctness |

Forbidden bare labels without dictionary binding:

```text
Sales, Revenue, Tickets, Orders, Value
```

---

## 5. Source Financial Field Map

**REPOSITORY EVIDENCE**

| Meaning | Resource.Field | Source | Persist? | Metric role |
| --- | --- | --- | --- | --- |
| Order currency | `Order.currency` | Woo `currency` | Yes | Currency partition |
| Order grand total | `Order.raw_total` | Woo order `total` | Yes | **Not** ticket Gross/Net |
| Order discount | `Order.raw_discount_total` | Woo `discount_total` | Yes | Deferred discount |
| Order tax sum | `Order.raw_tax_total` | Woo `total_tax` | Yes | Deferred Tax Amount context only |
| Line qty | `OrderItem.quantity` | Woo line `quantity` | Yes | Gross Tickets Sold |
| Line subtotal (ex-tax) | `OrderItem.line_subtotal` | Woo line `subtotal` | Yes | Deferred discount basis |
| Line total (ex-tax) | `OrderItem.line_total` | Woo line `total` | Yes | Tax-exclusive component of Gross Ticket Sales |
| Line discount | `OrderItem.discount_total` | field or `subtotal−total` | Yes | Deferred Discount |
| Line total tax | — | Woo line `total_tax` | **MISSING** | Required for tax-inclusive Gross |
| Line subtotal tax | — | Woo line `subtotal_tax` | **MISSING** | Deferred Tax Amount |
| Shipping / fee lines | — | Woo `shipping_lines` / `fee_lines` | **MISSING** | Excluded from ticket metrics |
| Coupon snapshot | `CouponSnapshot.*` | `coupon_lines` | Yes | Deferred coupon dimension |
| Event booking fee meta | `Event.booking_fee_*` | Tickera catalogue | Yes | **Not** revenue math |

Citations:

```text
lib/event_sales/ingestion/parsers/woocommerce_order_parser.ex:16-47,79-103,141-145
lib/event_sales/sales/resources/order.ex:121-163
lib/event_sales/sales/resources/order_item.ex:213-233
docs/path-1/m1-01-current-repo-truth.md:431-447
```

**OFFICIAL SOURCE CONTRACT EVIDENCE**

WooCommerce Orders REST exposes separate line `total` and `total_tax` fields
(`developer.woocommerce.com` Orders API — Line items properties).

Maintainer-clarified semantics (WooCommerce issue `#62846` / PR `#63692`):

```text
order.total          → tax-inclusive grand total (customer paid)
line_items[].total   → tax-exclusive line total after discounts
line_items[].total_tax → line tax after discounts
tax-inclusive line money = line total + line total_tax
prices_include_tax reflects checkout price entry, not API line-total inclusion
```

Synthetic fixtures currently show `"total_tax": "0.00"` at order and line level
(`test/fixtures/woocommerce/order_completed.json:21,49-51`) — zero tax does **not**
authorize treating `line_total` as the general tax-inclusive contract.

---

## 6. Original Sale Financial Primitive Review

| Candidate | Verdict |
| --- | --- |
| `OrderItem.line_total` alone as Gross Ticket Sales | **NOT SUFFICIENT** for tax-inclusive product rule |
| `Order.raw_total` as ticket revenue | **REJECTED** — includes shipping/fees/non-ticket; not line-attributed |
| `OrderItem.line_subtotal` | Pre-discount ex-tax; not recognised sales after discount |
| Tax-inclusive composition `line_total + line_total_tax` | **AUTHORITATIVE** (source-proven; persistence gap) |

Current implementation:

```text
MetricRules.completed_revenue/2 → OrderItem.line_total when counts_as_sold?
```

Citation: `lib/event_sales/analytics/metric_rules.ex:90-93`.

M1-05 interim handoff named `OrderItem.line_total` as money basis until M1-06 verification.
This dictionary **revises that interim label** for Gross Ticket Sales only.

---

## 7. Tax-Inclusive Revenue Verification

**PRODUCT DECISION**

```text
Current prices and sales are inclusive of tax.
```

Citation: `docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md:63`.

### Verification outcome

```text
TAX-INCLUSIVE REVENUE CONTRACT:
IMPLEMENTATION_CHANGE_REQUIRED

Verification class:
REQUIRES_COMPOSITION
```

Deterministic formula (locked):

```text
tax_inclusive_original_ticket_line_money
  = Decimal.add(
      OrderItem.line_total,                    # Woo line "total" (ex-tax)
      OrderItem.line_total_tax                 # Woo line "total_tax" (REQUIRED durable field — missing today)
    )
```

When durable `line_total_tax` is absent:

```text
authoritative Gross Ticket Sales CANNOT be certified for non-zero tax environments
zero-tax datasets are numerically coincident with line_total but do not redefine the contract
```

Do **not**:

```text
infer tax by applying a rate to line_total
use Order.raw_tax_total allocated by residual arithmetic
treat prices_include_tax as changing line_total inclusion
silently ignore the product tax-inclusive rule
```

Separate **Tax Amount** reporting remains deferred (§17).

---

## 8. Canonical Metric Dictionary

| Metric | Canonical Definition | Formula | Source Primitives | Refund Treatment | Scope | Additivity | Currency | Authority Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Gross Tickets Sold | Original recognised ticket quantity | `sum(original_recognised_ticket_qty)` | `OrderItem.quantity` under historical M1-04 | Unaffected by refunds | Event / TicketType / Product / Variation / All | ADDITIVE | n/a | LOCKED_V1 |
| Refunded Ticket Quantity | Qualifying ticket quantity reversed | `sum(refunded_ticket_quantity)` | M1-05 bound ticket refund-line qty magnitudes | Includes only qty evidence | same | ADDITIVE | n/a | LOCKED_V1 (impl after refund persistence) |
| Net Tickets Sold | Tickets remaining after qty refunds | Gross Tickets Sold − Refunded Ticket Quantity | above | Derived | same | DERIVED | n/a | DERIVED / LOCKED_V1 |
| Gross Ticket Sales | Tax-inclusive original recognised ticket money | `sum(tax_inclusive_original_ticket_line_money)` | `line_total + line_total_tax` | Unaffected by refunds | same | ADDITIVE | per currency | LOCKED_V1 (persistence gap) |
| Ticket Refund Value | Qualifying ticket money returned (positive) | `sum(qualifying_ticket_refund_money_tax_inclusive)` | M1-05 bound ticket refund money + tax when present | Positive magnitude | same | ADDITIVE | per currency | LOCKED_V1 (impl after refund persistence) |
| Net Ticket Sales | Tax-inclusive ticket money after refunds | Gross Ticket Sales − Ticket Refund Value | above | Derived | same | DERIVED | per currency | DERIVED / LOCKED_V1 |
| Recognised Order Count | Distinct historically recognised ticket Orders in scope | `count(distinct Order identity)` where Order historically had ≥1 qualifying ticket line | `(source_system_id, woo_order_id)` | Refunds do **not** remove count | Event / All-event (see §14) | NON_ADDITIVE across overlapping scopes | n/a | LOCKED_V1 |
| Average Ticket Value | Mean net tax-inclusive money per net ticket | Net Ticket Sales ÷ Net Tickets Sold | Net metrics | Uses net after refunds | same | NON_ADDITIVE ratio | per currency | LOCKED_V1 |
| Product / Ticket-Type Ticket Quantity | Gross/Refunded/Net qty by historical attribution | Same qty formulas grouped by durable `event_id` / `ticket_type_id` / source product/variation | M1-03 historical FKs + source IDs | Same as parent qty metrics | Product dims | ADDITIVE within dim | n/a | LOCKED_V1 |
| Product / Ticket-Type Revenue | Gross/Refund/Net money by historical attribution | Same money formulas by durable attribution | same | Same as parent money metrics | Product dims | ADDITIVE within dim | per currency | LOCKED_V1 |
| Status Context Counts | Current lifecycle order/line visibility buckets | Count rows by current `Order.status` | `Order.status` | Not a refund-value metric | Operational | ADDITIVE for line rows; order-distinctness TBD for ops | n/a | OPERATIONAL_ONLY |
| Tax Amount | Separately reported tax component | Not locked | Line/order tax fields incomplete | Deferred | — | — | — | DEFERRED_SOURCE_CONTRACT |
| Ticket Fees | Reportable ticket fee revenue/cost | Not locked | Catalogue booking_fee meta ≠ order fee facts; fee_lines missing | Deferred | — | — | — | DEFERRED_SOURCE_CONTRACT |
| Discount Amount | Management discount total | Not locked | `discount_total` / coupons exist but tax-inclusive discount not proven | Deferred | — | — | — | DEFERRED_SOURCE_CONTRACT |
| Shipping Revenue | Shipping money | Excluded from ticket metrics | Not persisted | Excluded | — | — | — | NOT_SUPPORTED (v1 ticket metrics) |
| Non-ticket Product Revenue | Merchandise etc. | Excluded from ticket metrics | `item_kind != :ticket` | Excluded | — | — | — | NOT_SUPPORTED (v1 ticket metrics) |
| Average Ticket Order Value | Ticket money ÷ recognised orders | Not required for v1 | — | — | — | — | — | DEFERRED |
| Coupon-derived reporting | Acquisition/coupon dimensions | Later | CouponSnapshot | Deferred | — | — | — | DEFERRED |

---

## 9. Gross Ticket Quantity

| Field | Value |
| --- | --- |
| Canonical name | **Gross Tickets Sold** |
| Short UI label | Gross Tickets |
| Definition | Sum of original recognised ticket line quantities |
| Formula | `Σ OrderItem.quantity` over historically recognised ticket lines |
| Included | Historical M1-04: completed recognition + `:mapped` + `:ticket` + `quantity > 0` |
| Excluded | `:unmapped`, `:non_ticket`, `:ignored`, `:pending_mapping_resolution`, never-completed originals, `quantity <= 0` |
| Refund treatment | **Preserved** — later full/partial refund does not erase Gross |
| Currency | n/a |
| Aggregation | ADDITIVE across disjoint scopes |
| Zero behaviour | `0` when no qualifying originals |
| Timestamp category | original sale effective time (M1-07) |

---

## 10. Refunded / Net Ticket Quantity

### Refunded Ticket Quantity

| Field | Value |
| --- | --- |
| Canonical name | **Refunded Ticket Quantity** |
| Short UI label | Refunded Tickets |
| Definition | Sum of M1-05 qualifying ticket quantity reversals |
| Formula | `Σ abs(bound ticket refund-line quantity)` where historical OrderItem is ticket |
| Included | Bound refund lines with quantity magnitude > 0 on ticket OrderItems |
| Excluded | Value-only refunds (qty 0); shipping/fee/unbound residuals; non-ticket lines; invented qty from money |
| Refund treatment | This **is** the quantity adjustment |
| Sign | Non-negative magnitude (M1-05 R11) |
| Zero behaviour | `0` when no qty refunds |
| Timestamp category | refund adjustment effective time (M1-07) |

### Net Tickets Sold

| Field | Value |
| --- | --- |
| Canonical name | **Net Tickets Sold** |
| Short UI label | Net Tickets |
| Formula | Gross Tickets Sold − Refunded Ticket Quantity |
| Partial refund | Reduces Net by refunded qty only |
| Full qty refund | Net may be `0` while Gross remains original |
| Multiple refunds | Sum distinct refund-line qty facts (idempotent) |
| Value-only refund | Refunded Ticket Quantity = `0`; Net Tickets = Gross Tickets |
| Unresolved attribution | Do not invent qty; unresolved refunds do not contribute until bound (M1-05) |
| Over-refund qty | Do not clamp; REVIEW flag (M1-05); Net may go exceptional/negative pending review |
| Authority | Formula locked; authoritative display requires refund completeness (M1-08) |

---

## 11. Gross Ticket Sales

| Field | Value |
| --- | --- |
| Canonical name | **Gross Ticket Sales** |
| Alias accepted | Gross Ticket Revenue (same formula; prefer Sales in UI glossary) |
| Short UI label | Gross Ticket Sales |
| Definition | Tax-inclusive original recognised ticket line money |
| Formula | `Σ (OrderItem.line_total + OrderItem.line_total_tax)` over historically recognised ticket lines |
| Included | Same recognition exclusions as Gross Tickets Sold |
| Excluded | Shipping; fees; non-ticket lines; whole-order `raw_total`; unmapped/unknown |
| Refund treatment | **Preserved** historically |
| Currency | Partition by `Order.currency` |
| Rounding | Sum exact Decimals; round only for presentation |
| Zero behaviour | `Decimal 0` when none |
| Timestamp category | original sale effective time |

**Current repo conflict:** `completed_revenue/2` returns tax-exclusive `line_total` only
(`metric_rules.ex:90-93`). Future change required before authoritative Gross Ticket Sales.

---

## 12. Refund / Net Ticket Sales

### Ticket Refund Value

| Field | Value |
| --- | --- |
| Canonical name | **Ticket Refund Value** |
| Short UI label | Ticket Refunds |
| Definition | Tax-inclusive qualifying ticket money returned |
| Formula | `Σ` positive magnitudes of bound ticket refund-line money, including refund-line tax components when present (M1-05 captures tax where available) |
| Display/store convention | **Positive magnitude** (M1-05 R11) — never mix negative stored refunds into Net algebra |
| Excluded | Non-ticket merchandise refunds; shipping refunds; fee refunds; unbound/manual residuals **unless** a separately defined metric includes them (none in v1 ticket Net) |
| Currency | Parent `Order.currency` |
| Timestamp category | refund adjustment effective time |

### Net Ticket Sales

| Field | Value |
| --- | --- |
| Canonical name | **Net Ticket Sales** |
| Alias accepted | Net Ticket Revenue |
| Formula | Gross Ticket Sales − Ticket Refund Value |
| Example | Gross R1,000; Ticket Refund Value R250 → Net R750; Gross remains R1,000 |
| Status rule | **Do not** compute Net by checking current `Order.status` |
| Over-refund money | Do not silent-clamp; REVIEW; Net may go exceptional/negative |
| Authority | Withheld when refund completeness not certified (M1-08) |

---

## 13. Recognised Order Count

| Field | Value |
| --- | --- |
| Canonical name | **Recognised Order Count** |
| Short UI label | Orders |
| Definition | Distinct source-scoped Woo Orders that historically reached recognised completed-sale state with ≥1 qualifying ticket OrderItem in the reporting scope |
| Formula | `count(distinct (source_system_id, woo_order_id))` satisfying historical recognition in scope |
| Identity | M1-02 Order tuple |

### Explicit answers

| Question | Locked answer |
| --- | --- |
| Later partial refund removes Order from Order Count? | **No** |
| Full refund removes historical Order Count? | **No** |
| Value-only refund changes Order Count? | **No** |
| One Order with three ticket lines (same event) counts? | **Once** (per that event scope) |
| One Order with tickets for two Events? | **Once per Event** in event scope; **once globally** in all-event scope |
| Sum event Order Counts = global? | **No** — forbidden |

M1-04 prerequisite text that said “only when `Order.status = :completed`” is the **original recognition gate**. After M1-05 historical preservation, Order Count uses **historical recognition**, not live status.

---

## 14. Multi-Event Order Count

**CONTRACT DECISION**

| Metric | Multi-event Order behaviour |
| --- | --- |
| Ticket quantity | Allocate by historical `OrderItem` attribution (`event_id` / TicketType) |
| Ticket revenue | Allocate by historical OrderItem money |
| Refunds | Allocate via historical OrderItem binding (M1-05) |
| Event-level Recognised Order Count | One per Event that has ≥1 qualifying historical ticket line on that Order |
| All-event Recognised Order Count | One distinct Order globally |

```text
DO NOT:
global_order_count = sum(event_order_counts)
period_order_count = sum(ticket_type_order_counts)   # when one Order spans types
```

M5 must preserve distinctness (dedicated grain / projection / bounded distinct query — physical design later).

Evidence of multi-event fixture shape: `test/fixtures/woocommerce/order_mixed_event.json:40-90`.

---

## 15. Average Ticket Value

| Field | Value |
| --- | --- |
| Canonical name | **Average Ticket Value** |
| Short UI label | ATV |
| Formula | Net Ticket Sales ÷ Net Tickets Sold |
| Denominator | **Net Tickets Sold** — never Order Count |
| Numerator | **Net Ticket Sales** (tax-inclusive) |
| Zero denominator | **Undefined / N/A** — do not manufacture `0` |
| Aggregation | NON_ADDITIVE — derive from summed numerator and summed denominator |
| Gross ATV | Not a separate v1 locked metric |
| Average Ticket Order Value | **DEFERRED** (Net Ticket Sales ÷ Recognised Order Count) |

---

## 16. Product / Ticket-Type Allocation

**CONTRACT DECISION (consumes M1-03)**

Group Gross/Refund/Net quantity and money by durable historical attribution on the sale/refund facts:

```text
Event          → OrderItem.event_id
TicketType     → OrderItem.ticket_type_id
Logical product → OrderItem.woo_product_id (+ source_system via Order)
Logical variation → OrderItem.woo_variation_id when present
```

```text
Do NOT re-resolve ProductMapping / TicketType at reporting time.
A later catalogue rename must not reallocate historical money/qty.
```

Evidence: M1-03 historical immutability; `order_item.ex` relationships `event` / `ticket_type`
(`lib/event_sales/sales/resources/order_item.ex:269-275`).

---

## 17. Tax / Fees / Discounts

### Tax Amount

| Verdict | DEFERRED_SOURCE_CONTRACT / NOT AUTHORITATIVE for Path 1 v1 management |
| --- | --- |
| Why | Line `total_tax` / `subtotal_tax` not persisted; order `raw_tax_total` is order-level (includes non-ticket/shipping tax); refund tax adjustment persistence not implemented |
| Forbidden | Invent tax by rate × revenue |
| Relation to Gross | Gross Ticket Sales is tax-**inclusive**; Tax Amount is an optional component once fields verified |

### Ticket Fees

| Verdict | DEFERRED — SOURCE CONTRACT NOT VERIFIED |
| --- | --- |
| Catalogue `booking_fee_*` | Explicitly **not** for revenue math (`docs/ops/tickera_catalog_feed_contract.md:193`) |
| Order `fee_lines` | Not parsed (`woocommerce_order_parser.ex` — no fee_lines handling) |
| Forbidden | Residual `order.total − ticket lines` as fees; shipping-as-fees |

### Discount Amount

| Verdict | DEFERRED_SOURCE_CONTRACT |
| --- | --- |
| Existing fields | `OrderItem.discount_total` (often `subtotal − total`); `Order.raw_discount_total`; coupon `discount` / `discount_tax` |
| Gap | Tax-inclusive discount semantics not proven end-to-end; automatic `subtotal−total` is tax-exclusive composition of tax-exclusive fields |
| Coupon dimension | Later scope (`EVENTSALES_PRODUCT_DECISIONS.md:121-126`) |

---

## 18. Shipping / Non-Ticket Exclusions

**CONTRACT DECISION**

Excluded from Gross Ticket Sales, Net Ticket Sales, Average Ticket Value, and ticket quantity metrics:

```text
shipping (and shipping tax)
non-ticket products (item_kind != :ticket)
memberships/subscriptions unless qualifying mapped ticket lines
generic Woo fee_lines (until Ticket Fees contract verifies)
unrelated order-level taxes not on ticket lines
Order.raw_total as a substitute for ticket revenue
```

Inclusion requires M1-04 recognised ticket lines only.

---

## 19. Currency / Decimal / Rounding

### Currency

**REPOSITORY EVIDENCE:** `Order.currency` required
(`order.ex:121-124`; parser `:16-17`). Default display fallback config `ZAR`
(`config/runtime.exs:37`) is **not** authority to mix currencies.

**CONTRACT DECISION:**

```text
same-currency values may aggregate
different currencies must NOT be summed into one number
no FX conversion in Path 1 v1
if multiple currencies present → report per currency (or withhold mixed aggregate)
refunds inherit parent Order.currency (M1-05 R15)
```

### Decimal / rounding

```text
All authoritative money: Decimal / database numeric — never float
Preferred: sum exact stored primitives → derive metrics → format/round only for presentation
No floating-point percentages as durable truth
```

Evidence: parser `Decimal.new/1` (`woocommerce_order_parser.ex:244-248`);
MetricRules `Decimal.add` (`metric_rules.ex:150`); OrderItem money attributes `:decimal`
(`order_item.ex:219-233`).

---

## 20. Operational Status Context

**PRODUCT DECISION:** operational states remain visible alongside completed sales
(`EVENTSALES_PRODUCT_DECISIONS.md:58-62`).

| Canonical name | Current Order Status Count |
| --- | --- |
| Nature | OPERATIONAL_ONLY |
| Formula | Count by current `Order.status` (and/or line-visible status breakdown) |
| Statuses | `:pending`, `:processing`, `:on_hold`, `:completed`, `:failed`, `:cancelled`, `:refunded` |
| Boundary | Must **not** alter Gross/Net financial calculations |
| Note | Current `:refunded` count ≠ Ticket Refund Value |

Current code: `MetricRules.status_bucket/1` + `status_breakdown`
(`metric_rules.ex:105-106,164-174`); `visible_in_status_breakdown?/2` always true for Order+Item
(`metric_rules.ex:98-99`).

---

## 21. Refund-Incomplete Data Authority

**CONTRACT DECISION**

```text
Formulas for Net Tickets Sold, Ticket Refund Value, Net Ticket Sales, Average Ticket Value
are DEFINED here.

Authoritative management display eligibility depends on M1-08 ANALYTICS_READY / refund completeness.

When refund truth is known incomplete:
  Gross Tickets Sold / Gross Ticket Sales may still be shown as gross-only (if original sales complete)
  Net / Refund / ATV must be withheld or explicitly marked non-authoritative
  Do not pretend Net equals Gross merely because refund rows are missing
```

M1-06 does not design readiness UI.

---

## 22. Additive vs Non-Additive Matrix

| Metric | Classification |
| --- | --- |
| Gross Tickets Sold | ADDITIVE |
| Refunded Ticket Quantity | ADDITIVE |
| Gross Ticket Sales | ADDITIVE (per currency) |
| Ticket Refund Value | ADDITIVE (per currency) |
| Net Tickets Sold | DERIVED (Gross − Refunded) |
| Net Ticket Sales | DERIVED (Gross − Refund) |
| Recognised Order Count | NON_ADDITIVE across overlapping Event/TicketType scopes |
| Average Ticket Value | NON_ADDITIVE ratio |
| Status Context Counts | ADDITIVE for the chosen grain (document grain carefully) |

```text
Never persist/sum precomputed averages across periods.
For ratios: aggregate numerator + aggregate denominator → derive ratio.
```

---

## 23. Aggregate-Safe Primitive Set

Smallest additive set for M5:

```text
gross_ticket_quantity
refunded_ticket_quantity
gross_ticket_value          # tax-inclusive
ticket_refund_value         # positive tax-inclusive magnitude
currency
qualified_order_identity support (for distinct Order Count)
status_context counts (operational)
```

Derive at read time (or from exact additive components):

```text
net_ticket_quantity
net_ticket_value
average_ticket_value
```

```text
Postgres durable sale/refund facts + aggregate snapshots = cold truth
Existing ETS DashboardCache / HotStateAggregator may cache derived aggregates
Redis may warm shared state — NEVER metric authority
No Cachex
```

---

## 24. Current MetricRules Compatibility

| Metric Contract | Current MetricRules | Compatible? | Future Change |
| --- | --- | --- | --- |
| Gross Tickets Sold | `sold_quantity/2` via `counts_as_sold?` requiring **current** `:completed` | **No** after refunds | Historical recognition; preserve qty when status → `:refunded` |
| Gross Ticket Sales | `completed_revenue/2` = `line_total` | **No** | Tax-inclusive composition; rename/clarify vs Gross |
| Refunded Ticket Quantity | Absent | **No** | Consume M1-05 qty primitives |
| Ticket Refund Value | Absent | **No** | Consume M1-05 money primitives (positive) |
| Net Tickets Sold | Absent (status drop zeros sold) | **No** | Gross − Refunded |
| Net Ticket Sales | Absent | **No** | Gross − Ticket Refund Value |
| Recognised Order Count | Absent (status_breakdown counts **lines**, not distinct Orders) | **No** | Distinct historical Order identity; multi-event rules |
| Average Ticket Value | Absent | **No** | Net÷Net with N/A on zero denom |
| Status Context | `status_breakdown` increments per visible line | Partial | Keep operational; separate from finance |

**CURRENT METRICRULES COMPATIBILITY: IMPLEMENTATION_CHANGE_REQUIRED**

Why (conceptual):

1. Uses live `Order.status == :completed` instead of historical Gross preservation after refunds (`metric_rules.ex:72-77`).
2. Uses tax-exclusive `line_total` as “completed revenue” (`metric_rules.ex:90-93`).
3. Has no refund subtraction path.
4. `summarize/2` has no Order Count or ATV; status breakdown is line-additive, not distinct-order-safe (`metric_rules.ex:111-174`).
5. Snapshots mirror those summary fields (`event_aggregate_snapshot.ex:91-117`).

M1-05 already concluded IMPLEMENTATION_CHANGE_REQUIRED; M1-06 confirms the metric-level reasons.

---

## 25. Scenario Matrix

Legend: GQ/RQ/NQ = Gross/Refunded/Net Tickets; GS/RV/NS = Gross Sales / Ticket Refund Value / Net Sales; OC = Order Count; ATV; Auth = authoritative under complete refund truth unless noted.

| # | Scenario | GQ | RQ | NQ | GS | RV | NS | OC | ATV | Auth? |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | Completed mapped ticket qty 2, money TI=R900, no refund | 2 | 0 | 2 | 900 | 0 | 900 | 1 | 450 | yes |
| 2 | Same, refund qty 1 money R450 | 2 | 1 | 1 | 900 | 450 | 450 | 1 | 450 | yes |
| 3 | Same, refund qty 2 money R900 | 2 | 2 | 0 | 900 | 900 | 0 | 1 | N/A | yes |
| 4 | Qty 2, value-only refund R100 (qty 0) | 2 | 0 | 2 | 900 | 100 | 800 | 1 | 400 | yes |
| 5 | One order, 3 ticket lines same event | sum qtys | … | … | sum money | … | … | **1** | NS/NQ | yes |
| 6 | Ticket + non-ticket on one order | ticket only | ticket only | … | ticket only | … | … | 1 if ≥1 ticket | ticket-only | yes |
| 7 | Tickets for Events A and B | split by attribution | split | split | split | split | split | A:1 B:1; global:1 | per scope | yes |
| 8 | Fully refunded historical order | original GQ | =GQ | 0 | original GS | =GS | 0 | **1** | N/A | yes |
| 9 | Partially refunded historical order | original | partial | reduced | original | partial | reduced | **1** | NS/NQ | yes |
| 10 | Status `:refunded`, refund detail incomplete | Gross known | unknown | unknown | Gross known | unknown | unknown | 1 if historically recognised | unknown | **no** for Net/ATV |
| 11 | Same refund replayed | unchanged | unchanged | unchanged | unchanged | unchanged | unchanged | unchanged | unchanged | yes (idempotent) |
| 12 | Ticket fee present, source unverified | ignore fee | — | — | ticket lines only | — | — | — | — | fees not authoritative |
| 13 | Mixed currencies in scope | per currency | per currency | per currency | **partition** | partition | partition | per currency or global distinct still once | per currency | mixed sum **no** |
| 14 | Zero net tickets after full refund | GQ>0 | =GQ | 0 | GS | =GS | 0 | 1 | **N/A** | yes |
| 15 | Exceptional over-refund (M1-05 REVIEW) | GQ | >GQ possible | may be <0 | GS | may >GS | may be <0 | 1 | if NQ>0 else N/A | REVIEW / not silent clamp |

TI = tax-inclusive. Symbolic money assumes tax already composed.

---

## 26. Performance & Scaling Review

| Metric | Bounded additive aggregates? | Raw-order scan needed? | Event/day/hour composable? | Stream/batch? | Distinctness special? | Ratio from sums? |
| --- | --- | --- | --- | --- | --- | --- |
| Gross Tickets | Yes | No at dash time | Yes | Yes | No | n/a |
| Refunded Tickets | Yes | No | Yes | Yes | No | n/a |
| Gross Ticket Sales | Yes | No | Yes | Yes | No | n/a |
| Ticket Refund Value | Yes | No | Yes | Yes | No | n/a |
| Net qty/value | Derive | No | Derive from components | Yes | No | n/a |
| ATV | Derive | No | Derive num/den | Yes | No | **Yes** |
| Recognised Order Count | Needs distinct grain | Avoid unbounded scans | **Not** by summing child scopes | Yes with care | **Yes** | n/a |
| Status context | Yes at chosen grain | Avoid unbounded | Yes | Yes | Order vs line grain | n/a |

M5 must not need:

```text
unbounded sales_order_items scans at peak
full historical refund table scans per dashboard hit
per-dashboard N+1
summing precomputed averages
summing overlapping distinct order counts
```

Target later architecture (not implemented here): Postgres facts + snapshots; ETS hot cache; Redis warm; PubSub realtime.

---

## 27. Required Future Implementation Gaps

| ID | Gap | Timing |
| --- | --- | --- |
| MG1 | Persist Woo line `total_tax` (and likely `subtotal_tax`) on OrderItem | REQUIRED_DURING_M3 (with order ingestion) / before authoritative Gross Ticket Sales |
| MG2 | MetricRules / aggregators: tax-inclusive Gross composition | REQUIRED_BEFORE_M5 |
| MG3 | Refund persistence + qualifying qty/money primitives (M1-05 G1..) | REQUIRED_DURING_M3; completeness REQUIRED_BEFORE_M4 |
| MG4 | MetricRules: historical Gross preservation + Net after refunds | REQUIRED_BEFORE_M5 |
| MG5 | Distinct Recognised Order Count aggregate support | REQUIRED_BEFORE_M5 |
| MG6 | ATV derivation (Net÷Net; N/A on zero) | REQUIRED_BEFORE_M5 |
| MG7 | Currency-partitioned aggregates (no mixed sum) | REQUIRED_BEFORE_M5 |
| MG8 | Snapshot schema beyond total_sold/total_revenue | REQUIRED_BEFORE_M5 |
| MG9 | Tax Amount / Ticket Fees / Discount Amount source contracts | REQUIRED_LATER / OPTIONAL until product prioritises |
| MG10 | M1-03 attribution G1 (variation-parent) | REQUIRED_BEFORE_M2 (unchanged; not M1-06 failure) |

Missing physical Refund resources are **not** an M1-06 design failure (M1-05).

---

## 28. Explicit Non-Goals

M1-06 did **not**:

```text
modify MetricRules
implement refunds / Refund resources
fix M1-03 attribution gap
change completed-only original recognition
decide M1-07 timestamps / Johannesburg boundaries / freshness thresholds
design ANALYTICS_READY UI
implement financial reconciliation
create analytics snapshots
build dashboards
add Redis/ETS/Cachex logic
perform Path 2 / Phase 5E work
Apply / AutoApply / mutate WordPress
```

---

## 29. Decisions F1–F27

| ID | Decision |
| --- | --- |
| **F1** | Canonical v1 metrics: Gross Tickets Sold; Refunded Ticket Quantity; Net Tickets Sold; Gross Ticket Sales; Ticket Refund Value; Net Ticket Sales; Recognised Order Count; Average Ticket Value; Product/Ticket-Type qty & revenue variants; Status Context (operational). Deferred: Tax Amount, Ticket Fees, Discount Amount, Average Ticket Order Value, coupon dimensions, shipping/non-ticket revenue as ticket metrics |
| **F2** | Gross Tickets Sold = sum original historically recognised `OrderItem.quantity` |
| **F3** | Refunded Ticket Quantity = M1-05 qualifying bound ticket refund-line qty magnitudes only |
| **F4** | Net Tickets Sold = Gross Tickets Sold − Refunded Ticket Quantity |
| **F5** | Authoritative original ticket money = tax-inclusive composition `line_total + line_total_tax` (not `line_total` alone) |
| **F6** | Gross Ticket Sales = sum of F5 over historically recognised ticket lines; product tax-inclusive rule satisfied by composition |
| **F7** | Ticket Refund Value = positive magnitude of qualifying ticket refund money (tax-inclusive when tax components present); excludes non-ticket/shipping/fee residuals from v1 ticket Net |
| **F8** | Net Ticket Sales = Gross Ticket Sales − Ticket Refund Value |
| **F9** | Recognised Order Count = distinct historically recognised ticket Orders in scope |
| **F10** | Partial, full, and value-only refunds do **not** remove Order Count |
| **F11** | Multi-event: once per Event in event scope; once globally; never sum event counts for global |
| **F12** | Average Ticket Value = Net Ticket Sales / Net Tickets Sold |
| **F13** | Zero Net Tickets Sold → ATV = undefined/N/A (not 0) |
| **F14** | Product/Ticket-Type allocation uses durable historical OrderItem attribution / source IDs — no live ProductMapping re-resolve |
| **F15** | Tax Amount = DEFERRED_SOURCE_CONTRACT |
| **F16** | Ticket Fees = DEFERRED — SOURCE CONTRACT NOT VERIFIED |
| **F17** | Discount Amount = DEFERRED_SOURCE_CONTRACT |
| **F18** | Shipping and non-ticket value excluded from ticket Gross/Net/ATV |
| **F19** | Same-currency aggregate only; no FX; multi-currency → partition or withhold |
| **F20** | Decimal/numeric only; round at presentation |
| **F21** | Status context metrics are operational-only and do not alter Gross/Net |
| **F22** | Net/Refund/ATV non-authoritative until M1-08 refund completeness / ANALYTICS_READY |
| **F23** | Additive: gross/refund qty & value; Derived: nets; Non-additive: Order Count across overlaps, ATV |
| **F24** | M5 primitive set: gross_ticket_quantity, refunded_ticket_quantity, gross_ticket_value, ticket_refund_value, currency, order-identity support, status counts |
| **F25** | Distinct Order Count must not be obtained by summing overlapping scope counts |
| **F26** | MetricRules compatibility: IMPLEMENTATION_CHANGE_REQUIRED (matrix §24) |
| **F27** | Timestamp categories handed to M1-07: sale effective time; refund adjustment effective time; source freshness/update time — fields undecided |

All F1–F27 deterministic → **not BLOCKED**.

---

## 30. M1-07 Handoff Inputs

Provide only timestamp **categories**:

| Metric family | Required timestamp category |
| --- | --- |
| Gross Tickets / Gross Ticket Sales / historical Order Count eligibility | **sale effective time** |
| Refunded Ticket Quantity / Ticket Refund Value | **refund adjustment effective time** |
| Freshness / stale banners | **source freshness / update time** |

Do **not** decide here: payment vs completion field, Johannesburg day boundary, refund period assignment, 5m vs 10m freshness.

---

## 31. M1-08 / M5 Handoff Inputs

### M1-08

Withhold as non-authoritative when refund completeness not certified:

```text
Refunded Ticket Quantity
Ticket Refund Value
Net Tickets Sold
Net Ticket Sales
Average Ticket Value
```

Gross Tickets Sold / Gross Ticket Sales may remain showable as gross-only if original-sale completeness is certified independently.

### M5

```text
Persist/cache additive primitives in §23
Derive nets and ATV from summed components
Enforce currency partitioning
Preserve distinct Order Count (no sum-of-scopes)
Refund-aware aggregation required (independent adjustment facts)
Postgres remains durable metric truth; ETS/Redis may cache only
```

Do not design physical aggregate tables in this document.

---

## 32. Open Questions

| Item | Status |
| --- | --- |
| Exact Ash field name for durable line tax (`line_total_tax` vs other) | Implementation naming — formula locked |
| Whether zero-tax ZA production history needs backfill of `0` tax rows | Implementation detail; composition still required |
| Physical Refund resource shape | Owned by M1-05 / M3 — not reopened |
| Average Ticket Order Value product need | DEFERRED unless product prioritises |

No UNKNOWN that blocks F1–F27.

---

## 33. M1-06 Verdict

```text
M1-06 = PASS

Baseline: 78002a143148e98fc49fb80f1351f7a16bf67dba
Document: docs/path-1/m1-06-financial-metric-dictionary.md
Production code: NONE
Migration: NO

TAX-INCLUSIVE REVENUE CONTRACT: IMPLEMENTATION_CHANGE_REQUIRED
CURRENT METRICRULES COMPATIBILITY: IMPLEMENTATION_CHANGE_REQUIRED

M1-07 AUTHORIZATION: NOT GRANTED BY THIS TASK
```

Success criteria: a fresh M1-07/M5 agent can answer all §47 dictionary questions identically from this document without inferring numbers from ambiguous UI labels.
