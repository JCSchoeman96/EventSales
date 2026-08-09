Document:
Path 1 M1-04 Order Lifecycle and Recognised-Sale Contract

Baseline:
6caac9429b536f017e52f7134678d09d7a7d5c7c

origin/main:
6caac9429b536f017e52f7134678d09d7a7d5c7c

Contract date:
2026-08-09

Verdict:
PASS

Authority:
CERTIFY CONTRACT DOCUMENTATION (no production code)

---

# Path 1 M1-04 — Order Lifecycle and Recognised-Sale Contract

| Field | Value |
| --- | --- |
| Document | Order lifecycle and recognised-ticket-sale contract |
| Plan ID | `m1-04-order-lifecycle-and-recognised-sale-contract` |
| Plan version | `v1` |
| Status | LOCKED for Path 1 order status / recognised-sale semantics — M1-04 COMPLETE (PASS) |
| Scope | Woo → EventSales status normalization; Order lifecycle; recognised ticket sale predicate; operational visibility; source-sync vs state-machine; refunded status boundary |
| Identity input | `docs/path-1/m1-02-source-scoped-external-identity-contract.md` (immutable) |
| Attribution input | `docs/path-1/m1-03-event-product-variation-orderline-attribution-contract.md` (immutable for attribution) |
| Repository truth | `docs/path-1/m1-01-current-repo-truth.md` |
| Product authority | `docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md` §3 |
| Execution roadmap | `docs/path-1/path-1-phase-breakdown.md` |
| Strategy | CERTIFY existing parser / Order / MetricRules / AutomaticMappingPolicy / OrderUpserter behaviour; no implementation |

### Revision log

- `v1` — initial locked lifecycle and recognised-sale contract at baseline `6caac9429b536f017e52f7134678d09d7a7d5c7c`

### Conflict rule

```text
This contract wins for Path 1 ORDER STATUS lifecycle and RECOGNISED TICKET SALE semantics.

M1-02 wins for identity tuples and source-scoped lookup vocabulary.
M1-03 wins for attribution / mapping_status / attribution_status_reason behaviour.
This document consumes M1-02 and M1-03; it does not revise them.

M1-05 owns refund financial adjustments (amounts, quantities, partials, net).
M1-06 owns named financial metric dictionary (Gross/Net, ATV, Order Count aggregation).
M1-07 owns payment/completion/freshness timestamp authority.
```

---

## 1. Contract Metadata / Baseline

```text
branch: main
HEAD: 6caac9429b536f017e52f7134678d09d7a7d5c7c
origin/main: 6caac9429b536f017e52f7134678d09d7a7d5c7c
worktree at start: CLEAN
P1-00 / M1-01 / M1-01A / M1-02 / M1-03: COMPLETE
Path 2 / Phase 5E: PAUSED
```

Preflight evidence: `HEAD == origin/main`, clean worktree, on `main`, baseline matches authorized SHA.

M1-03 contract present and COMPLETE (PASS) at
`docs/path-1/m1-03-event-product-variation-orderline-attribution-contract.md`.

Focused tests run (supporting evidence only):

```text
mix test test/event_sales/analytics/metric_rules_test.exs \
         test/event_sales/sales/automatic_mapping_policy_test.exs \
         test/event_sales/sales/status_rules_test.exs
→ 12 tests, 0 failures
```

---

## 2. Executive Verdict

```text
M1-04 = PASS
```

Reasons:

```text
Supported Woo statuses are exact and reject unsupported values fail-closed.
Normalized Order.status atoms match product-required operational set plus :processing.
Recognised ticket sale is completed-only and also requires M1-03 mapped ticket line + qty > 0.
:processing / :on_hold / :pending / :failed / :cancelled / :refunded do NOT recognise sales.
Operational visibility is intentionally broader than financial recognition.
Ash state-machine transitions are narrow; Woo source sync may force any allowed status atom.
:refunded is lifecycle status only — not a refund financial model (M1-05).
No production code changes required to lock this contract.
```

Production code changes: **NONE**.

Migration authorized: **NO**.

---

## 3. Inputs from M1-02 / M1-03

### 3.1 M1-02 (identity — consumed, not redefined)

