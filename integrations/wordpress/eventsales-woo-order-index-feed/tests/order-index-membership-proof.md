# M3-01/02E2A — Atomic Woo Membership Capture Proof

Status: **E2A LOCKED IMPLEMENTATION DECISION — COMPLETE (PASS); E2B LOCAL GATE — PASS**

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
short bounded BUILDING appends. The production adapter owns continuation; no
caller or HTTP request supplies a source cursor.

```text
source connection A:
  SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ
  START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY
  D = the InnoDB read view established by that statement
  confirmed_cursor = 0
  read_next_candidate: at most 100 identity rows with id > confirmed_cursor
  append candidate to E1
  confirm_persisted(candidate)
  repeat until an empty candidate is confirmed
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
WHERE source_id > :confirmed_cursor
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
`source_id > confirmed_cursor` predicate make each snapshot member appear once.

The source state machine has exactly one pending candidate. Reading before
confirmation replays the exact candidate without another SQL query. The
candidate binds its starting confirmed cursor, ending ID, rows, limit, terminal
flag, and digest. Acknowledgement advances the internal cursor only after the
corresponding E1 append succeeds. Forged, stale, duplicate, or out-of-order
acknowledgements fail closed. The empty terminal candidate is pending until
acknowledged; source COMMIT is forbidden before that acknowledgement and is
also forbidden while any candidate remains pending.

The source transaction is never continued across HTTP requests. If capture
fails before source exhaustion, source commit, or E1 finalization, the
BUILDING manifest cannot become READY. A retry starts a new BUILDING manifest
and a new source snapshot boundary `D`; it does not continue the old manifest
from a newer source observation.

The HPOS and legacy adversarial harnesses have passed, including the required
query-plan and bounded-snapshot measurements. The decision is locked for E2B;
the production builder and public boundary are now covered by the local E2B
gate. This does not claim unsupported deployment scale.

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

The storage authority is also bound to `D`. The Woo-supported capability API
is a preflight expectation, not the proof by itself. After the source
transaction establishes its read view, the adapter reads the authoritative
HPOS usage option from the same snapshot and requires it to be exactly `yes`
for HPOS or exactly `no` for legacy, matching the preflight result. A missing,
malformed, or mismatching option fails capture closed. The selected table is
then the table for that mode; the adapter never mixes rows from both stores or
guesses from table existence.

Before `D`, the dedicated source connection must prove all of the following:

- effective session isolation is `REPEATABLE-READ`;
- the selected source table and the options table engine are `InnoDB`;
- the source connection has the same database/server identity as the
  authoritative WordPress connection and is not a read-only/replica endpoint;
- the selected table has the exact fields and identity primary key required by
  its mode.

The adapter fails closed on any inability to verify these prerequisites. A
source SQL error, missing table/column/index, mode-marker mismatch, or MySQL
table-definition error such as `ER_TABLE_DEF_CHANGED` aborts the snapshot and
leaves the E1 manifest non-READY. The proof does not claim that a concurrent
authority switch or DDL operation is harmless; it claims that such a change
cannot silently produce a mixed or guessed observation.

All source comparisons use canonical UTC `DATETIME` values. The conceptual
contract is inclusive `[B, C]`; the SQL predicates are explicitly `>= B` and
`<= C`. Source second-precision values are normalized to six fractional digits
when returned to E1.

## Storage-specific source mapping

| Mode | Capability detection | Table | Type filter | ID | Created GMT | Modified GMT |
| --- | --- | --- | --- | --- | --- | --- |
| HPOS | `OrderUtil::custom_orders_table_usage_is_enabled()` returns true before D, then the same-snapshot usage option is exactly `yes` | Woo `wc_orders` table obtained from the HPOS datastore | `type = 'shop_order'` | `id` | `date_created_gmt` | `date_updated_gmt` |
| Legacy | The same capability returns false before D, then the same-snapshot usage option is exactly `no` | WordPress `$wpdb->posts` table | `post_type = 'shop_order'` | `ID` | `post_date_gmt` | `post_modified_gmt` |

The proof does not infer HPOS from the existence of a table. It uses the
WooCommerce capability API, then verifies the selected source table's engine,
columns, and primary identity index before reading it. Refund types such as
`shop_order_refund` are excluded by the exact normal-order type predicate.

The same-snapshot option check is the storage-authority-at-D proof. Woo's
`OrderUtil::custom_orders_table_usage_is_enabled()` delegates to the
`CustomOrdersTableController`, whose supported authority marker is the
`woocommerce_custom_orders_table_enabled` option. The adapter uses that
official marker only as a scalar mode binding read inside the source snapshot;
it does not use direct SQL as a replacement for Woo's capability API or infer
HPOS from physical table presence.

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
| An unseen matching order is deleted after D | It remains included because it existed and matched at D. |
| Equal creation timestamps | Every matching identity is included once, ordered by ID. |
| Equal modified timestamps | Every matching identity is included once; modified time is not a cursor. |
| Capture is replayed | A new manifest has the same ordered identities and item digest. Its E1 manifest hash may differ because the immutable header binds the new boundary `D`. |
| Capture fails before publication | No READY manifest is published; retry starts a new D. |

The same matrix runs against HPOS and legacy source tables. The harness also
asserts that the public feed loads only the production source adapter and
manifest builder required for POST; the catalog plugin remains unchanged. The
activated POST is covered separately by the database-independent builder/feed
tests and returns success only for a READY manifest.

## Harness evidence

The local proof ran on the verified `http://localhost:10059` WordPress site
with MySQL 8.4. It inserted six synthetic source rows per mode: four normal
orders in `[B,C]`, one out-of-range normal order, and one in-range
`shop_order_refund` row. The source adapter returned only the four normal
orders. The two non-empty chunks used a limit of two, followed by the required
empty terminal chunk. No customer or full order payload was read.

