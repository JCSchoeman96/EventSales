# EventSales Woo Order Index Feed

This plugin is the separate WordPress trust boundary for the historical WooCommerce
order-identity manifest. M3-01/02E2B activates one authenticated, bounded POST
that captures one source-consistent membership set at one source boundary `D`,
stores it through E1, and publishes it only after the immutable manifest is
READY.

The existing `eventsales-tickera-catalog-feed` remains catalog-only and is not
modified.

## E1 scope

E1 provides:

- two WordPress database tables using the active `$wpdb->prefix`;
- an internal API for a trusted builder to persist already-resolved identity rows;
- cryptographically random opaque boundary/lookup identifiers stored only as
  SHA-256 lookup hashes;
- immutable READY membership, deterministic hash evidence, and terminal metadata;
- 24-hour expiry with a seven-day hard maximum;
- directly callable bounded garbage collection, including abandoned BUILDING rows;
- authenticated, bounded READY manifest GET pages with authenticated cursors;
- an authenticated manifest POST backed by the production source adapter and
  bounded builder.

The E1 store itself does not:

- call `wc_get_orders`, `WC_Order_Query`, `wc_get_order`, `WP_Query`, HPOS, or
  legacy order storage;
- page the WooCommerce REST API or perform any source membership query;
- decide Woo membership or open the source snapshot;
- store customer, billing, shipping, payment, totals, line-item, notes, or raw
  WooCommerce payload data;
- change EventSales/Ash/Postgres code, `SyncRun`, `SyncCursor`, or the catalog
  plugin.

M3-01/02E2B owns the source-consistent Woo membership observation and atomic
builder that supplies rows to this storage API. EventSales Elixir consumption,
modified-time catch-up, refunds, and later slices are not part of this plugin.

## Durable tables

The plugin creates these InnoDB tables, with the current WordPress table prefix:

```text
{$wpdb->prefix}eventsales_order_manifests
{$wpdb->prefix}eventsales_order_manifest_items
```

The manifest header stores:

```text
id
token_hash
schema_version
source_system
backfill_start_gmt
backfill_cutoff_gmt
source_observed_at_gmt
membership_predicate_version
status
created_at_gmt
expires_at_gmt
completed_at_gmt
item_count
manifest_hash
terminal_evidence
```

The item table stores only:

```text
manifest_id
sequence
source_order_id
source_created_at_gmt
source_modified_at_gmt
```

The header has a unique `token_hash` and an indexed `(status, expires_at_gmt)`
cleanup path. Items use `(manifest_id, sequence)` as their primary paging key
and a unique `(manifest_id, source_order_id)` identity constraint. A foreign key
cascades lifecycle cleanup from a manifest header to its items.

Installation is additive and idempotent. Database guards are installed with the
tables; no destructive upgrade or existing WordPress table alteration is used.

## Lifecycle and internal storage API

The store class is:

```text
EventSales_Woo_Order_Index_Manifest_Store
```

Its narrow builder flow is:

```text
begin_manifest(scope, ttl)
  |> append_items(manifest_id, iterable identity rows)
  |> finalize_manifest(manifest_id)
```

`store_resolved_manifest(scope, iterable, ttl)` composes that flow for an
already-resolved identity set. It is not a Woo enumerator. Rows are accepted in
batches of at most 100, and each append batch has its own short transaction; an
unbounded PHP array or request-spanning transaction is not required.

The lifecycle is deliberately minimal:

```text
BUILDING -> READY
BUILDING -> FAILED
BUILDING -> EXPIRED
READY    -> EXPIRED
```

BUILDING membership is append-only and is not publicly readable. Finalization
streams the stored rows in sequence-keyset batches, verifies contiguous storage
and the exact item count, then performs a short locked promotion. A concurrent
append cannot promote after the header is locked. A failed or incomplete
BUILDING manifest never becomes READY and can be cleaned up.

READY membership and membership-defining header fields are immutable. MySQL
triggers reject READY item insert/update/delete, READY header mutation, READY
deletion, reopening FAILED/EXPIRED rows, and promotion without complete stored
sequence invariants. Application guards provide the narrow lifecycle API in
addition to those database guards.

## E2B production capture

The production orchestration boundary is
`EventSales_Woo_Order_Manifest_Builder` in
`eventsales-woo-order-manifest-builder.php`. It runs after HMAC authentication
and request validation, then acquires a source-scoped zero-wait MySQL named lock
for load/concurrency control. The lock key is derived from the authoritative
database host, database name, and table prefix; it is connection-scoped and is
released on every path. A simultaneous capture returns bounded `busy`. The lock
does not decide membership, source continuation, or `D`.

