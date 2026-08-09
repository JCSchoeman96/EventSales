Document:
Path 1 M1-07 Timestamp, Johannesburg Period and Freshness Contract

Baseline:
8b0d82ca97c9c5ff918fedf6ee0bccfb552e5e66

origin/main:
8b0d82ca97c9c5ff918fedf6ee0bccfb552e5e66

Contract date:
2026-08-09

Verdict:
PASS

Authority:
NEW CONTRACT DOCUMENTATION (no production code)

---

# Path 1 M1-07 — Timestamp, Johannesburg Period and Freshness Contract

| Field | Value |
| --- | --- |
| Document | Timestamp, Johannesburg reporting-period, and freshness contract |
| Plan ID | `m1-07-timestamp-johannesburg-period-and-freshness-contract` |
| Plan version | `v1` |
| Status | LOCKED for Path 1 sale/refund effective clocks, Johannesburg periods, and freshness/stale semantics — M1-07 COMPLETE (PASS) |
| Scope | Time vocabulary; Order timestamp map; sale/refund effective clocks; source vs read-model age; 5m/10m thresholds; Johannesburg `[start,end)` periods; refresh/PubSub boundaries; hot/warm/cold roles; T1–T31; M1-08/M5/M6 handoffs |
| Identity input | `docs/path-1/m1-02-source-scoped-external-identity-contract.md` (immutable) |
| Attribution input | `docs/path-1/m1-03-event-product-variation-orderline-attribution-contract.md` (immutable) |
| Lifecycle input | `docs/path-1/m1-04-order-lifecycle-and-recognised-sale-contract.md` (immutable for recognition predicate) |
| Refund input | `docs/path-1/m1-05-refund-and-financial-adjustment-contract.md` (immutable for refund primitives / R22 clocks) |
| Metric input | `docs/path-1/m1-06-financial-metric-dictionary.md` (immutable for metric formulas; F27 timestamp categories consumed) |
| Repository truth | `docs/path-1/m1-01-current-repo-truth.md` |
| Product authority | `docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md` §§3–5 |
| Programme windows | `docs/roadmap/EVENTSALES_LIVE_SALES_PROGRAMME.md` VS-27B.1 |
| Execution roadmap | `docs/path-1/path-1-phase-breakdown.md` |
| Strategy | CERTIFY existing timestamp behaviour + NEW CONTRACT where fields/authority are missing — documentation only |

### Revision log

- `v1` — initial locked timestamp / Johannesburg / freshness contract at baseline `8b0d82ca97c9c5ff918fedf6ee0bccfb552e5e66`

### Conflict rule

```text
This contract wins for Path 1:
  sale effective time field selection and fallback
  refund effective time field selection and fallback
  Johannesburg reporting timezone and [start,end) period boundaries
  source-freshness vs read-model-age separation
  <5m visibility / >10m stale operators
  refresh and PubSub freshness boundaries

M1-02 wins for Order / OrderItem identity and OrderUpserter stale/equal/newer branches.
M1-03 wins for attribution / mapping_status.
M1-04 wins for original recognised-sale predicate (completed + mapped + ticket + qty > 0).
M1-05 wins for refund identity, binding, quantity-vs-money, sign/currency, gross preservation.
M1-06 wins for named Gross/Refund/Net metric formulas.
M1-08 wins for BACKFILL_COMPLETE / RECONCILED / ANALYTICS_READY display authority.

This document does not revise M1-02..M1-06 locked predicates or formulas.
It resolves the OPEN M1-07 CONTRACT CONFLICT (programme >10m stale vs HotStateAggregator 5m).
```

---

## 1. Contract Metadata / Baseline

```text
branch: main
HEAD: 8b0d82ca97c9c5ff918fedf6ee0bccfb552e5e66
origin/main: 8b0d82ca97c9c5ff918fedf6ee0bccfb552e5e66
worktree at start: CLEAN
P1-00 / M1-01 / M1-01A / M1-02 / M1-03 / M1-04 / M1-05 / M1-06: COMPLETE
Path 2 / Phase 5E: PAUSED
```

Preflight evidence: `HEAD == origin/main`, clean worktree, on `main`, baseline matches authorized SHA.

M1-06 contract present and COMPLETE (PASS) at
`docs/path-1/m1-06-financial-metric-dictionary.md`.

Evidence classes used below:

```text
REPOSITORY EVIDENCE
OFFICIAL SOURCE CONTRACT EVIDENCE
PRODUCT DECISION
CONTRACT DECISION
```

Official WooCommerce REST API docs used only where repository fixtures do not establish source timestamp property meaning:

```text
https://woocommerce.github.io/woocommerce-rest-api-docs/#order-properties
https://woocommerce.github.io/woocommerce-rest-api-docs/#order-refund-properties
```

---

## 2. Executive Verdict

```text
M1-07 = PASS
```

Reasons:

```text
Timestamp vocabulary is disjoint (sale ≠ refund ≠ source-updated ≠ ingestion ≠ cache age).
Recognised-sale effective clock locked: Woo date_paid_gmt preferred, date_completed_gmt fallback.
Refund effective clock locked: Woo refund date_created_gmt (M1-05 R22).
Source freshness separated from read-model / cache generation age.
Programme conflict resolved:
  age < 5m  → NORMAL visibility target
  5m ≤ age ≤ 10m → AGING (outside normal; not stale)
  age > 10m → STALE
Current HotStateAggregator stale_after_ms = 300_000 (5m) on rebuild last_fresh_at
  → IMPLEMENTATION_CHANGE_REQUIRED (threshold and semantic separation).
Johannesburg reporting timezone Africa/Johannesburg; durable source instants UTC;
  reporting periods half-open [start, end).
Sale and refund may fall in different periods; Gross stays in sale period.
No production code required to lock this contract.
```

Production code changes: **NONE**.

Migration authorized: **NO**.

---

## 3. Inputs from M1-04 / M1-05 / M1-06

### 3.1 M1-04 — recognition and completed_at write behaviour

**CONTRACT DECISION (consumed)**

Original recognised ticket-sale predicate remains:

```text
Order.status == :completed
AND OrderItem.mapping_status == :mapped
AND OrderItem.item_kind == :ticket
AND OrderItem.quantity > 0
```

Evidence: `docs/path-1/m1-04-order-lifecycle-and-recognised-sale-contract.md`;
`lib/event_sales/analytics/metric_rules.ex:72-77`.

Current `completed_at` sync behaviour (`lib/event_sales/sales/changes/sync_status_from_source.ex:21-27`):

| Incoming status | `completed_at` handling |
| --- | --- |
| `:completed` with `%DateTime{}` | force-set to supplied value |
| any other status | left unchanged (not cleared) |

M1-04 deferred payment-vs-completion and freshness authority to M1-07 (G4).

### 3.2 M1-05 — refund clocks required

**CONTRACT DECISION (consumed — R22)**

| Clock | Required? |
| --- | --- |
| Refund source-created (`date_created_gmt`) | REQUIRED |
| Refund source-updated | NOT AVAILABLE on official refund resource |
| Refund ingestion / local inserted/updated | REQUIRED (audit) |
| Parent `Order.completed_at` | context only — not refund period authority |

Evidence: `docs/path-1/m1-05-refund-and-financial-adjustment-contract.md` §18 / R22;
official refund properties `date_created` / `date_created_gmt`.

### 3.3 M1-06 — timestamp categories (fields undecided there)

**CONTRACT DECISION (consumed — F27)**

| Metric family | Timestamp category |
| --- | --- |
| Gross Tickets / Gross Ticket Sales / historical Order Count | **sale effective time** |
| Refunded Ticket Quantity / Ticket Refund Value | **refund adjustment effective time** |
| Freshness / stale banners | **source freshness / update time** |

Evidence: `docs/path-1/m1-06-financial-metric-dictionary.md:858-866`.

M1-07 selects fields and period/freshness operators for those categories. It does **not** change Gross/Net formulas.

---

## 4. Timestamp Vocabulary

**CONTRACT DECISION (T1)**

| Term | Meaning | Answers |
| --- | --- | --- |
| **SOURCE CREATED TIME** | When the source system created the entity | “When did Woo create this order/refund?” |
| **SOURCE UPDATED TIME** | When the source system last modified the entity | “What is the latest source revision we know?” |
| **SALE EFFECTIVE TIME** | Authoritative instant placing a **recognised original sale** into a reporting period | “Which Johannesburg period owns Gross for this sale?” |
| **REFUND EFFECTIVE TIME** | Authoritative instant placing a **refund adjustment** into a reporting period | “Which Johannesburg period owns this refund adjustment?” |
| **INGESTION TIME** | When EventSales durably received/processed a payload | “When did we ingest?” — audit only |
| **CACHE / READ-MODEL GENERATED TIME** | When a derived summary/snapshot/hot cache was last successfully written | “How old is this read model?” |
| **FRESHNESS OBSERVED TIME** | Instant used as the numerator end for source-freshness age (`now − freshness_anchor`) | “How stale is authoritative source coverage?” |
| **REPORTING PERIOD** | Half-open Johannesburg business interval `[start, end)` | “Which civil/business window are we reporting?” |

A single stored field must not serve two vocabulary roles without an explicit dual-purpose exception. No dual-purpose exceptions are authorized in this contract.

---

## 5. Current Repository Timestamp Map

**REPOSITORY EVIDENCE**

### 5.1 `Order.created_at_source`

| Aspect | Value |
| --- | --- |
| Source field | Woo `date_created_gmt` |
| Input form | ISO-8601 naive string treated as UTC (`Etc/UTC`) |
| Persistence | `:utc_datetime_usec`, required |
| Mutation | Written on create; accepted on `:sync_from_normalized` when newer source update allowed |
| Purpose | SOURCE CREATED TIME |
| NOT valid for | SALE EFFECTIVE TIME; REFUND EFFECTIVE TIME; source freshness age of “latest apply”; stale banner |