| Concept | Identity |
| --- | --- |
| Order | `(source_system_id, woo_order_id)` |
| OrderItem physical line | `(order_id, woo_line_item_id)` |

Status changes do not create a new Order identity. Idempotency and stale source updates remain M1-02 / OrderUpserter concerns.

### 3.2 M1-03 (attribution — consumed, not redefined)

| Concept | Locked meaning for recognition |
| --- | --- |
| `mapping_status == :mapped` | Durable Event/TicketType attribution succeeded |
| `item_kind == :ticket` | Line classified as ticket on mapping apply paths |
| `:on_hold` deferral | Automatic mapping deferred only — not a sales-recognition exception |
| Historical immutability | Normal ingestion does not reassign mapped Event/TicketType when status evolves |

M1-04 recognition predicate **requires** M1-03 `:mapped` + `:ticket`. Completed order status alone is insufficient.

Evidence: M1-03 §2 / §23; `metric_rules.ex:72-77`.

---

## 4. Lifecycle Terminology

| Term | Meaning in this contract |
| --- | --- |
| **ORDER STATUS** | Durable `Order.status` atom (`:pending` … `:failed`) |
| **ATTRIBUTION STATUS** | Durable `OrderItem.mapping_status` (+ reasons) — owned by M1-03 |
| **RECOGNISED SALE STATUS** | Whether a line contributes sold qty / completed revenue via `MetricRules` |
| **SOURCE SYNC** | Incoming Woo payload updating Order via `:sync_from_normalized` / `:sync_status_from_source` |
| **INTERNAL STATE MACHINE** | Narrow AshStateMachine transitions (`mark_processing`, `mark_completed`, …) |
| **OPERATIONAL VISIBILITY** | Inclusion in status-breakdown style views (`visible_in_status_breakdown?/2`) |
| **MAPPING ELIGIBILITY** | Whether automatic mapping may run (`AutomaticMappingPolicy`) |
| **REFUNDED LIFECYCLE** | `Order.status == :refunded` only |
| **REFUND FINANCIAL TRUTH** | Out of scope — M1-05 |

Core distinction:

```text
Order.status = :completed
  ≠ recognised ticket sale

recognised ticket sale
  = Order.status = :completed
    AND OrderItem.mapping_status = :mapped
    AND OrderItem.item_kind = :ticket
    AND OrderItem.quantity > 0
```

---

## 5. Woo → EventSales Status Matrix

Parser authority: `WoocommerceOrderParser.parse_status/1`
(`lib/event_sales/ingestion/parsers/woocommerce_order_parser.ex:53-61`).

Persistable atoms: `Order.@order_statuses`
(`lib/event_sales/sales/resources/order.ex:14-22`).

| Woo value | Normalized atom | Persistable? | Initial/create? | Source-sync allowed? | Mapping attempted? | Operationally visible? |
| --- | --- | --- | --- | --- | --- | --- |
| `pending` | `:pending` | Yes | Yes | Yes (if newer `updated_at_source`) | Eligible | Yes |
| `processing` | `:processing` | Yes | Yes | Yes | Eligible | Yes |
| `on-hold` | `:on_hold` | Yes | Yes | Yes | **Deferred** | Yes |
| `on_hold` | `:on_hold` | Yes | Yes | Yes | **Deferred** | Yes |
| `completed` | `:completed` | Yes | Yes | Yes | Eligible | Yes |
| `failed` | `:failed` | Yes | Yes | Yes | Eligible | Yes |
| `cancelled` | `:cancelled` | Yes | Yes | Yes | Eligible | Yes |
| `refunded` | `:refunded` | Yes | Yes | Yes | Eligible | Yes |
| unsupported / unknown | — | No | No | N/A | N/A | N/A |

Unsupported status behaviour:

```text
{:error, {:invalid_order_payload, :status, :unsupported}}
```

Evidence: `woocommerce_order_parser.ex:61`; `woocommerce_order_parser_test.exs:155-159`.

Notes:

- Create path `:create_normalized` accepts any atom in `@order_statuses` (`order.ex:24-41,63-65`). Fixtures/tests create non-pending statuses directly (`sales_storage_status_state_machines_test.exs:266-334`).
- Ash `initial_states [:pending]` (`order.ex:202-203`) is the default SM initial state; it does **not** prevent Woo-sourced creates of other supported statuses.
- Mapping columns refer to **automatic mapping eligibility**, not recognition (see §9).