The builder uses one dedicated source `wpdb` connection, preserves the E2A
OrderUtil preflight and same-snapshot HPOS/legacy authority checks, and opens
one InnoDB `REPEATABLE READ` transaction with
`WITH CONSISTENT SNAPSHOT, READ ONLY`. The source adapter owns an internal
confirmed primary-ID cursor. A candidate is replayable until its exact rows,
start ID, end ID, limit, and digest are confirmed after the corresponding E1
append succeeds. The source cannot commit until the empty terminal candidate is
also confirmed. A retry never resumes a failed attempt: it creates a new
manifest and a new `D`.

The server-controlled capture limit is:

```text
CAPTURE_BUDGET_SECONDS = 5
source capture chunk = 1..100 identities
```

Elapsed time is checked between every bounded source read, append, confirmation,
terminal confirmation, and source commit. A timeout rolls back the source
snapshot, fails the BUILDING manifest where possible, and prevents READY
publication. The client cannot change or extend this budget. `set_time_limit(0)`
is not used. This five-second limit is the E2B operating gate for this slice,
not a claim that every deployment or dataset is safe.

The public `busy` result is HTTP 409. Other source, storage, budget, authority,
and finalization failures are HTTP 503 with a stable bounded error code.

HPOS and legacy support are enabled only when their representative local
capture completes within this fixed five-second budget. The legacy source uses
the primary-ID path over `wp_posts` and may examine a large identity space
because `post_date_gmt` is not a standard indexed seek field. If a representative
mode cannot complete within five seconds, that mode is fail-closed and E2B is
blocked pending a different source materialization mechanism. No unsupported
legacy deployment-scale claim is made.

The representative local E2B benchmark below used the verified loopback
WordPress/MySQL installation, synthetic four-match fixtures, and proof-only
`EXPLAIN ANALYZE` metrics in the test adapter. The production default adapter
does not run that instrumentation. PHP memory is the process peak reported by
the harness; it is not a claim that the source chunk itself consumes that full
amount.

| Mode | Total `shop_order` identity space | Matching identities | Rows examined | Source chunks | Snapshot wall time | PHP peak | Largest ID gap | Plan/key |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| HPOS | 5 | 4 | 8 | 1 | 12.512 ms | 105,906,176 bytes | 9 | range / `PRIMARY` |
| Legacy | 19,745 | 4 | 68,441 | 1 | 187.934 ms | 105,906,176 bytes | 9 | range / `PRIMARY` |

Both representative captures completed below the fixed five-second gate. The
legacy result still demonstrates the structural cost of primary-ID traversal
over `wp_posts`; it does not support an unsupported scale claim.

The POST request `limit` has one meaning only: it controls the number of READY
manifest identities returned in the first response page, from 1 through 100.
It does not change source capture chunk size. For example, `limit=20` still
captures source chunks of at most 100 and returns at most 20 immutable E1
identities. The response uses the existing E1 READY reader; it never exposes
BUILDING state.

An exact authenticated request replay after a completed request intentionally
starts a new source snapshot and returns a new manifest/new `D`, because the
current contract has no idempotency key. There is no durable replay cache or
Redis correctness dependency. If that duplicate work becomes operationally
unacceptable, a future slice must add an explicit idempotency design rather
than pretending the current command is idempotent.

## Token and cursor security

Tokens are `bin2hex(random_bytes(32))`: 256 bits of cryptographic entropy. The
manifest token is an opaque boundary/lookup identifier, not a standalone
access authority. It is returned to the internal builder and as the locked
`boundary_token` field only in an authenticated READY POST/GET response. Surrounding HTTP
infrastructure may record URLs, so possession of the token alone must not grant
access. Order-index HMAC authentication remains mandatory before membership is
returned. The plugin does not deliberately log the raw token, persist it, or
echo it in error bodies; hashing it at rest is defense-in-depth. The header
stores only:

```text
sha256(raw_token)
```

GET cursors are opaque and do not expose an offset. Their exact wire shape is:

```text
base64url(canonical-json-payload).base64url(hmac-sha256(mac))
```

The canonical payload contains `last_sequence`, `manifest_token_hash`, and
`v: 1`. The HMAC input is exactly:

```text
eventsales/woo-order-index/cursor/v1
<newline>
<canonical payload bytes>
```

The existing order-index secret signs the cursor under this domain-separated
purpose. No catalog credential or new credential scope is used. A cursor is
accepted only when its MAC and exact manifest token hash match.

## Expiry and garbage collection

The default TTL is 24 hours. The hard maximum is seven days. Reads reject an
expired manifest and never extend its expiry. Expired, failed, and abandoned
BUILDING state is removed by:

```text
EventSales_Woo_Order_Index_Manifest_Store::garbage_collect($batch_size)
```

The batch size is bounded to 1..100 and the indexed `(status, expires_at_gmt)`
path is used. A scheduler may call this function, but correctness does not
depend on cron because expiry is checked on every read and promotion.

## Manifest integrity and terminal evidence

The final SHA-256 manifest hash is computed from deterministic canonical JSON
records in this order:

