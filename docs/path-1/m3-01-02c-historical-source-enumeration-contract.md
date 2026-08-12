# Path 1 M3-01/02C — Historical Source Enumeration Contract

| Field | Value |
| --- | --- |
| Status | **DRAFT — proposed contract lock** |
| Scope | Source-safe historical Woo order enumeration only |
| Canonical base | `068e2d09aaf6b29eb3aad69c8697a55744c1af5a` |
| Blocked implementation | PR #188, head `2544c26351ba537792f789eff9f20f805f2e8169` |
| Implementation | None in this slice |
| Downstream gate | M3-01/02B historical transport may not unblock until this contract is implemented and proven |

This document is an architecture contract. It does not add a WordPress
plugin, an Elixir consumer, an Ash resource, a migration, or a source query.

## 1. Executive verdict

The standard WooCommerce REST collection is not a safe historical enumerator
for Path 1. Its `page`/`offset` traversal can skip an order when that order's
mutable `date_modified_gmt` changes while a run is in progress. Adding
`(date_modified_gmt, order_id)` to the sort does not repair that failure.

The chosen model is **immutable discovery + modified-time catch-up**:

1. A source-owned order-index endpoint establishes an immutable initial
   membership boundary using source order identity and a source creation-time
   keyset. Its boundary is fixed to the run's immutable
   `BACKFILL_CUTOFF`.
2. EventSales consumes bounded pages of metadata only and fetches each returned
   order by identity through the existing Woo client. `OrderUpserter` remains
   the sole durable order writer.
3. A separate modified-time catch-up pass drains changes for that fixed
   membership using a source-safe boundary and cursor. A current modified time
   greater than `run.date_to` does not evict an order already admitted by the
   immutable membership boundary.
4. If the source cannot provide a genuinely stable creation/identity boundary
   in both legacy and HPOS storage, the source implementation must use an
   atomic, short-lived identity snapshot/manifest. A live offset collection is
   never an acceptable fallback.

The source integration is a new, separate boundary provisionally named
`integrations/wordpress/eventsales-woo-order-index-feed/`. The existing
`eventsales-tickera-catalog-feed` remains catalog-only and is not changed.

`SyncRun.status == :completed` will mean only that the contracted source
transport phases reached their terminal evidence and any deterministic item
failures were durably inventoried. It will not mean `ORDER_COMPLETE`,
`REFUND_COMPLETE`, or `ANALYTICS_READY`. M3-08 remains the owner of
completeness certification.

## 2. Proven WooCommerce limitation

### 2.1 What the standard REST collection provides

The current WooCommerce orders REST collection exposes `page`, `per_page`,
`offset`, `modified_after`, `modified_before`, `dates_are_gmt`, `order`, and
`orderby`. The documented collection has no source cursor, `after_id`
predicate, or snapshot token. The documented maximum `per_page` is 100.

The current WooCommerce REST controller maps the request into WordPress query
arguments:

- `offset` remains an offset;
- `page` becomes `paged`;
- `per_page` becomes `posts_per_page`;
- modified bounds become a current-row date filter; and
- when ordering by `date` or `modified`, WooCommerce appends `ID` as a tie
  breaker.

The appended ID makes the order deterministic for equal timestamps. It does
not turn the collection into a keyset query.

WordPress then computes the page start as either the supplied offset or
`(page - 1) * posts_per_page` and emits a SQL `LIMIT` with that start. The
date predicate is evaluated against the rows visible to that request. It is
not a snapshot of the first request.

Primary evidence:

- [WooCommerce REST orders documentation](https://developer.woocommerce.com/docs/apis/rest-api/v3/orders/)
- [Current WooCommerce REST collection controller](https://raw.githubusercontent.com/woocommerce/woocommerce/trunk/plugins/woocommerce/includes/rest-api/Controllers/Version3/class-wc-rest-crud-controller.php)
- [Current WordPress `WP_Query` source](https://raw.githubusercontent.com/WordPress/wordpress-develop/trunk/src/wp-includes/class-wp-query.php)
- [Current WordPress `WP_Date_Query` source](https://raw.githubusercontent.com/WordPress/wordpress-develop/trunk/src/wp-includes/class-wp-date-query.php)

### 2.2 The mutation failure already proven by PR #188

PR #188's red regression uses an initially bounded ordered source containing
`T/10`, `T/20`, `T/30`, and `T/40`:

1. page 1 returns `T/10` and `T/20`;
2. `T/10` is mutated so its current modified time is beyond the immutable
   cutoff;
3. page 2 is evaluated against the now-shorter result and returns `T/40`;
4. `T/30` is never returned.

A short page then looks terminal even though a source member was skipped. The
failure is caused by offset traversal over a mutable result set. It is not
fixed by `orderby=modified,ID`, by increasing `per_page`, or by treating a
short response as terminal evidence.

### 2.3 Why a supported Woo query is not already a portable keyset API

WooCommerce officially recommends `wc_get_orders` / `WC_Order_Query` so that
callers remain compatible with legacy order storage and HPOS. Those APIs
provide page, limit, offset, and ordering controls, but they do not provide a
portable composite seek predicate.

HPOS has `field_query` support for richer field comparisons. The legacy order
data store does not support that HPOS-only query facility. The REST collection
does not expose either form as a cursor contract. Therefore this document
does not pretend that one set of `WC_Order_Query` arguments proves the tuple
predicate in both storage modes.

Primary evidence:

- [Official `wc_get_orders` / `WC_Order_Query` guidance](https://developer.woocommerce.com/docs/features/orders/wc-get-orders/)
- [Current `wc_get_orders` implementation](https://raw.githubusercontent.com/woocommerce/woocommerce/trunk/plugins/woocommerce/includes/wc-order-functions.php)
- [Current `WC_Order_Query` source](https://raw.githubusercontent.com/woocommerce/woocommerce/trunk/plugins/woocommerce/includes/class-wc-order-query.php)
- [Current legacy order data-store source](https://raw.githubusercontent.com/woocommerce/woocommerce/trunk/plugins/woocommerce/includes/data-stores/class-wc-order-data-store-cpt.php)
- [HPOS order-query improvements](https://developer.woocommerce.com/docs/features/orders/high-performance-order-storage/wc-order-query-improvements/)
- [Current HPOS `OrdersTableQuery` source](https://raw.githubusercontent.com/woocommerce/woocommerce/trunk/plugins/woocommerce/src/Internal/DataStores/Orders/OrdersTableQuery.php)

The source integration must therefore own and test a stable enumeration
contract. It may use Woo's supported query APIs and storage-specific adapters,
or it may materialize a source-side identity manifest when those APIs cannot
prove the required invariant. Brittle `wp_posts`-only SQL is not the default
architecture.

## 3. Exact transport-completion semantics

### 3.1 Terms

For one historical `SyncRun`:

```text
B = BACKFILL_START
  = the selected Tickera event's durable source creation instant

C = BACKFILL_CUTOFF
  = the run's immutable date_to

D = immutable source discovery boundary
  = a source-issued boundary token and its captured source observation point

H = catch-up high-water
  = a separate source observation bound captured for the catch-up phase
```

`B` and `C` are the Path 1 coverage bounds. `C` is inclusive at the logical
contract level; the source adapter must define precision and use a consistent
half-open representation where its API requires it. The adapter must not
silently widen or move `C`.

`D` is not a worker wall-clock timestamp. It is source evidence that binds the
initial membership query to the requested bounds. It may be a stateless,
authenticated boundary token. If a source cannot issue such a token without
run-long state, it must use the snapshot/manifest fallback in §5.2.

`H` is operational transport evidence for draining source changes observed
after discovery. It is not a new `BACKFILL_CUTOFF`, is not
`sales_covered_through`, and must not be recorded as extending the certified
historical range.

### 3.2 Membership and the mutable modified timestamp

The initial launch backfill membership is the source order identity set whose
source creation time is in `[B, C]` at boundary `D`. The source contract must
make the membership key stable for the life of `D`:

```text
source_created_at_gmt is stable for D
source_order_id is immutable identity
```

The source order index returns the ID and both source timestamps. The current
`date_modified_gmt` is metadata for catch-up and source-version ordering; it
is not the membership authority.

If a member's `date_modified_gmt` changes from a value inside the historical
window to a value after `C` before it is fetched, the member remains in the
immutable creation/identity set. EventSales must fetch it by ID and must not
discard it because its current modified time is now greater than `C`.

This resolves the launch scope used by the existing Path 1 product and phase
contracts: initial backfill begins at the selected event creation date. A
source order created before `B` but modified during `[B, C]` is not silently
added to the initial sales membership by this document. If M1-08 is later
interpreted to require every such modified-only order as part of the initial
sales membership, that is a contract contradiction requiring an explicit
M1-08/source-membership amendment. It cannot be repaired by changing a
cursor or by silently redefining `B` or `C`.

### 3.3 What `SyncRun.status == :completed` means

For this historical transport, `SyncRun.status == :completed` is allowed only
when all of the following are durably true:

1. the run's immutable `B` and `C` were persisted before transport began;
2. the source returned a boundary-bound initial discovery response for `D`;
3. every discovery page was replay-safe and ended with source terminal
   evidence, not merely a short page from the standard REST collection;
4. every returned source identity was either fetched through the approved
   full-order transport or durably classified in a blocking per-item
   inventory;
5. the bounded catch-up phase reached its own `H`-bound terminal evidence;
6. cursors advanced only after the durable success or explicit blocking
   inventory required by the M1-08 cursor rules; and
7. no source request, cursor, or boundary is still in flight for the run.

The status may coexist with a durable blocking inventory. A deterministic
source `not_found`, an unprocessable source identity, or a local write failure
may therefore leave transport terminal while keeping Path 1 completeness
false. Network failures, authentication failures, expired/invalid boundaries,
and unproven source terminal conditions do not qualify; they leave the run
retryable, paused, or failed-closed.

The following claims remain forbidden from `:completed` alone:

```text
ORDER_COMPLETE
REFUND_COMPLETE
ANALYTICS_READY
zero unresolved order/write inventory
financial reconciliation PASS
```

## 4. Explicit answers to the architectural question

### 4.1 Relationship to M1-08 and future M3-08

The current durable foundation remains the existing source/event-scoped
`SyncRun` plus its one-per-run `SyncCursor`. `SyncRun` owns the immutable
historical date bounds and lifecycle; `SyncCursor` owns replayable progress
and the current modified-window fields. M3-01/02B may extend that contract
with phase, boundary, and terminal-evidence metadata, but this document does
not authorize a parallel `SalesImportRun` or a new durable order writer.

The relationship to the locked Path 1 contracts is:

| Contract | Effect of this document |
| --- | --- |
| M1-08 C3 | `BACKFILL_START` remains the selected Tickera `post_date_gmt` source creation instant. This source enumeration does not invent or replace it. |
| M1-08 C4 | `BACKFILL_CUTOFF` remains the explicit immutable `SyncRun.date_to`. The initial transport cursor's `modified_before` remains `C`; the catch-up high-water `H` is separate evidence and never rewrites `C`. |
| M1-08 C6 | Cursor progress still advances only after durable success or explicit durable blocking inventory. Boundary replay and page replay remain required. |
| M1-08 C7 | Transport `SyncRun :completed` remains distinct from `ORDER_COMPLETE`. The source terminal proof is an input to later certification, not certification itself. |
| M1-08 C28 | M3 still must produce durable bounded order history, idempotent writes, terminal cursor/evidence, and unresolved inventory before M4. This document supplies only the source-enumeration part of that evidence. |
| M3-08 | M3-08 must certify event-relevant orders, order-item durability, attribution, effective timestamps, refunds, unresolved inventory, and the durable completeness watermark. It may reject a transport-completed run. |

`SyncRun :completed` therefore means “the contracted source transport and
identity delivery phases terminated,” not “the Path 1 sales scope is complete.”
No watermark, `ORDER_COMPLETE`, `REFUND_COMPLETE`, or `ANALYTICS_READY` claim
may be derived from the status alone.

### A. Is modified-time + ID keyset pagination sufficient?

**No, not by itself.** The predicate

```text
modified > cursor_modified
OR (modified = cursor_modified AND id > cursor_id)
```

is a correct seek predicate only for the rows that remain members of the
query while the traversal proceeds. If a row moves from `modified <= C` to
`modified > C` before the cursor reaches it, the row no longer satisfies the
upper-bounded query. The keyset has no record that the row was previously
eligible. The row can therefore be lost without any duplicate or cursor
ordering error.

The same conclusion applies to the standard REST collection even earlier:
the collection does not expose the tuple predicate and uses offset paging.

### B. What makes a keyset safe conditionally?

A modified-time keyset is safe only as a phase inside a stronger contract
that has an immutable membership or change-evidence invariant:

```text
Every source identity in the historical membership set is established by D
before modified-time traversal is used as the source of progress.

Every established identity is fetched by identity, regardless of its current
modified time.

The catch-up pass is bounded by H and has source terminal evidence proving
that no eligible member/change remains in that fixed boundary.

An identity that changes after H is outside this transport claim and is
handled by later live/reconciliation semantics; it does not move C.
```

Under those conditions, an order that moves beyond `C` is not lost: its
immutable ID was already in the source membership set, and identity retrieval
does not apply the mutable `modified <= C` filter. The catch-up pass may see
its newer modified timestamp as well, but it is not relying on that timestamp
to prove initial membership.

### C. What immutable evidence is required?

At minimum, the source must provide:

- an immutable source order ID;
- a source creation timestamp that is stable for the boundary, or an
  equivalent immutable membership sequence;
- a source-issued boundary token binding the query to `B`, `C`, and the source
  observation point;
- a strict, replayable cursor over `(source_created_at_gmt, source_order_id)`
  for initial discovery;
- `source_modified_at_gmt` as the version/catch-up value; and
- terminal evidence bound to the same source boundary.

A full identity manifest is **not mandatory** if the source can provide those
properties with a stateless or source-native immutable keyset. A snapshot or
manifest is mandatory when creation/identity membership can change during
enumeration, when the legacy and HPOS adapters cannot prove the same keyset
semantics, or when the source cannot issue boundary-bound terminal evidence.

### D. Is immutable creation/identity discovery plus modified reconciliation
compatible with M1/M3?

**Yes, with the explicit scope resolution in §3.2.** It preserves the locked
`BACKFILL_START`, leaves `SyncRun.date_to` immutable, uses existing
`SyncRun`/`SyncCursor` as the durable run/cursor foundation, and keeps
`SyncRun :completed` distinct from `ORDER_COMPLETE`.

It is compatible because the Path 1 launch scope already says historical
backfill begins at selected event creation date, while M1-08 requires source
terminal evidence and a later completeness watermark rather than a particular
Woo pagination mechanism.

The phrase “modified/created window” in M1-08 remains an explicit boundary to
watch. This document chooses creation/identity as the initial sales-membership
authority and modified time as catch-up/version evidence. If a later reviewer
requires modified-only membership for orders created before `B`, the current
contract set is insufficient; M3-01/02B must stop until M1-08 is amended or a
stronger immutable source change-evidence contract is approved.

## 5. Option analysis

### 5.1 Option 1 — source-side modified-time keyset

The required logical query is:

```text
(source_modified_gmt > cursor_modified_gmt)
OR
(source_modified_gmt = cursor_modified_gmt
 AND source_order_id > cursor_order_id)
```

with a fixed upper transport bound.

**Correctness:**

- It removes offset drift when rows retain membership and their tuple order
  does not move behind the cursor.
- It does not prove membership for a row that moves beyond the upper bound
  before it is fetched.
- Removing the upper bound may find that row later, but it changes the
  historical boundary and does not prove a terminal state for `C`.
- A second pass can make it conditionally safe only when that pass is backed
  by immutable membership or a source change log that records every departure
  from the first range. A best-effort re-query is not that invariant.

**Woo API compatibility:**

The standard REST API does not express this predicate. HPOS `field_query` can
express richer comparisons in an HPOS-specific adapter, but the legacy data
store does not provide the same supported facility. A portable
`WC_Order_Query` argument set is therefore not proven.

**Performance and state:**

- bounded response memory when the source streams one page;
- no giant response or `limit=-1` query;
- no O(n) offset scan when the source has a real seek plan;
- no source-side persistent state in a true stateless keyset;
- feasible for millions of rows only with source indexes and a bounded request
  budget;
- maximum page size in this contract: 100 identities;
- source indexes must support the canonical modified-time plus ID ordering,
  or the adapter must fail closed/use a manifest;
- arbitrary ranges, high concurrency, or repeated retries can amplify source
  database work, so the endpoint needs authentication, maximum page size,
  bounded request time, per-key rate/concurrency limits, and no total-count
  query.

**Verdict:** useful as a catch-up primitive after immutable membership is
known, rejected as the sole historical enumerator.

### 5.2 Option 2 — immutable source snapshot/manifest

The source creates an immutable membership set for the requested bounds and
returns a token. Subsequent calls seek through manifest sequence/order, not a
live Woo collection.

**Correctness:**

- a modified row cannot disappear from the frozen member set;
- the manifest can include rows that were eligible at snapshot time even if
  their current modified timestamp is beyond `C`;
- terminal evidence is a property of the frozen manifest, not of a changing
  collection;
- the source must create the membership atomically or expose an equivalent
  source snapshot boundary; iterating a live offset query and calling the
  result a manifest is not sufficient.

**Performance and state:**

- construction and consumption must stream bounded identity pages;
- no full order payload may be materialized in PHP memory;
- no giant response is permitted;
- manifest storage is O(n) in matching identities and must be indexed by
  `(snapshot_id, sequence)` and by source identity as needed;
- state is source-side persistent state with a default TTL of 24 hours and a
  hard maximum TTL of 7 days; expired tokens are rejected, not renewed;
- an abandoned snapshot is garbage-collected after expiry and cannot be
  silently resumed with a different membership set;
- maximum page size is 100 identities;
- source construction must avoid an unbounded `wc_get_orders(limit: -1)` call,
  repeated offset scans, and an unconditional total count;
- a manifest endpoint must enforce date-range, page, request-time, rate, and
  concurrency limits so a caller cannot turn it into an unbounded database
  amplification service.

**Verdict:** the strongest fallback and the required escape hatch when a
  portable immutable keyset cannot be proven. It is not the default because
  it adds persistent source state proportional to the historical membership.

### 5.3 Option 3 — immutable initial discovery boundary plus modified catch-up

The source exposes a stateless or source-native immutable initial discovery
boundary ordered by `(source_created_at_gmt, source_order_id)`. The mandatory
logical seek predicate is:

```text
(created > cursor_created)
OR
(created = cursor_created AND id > cursor_id)
```

within the immutable `[B, C]` membership boundary. After discovery, the
consumer performs identity retrieval and a bounded modified-time catch-up
through `H`.

**Correctness:**

- source modification cannot move a member out of the creation predicate;
- an order that moves beyond `C` stays in the member set and is fetched by
  identity;
- the discovery cursor has a stable ordering and a source-bound terminal
  condition;
- modified-time is used to observe versions/updates, not to decide whether an
  already-established member existed;
- the source must provide a tombstone or deterministic blocking response if a
  discovered identity is deleted before retrieval;
- if creation timestamps or identities can be changed by the source, this
  option is not actually immutable and must use Option 2.

**Performance and state:**

- bounded one-page memory and bounded full-order fetches by ID;
- no giant query, no offset scan, and no full-payload index response;
- feasible for millions of orders if the source provides usable creation/ID
  and modified/ID seek plans;
- no run-long source-side state in the chosen stateless form; the opaque
  boundary token may be signed metadata but must not depend on mutable local
  page state;
- maximum page size is 100 identities;
- source indexes must support `(created_gmt, id)` for discovery and
  `(modified_gmt, id)` for catch-up, or the source must use the manifest
  fallback;
- rate limits, maximum range, bounded query time, and the existing maximum
  Woo concurrency of two remain in force.

**Verdict:** chosen as the smallest contract that preserves Path 1
completeness without making a source manifest mandatory for every run. Option
2 is a required source implementation fallback, not permission to return to
standard REST offset paging.

## 6. Chosen architecture

### 6.1 Source boundary

Create a separate source integration boundary, provisionally:

```text
integrations/wordpress/eventsales-woo-order-index-feed/
```

Its responsibility is limited to authenticated, bounded order identity
enumeration and boundary evidence. It must not become a catalog feed, a full
order webhook, a payment integration, a customer/CRM integration, or a second
durable order writer.

The endpoint must provide two explicit phases:

1. **Initial discovery:** source-created/ID keyset inside immutable `B`/`C`
   membership and boundary `D`.
2. **Modified catch-up:** source-modified/ID keyset through a separately
   captured `H`, bound to the established membership boundary.

The endpoint may expose these as one versioned contract with a phase field or
as two endpoints. It must not expose a misleading `page`/`offset` contract as
the only continuation mechanism.

### 6.2 EventSales flow

The later implementation must follow this sequence:

1. Persist `SyncRun.date_from`/`date_to` and the historical mode before source
   transport begins.
2. Request the initial source boundary and persist its metadata with the
   durable cursor.
3. Consume at most 100 source identities per page.
4. Retrieve each full Woo order by source ID through the existing approved Woo
   client. The identity feed never supplies the full order payload.
5. Process the full payload through the existing parser and `OrderUpserter`;
   no parallel order writer is introduced.
6. Advance the cursor only after durable success or an explicit, durable
   blocking inventory entry under M1-08 C6.
7. After discovery terminal evidence, capture `H` and drain modified catch-up
   for the established member boundary.
8. Persist discovery and catch-up terminal evidence. Only then may the run
   enter transport `:completed` under §3.3.
9. Leave ORDER/REFUND completeness and the durable watermark to M3-08 and its
   downstream contracts.

### 6.3 Why the selected architecture is safe

The proof is a membership proof, not a pagination hope:

```text
An in-scope order has an immutable creation/identity key in D.
That key remains eligible even if date_modified_gmt changes.
The source terminal response proves the complete immutable keyset was emitted.
EventSales fetches every emitted identity by ID.
Therefore a modified-time change cannot remove an established member from
the historical transport set.
```

The modified catch-up phase can observe current versions through `H`, but it
does not change the meaning of `C`. A mutation after `H` belongs to later
live/reconciliation processing and may invalidate a future completeness
certification according to M1-08; it does not rewrite this run's cutoff.

## 7. Rejected alternatives and why

| Alternative | Decision | Reason |
| --- | --- | --- |
| Standard Woo REST `page`/`offset` collection | Reject | Mutable result membership can shrink between pages; PR #188 proves an unseen row can be followed by a short terminal page. |
| Modified-time + ID keyset as the only historical boundary | Reject | A row can leave `modified <= C` before its tuple is reached; no immutable membership evidence remains. |
| Increase `per_page`, add overlap, or retry the same page | Reject | These reduce probability or create duplicates; none proves that every row in a mutable collection was emitted. |
| `wc_get_orders(limit: -1)` / one giant source query | Reject | Unbounded PHP/database work, poor failure/replay behavior, and unacceptable scale/privacy characteristics. |
| Direct `wp_posts` SQL as the default | Reject | It is legacy-storage-specific and bypasses Woo's HPOS-compatible data-store boundary. |
| A full order-payload manifest | Reject | It duplicates PII/payment data and expands source storage; the required manifest contains identities and metadata only. |
| Snapshot created by paging a live offset query | Reject | The materialization itself can skip rows; a manifest is valid only when its membership boundary is atomic/source-proven. |
| Expand `eventsales-tickera-catalog-feed` | Reject | Its README explicitly excludes orders, customers, payments, and order catch-up. Mixing credentials and responsibilities weakens the boundary. |
| Use `SyncRun :completed` as ORDER_COMPLETE | Reject | M1-08 C7 explicitly makes these non-equivalent; M3-08 owns certification. |

## 8. Source API request/response contract (conceptual)

This is a contract shape, not implementation code. Exact route names may be
finalized by the source integration implementation, but the semantics below
are mandatory.

### 8.1 Request

Every request is authenticated with an order-index key scope and contains:

| Field | Initial discovery | Modified catch-up |
| --- | --- | --- |
| `phase` | `initial_discovery` | `modified_catch_up` |
| boundary | `B`, `C`, source boundary request | established `D` and `H` |
| cursor | opaque creation/ID cursor, absent on first page | opaque modified/ID cursor, absent on first page |
| bounds | `created_from_gmt`, `created_to_gmt` | `modified_from_gmt`, `modified_to_gmt = H` as applicable |
| `limit` | 1–100 | 1–100 |

The first response establishes `D`; subsequent requests must echo the opaque
boundary/cursor issued by the source. A cursor is valid only for the exact
source system, phase, bounds, and boundary that created it.

The request must not accept an arbitrary `offset` as a continuation mechanism.
It must not require a full source result count. The endpoint must not use
`paginate=true` merely to produce a total count for EventSales.

### 8.2 Response

Each response contains only:

| Field | Meaning |
| --- | --- |
| `schema_version` | Version of the index contract |
| `phase` | Echoed phase |
| `boundary_token` | Opaque source boundary bound to the requested scope |
| `source_observed_at_gmt` | Source observation metadata |
| `items` | At most 100 identity records |
| `next_cursor` | Opaque continuation cursor, absent at terminal |
| `has_more` | Explicit continuation indicator |
| `terminal_evidence` | Boundary/phase-specific proof when `has_more` is false |

Each `items` record contains exactly the minimum enumeration data:

```text
source_order_id
source_created_at_gmt
source_modified_at_gmt
```

The timestamp fields are UTC and use a documented precision. A source may
include a source version or tombstone classification when required to explain
an identity failure. It must not include customer name/email, billing or
shipping addresses, payment data, order totals, line items, notes, raw
provider payloads, or authentication material.

The response must not expose a total count as a correctness requirement. A
terminal proof and opaque cursor are authoritative; `items.length < limit`
alone is not.

### 8.3 Full order retrieval boundary

The existing Woo client remains responsible for full order retrieval. It may
request an order by `source_order_id` after the index feed returns that ID.
That response stays inside the approved ingestion worker boundary and is
passed to the existing parser and `OrderUpserter`. The index endpoint is not a
replacement full-order API and is not a second writer.

## 9. Cursor and snapshot invariants

1. `SyncRun.date_to` is immutable after queueing. No retry, source mutation,
   or catch-up high-water may overwrite it.
2. `BACKFILL_START` is the durable selected event source creation instant from
   M1-08 C3. It is not reconstructed from local insertion time.
3. Initial discovery uses a strict `(created_at_gmt, order_id)` seek. Equal
   timestamps are resolved by the numeric/source-identity tie breaker.
4. Catch-up uses a strict `(modified_at_gmt, order_id)` seek only inside the
   fixed membership/boundary and through `H`.
5. Timestamps are normalized to UTC with source precision before comparison;
   precision loss that can collapse distinct source values is a contract
   failure.
6. A cursor is advanced only after the page's durable work succeeds or every
   failed identity has a durable blocking classification. A failed network or
   source-boundary request never advances it.
7. Replaying a page with the same boundary and cursor is safe. Duplicate IDs
   are harmless because identity retrieval and `OrderUpserter` are
   idempotent; a replay must not create duplicate durable facts.
8. A cursor cannot be reused with a different `B`, `C`, phase, source, event
   scope, or boundary token.
9. A source terminal response must be bound to the exact cursor/boundary and
   must prove exhaustion of that immutable phase. An empty or short standard
   REST page is not terminal evidence.
10. A source-deleted discovered ID must produce a deterministic tombstone or
    blocking response. It must not disappear from a later page without an
    inventory record.
11. If a snapshot/manifest fallback is used, its token binds an immutable
    membership set and the exact bounds; its rows contain identities/metadata,
    not order payloads. It expires after the source-defined TTL and is
    garbage-collected. An expired/abandoned token is rejected rather than
    silently recreated.
12. Discovery terminal evidence, catch-up high-water `H`, catch-up terminal
    evidence, and any blocking inventory are separate evidence from M3-08's
    later completeness watermark.

## 10. HPOS and legacy storage compatibility

### 10.1 Common source contract

The source endpoint exposes canonical fields (`source_order_id`,
`source_created_at_gmt`, and `source_modified_at_gmt`) independent of the
underlying Woo storage. The implementation must exercise the same contract
with legacy order storage enabled and with HPOS enabled. A passing test in one
storage mode is not evidence for the other.

Woo's supported `wc_get_orders` / `WC_Order_Query` remains the preferred
full-order retrieval boundary because Woo documents it as the storage-safe
API. The new metadata endpoint may use a source adapter to obtain bounded
identity pages, but it must preserve the same semantics in both stores.

### 10.2 HPOS

HPOS provides richer `field_query` and date-query capabilities, and its order
table maps modified ordering to HPOS order-date fields. An HPOS adapter may
use those supported capabilities to express the creation/ID and modified/ID
seek logic when the relevant field mappings are available. It must still
return source-bound terminal evidence and must not rely on REST `page`.

The adapter must verify the actual query plan/index support for the two
canonical orderings. If a bounded seek degenerates into an unbounded scan or
the field mapping is not available, it must use the manifest fallback or fail
closed.

### 10.3 Legacy order storage

The legacy data store maps order dates to WordPress post dates and supports
the older date-query path, but it does not provide HPOS `field_query` as a
portable query contract. The source adapter must not assume that an HPOS
`field_query` works when orders are stored in `wp_posts`.

The legacy adapter may use a narrowly scoped Woo-supported data-store hook or
another source-owned, version-tested mechanism. It must not make brittle
`wp_posts`-only SQL the application-wide architecture. If the legacy adapter
cannot prove an equivalent immutable creation/ID keyset and terminal
boundary, it must build the bounded identity manifest fallback and enumerate
that frozen manifest.

### 10.4 Shared limits

Both adapters are subject to:

- maximum 100 identities per response;
- bounded source request time;
- no full-payload materialization while enumerating;
- no unbounded result count query;
- no offset continuation;
- source index/query-plan evidence for the required seek order; and
- the existing maximum WooCommerce REST concurrency of two unless a separate
  reviewed contract changes it.

## 11. Security and privacy boundary

### 11.1 Separate integration and credential scope

The catalog feed remains:

```text
integrations/wordpress/eventsales-tickera-catalog-feed/
```

The order identity feed is separate:

```text
integrations/wordpress/eventsales-woo-order-index-feed/
```

The order feed must have a separate key/secret scope and key identifier. It
must not implicitly reuse the catalog-feed credential. Authentication,
replay-window, signature, rotation, and authorization rules are independently
defined for the order feed. The feed must authenticate the exact request
scope, boundary, and source system; an authenticated catalog request must not
authorize order enumeration.

### 11.2 Minimum exposed data

The identity feed exposes exactly:

```text
source_order_id
source_created_at_gmt
source_modified_at_gmt
cursor/boundary/terminal metadata
```

No customer PII, payment data, billing/shipping payload, line-item payload,
order totals, notes, or raw Woo JSON is duplicated into the index feed. Full
payloads are retrieved only by the existing approved Woo client and are
handled by the existing parser and `OrderUpserter`.

Logs, metrics, errors, and terminal evidence must redact request signatures,
secrets, raw payloads, and customer data. Redis, ETS, and Cachex have no
authority over membership, cursors, snapshots, or completeness.

### 11.3 Endpoint abuse controls

The source endpoint must enforce authenticated access, maximum page size,
bounded date ranges, bounded query time, per-key rate/concurrency limits, and
the existing source-call concurrency budget. It must reject arbitrary offsets,
unbounded page loops, and unnecessary total-count requests. These are
correctness and availability controls, not optional optimizations.

## 12. Failure and replay semantics

| Failure | Required result |
| --- | --- |
| Boundary creation/authentication fails | No cursor advancement; run remains retryable/failed-closed. |
| Source timeout, 429, or 5xx | Replay the same boundary/cursor; do not skip the page. |
| Boundary token is invalid or expired | Stop the run; do not create a fresh boundary under the same completion evidence. Operator/new-run policy is required. |
| Source reports boundary invalidated | No terminal claim; preserve the run as incomplete and retain the reason. |
| Discovered ID is deleted/not found | Record a durable blocking identity inventory or source tombstone; never silently drop it. |
| Full payload fetch fails | Do not advance past the page unless the failure is durably classified under M1-08 C6; otherwise retry the same page. |
| `OrderUpserter` fails | Keep the page retryable or record explicit durable blocking inventory; no silent source-range skip. |
| Worker crashes after durable writes before checkpoint | Replay the same page; idempotent order/order-item identity prevents duplicate facts. |
| Duplicate source page or ID | Reprocess safely; no duplicate durable facts and no cursor regression. |
| Order modified beyond `C` | Keep it in the immutable membership set; fetch by ID and allow catch-up metadata beyond `C` without moving `C`. |
| Order changes after `H` | Outside this transport claim; later webhook/reconciliation handles it and M3-08 may invalidate/reopen certification if required. |
| Snapshot fallback abandoned | Expire and garbage-collect the manifest; reject the token and do not resume under different membership. |

Transport terminal evidence is not a waiver for a failed source request. It is
acceptable only for deterministic item-level failures that have been
durably inventoried so M3-08 can block certification explicitly.

## 13. Performance and scaling review

| Candidate | PHP memory | Giant query | Offset scans | HPOS/legacy | Millions of orders | Source state | Abandoned state | Max page | Amplification controls |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Standard REST collection | Bounded per response | Usually bounded, but count/page behavior varies | **Yes** | REST hides storage but correctness is unsafe | Unsafe as a completeness primitive | None | N/A | 100 | Existing limits do not repair skips |
| Modified/ID keyset alone | Bounded | No, if seek plan exists | No, if real keyset | Requires storage-specific proof | Feasible with `(modified,id)` support | None | N/A | 100 | Auth, max range, rate/time/concurrency limits |
| Frozen identity manifest | Bounded if streamed | No giant response; creation must stream/atomically bound | No after manifest creation | Strongest storage abstraction; adapter still required | Feasible but O(n) manifest storage | Persistent O(n) manifest | Default TTL 24h; hard max 7d; GC; expired tokens reject | 100 | Manifest quotas, no total count, request limits |
| **Chosen discovery + catch-up** | **Bounded** | **No** | **No** when source seek plans are proven | **Requires tested adapters; manifest fallback otherwise** | **Feasible with `(created,id)` and `(modified,id)` support** | **None by default**; signed boundary metadata only | N/A in default; fallback follows manifest rules | **100** | **Auth, max range, max page, bounded time, max two source calls, no offsets/counts** |

The chosen model does not require unbounded PHP memory, a giant Woo query, or
repeated O(n) offset scans. It does require source-side query/index evidence.
If the source cannot provide that evidence in either storage mode, the
manifest fallback is not an optional performance choice; it is the only safe
source implementation.

The source endpoint should not return a total count. Counting the entire
matching set on every request adds database work without improving the
terminal proof. `has_more`, the opaque cursor, and boundary-specific terminal
evidence are sufficient.

## 14. Required implementation slices after this contract

No slice below is implemented by this document. The required order is:

1. **Source boundary implementation:** create the separate Woo order-index
   feed with separate authentication/key scope, metadata-only responses,
   maximum page 100, and no catalog-feed changes.
2. **Storage adapters:** prove immutable creation/ID discovery and
   modified/ID catch-up with legacy storage and HPOS. Record query/index
   evidence. Use a bounded identity manifest when either adapter cannot prove
   the stateless boundary.
3. **Source contract tests:** cover mutation beyond `C`, equal timestamp/ID
   ties, deletion/tombstone, cursor replay, boundary invalidation, page
   limits, rate/concurrency limits, and both storage modes.
4. **EventSales index client:** add only the approved metadata transport. Keep
   full order retrieval on the existing Woo client and keep `OrderUpserter` as
   the sole durable writer.
5. **SyncRun/SyncCursor extension:** persist phase, boundary, creation cursor,
   catch-up high-water, terminal evidence, and blocking inventory without
   changing the immutable `date_to` meaning.
6. **M3-01/02B follow-up:** replace the unsafe standard REST historical
   traversal with the contracted source boundary, preserve fail-closed page
   checkpoints, and rerun the PR #188 mutation regression.
7. **M3-08:** separately implement completeness watermark/certification using
   the transport evidence plus durable order, attribution, refund, timestamp,
   and unresolved-inventory predicates from M1-08.

M3-03 and later implementation work is outside this contract and is not
started here.

## 15. Explicit effect on blocked PR #188

PR #188 remains blocked and is not modified by this slice.

Its mutation regression is valid evidence that the current standard REST
offset traversal cannot certify historical transport. The current PR cannot
be unblocked by a test-only change, a larger page size, a tie-breaker, or a
short-page rule.

The exact unblocking requirement is a later, separately reviewed change that:

1. consumes the new source order-index contract;
2. establishes immutable discovery membership and boundary evidence before
   modified catch-up is treated as progress;
3. uses bounded source-safe cursors or an atomic identity manifest in both
   legacy and HPOS modes;
4. fetches every enumerated identity by ID, including IDs whose current
   modified timestamp is beyond `run.date_to`;
5. persists phase/cursor/terminal evidence with the existing fail-closed
   durable-checkpoint rules; and
6. passes the existing mutation regression while proving no unseen member can
   be hidden by a terminal page.

Until those conditions are met, PR #188 must remain **BLOCKED — do not merge**.

## 16. STOP conditions

Stop the implementation work and report a blocker if any of the following is
observed:

- the source cannot provide immutable identity membership or an atomic
  snapshot/manifest;
- a design relies on a standard REST offset page as completeness evidence;
- satisfying the design requires silently changing `BACKFILL_START`,
  `BACKFILL_CUTOFF`, or the meaning of `SyncRun.date_to`;
- the chosen membership interpretation contradicts an explicitly locked
  M1-08 requirement for modified-only records and no amendment is approved;
- HPOS and legacy storage cannot share the canonical source contract or the
  source adapter cannot prove bounded seek behavior;
- correctness requires unbounded full-order payload materialization, one
  giant Woo query, or repeated O(n) offset scans;
- a source boundary, cursor, terminal condition, or snapshot expiry cannot be
  replayed and audited;
- production WordPress, production Woo, production databases, Railway, VPS,
  public tunnels, or production secrets are required to prove the contract;
- the catalog feed is expanded to carry order/customer/payment data or its
  credential is reused for order enumeration;
- Redis, ETS, Cachex, or an in-memory process is proposed as membership,
  cursor, snapshot, or completeness authority;
- work expands into order import semantics, refunds, tax, readiness,
  attribution, or M3-03+ implementation in this contract-only slice; or
- implementation of the source plugin or Elixir consumer begins before this
  contract is reviewed and the follow-up slice is explicitly authorized.

## 17. Contract references

Repository contracts:

- [M1-08 completeness, reconciliation, and ANALYTICS_READY contract](m1-08-backfill-completeness-reconciliation-and-analytics-ready-contract.md)
- [Path 1 phase breakdown](path-1-phase-breakdown.md)
- [Catalog feed boundary README](../../integrations/wordpress/eventsales-tickera-catalog-feed/README.md)

Primary WooCommerce/WordPress evidence:

- [WooCommerce REST orders API](https://developer.woocommerce.com/docs/apis/rest-api/v3/orders/)
- [WooCommerce `wc_get_orders` documentation](https://developer.woocommerce.com/docs/features/orders/wc-get-orders/)
- [WooCommerce HPOS query improvements](https://developer.woocommerce.com/docs/features/orders/high-performance-order-storage/wc-order-query-improvements/)
- [WooCommerce REST controller source](https://raw.githubusercontent.com/woocommerce/woocommerce/trunk/plugins/woocommerce/includes/rest-api/Controllers/Version3/class-wc-rest-crud-controller.php)
- [WooCommerce order query source](https://raw.githubusercontent.com/woocommerce/woocommerce/trunk/plugins/woocommerce/includes/class-wc-order-query.php)
- [WooCommerce HPOS orders-table query source](https://raw.githubusercontent.com/woocommerce/woocommerce/trunk/plugins/woocommerce/src/Internal/DataStores/Orders/OrdersTableQuery.php)
- [WordPress `WP_Query` source](https://raw.githubusercontent.com/WordPress/wordpress-develop/trunk/src/wp-includes/class-wp-query.php)
- [WordPress `WP_Date_Query` source](https://raw.githubusercontent.com/WordPress/wordpress-develop/trunk/src/wp-includes/class-wp-date-query.php)