Evidence: `lib/event_sales/ingestion/parsers/woocommerce_order_parser.ex:17-18,35,261-271`;
`lib/event_sales/sales/resources/order.ex:130-133,177-178`.

### 5.2 `Order.updated_at_source`

| Aspect | Value |
| --- | --- |
| Source field | Woo `date_modified_gmt` |
| Input form | ISO-8601 naive string treated as UTC |
| Persistence | `:utc_datetime_usec`, required |
| Mutation | Upserter stale/equal/newer guard (`DateTime.compare`); Ash `GuardSourceVersion` requires incoming `>` existing |
| Purpose | SOURCE UPDATED TIME; durable order version clock; catch-up `orderby=modified` alignment |
| NOT valid for | SALE EFFECTIVE TIME; REFUND EFFECTIVE TIME |

Evidence: `woocommerce_order_parser.ex:19-20,36`;
`order_upserter.ex:68-92`;
`source_version_guard.ex:19-23`;
`order.ex:55,135-138`.

### 5.3 `Order.completed_at`

| Aspect | Value |
| --- | --- |
| Source field | Woo `date_completed_gmt` (optional) |
| Input form | ISO-8601 naive string treated as UTC; may be `nil` |
| Persistence | `:utc_datetime_usec`, nullable; indexed |
| Mutation | Set when incoming status is `:completed` and datetime present; **not cleared** when status leaves `:completed` |
| Purpose | Current repository completion clock; used today by `MetricRules` “today” bucketing |
| NOT valid for | Final sole SALE EFFECTIVE TIME when `date_paid_gmt` exists; source freshness; refund effective time |

Evidence: `woocommerce_order_parser.ex:21-22,34`;
`sync_status_from_source.ex:21-27`;
`order.ex:54,126-128`;
`metric_rules.ex:138`.

### 5.4 `Order.inserted_at` / `Order.updated_at`

| Aspect | Value |
| --- | --- |
| Source field | None (Ash local timestamps) |
| Persistence | create/update timestamps |
| Purpose | Local row audit (INGESTION-adjacent local durability clocks) |
| NOT valid for | SALE EFFECTIVE TIME; REFUND EFFECTIVE TIME; source freshness |

Evidence: `order.ex:177-178`.

### 5.5 Absent payment clock

| Aspect | Value |
| --- | --- |
| Woo field | `date_paid_gmt` / `date_paid` exist on official Order properties |
| Repository | **Not parsed; not persisted** |
| Classification | REQUIRED_DURING_M3 persistence gap (see §23) |

Evidence: `docs/path-1/m1-01-current-repo-truth.md:493`;
`rg date_paid` over `lib/` → no parser/resource field;
official Order properties table (`date_paid_gmt`: “The date the order was paid, as GMT”).

### 5.6 Related analytics clocks (certified, not overloaded)

| Field | Layer | Role |
| --- | --- | --- |
| Snapshot `refreshed_at` | Postgres snapshot | CACHE/READ-MODEL GENERATED TIME |
| Snapshot `source_watermark_at` | Postgres snapshot | max `Order.updated_at_source` among rows in refresh scope |
| Hot summary `:updated_at` | ETS / Redis warm | CACHE/READ-MODEL GENERATED TIME (`DateTime.utc_now()` at write) |
| HotStateAggregator `last_fresh_at` | process state | currently rebuild/restore finish or newest warm summary `updated_at` — **read-model age**, not source freshness |
| WebhookEvent `received_at` | ingestion | INGESTION TIME |

Evidence: `snapshot_refresh.ex:92-110,172-180`;
`hot_state_aggregator.ex:27,213-226,338-349,421-422,468-485`;
`rebuild_hot_state_worker.ex:95-96`;
`webhook_event.ex:147` (received_at attribute).

---

## 6. Sale Effective-Time Contract

**CONTRACT DECISION (T4, T6)**

For a line that is (or was historically) an M1-04 recognised original sale, **SALE EFFECTIVE TIME** is:

```text
1) Woo date_paid_gmt   when present (non-null)
2) else Woo date_completed_gmt when present
3) else MISSING → withhold period authority for that sale (see §16 / M1-08)
```

Forbidden as sale effective time (unless a future contract explicitly reopens this):

```text
created_at_source
updated_at_source
inserted_at / updated_at
ingestion received_at
cache updated_at / last_fresh_at / refreshed_at
```

Recognition remains status-gated by M1-04 (`:completed` historically). Effective-time selection does **not** invent recognition from payment alone.

Current interim repository behaviour uses `completed_at` only (`metric_rules.ex:138`). That is **certified current behaviour**, not final Path 1 authority once `date_paid_gmt` is persisted.

---

## 7. Payment vs Completion Decision

**CONTRACT DECISION (T5)**