---

## 6. State Machine vs Source Synchronization

### 6.1 Internal state machine (narrow)

Exposed transition actions (`order.ex:81-99,206-212`):

| Action | From | To |
| --- | --- | --- |
| `:mark_processing` | `:pending` | `:processing` |
| `:mark_completed` | `:processing` | `:completed` |
| `:mark_cancelled` | `:processing` | `:cancelled` |
| `:cancel_pending` | `:pending` | `:cancelled` |
| `:mark_refunded` | `:completed` | `:refunded` |

Extra states present without user-facing transition actions from every peer:

```text
:on_hold, :failed
```

Evidence: `order.ex:204`.

Invalid internal jumps are rejected (example: `mark_completed` from `:pending`).
Evidence: `sales_storage_status_state_machines_test.exs:258-264`.

### 6.2 External source synchronization (broad)

Primary ingestion path:

```text
WoocommerceOrderParser.parse
  → OrderUpserter.upsert_normalized_order
    → create :create_normalized
       OR update :sync_from_normalized (when incoming updated_at_source is newer)
```

Evidence: `order_upserter.ex:20-93,320-339`.

`:sync_from_normalized` and `:sync_status_from_source` both apply:

1. `GuardSourceVersion` — allow only when incoming `updated_at_source` is **strictly newer** than stored (`guard_source_version.ex:13-24`; `source_version_guard.ex:18-25`).
2. `SyncStatusFromSource` — **force-sets** `:status` and `:updated_at_source`, bypassing SM transition graph (`sync_status_from_source.ex:16-27`).

Therefore a newer Woo payload may move an order among **any** allowed `@order_statuses` atoms, including transitions the internal SM cannot express, for example:

```text
pending → completed
processing → completed
on_hold → completed
completed → refunded
completed → cancelled
completed → pending   (source may regress status; completed_at is not cleared)
```

Evidence: `sales_storage_status_state_machines_test.exs:266-301,337-368`.

`completed_at` behaviour under source sync (`sync_status_from_source.ex:21-27`):

| Incoming status | `completed_at` handling |
| --- | --- |
| `:completed` with `%DateTime{}` | force-set to supplied value |
| any other status | left unchanged (not cleared) |

Timestamp authority for “what completed_at means for reporting windows” remains **M1-07**. M1-04 only records current write behaviour.

### 6.3 OrderUpserter version branches (status evolution)

| Incoming vs stored `updated_at_source` | Order header | Children / mapping |
| --- | --- | --- |
| incoming **older** | `:stale_noop` — no status change | not updated |
| incoming **newer** | `:sync_from_normalized` (status + fields) | upsert + `map_pending_items_for_order` |
| incoming **equal** | order header unchanged | children upserted + mapping attempted |

Evidence: `order_upserter.ex:68-100`.

Identity/idempotency semantics remain M1-02. M1-04 locks only the resulting status/recognition effect of those branches.

---

## 7. Recognised Ticket Sale Predicate

### 7.1 Analytics source of truth

```text
EventSales.Analytics.MetricRules
```

Moduledoc: dashboard/cache/snapshot code must delegate here
(`metric_rules.ex:1-8`).

Parallel storage-era predicates in `EventSales.Sales.StatusRules` match the same completed-only rule (`status_rules.ex:14-17`) and must not diverge. Path 1 recognition certification uses **MetricRules**.

### 7.2 Exact predicate

```elixir
def counts_as_sold?(%Order{status: :completed}, %OrderItem{} = item) do
  item.mapping_status == :mapped and item.item_kind == :ticket and item.quantity > 0
end

def counts_as_sold?(_order, _item), do: false
```

Evidence: `metric_rules.ex:72-77`.

### 7.3 Derived quantities and money

| Function | When `counts_as_sold?` | Otherwise |
| --- | --- | --- |
| `sold_quantity/2` | `OrderItem.quantity` | `0` |
| `completed_revenue/2` | `OrderItem.line_total` | `Decimal.new("0")` |

Evidence: `metric_rules.ex:82-93`.

### 7.4 Locked recognition facts

