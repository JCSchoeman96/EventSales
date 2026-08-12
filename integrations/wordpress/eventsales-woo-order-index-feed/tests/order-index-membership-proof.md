# M3-01/02E2A — Atomic Woo Membership Capture Proof

Status: **LOCKED IMPLEMENTATION DECISION — pending harness execution**

Base: `e8f1cb0b7e32afc9ffe8d161c0af2a81b2022f11`

This document is the source-side correctness decision for M3-01/02E2A. It
does not activate the public manifest POST, change EventSales Elixir code, or
modify PR #188.

## Scope

The membership predicate is normal WooCommerce orders whose source creation
timestamp is inclusively within `[B, C]`, observed at one source-consistent
boundary `D`. Refund resources are outside this slice.

The frozen item contains exactly:

```text
source_order_id
source_created_at_gmt
source_modified_at_gmt
```

No customer, payment, address, total, line-item, note, or raw order payload is
read or stored by the proof adapter.

## Decision

Use one dedicated source database connection with an InnoDB
`REPEATABLE READ` consistent snapshot and bounded primary-ID keyset reads.
Use the existing E1 manifest store on the normal WordPress connection for
short bounded BUILDING appends.

```text
source connection A:
  SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ
  START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY
  D = the InnoDB read view established by that statement
  SELECT at most 100 identity rows with id > last_id
  repeat until the snapshot returns no rows
  COMMIT / close source snapshot

manifest connection B:
  begin BUILDING manifest after D is established
  append each source chunk in E1's short bounded transaction
  never expose BUILDING membership
  finalize only after source exhaustion and source commit
```

The source rows are ordered by their immutable numeric identity, not by a
mutable timestamp:

```sql
WHERE source_id > :last_source_id
  AND source_type = 'shop_order'
  AND source_created_gmt >= :B
  AND source_created_gmt <= :C
ORDER BY source_id ASC
LIMIT :chunk_size
```

The primary-ID keyset is safe here because membership is evaluated against the
same InnoDB snapshot for every chunk. Ordering alone is not the proof. A source
row that changes, is deleted, or is inserted after `D` cannot become visible
or invisible to that read view. The unique source identity and strict
`source_id > last_source_id` predicate make each snapshot member appear once.

The source transaction is never continued across HTTP requests. If capture
fails before source exhaustion, source commit, or E1 finalization, the
BUILDING manifest cannot become READY. A retry starts a new BUILDING manifest
and a new source snapshot boundary `D`; it does not continue the old manifest
from a newer source observation.

## Boundary D

`D` is not a PHP wall-clock timestamp and is not a signed REST cursor. It is
the source-owned InnoDB read view established on the dedicated source
connection by:

```sql
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY;
```

`source_observed_at_gmt` is the UTC server timestamp read immediately after
the transaction starts and is retained as bounded E1 metadata. It is evidence
of when the source boundary was established; the read view, not the wall-clock
value, is the membership authority.

All source comparisons use canonical UTC `DATETIME` values. The conceptual
contract is inclusive `[B, C]`; the SQL predicates are explicitly `>= B` and
`<= C`. Source second-precision values are normalized to six fractional digits
when returned to E1.

## Storage-specific source mapping

| Mode | Capability detection | Table | Type filter | ID | Created GMT | Modified GMT |
| --- | --- | --- | --- | --- | --- | --- |
| HPOS | `OrderUtil::custom_orders_table_usage_is_enabled()` returns true | Woo `wc_orders` table obtained from the HPOS datastore | `type = 'shop_order'` | `id` | `date_created_gmt` | `date_updated_gmt` |
| Legacy | The same capability returns false | WordPress `$wpdb->posts` table | `post_type = 'shop_order'` | `ID` | `post_date_gmt` | `post_modified_gmt` |

The proof does not infer HPOS from the existence of a table. It uses the
WooCommerce capability API, then verifies the selected source table's engine,
columns, and primary identity index before reading it. Refund types such as
`shop_order_refund` are excluded by the exact normal-order type predicate.