```text
Preferred financial period clock: PAYMENT TIME (Woo date_paid_gmt)
Fallback when payment absent: COMPLETION TIME (Woo date_completed_gmt)
```

Rationale:

```text
PRODUCT: “authoritative payment/completion timestamp” (payment listed first)
  — docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md §3
OFFICIAL SOURCE: date_paid_gmt and date_completed_gmt are distinct Order properties
OFFICIAL EXAMPLES: paid can exist without completed; completed can exist without paid;
  when both present, paid may precede completed by minutes
REPOSITORY: only date_completed_gmt is persisted today → IMPLEMENTATION_CHANGE_REQUIRED
```

### 7.1 Edge cases

| Case | Sale effective time |
| --- | --- |
| Completed with payment timestamp | `date_paid_gmt` |
| Completed without payment timestamp | `date_completed_gmt` |
| EFT / `on_hold` → later `completed` | No sale period placement until historically recognised; then paid→completed fallback |
| `processing` → later `completed` | Same as above |
| Completion present, payment absent | `date_completed_gmt` |
| Payment earlier than completion | `date_paid_gmt` (preferred) |
| Source correction updates payment/completion | Newer `updated_at_source` may replace stored clocks; period uses **corrected** effective time, not ingestion time |
| Both paid and completed missing while status `:completed` | MISSING → withhold period authority (do not invent from create/update) |

No silent substitution of order creation time.

---

## 8. Refund Effective-Time Contract

**CONTRACT DECISION (T7, T8)**

```text
REFUND EFFECTIVE TIME = Woo refund date_created_gmt
  persisted as UTC instant on the durable refund fact (physical form TBD in M3)
```

Forbidden as refund effective time:

```text
parent Order.completed_at / sale effective time
Order.updated_at / Order.updated_at_source
refund ingestion time alone
cache / rebuild timestamps
```

Missing `date_created_gmt` on a refund:

```text
fail closed for period placement of that refund adjustment
persist unresolved/incomplete timestamp state for review
do not invent from parent completion or local now
```

M1-05 already established there is **no** official refund `date_modified` / source-updated field. Replay/idempotency uses refund identity, not a source-updated clock.

Ingestion timestamps remain required for audit (R22) but are **not** period authority.

---

## 9. Source Freshness Contract

**CONTRACT DECISION (T10)**

Source freshness answers:

> How long ago did EventSales last receive/apply authoritative source state for this scope?

It does **not** answer when the sale happened.

### 9.1 Locked definition

For a management dashboard scope (all-events or one event):

```text
SOURCE FRESHNESS ANCHOR
  = latest durable authoritative source-state application time for that scope
```

Composition (logical; physical watermark resource owned with M1-08/M5 projection):

```text
max(
  latest Order.updated_at_source among in-scope durable orders last applied,
  latest successful bounded catch-up / sync covered-through source-modified watermark
    for that scope when catch-up is the freshness path,
  latest durable refund source-created apply watermark when refunds are in scope
)
```

Notes:

```text
Webhook/order apply advances freshness via Order.updated_at_source.
Bounded SyncRun/SyncCursor catch-up advances covered-through source-modified progress.
Hot-state rebuild from Postgres alone does NOT advance source freshness.
Manual refresh that only rebuilds ETS/Redis from Postgres does NOT advance source freshness.
```

`completed_at` must not be used as freshness.

### 9.2 Current repository gap

HotStateAggregator `last_fresh_at` advances on restore/rebuild finish (`hot_state_aggregator.ex:218,349`) and is compared with `stale_after_ms` (`:421-422`). That is **read-model age**, not source freshness — see §10–§11.

Snapshots already separate `refreshed_at` vs `source_watermark_at` (`snapshot_refresh.ex:104-105,172-180`) — certify as the correct *shape* for durable separation.

---

## 10. Read-Model Age vs Source Age

**CONTRACT DECISION (T11, T12)**

| Clock | Definition | Example fields |
| --- | --- | --- |
| **SOURCE DATA AGE** | `now − SOURCE FRESHNESS ANCHOR` | max in-scope `updated_at_source` / catch-up covered-through |
| **READ-MODEL AGE** | `now − CACHE/READ-MODEL GENERATED TIME` | `last_fresh_at`, summary `:updated_at`, snapshot `refreshed_at` |
| **REFRESH JOB STATE** | queued / running / completed / failed | rebuild_in_flight?, Oban job status |

Hard rule:

```text
A cache rebuilt one second ago from source data last updated twenty minutes ago
is NOT fresh source data.
```

Stale banners and programme freshness thresholds (§11) bind to **SOURCE DATA AGE**, not read-model age alone.

Read-model age may independently drive “warming / rebuild needed” UX, but must not redefine `stale`.

---

## 11. Freshness Threshold Resolution

**PRODUCT DECISION**

```text
Normal sales-data visibility: less than five minutes
Data is stale when freshness exceeds ten minutes
```

Evidence: `docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md:83-84`;
`docs/path-1/path-1-phase-breakdown.md:228-239`.