The proof output was:

| Mode | EXPLAIN access/key | Estimated rows | Measured rows examined | Matching rows | Chunks | Snapshot duration | Largest ID gap |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| HPOS | `range`, `PRIMARY`; possible `PRIMARY,date_created,type_status_date` | 6 | 6 | 4 | 2 | 19.759 ms | 9 |
| Legacy | `range`, `PRIMARY`; possible `PRIMARY,type_status_date,type_status_author` | 35,368 | 68,439 | 4 | 2 | 284.158 ms | 9 |

The local MySQL 8.4 server does not expose `Rows_examined` as a session
status variable, so the harness-enabled adapter used `EXPLAIN ANALYZE` actual
plan rows for the measured fallback. On versions exposing `Rows_examined`, the
harness-enabled adapter records the per-chunk session-status delta. These
local durations include the bounded `EXPLAIN ANALYZE` fallback used to collect
the metric and are not a production throughput benchmark. The legacy result
demonstrates the
expected primary-ID traversal cost: only four rows matched while the source
plan examined substantially more of the `posts` identity space. This is
correctness evidence and a finite local feasibility measurement, not an
unsupported legacy deployment-scale claim.

The E2B production-builder benchmark used the same verified loopback site and
enabled proof-only query metrics through an injected test adapter. The default
production adapter does not run `EXPLAIN ANALYZE`. It recorded:

| Mode | Total source identity-space size (`shop_order`) | Matching identities | Rows examined | Source chunks | Snapshot wall time | PHP peak memory | Largest ID gap | Plan/key |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| HPOS | 5 | 4 | 8 | 1 | 13.404 ms | 105,906,176 bytes | 9 | range / `PRIMARY` |
| Legacy | 19,745 | 4 | 68,441 | 1 | 188.254 ms | 105,906,176 bytes | 9 | range / `PRIMARY` |

Both modes completed within the fixed five-second server-controlled E2B
budget. The memory value is the PHP process peak reported by the harness, not
the size of a materialized full membership set. The legacy scan remains an
operational limitation; these values do not certify arbitrary deployment
scale.

The harness changes the official HPOS usage option directly only while setting
up the local HPOS/legacy fixture runs. The normal Woo option API correctly
refused a mode switch because this local database has unsynchronised orders;
the direct local fixture setup avoids that unrelated guard while the adapter
still detects mode through `OrderUtil` and verifies the option from D. The
original option value is restored and all synthetic rows are deleted in the
test `finally` path.

## Scaling and operational cost

This is cold, source-authoritative durable database state. Redis, ETS, Cachex,
and process memory are not membership authority. Historical materialization
does not create per-user work, including for 100,000 EventSales users.

The PHP memory bound is one source chunk plus the E1 append batch (maximum 100
identity rows and three fields per row); no full order object, payload, or
unbounded result is materialized. The E2B benchmark records
`memory_get_peak_usage(true)` for each mode. The database holds the durable E1
item rows, O(m) for the matching membership size.

The required source access path is the primary identity index: HPOS `PRIMARY
KEY (id)` and WordPress `PRIMARY KEY (ID)`. HPOS additionally supplies
date/type indexes in its official schema; WordPress's standard `posts` schema
does not index `post_date_gmt`, which is why the proof keyset advances by the
primary identity rather than repeatedly seeking by creation time. Each source
identity space is traversed once under the snapshot; there is no OFFSET scan,
count query, or repeated rewind.