The adapter uses direct, prepared, identity-only SQL because the supported
Woo query API has no portable composite seek predicate bound to one source
snapshot. This is a narrowly scoped source adapter, not a generic EventSales
query abstraction.

## Why other mechanisms are rejected

### Woo REST collection

`page`, `offset`, `per_page`, `orderby`, and modified-date bounds are evaluated
against the current collection for each request. They provide no source
snapshot token or `after_id` contract. A deterministic `ORDER BY` does not
freeze membership, so REST traversal is not used.

### `wc_get_orders()` / `WC_Order_Query`

These APIs remain the supported general Woo access path, but their paging
controls are offset-based. HPOS `date_query` and `field_query` are not a
portable legacy facility, and the legacy datastore maps its standard date
queries to local `post_date` / `post_modified` rather than this proof's exact
GMT source fields. The adapter therefore uses the storage-specific source
columns only after capability and schema verification.

### Creation-time or modified-time live keysets

A live `(created,id)` or `(modified,id)` keyset can still miss or admit rows
when source timestamps mutate between chunks. The chosen ID keyset is only
safe because every chunk is a non-locking read from the same InnoDB snapshot.
Modified time is returned as metadata for later catch-up; it is not membership
authority.

### One `INSERT ... SELECT` into the manifest tables

This would couple source storage internals, E1 sequence/hash lifecycle, and
source-side DML in one statement. It is not needed: E1 already accepts
bounded resolved identity iterables, and the source transaction can remain on
connection A while E1 performs separate short writes on connection B. No E1
schema redesign or internal API extension is required for E2B.

## E1 compatibility

E1's existing API is sufficient:

```text
begin_manifest(scope)
append_items(manifest_id, one source chunk of <= 100 rows)
finalize_manifest(manifest_id)
```

The adapter never passes an unbounded array. E1's BUILDING state is not
publicly readable; its item identity unique constraint and finalization checks
provide duplicate and contiguous-sequence protection. The source snapshot is
closed before finalization, so no source transaction is held during E1's
final short promotion.

Required E2B store change: **none**.

## Adversarial proof matrix

The harness establishes `D` before making concurrent changes through a third
local database connection. With an initial in-range set `10, 20, 30, 40`, the
frozen result must remain the set present at `D`:

| Mutation after D | Required result |
| --- | --- |
| Already-seen order's modified time moves beyond `C` | It remains included with the modified timestamp observed at `D`. |
| Unseen order's modified time changes | It remains included or excluded solely according to creation membership at `D`; modified time cannot affect membership. |
| Existing out-of-range order is backdated into `[B,C]` | It is excluded. |
| Existing in-range order's creation time moves outside `[B,C]` | It remains included. |
| New post-D order is inserted with historical creation time | It is excluded. |
| Existing order is deleted after D | It remains included if it existed and matched at D. |
| Equal creation timestamps | Every matching identity is included once, ordered by ID. |
| Equal modified timestamps | Every matching identity is included once; modified time is not a cursor. |
| Capture is replayed | A new manifest has the same ordered identities and hash. |
| Capture fails before publication | No READY manifest is published; retry starts a new D. |

The same matrix runs against HPOS and legacy source tables. The harness also
asserts that the public POST remains HTTP 501 and that the public feed file
does not load or reference the proof adapter.

## Scaling and operational cost

This is cold, source-authoritative durable database state. Redis, ETS, Cachex,
and process memory are not membership authority. Historical materialization
does not create per-user work, including for 100,000 EventSales users.

The PHP memory bound is one source chunk plus the E1 append batch (maximum 100
identity rows and three fields per row); no full order object, payload, or
`limit = -1` result is materialized. The database holds the durable E1 item
rows, O(m) for the matching membership size.