```text
header:
  backfill_cutoff_gmt
  backfill_start_gmt
  item_count
  membership_predicate_version
  schema_version
  source_observed_at_gmt
  source_system

then one record per ordered sequence:
  sequence
  source_created_at_gmt
  source_modified_at_gmt
  source_order_id
```

All timestamps are canonical UTC values with six fractional digits. The raw
token, secret, wall-clock replay time, and full order payloads do not contribute.
Terminal evidence is the bounded stored value:

```text
v1;manifest_sha256=<hash>;item_count=<count>;last_sequence=<sequence>
```

GET returns that stored evidence only when `has_more` is false. Nonterminal
pages omit `terminal_evidence`; a short page is not terminal proof.

## Endpoints

Both routes retain the M3-01/02D HMAC authentication contract:

```text
POST /wp-json/eventsales/v1/woo-order-index/manifests
GET  /wp-json/eventsales/v1/woo-order-index/manifests/{token}
```

### POST

POST is implemented by E2B only when the fixed five-second representative
HPOS/legacy performance gate has passed for the enabled mode. After request
size, HMAC, and explicit UTC `[B,C]` validation, it acquires the source-scoped
zero-wait lock and performs one bounded source capture. The request `limit`
controls only the first READY response page; source chunks remain at most 100.

Success returns the existing E1 READY reader envelope:

```json
{
  "schema_version": "2026-08-12.v1",
  "phase": "manifest_enumerate",
  "boundary_token": "<opaque token>",
  "manifest_hash": "<sha256>",
  "manifest_expires_at_gmt": "<UTC>",
  "source_observed_at_gmt": "<UTC>",
  "items": ["<metadata-only identities>"],
  "has_more": true,
  "next_cursor": "<opaque authenticated cursor>"
}
```

The terminal page omits `next_cursor` and includes the immutable stored
`terminal_evidence`. POST never returns BUILDING. On any failure it returns a
bounded non-success error and does not expose a token, SQL, request signature,
credentials, or order/customer data. A failed attempt is not resumed; retry
means a new manifest and new `D`.

### GET

GET is active only for manifests already created through the internal storage
API. It authenticates exactly as M3-01/02D, looks up by `sha256(token)`, and
returns READY, unexpired identity pages only:

- maximum 100 items;
- deterministic `sequence > last_sequence` keyset paging;
- no page, offset, or total-count parameter;
- opaque, manifest-bound cursor only;
- BUILDING and FAILED return no membership;
- expired returns stable `manifest_expired` HTTP 410;
- unknown tokens return `manifest_not_found` HTTP 404;
- terminal responses use stored `terminal_evidence`; nonterminal responses omit
  it.

The response envelope remains limited to the locked metadata-only fields:

```text
schema_version
phase
boundary_token
manifest_hash
manifest_expires_at_gmt
source_observed_at_gmt
items
next_cursor (nonterminal pages only)
has_more
terminal_evidence (terminal pages only)
```

The HMAC secret remains the access authority. The token is only the immutable
manifest lookup/boundary identifier and does not replace HMAC authentication.

## Tests

The standalone D boundary harness remains available:

```bash
php -l integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-index-feed.php
php -l integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-index-manifest-store.php
php -l integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-membership-source.php
php -l integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-manifest-builder.php
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-test.php
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-manifest-builder-test.php
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof-test.php --mode=hpos
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-membership-proof-test.php --mode=legacy
```

The E1 harness uses the real local WordPress `wpdb`/MySQL service. It refuses a
non-loopback database host and takes credentials only from environment variables
without printing them:

```bash
php -l integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-db-test.php
EVENTSALES_WP_ROOT=/path/to/local/wordpress \
EVENTSALES_WP_DB_HOST=localhost:/path/to/local/mysql.sock \
EVENTSALES_WP_DB_NAME=local \
EVENTSALES_WP_DB_USER=root \
EVENTSALES_WP_DB_PASSWORD=<local-only-secret> \
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-db-test.php
```

The database tests prove schema idempotence and indexes, token hashing,
READY/FAILED/EXPIRED/BUILDING lifecycle behavior, database immutability,
duplicate identity constraints, deterministic hashes, bounded pages, cursor
replay/binding, TTL, and bounded GC. They also prove that no live Woo
enumeration reference is introduced, the activated POST fails closed when the
verified local source runtime is absent, and the catalog plugin is unchanged.

The E2B performance gate must also record, separately for HPOS and legacy,
source mode, total source identity-space size, matching identities, rows
examined, source chunks, snapshot wall time, PHP peak memory, largest emitted
ID gap, and the query plan/key. Both enabled modes must complete within the
fixed five-second budget. These local measurements do not claim unsupported
deployment scale.

## Later slices

E2B intentionally stops at the authenticated READY manifest boundary. Later
work may consume the immutable manifest from EventSales Elixir, but this slice
does not change Elixir, `SyncRun`, `SyncCursor`, modified-time catch-up `H`,
refunds, or M3-03+ behavior.