| Question | Locked answer |
| --- | --- |
| Which quantity is recognised? | `OrderItem.quantity` when predicate true |
| Which money field is recognised revenue today? | `OrderItem.line_total` (Decimal) |
| Do non-ticket items qualify? | **No** (`item_kind` must be `:ticket`) |
| Do unmapped / pending / ignored / non_ticket mapping statuses qualify? | **No** (must be `:mapped`) |
| Does `Order.status == :completed` alone qualify? | **No** |
| Does `:processing` qualify? | **No** |
| Can quantity ≤ 0 qualify? | **No** in predicate; durable create also constrains `quantity` min 1 (`order_item.ex:213-217`) |

Do **not** rename this field Gross/Net or declare final metric dictionary here — that is M1-06 after M1-05.

---

## 8. Status-by-Status Recognition Matrix

For a durable OrderItem that is otherwise a mapped ticket with `quantity > 0`:

| Order.status | Recognised ticket qty? | Recognised ticket revenue? | Operationally visible? | Mapping eligible? | Freshness/change activity relevant? | May later become recognised? | Special processing? |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `:pending` | No (`0`) | No (`0`) | Yes | Eligible | Via `updated_at_source` (M1-07 owns clocks) | Yes, if source advances to `:completed` and line maps | None |
| `:processing` | No | No | Yes | Eligible | Same | Yes, if becomes `:completed` + mapped ticket | Operational-only; **must not** be treated as paid recognition |
| `:on_hold` | No | No | Yes | **Deferred** | Same | Yes, after status advances and mapping runs | EFT-awaiting operational meaning possible; **do not infer payment** |
| `:completed` | Yes if mapped ticket qty>0 | `line_total` if sold | Yes | Eligible | Same | Already eligible when predicate holds | Prerequisite for recognition |
| `:failed` | No | No | Yes | Eligible | Same | Only if source later becomes `:completed` | Mapping may still run |
| `:cancelled` | No | No | Yes | Eligible | Same | Only if source later becomes `:completed` | Mapping may still run |
| `:refunded` | No | No | Yes | Eligible | Same | Not while status remains `:refunded` | Lifecycle only — M1-05 owns refund finance |

Evidence: `metric_rules.ex:72-100`; `metric_rules_test.exs:19-40`; `automatic_mapping_policy.ex:21-24`; product decisions §3 (`EVENTSALES_PRODUCT_DECISIONS.md:58-62`).

### 8.1 Completed (Path 1 lock)

```text
Order.status = :completed
+ OrderItem.mapping_status = :mapped
+ OrderItem.item_kind = :ticket
+ OrderItem.quantity > 0
→ eligible recognised ticket sale
→ recognised quantity = OrderItem.quantity
→ recognised revenue field (repo truth) = OrderItem.line_total
```

### 8.2 Processing (STOP check)

Current `MetricRules` does **not** count `:processing`.
Evidence: `metric_rules.ex:77`; `metric_rules_test.exs:7,19-30`.

```text
:processing = operational-only for recognition purposes
```

No STOP / BLOCKED condition triggered.

### 8.3 On-hold

```text
:on_hold → not recognised sale
```

Mapping deferral owned by M1-03 / `AutomaticMappingPolicy`; sales recognition independently excludes it because status ≠ `:completed`.

### 8.4 Pending / failed / cancelled

```text
recognised quantity = 0
recognised revenue = 0
operational visibility = yes
mapping processing = eligible (not deferred)
```

### 8.5 Refunded (lifecycle only)

```text
Order.status = :refunded
→ counts_as_sold? = false
→ visible_in_status_breakdown? = true
```

This is **not** a complete refund financial model. See §14–§15.

---

## 9. Mapping Eligibility vs Recognition

| Order.status | May automatic mapping run? | May line count as recognised sale? |
| --- | --- | --- |
| `:pending` | Yes (`:eligible`) | No |
| `:processing` | Yes | No |
| `:on_hold` | No (`:deferred`) — leave pending | No |
| `:completed` | Yes | Yes **only if** mapped + ticket + qty>0 |
| `:failed` | Yes | No |
| `:cancelled` | Yes | No |
| `:refunded` | Yes | No |