The correctness cost is bounded PHP memory, but production feasibility is not
asserted from query shape alone. In particular, legacy `wp_posts` may scan a
substantial portion of the general WordPress ID space because its standard
schema does not index `post_date_gmt`. The harness must record, separately for
HPOS and legacy:

```text
source mode
total source identity-space size
matching identities
EXPLAIN/query plan
rows examined (session Rows_examined delta)
number of source chunks
elapsed source snapshot duration
PHP peak memory
largest observed gap between emitted source IDs
```

The fixed server-controlled E2B capture budget is five seconds. The decision
remains production-feasible only if those measurements fit that finite worker
and transaction budget on representative datasets. If either enabled mode
exceeds five seconds, E2B is blocked pending a source materialization mechanism;
the budget is not raised to make the benchmark pass.

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

1. Validate immutable `B` and `C` and the source system. The HTTP `limit` is
   only the READY response page size; the source chunk is fixed at 100.
2. Acquire the source-scoped zero-wait MySQL connection lock, then open a
   dedicated source connection and use
   `OrderUtil::custom_orders_table_usage_is_enabled()` for the preflight mode
   expectation. Verify same authoritative database/server identity, writable
   primary state, effective `REPEATABLE-READ`, the mode-specific table's
   `InnoDB` engine, exact fields, and primary identity index.
3. Start `WITH CONSISTENT SNAPSHOT, READ ONLY`; define D as the resulting read
   view and read `woocommerce_custom_orders_table_enabled` from the options
   table in that same view. Require `yes`/`no` to match the preflight mode;
   otherwise abort closed.
4. Record bounded D metadata and create one E1 BUILDING manifest bound to B,
   C, D, and the predicate version.
5. Fetch identity-only candidates using the mode-specific fields, exact
   `shop_order` filter, inclusive `[B,C]` predicate, the internal
   `id > confirmed_cursor` keyset, and `ORDER BY id ASC LIMIT 100`.
6. Append each candidate to E1, then acknowledge that exact candidate. Advance
   the source cursor only after the append succeeds. On any error, fail/abandon
   the BUILDING manifest, roll back the source snapshot, and do not resume it.
7. Require an empty source candidate as source terminal evidence. Commit the source
   transaction, close connection A, then finalize the E1 manifest in its short
   transaction.
8. Publish/use the manifest only after READY. E2B activates the existing
   authenticated POST and reuses the bounded E1 READY GET reader; it does not
   expose BUILDING state or add a second paging implementation.

Query-plan and rows-examined collection is harness instrumentation. E2B must
measure representative plans before deployment and must not run per-chunk
`EXPLAIN ANALYZE` in the production capture path unless its added snapshot
cost is explicitly included in the finite transaction budget.

## Primary sources

- [WooCommerce `wc_get_orders()` and order-query guidance](https://developer.woocommerce.com/docs/features/orders/wc-get-orders/)
- [WooCommerce HPOS order-query APIs](https://developer.woocommerce.com/docs/features/orders/high-performance-order-storage/wc-order-query-improvements/)
- [WooCommerce HPOS `OrdersTableQuery`](https://raw.githubusercontent.com/woocommerce/woocommerce/trunk/plugins/woocommerce/src/Internal/DataStores/Orders/OrdersTableQuery.php)
- [WooCommerce HPOS `OrdersTableDataStore`](https://raw.githubusercontent.com/woocommerce/woocommerce/trunk/plugins/woocommerce/src/Internal/DataStores/Orders/OrdersTableDataStore.php)
- [WooCommerce `OrderUtil` supported HPOS capability](https://raw.githubusercontent.com/woocommerce/woocommerce/trunk/plugins/woocommerce/src/Utilities/OrderUtil.php)
- [WooCommerce `CustomOrdersTableController` authority option and switching rules](https://raw.githubusercontent.com/woocommerce/woocommerce/trunk/plugins/woocommerce/src/Internal/DataStores/Orders/CustomOrdersTableController.php)
- [WooCommerce legacy CPT order datastore](https://raw.githubusercontent.com/woocommerce/woocommerce/trunk/plugins/woocommerce/includes/data-stores/class-wc-order-data-store-cpt.php)
- [WooCommerce mutable order date setters](https://raw.githubusercontent.com/woocommerce/woocommerce/trunk/plugins/woocommerce/includes/abstracts/abstract-wc-order.php)
- [WordPress core posts schema](https://raw.githubusercontent.com/WordPress/wordpress-develop/trunk/src/wp-admin/includes/schema.php)
- [MySQL InnoDB consistent nonlocking reads](https://dev.mysql.com/doc/refman/8.4/en/innodb-consistent-read.html)
- [MySQL `START TRANSACTION WITH CONSISTENT SNAPSHOT`](https://dev.mysql.com/doc/refman/8.4/en/commit.html)