The required source access path is the primary identity index: HPOS `PRIMARY
KEY (id)` and WordPress `PRIMARY KEY (ID)`. HPOS additionally supplies
date/type indexes in its official schema; WordPress's standard `posts` schema
does not index `post_date_gmt`, which is why the proof keyset advances by the
primary identity rather than repeatedly seeking by creation time. Each source
identity space is traversed once under the snapshot; there is no OFFSET scan,
count query, or repeated rewind.

Plain consistent reads acquire no row locks, but the source read view remains
open while bounded chunks are appended to E1. Transaction duration is

```text
source snapshot setup
+ source rows scanned for the ID-keyset range
+ at most one short E1 append transaction per chunk
```

MVCC undo retention and replica lag pressure therefore grow with this wall
time and concurrent source write volume. E2B must run the operation within a
finite request/worker time budget and fail closed if that budget is exceeded;
it must never continue a BUILDING manifest under a new snapshot. The harness
records chunk count and elapsed time so a deployment can set that budget from
local source evidence rather than hiding an unbounded transaction behind the
word atomic.

## Recommended E2B algorithm

1. Validate immutable `B` and `C`, the source system, and a bounded chunk size
   no greater than 100.
2. Detect HPOS through `OrderUtil::custom_orders_table_usage_is_enabled()`.
3. Resolve and verify the mode-specific source table, InnoDB engine, exact
   fields, and primary identity index.
4. Open a dedicated source connection; verify it targets the same local/source
   database as the WordPress connection without logging credentials.
5. Start `REPEATABLE READ, WITH CONSISTENT SNAPSHOT, READ ONLY`, record D
   metadata, and create one E1 BUILDING manifest bound to B, C, D, and the
   predicate version.
6. Fetch identity-only chunks using the mode-specific fields, exact
   `shop_order` filter, inclusive `[B,C]` predicate, `id > last_id`, and
   `ORDER BY id ASC LIMIT 100`.
7. Append each chunk to E1. Advance the source cursor only after the append
   succeeds. On any error, fail/abandon the BUILDING manifest, roll back the
   source snapshot, and do not resume it.
8. Require an empty source chunk as source terminal evidence. Commit the source
   transaction, close connection A, then finalize the E1 manifest in its short
   transaction.
9. Publish/use the manifest only after READY. The public POST remains disabled
   in E2A; E2B must preserve the existing authenticated boundary and bounded
   READY GET.

## Primary sources

- [WooCommerce `wc_get_orders()` and order-query guidance](https://developer.woocommerce.com/docs/features/orders/wc-get-orders/)
- [WooCommerce HPOS order-query APIs](https://developer.woocommerce.com/docs/features/orders/high-performance-order-storage/wc-order-query-improvements/)
- [WooCommerce HPOS `OrdersTableQuery`](https://raw.githubusercontent.com/woocommerce/woocommerce/trunk/plugins/woocommerce/src/Internal/DataStores/Orders/OrdersTableQuery.php)
- [WooCommerce HPOS `OrdersTableDataStore`](https://raw.githubusercontent.com/woocommerce/woocommerce/trunk/plugins/woocommerce/src/Internal/DataStores/Orders/OrdersTableDataStore.php)
- [WooCommerce legacy CPT order datastore](https://raw.githubusercontent.com/woocommerce/woocommerce/trunk/plugins/woocommerce/includes/data-stores/class-wc-order-data-store-cpt.php)
- [WooCommerce mutable order date setters](https://raw.githubusercontent.com/woocommerce/woocommerce/trunk/plugins/woocommerce/includes/abstracts/abstract-wc-order.php)
- [WordPress core posts schema](https://raw.githubusercontent.com/WordPress/wordpress-develop/trunk/src/wp-admin/includes/schema.php)
- [MySQL InnoDB consistent nonlocking reads](https://dev.mysql.com/doc/refman/8.4/en/innodb-consistent-read.html)
- [MySQL `START TRANSACTION WITH CONSISTENT SNAPSHOT`](https://dev.mysql.com/doc/refman/8.4/en/commit.html)