Evidence: `automatic_mapping_policy.ex:3-26`; `order_item_mapper.ex:29-55`; `metric_rules.ex:72-77`.

These columns are intentionally different. Mapping eligibility ≠ financial eligibility.

Example: a cancelled order may still receive automatic mapping work, yet contributes zero recognised sales.

On-hold deferral end-to-end: `order_upserter_test.exs:73-108`.

---

## 10. Operational Visibility

```elixir
def visible_in_status_breakdown?(%Order{}, %OrderItem{}), do: true
def visible_in_status_breakdown?(_order, _item), do: false
```

Evidence: `metric_rules.ex:98-100`.

Lock:

```text
Every durable Order + OrderItem pair is operationally visible in status breakdown math.
Financial recognition is a separate, narrower predicate.
```

`status_bucket/1` returns `Order.status` unchanged (`metric_rules.ex:105-106`).

UI design is out of scope for M1-04. Product direction requires completed-only totals not hide operational context (`EVENTSALES_PRODUCT_DECISIONS.md:58-62`).

`StatusRules.visible_status?/2` is likewise always true (`status_rules.ex:31-32`).

---

## 11. Reprocessing / Status Evolution

| Scenario | Status / recognition outcome (M1-04) |
| --- | --- |
| pending → completed (newer source) | Status becomes `:completed`; recognition becomes true for qualifying mapped ticket lines |
| on_hold → completed (newer source) | Status becomes `:completed`; deferred mapping may run; recognition follows predicate |
| completed webhook replayed (equal `updated_at_source`) | Header status unchanged; children/mapping may re-run; recognition unchanged if attrs unchanged |
| completed → refunded (newer source) | Status `:refunded`; recognition becomes false; Order identity unchanged |
| completed → cancelled (newer source) | Status `:cancelled`; recognition becomes false |
| older Woo payload after newer | `:stale_noop`; status/recognition unchanged |
| same `updated_at_source` again | No header sync; recognition unchanged unless child mapping state changes |

Attribution identity rewrite rules remain M1-03. Status evolution alone is not remapping.

---

## 12. Historical Attribution Boundary

```text
order status evolution ≠ attribution reassignment
```

Locked:

- Changing `Order.status` does not create a new Order identity (`(source_system_id, woo_order_id)`).
- Becoming `:refunded` or `:cancelled` after `:completed` may change lifecycle/recognition treatment.
- It does **not** authorize silent Event/TicketType remapping (M1-03 historical immutability).
- Explicit correction remains the narrow audited admin path owned by M1-03.

---

## 13. Current Money Field Usage

Repository truth for recognised revenue **today**:

```text
MetricRules.completed_revenue/2 → OrderItem.line_total when counts_as_sold?
```

Related durable money fields (stored; **not** MetricRules sold revenue unless noted):

| Field | Resource | Role in M1-04 |
| --- | --- | --- |
| `OrderItem.line_total` | OrderItem | **Recognised revenue field** when sold |
| `OrderItem.line_subtotal` | OrderItem | Stored; not MetricRules sold revenue |
| `OrderItem.discount_total` | OrderItem | Stored; not MetricRules sold revenue |
| `Order.raw_total` | Order | Order header total; not MetricRules sold revenue |
| `Order.raw_discount_total` | Order | Stored |
| `Order.raw_tax_total` | Order | Stored |

All monetary attributes are Decimal/numeric — never float.

Final names (Gross Ticket Sales, Net Ticket Sales, Discounts, Refunds, Average Ticket Value) belong to **M1-06** after **M1-05**.

---

## 14. Refunded Status Boundary

M1-04 locks:

```text
Order.status = :refunded
  is a lifecycle representation of Woo status "refunded"
```

and:

```text
MetricRules does not count :refunded as sold
```

Evidence: parser `woocommerce_order_parser.ex:59`; `metric_rules_test.exs:33-40`.

**STOP before defining (M1-05):**

```text
refund amount
refund quantity
partial refund
net revenue after refund
refund timestamp
refund transaction identity
Woo "refunds" array ingestion
first-class Refund / RefundLine resources
```

Current repository has no Refund resource under `lib/` (rg finds none). Parser does not read a `"refunds"` array (M1-01 already established).

```text
refunded order status ≠ complete refund financial model
```

---