**REPOSITORY EVIDENCE (conflict)**

```text
@default_stale_after_ms 300_000  # 5 minutes
stale_fresh_at? when age_ms > stale_after_ms()
```

Evidence: `hot_state_aggregator.ex:27,421-422,638-641`;
`config/config.exs:75`.

### 11.1 Locked operators (T13–T16)

Let `age` = SOURCE DATA AGE.

| Condition | Classification | Meaning |
| --- | --- | --- |
| `age < 5 minutes` | **NORMAL** | Within normal visibility / service target |
| `5 minutes ≤ age ≤ 10 minutes` | **AGING** | Outside normal visibility target; **not** stale |
| `age > 10 minutes` | **STALE** | Programme stale state |

Boundary notes:

```text
age == 5 minutes  → AGING (not NORMAL; “less than five” is exclusive at 5m)
age == 10 minutes → AGING (not STALE; “exceeds ten” is exclusive at 10m)
age > 10 minutes  → STALE
```

There is **one** Path 1 definition of `stale`: `age > 10 minutes` on **source freshness**.

### 11.2 Future / clock-skew values

```text
If freshness_anchor > now (negative age): clamp age to 0 for threshold classification
→ treat as NORMAL for thresholds
→ emit low-cardinality telemetry for clock skew
Do not invent a custom timezone/skew engine.
```

### 11.3 Current 5-minute implementation verdict

```text
CURRENT 5-MINUTE STALE IMPLEMENTATION: IMPLEMENTATION_CHANGE_REQUIRED
```

Required future changes (not in this task):

```text
1) Stop treating HotStateAggregator last_fresh_at (rebuild age) as programme stale truth
2) Bind programme stale to SOURCE DATA AGE > 10 minutes
3) Optionally keep a separate read-model aging signal; do not call it “stale”
4) Align stale_data_banner / M5-07 / M6-06 to the locked operators
```

Timing: **REQUIRED_BEFORE_M5** for freshness projection; UX copy alignment **REQUIRED_BEFORE_M6**.

---

## 12. Johannesburg Timezone Contract

**CONTRACT DECISION (T17, T18, T19)**

```text
Reporting / business timezone: Africa/Johannesburg (IANA)
Durable source/effective instants: UTC (:utc_datetime_usec in Postgres)
Reporting period boundaries: interpret in Johannesburg civil time, convert once to UTC instants
```

Rules:

```text
Do not store local naive timestamps as universal truth when UTC/GMT source fields exist.
Do not hardcode a project-specific “UTC+2” reporting timezone as the contract.
Use standard Elixir timezone-aware APIs (DateTime.shift_zone / Calendar) with Africa/Johannesburg.
Johannesburg currently has no DST shifts; the named zone remains mandatory anyway.
```

**REPOSITORY NOTE (gap):** `MetricRules.business_date/2` for `"Africa/Johannesburg"` currently uses `DateTime.add(2, :hour)` (`metric_rules.ex:34-38`) instead of `DateTime.shift_zone/2`. Config default is already `"Africa/Johannesburg"` (`config/runtime.exs:36`). Classify as **REQUIRED_BEFORE_M5** conformance (behaviour coincides with SAST today; contract still requires named-zone shift).

Day boundary:

```text
Johannesburg day D:
  start = D 00:00:00 Africa/Johannesburg inclusive
  end   = (D + 1 day) 00:00:00 Africa/Johannesburg exclusive
Interval form: [start, end)
Convert start/end to UTC once; query with UTC predicates.
```

---

## 13. Reporting Period Boundaries

**CONTRACT DECISION**

All management reporting periods are half-open:

```text
[start, end)
```

Membership test for an effective instant `t` (UTC):

```text
start_utc <= t < end_utc
```

Prefer:

```text
1) convert Johannesburg civil boundaries → UTC instants once
2) filter/aggregate on UTC effective timestamps
```

Avoid per-row timezone conversion in unbounded scans.

---

## 14. Today / Rolling / Calendar Period Semantics

**PRODUCT / PROGRAMME INPUT**

```text
today / yesterday
rolling 7 days
bounded custom ranges
(also last 15/30/60 minutes in programme windows — Path 1 management core uses Today / Last 7 / Last 30 / Custom)
```

Evidence: `EVENTSALES_LIVE_SALES_PROGRAMME.md:312`;
`EVENTSALES_PRODUCT_DECISIONS.md:98-117`.

**CONTRACT DECISION (T20–T23)**

| Period | Kind | Definition |
| --- | --- | --- |
| **Today** | Calendar day | Johannesburg civil day containing `now`: `[today 00:00, tomorrow 00:00)` |
| **Yesterday** | Calendar day | Previous Johannesburg civil day |
| **Last 7 Days** | Rolling duration | `[now − 7 days, now)` using exact UTC instant arithmetic from current `now` |
| **Last 30 Days** | Rolling duration | `[now − 30 days, now)` same form |
| **Custom Period** | Calendar/civil bounds | Caller supplies Johannesburg local start date/time and end date/time; interpret as `[start, end)` in `Africa/Johannesburg`, convert once to UTC |