## 15. Lifecycle vs Refund Contract

| Concern | M1-04 lifecycle | M1-05 financial adjustment |
| --- | --- | --- |
| `Order.status = :refunded` | YES | Input only |
| Original completed sale recognition rules | YES | YES (as prior recognised sale context) |
| Partial refund | NO | YES |
| Refund transaction ID | NO | YES |
| Refund quantity | NO | YES |
| Refund amount | NO | YES |
| Refund timestamp | NO | YES |
| Net after refund | NO | YES |
| Ingest Woo `refunds` array | NO | YES (if contracted) |

Also locked:

```text
order lifecycle alone cannot represent complete refund financial truth
```

---

## 16. Performance Review

Recognised-sale classification:

| Property | Current behaviour |
| --- | --- |
| Operates from already-loaded Order/OrderItem? | Yes — pure struct predicates |
| Extra DB queries inside MetricRules? | No |
| Pure / deterministic? | Yes |
| Aggregatable later? | Yes — from durable rows / future bounded aggregates |
| Durable lifecycle truth | Postgres `sales_orders.status` |
| Caching required by M1-04? | No |

Do **not** introduce Redis / ETS / GenServer / Cachex as lifecycle truth.

At high concurrency, status handling remains:

```text
bounded
idempotent through existing OrderUpserter + SourceVersionGuard
not dependent on dashboard reads
```

Future analytics may cache derived MetricRules results; that is outside M1-04.

---

## 17. Required Future Implementation Gaps

Evidence-backed gaps only. **Do not implement in M1-04.**

| ID | Gap | Severity | Owner |
| --- | --- | --- | --- |
| G1 | No first-class refund objects / Woo `refunds` array ingestion | REQUIRED for financial refund truth | **M1-05** |
| G2 | Partial-refund cannot be expressed by `Order.status` alone | REQUIRED for financial refund truth | **M1-05** |
| G3 | Final named financial metrics (Gross/Net/ATV/Order Count aggregation) not locked | REQUIRED for metric dictionary | **M1-06** |
| G4 | Payment vs completion vs freshness timestamp authority unresolved (`completed_at` retained when leaving `:completed`) | REQUIRED for period/freshness | **M1-07** |
| G5 | Dual predicate modules (`MetricRules` + `StatusRules`) exist; currently aligned | OPTIONAL_HARDENING — keep single analytics SoT | Later if they diverge |
| G6 | Internal SM cannot express all Woo transitions (by design today) | INFORMATIONAL — source sync is authoritative for Woo | No change unless product forbids certain source jumps |

No gap blocks locking L1–L20 for recognised-sale / lifecycle semantics.

M1-03 G1 (TicketType parent fail-closed) remains REQUIRED_BEFORE_M2 and is **out of scope** here.

---

## 18. Explicit Non-Goals

M1-04 does **not**:

```text
modify source identity (M1-02)
modify attribution (M1-03)
fix M1-03 TicketType parent gap
generalize remapping
create Refund resources
design partial refunds
define final financial metrics
define tax allocation
define discounts
define average ticket value
resolve payment/completion timestamp authority
resolve freshness
design backfill
design reconciliation
design ANALYTICS_READY
change caches/dashboard
perform Path 2 work
Apply / AutoApply
mutate WordPress
change production code or migrations
```

---

## 19. Decisions L1–L20