Custom range rules:

```text
start inclusion: yes (half-open start)
end exclusion: yes
timezone: Africa/Johannesburg for civil interpretation
maximum permitted range: NOT YET LOCKED numerically
  → record need for M5/M6 bounded-query design
  → no unbounded raw-history query contract
```

“Last 7 Days” is **not** “current ISO week” and **not** “today + previous 6 calendar days” — it is the rolling 7×24h window ending at `now`, matching programme “rolling 7 days”.

Current `MetricRules` “today_*” uses same Johannesburg business date as `completed_at` vs `now` (`metric_rules.ex:138`) — certify as calendar-day Today intent; field authority still moves to sale effective time (§6).

---

## 15. Sale vs Refund Period Placement

**CONTRACT DECISION (T24)**

Aligned with M1-05 gross preservation and M1-06 Gross/Net:

```text
Gross sale facts belong to the SALE EFFECTIVE TIME period
Refund adjustments belong to the REFUND EFFECTIVE TIME period
```

Example:

```text
Sale effective: 1 August (Johannesburg period)
Refund effective: 8 August
→ August 1 Gross includes the sale
→ August 8 Refund metrics include the refund
→ Net for a period = period Gross − period refund adjustments
  (per M1-06 formulas; currency rules unchanged)
```

Do **not** retroactively move the original sale into the refund period.

---

## 16. Missing / Corrected Timestamp Behaviour

**CONTRACT DECISION (T25, T26 partial)**

### 16.1 Missing authoritative timestamps

| Required clock | If missing |
| --- | --- |
| Sale effective (`date_paid_gmt` and `date_completed_gmt` both absent) for a recognised sale | **Withhold** period-authority for that record; do not use create/update/ingestion |
| Refund effective (`date_created_gmt`) | **Fail closed / withhold** refund period authority; review |
| Source created/updated on order parse | Already **required** by parser for create/modified GMT — reject invalid payload |
| Ingestion time | Always local; optional for metrics; required for audit trails where M1-05 says so |

Hand to M1-08: missing effective times may block `ANALYTICS_READY` / authoritative display for affected scopes.

### 16.2 Corrected source timestamps

```text
Source-corrected historical effective timestamp
  → durable truth updates when newer updated_at_source allows
  → period placement uses corrected effective time

New ingestion/update timestamp
  → audit only; does not replace effective time
```

If both old and new values must be preserved for audit, record an implementation requirement for M3 audit/history — do not design the resource here.

---

## 17. Out-of-Order / Replay Behaviour

**CONTRACT DECISION (T26)** — consume M1-02 / OrderUpserter

| Arrival pattern | Behaviour |
| --- | --- |
| Older `updated_at_source` after newer | `:stale_noop` — no header regression (`order_upserter.ex:70-71`) |
| Newer source update | `:sync_from_normalized` — status/fields/children update (`:73-82`) |
| Equal `updated_at_source` replay | header unchanged; children upserted (`:85-88`) |
| Completion payload after earlier operational payload | newer source may move status→`:completed` and set `completed_at`; recognition may appear |
| Refund before parent sale present | M1-05 unresolved-parent allowed; converge later; no duplicate financial facts by identity |
| Refund detail later | idempotent identity upsert (M1-05) |
| Equal timestamp replay | must not create duplicate Gross/Refund facts |

Ash `SourceVersionGuard` requires incoming `>` existing (`source_version_guard.ex:21-22`), matching upserter newer branch.

Time ordering must not create duplicate financial facts — identity remains M1-02 / M1-05.

---

## 18. Manual Refresh State Boundary

**PRODUCT DECISION**

```text
Manual refresh queues bounded async work
LiveView/controllers never call Woo inline
```

Evidence: `EVENTSALES_PRODUCT_DECISIONS.md:85-87`;
`dashboard_live.ex:50-55` → `HotStateAggregator.request_rebuild(:manual_refresh)`.

**CONTRACT DECISION (T27)**

Refresh lifecycle (logical):

```text
refresh_requested
→ refresh_queued
→ refresh_running
→ refresh_completed | refresh_failed
```

Semantics:

```text
Request alone does NOT label data fresh.
Only authoritative durable success advances the relevant clocks:
  - rebuild success → advances READ-MODEL GENERATED TIME / last_fresh_at
  - catch-up/apply success that writes newer source state → advances SOURCE FRESHNESS ANCHOR
Current dashboard manual_refresh rebuilds hot state from Postgres only
  → may clear read-model aging; does NOT by itself clear programme SOURCE STALE
```

Do not implement worker/status UI in M1-07.

---

## 19. PubSub Boundary

**CONTRACT DECISION (T28)**

```text
PubSub = delivery / update notification
PubSub ≠ freshness truth
```

Locked sequence:

```text
durable source and/or read-model state changes first
→ PubSub notification
→ open LiveView refreshes from durable/read-model facades
```

Evidence pattern: `hot_state_aggregator.ex:484-485`;
`dashboard_pub_sub.ex:21-25`;
`dashboard_live.ex:70-78`.

```text
Do not use PubSub message arrival time as SOURCE FRESHNESS ANCHOR
Do not require browser polling for live updates
```

---

## 20. Hot / Warm / Cold Timestamp Roles

**CONTRACT DECISION (T29)**

Architecture (certified): Hot ETS / Warm Redis / Cold Postgres; **no Cachex**.

| Layer | Timestamp metadata role |
| --- | --- |
| **Cold Postgres (orders/refunds)** | Durable SOURCE CREATED/UPDATED, SALE/REFUND EFFECTIVE clocks |
| **Cold Postgres (snapshots)** | `refreshed_at` = read-model generated; `source_watermark_at` = source-updated watermark for scoped rows; `business_date` + `business_timezone` keys |
| **Warm Redis** | Cached summary + generated `updated_at`; mirror only |
| **Hot ETS / HotStateAggregator** | Cached summary + `last_fresh_at` / lifecycle; process-local |

Cache rebuild time must remain distinguishable from source-data freshness (§10).

---

## 21. Aggregate Bucketing Handoff

**CONTRACT DECISION (T30)**

M5 aggregates must bucket using locked effective timestamps:

```text
Gross / Order Count buckets → SALE EFFECTIVE TIME
Refund buckets → REFUND EFFECTIVE TIME
Business-day keys → Africa/Johannesburg civil date of the effective instant
Hour grain (where required by roadmap) → Johannesburg local hour of the effective instant,
  stored/queryable via UTC bucket bounds
```

Do **not** design physical M5 tables here.

Logical grain requirements already implied by roadmap:

```text
hour / day / event / ticket type
```

Period bucketing must not use `updated_at_source`, ingestion time, or cache generated time.

---

## 22. Performance & Index Review

| Question | Current / required answer |
| --- | --- |
| Is sale effective timestamp indexed? | Today `completed_at` is indexed (`order.ex:54`). When `date_paid` / paid_at is added, index the **query clock used for period predicates** (paid_at or coalesced expression strategy TBD in M3/M5). |
| Bounded `[start,end)` UTC predicates? | Required for all period queries |
| Avoid per-row TZ conversion? | Required — convert boundaries once |
| Deterministic business-day keys? | Snapshots already key `business_date` + `business_timezone` (`daily_sales_aggregate_snapshot.ex:168`) |
| Does freshness checking require source calls? | **No** — compute from durable watermarks / `updated_at_source`; LiveView must not call Woo |

Hard performance rules:

```text
no inline Woo calls from LiveView/controllers
no full scans during peak for management dashboards
no polling for live updates
no cache timestamp masquerading as source freshness
Postgres = durable time truth
Redis/ETS = derived freshness/read models only
```

---

## 23. Future Implementation Gaps

| Gap | Classification | Notes |
| --- | --- | --- |
| Persist Woo `date_paid_gmt` (sale preferred clock) | **REQUIRED_DURING_M3** | Parser + Order attribute + upsert accept; no silent create-time fallback |
| Persist refund `date_created_gmt` as refund effective time | **REQUIRED_DURING_M3** | With M1-05 refund persistence |
| MetricRules / snapshots bucket on sale effective time (paid→completed coalesce) | **REQUIRED_BEFORE_M5** | Replaces sole `completed_at` today bucketing |
| HotStateAggregator / banner: programme stale = source age > 10m; separate read-model age | **REQUIRED_BEFORE_M5** | Resolves 5m conflict |
| UX copy / stale banner alignment | **REQUIRED_BEFORE_M6** | M6-06 |
| `MetricRules.business_date` use `DateTime.shift_zone` for Johannesburg | **REQUIRED_BEFORE_M5** | Stop hardcoded `+2` as the Johannesburg path |
| Index strategy for paid_at / coalesced sale effective queries | **REQUIRED_BEFORE_M5** | With aggregate design |
| Custom range maximum duration | **REQUIRED_BEFORE_M5** / M6 bounded-query design | Number not invented here |
| Durable source-freshness watermark projection for scopes | **REQUIRED_BEFORE_M5** (inputs to M1-08 readiness) | May extend snapshot `source_watermark_at` / SyncCursor |
| Audit history of corrected effective timestamps | **OPTIONAL_HARDENING** / M3 if required by ops | Record need; no resource design here |

No implementation in M1-07.

---

## 24. Explicit Non-Goals

M1-07 does **not**:

```text
implement date_paid / paid_at fields
implement refund timestamp fields or Refund resources
change HotStateAggregator / stale_after_ms
change stale banners or MetricRules production behaviour
implement MG1–MG8
implement refunds, aggregates, refresh workers, dashboards
design ANALYTICS_READY / reconciliation (M1-08)
change identity / attribution / Gross-Net formulas
Path 2 / Phase 5E work
Apply / AutoApply
mutate WordPress
```

---

## 25. Decisions T1–T31

| ID | Decision |
| --- | --- |
| **T1** | Disjoint vocabulary: source created/updated; sale effective; refund effective; ingestion; cache generated; freshness observed; reporting period |
| **T2** | Source-created clock = Woo `date_created_gmt` → `Order.created_at_source` |
| **T3** | Source-updated clock = Woo `date_modified_gmt` → `Order.updated_at_source` |
| **T4** | Recognised-sale effective clock = paid→completed fallback (§6) |
| **T5** | Payment preferred over completion for period placement; recognition still M1-04 completed |
| **T6** | Fallback: `date_paid_gmt` then `date_completed_gmt` then withhold; never create/update/ingestion |
| **T7** | Refund effective clock = refund `date_created_gmt` |
| **T8** | Missing refund created-gmt → withhold/fail closed; no parent/ingestion substitute |
| **T9** | Ingestion timestamps are audit-only for financial periods |
| **T10** | Source freshness = age of latest durable source-state apply / catch-up covered-through for scope |
| **T11** | Read-model age = age of last successful cache/snapshot/hot rebuild write |
| **T12** | Source freshness and cache age remain strictly separate |
| **T13** | `< 5m` = NORMAL visibility target |
| **T14** | `> 10m` = STALE |
| **T15** | Operators: `<5m` NORMAL; `5m≤age≤10m` AGING; `>10m` STALE; future skew clamps to age 0 |
| **T16** | Current 5m HotStateAggregator stale clock = **IMPLEMENTATION_CHANGE_REQUIRED** |
| **T17** | Reporting timezone = `Africa/Johannesburg` |
| **T18** | Persist durable source/effective instants in UTC |
| **T19** | Periods are half-open `[start, end)` |
| **T20** | Today = Johannesburg calendar day containing now |
| **T21** | Last 7 Days = rolling `[now−7d, now)` |
| **T22** | Last 30 Days = rolling `[now−30d, now)` |
| **T23** | Custom = Johannesburg `[start,end)`; max duration deferred to M5/M6 |
| **T24** | Sale and refund may occupy different periods; Gross not moved into refund period |
| **T25** | Missing authoritative effective time → withhold; no silent local substitutes |
| **T26** | Corrections follow newer source updates; out-of-order uses OrderUpserter stale/equal/newer; no duplicate facts |
| **T27** | Refresh request ≠ fresh; only durable success advances the relevant clock; Postgres-only rebuild ≠ source fresh |
| **T28** | PubSub notifies after durable/read-model change; not freshness truth |
| **T29** | Hot/Warm/Cold roles per §20; no Cachex |
| **T30** | M5 buckets by locked effective timestamps + Johannesburg day/hour keys |
| **T31** | M1-08 receives missing-effective-time withhold, source-freshness watermarks, and catch-up covered-through as readiness inputs |

All T1–T31 deterministic → **not BLOCKED**.

---

## 26. M1-08 Handoff Inputs

Provide readiness/completeness inputs only (do not design gates here):

```text
missing sale-effective time on recognised sales → withhold period authority
missing refund-effective time → withhold refund period authority
SOURCE FRESHNESS ANCHOR vs READ-MODEL age must both be observable for scopes
catch-up covered-through (SyncRun/SyncCursor modified window) is a freshness/completeness input
ANALYTICS_READY must not treat cache rebuild success as source completeness
refund completeness clocks remain per M1-05 R24
```

---

## 27. M5 / M6 Handoff Inputs

### M5

```text
bucket Gross/Order Count by sale effective time
bucket refunds by refund effective time
Johannesburg [start,end) day keys; hour grain as required
source_watermark_at / freshness projection per M1-07 operators
HotStateAggregator stale semantics → source age > 10m
index strategy for period predicates on effective clocks
lock numeric max custom range (not invented in M1-07)
conform MetricRules Johannesburg path to DateTime.shift_zone
```

### M6

```text
stale / aging / normal UX copy and banners per T13–T15
manual refresh shows queued/running/completed/failed without claiming source-fresh on rebuild-only
PubSub auto-update; no polling
```

---

## 28. Open Questions

```text
None that block T1–T31.
```

Deferred non-blocking items:

```text
Exact numeric maximum custom range length → M5/M6
Physical paid_at column name / coalesce SQL vs application coalesce → M3 design
Whether AGING has a distinct banner vs silent service target breach → M6 UX
```

---

## 29. M1-07 Verdict

```text
M1-07 = PASS
```

```text
Sale effective time locked (paid → completed → withhold)
Refund effective time locked (refund date_created_gmt)
Johannesburg [start,end) locked
Source freshness vs cache age separated
5m vs 10m conflict resolved deterministically
Current 5m HotStateAggregator stale implementation: IMPLEMENTATION_CHANGE_REQUIRED
No production code
No migration
M1-08 not authorized by this task
```