| ID | Decision | Locked value |
| --- | --- | --- |
| **L1** | Supported Woo source statuses | `pending`, `processing`, `on-hold`, `on_hold`, `completed`, `cancelled`, `refunded`, `failed` |
| **L2** | Source → normalized atom | as §5 matrix; `on-hold`/`on_hold` → `:on_hold` |
| **L3** | Unsupported status | parse error `{:invalid_order_payload, :status, :unsupported}`; not persisted |
| **L4** | Internal SM vs source sync | SM = narrow user transitions; source sync force-sets any allowed status when newer |
| **L5** | Completed prerequisite | Only `:completed` orders may contribute recognised sales |
| **L6** | Exact OrderItem predicate | `:completed` + `:mapped` + `:ticket` + `quantity > 0` |
| **L7** | Mapping requirement | `mapping_status` must be `:mapped` |
| **L8** | Positive quantity | `quantity > 0` required by predicate |
| **L9** | Non-ticket lines | Never recognised (`item_kind` must be `:ticket`) |
| **L10** | `:pending` | Not recognised; visible; mapping eligible |
| **L11** | `:processing` | Not recognised; operational-only; mapping eligible |
| **L12** | `:on_hold` | Not recognised; mapping deferred; visible |
| **L13** | `:failed` | Not recognised; visible; mapping eligible |
| **L14** | `:cancelled` | Not recognised; visible; mapping eligible |
| **L15** | `:refunded` lifecycle | Not recognised; visible; mapping eligible; **not** refund finance |
| **L16** | Operational visibility | `visible_in_status_breakdown?/2` true for any Order+OrderItem |
| **L17** | Mapping vs recognition | Distinct axes; mapping may run when recognition is false |
| **L18** | Replay / status-update recognition | Newer source may change status→recognition; stale noop; equal skips header |
| **L19** | Lifecycle vs attribution immutability | Status evolution ≠ Event/TicketType reassignment |
| **L20** | M1-05 refund boundary | Amounts/qty/partials/net/txn/timestamps out of scope |

No L1–L20 decision is UNKNOWN.

---

## 20. M1-05 Handoff Inputs

M1-05 may assume:

```text
LIFECYCLE
  supported statuses + normalization locked (L1–L3)
  :refunded is a first-class Order.status atom
  MetricRules currently drops recognition when status ≠ :completed
  source sync can move completed → refunded when newer

RECOGNITION
  completed + mapped + ticket + qty>0 → sold qty + line_total revenue
  processing/on_hold/pending/failed/cancelled/refunded → zero recognised sale

ATTRIBUTION
  M1-03 remains authority; status change does not remap

MISSING
  Refund / RefundLine resources
  Woo refunds[] ingestion
  partial refund semantics
  net-after-refund metrics
```

M1-05 must **not** redefine L1–L19 unless product authority formally revises completed-only recognition.

```text
M1-05 AUTHORIZATION: NOT GRANTED BY THIS TASK
```

---

## 21. Open Questions

| Question | Blocks M1-04? |
| --- | --- |
| Exact refund object schema / partial refund rules | DOES NOT BLOCK (M1-05) |
| Gross vs Net naming / Order Count aggregation | DOES NOT BLOCK (M1-06) |
| Payment timestamp vs `completed_at` vs freshness clocks | DOES NOT BLOCK (M1-07) |
| Whether product should forbid certain source status regressions (e.g. completed→pending) | DOES NOT BLOCK — current sync allows any allowed atom |
| Whether `StatusRules` should be deleted/aliased to MetricRules | DOES NOT BLOCK — predicates currently agree |
| When to implement M1-03 G1 | DOES NOT BLOCK M1-04 |

No open question leaves L1–L20 ambiguous.

---

## 22. M1-04 Verdict

```text
M1-04 VERDICT:
PASS

BASELINE:
6caac9429b536f017e52f7134678d09d7a7d5c7c

DOCUMENT:
docs/path-1/m1-04-order-lifecycle-and-recognised-sale-contract.md

PRODUCTION CODE CHANGES:
NONE

MIGRATION AUTHORIZED:
NO

LIFECYCLE IMPLEMENTATION GAPS:
1) REQUIRED — G1/G2 refund financial model missing (M1-05)
2) REQUIRED_LATER — G3 named financial metrics (M1-06)
3) REQUIRED_LATER — G4 timestamp/freshness authority (M1-07)
4) OPTIONAL_HARDENING — G5 dual StatusRules/MetricRules modules
5) INFORMATIONAL — G6 narrow SM vs broad source sync (by design)

M1-05 AUTHORIZATION:
NOT GRANTED BY THIS TASK

NEXT RECOMMENDED ACTION:
Close out M1-04 on main when authorized, then start M1-05 with a FRESH agent using m1-01..m1-04, product decisions, and the refund boundary matrices — without redesigning lifecycle recognition.
```

### Recognised-sale order-count prerequisite (for M1-06)

```text
An order may be considered for recognised-sale order-count metrics
only when Order.status = :completed
and it contains at least one qualifying recognised ticket line
(as locked by L6).

Distinct-order aggregation semantics remain M1-06.
```
