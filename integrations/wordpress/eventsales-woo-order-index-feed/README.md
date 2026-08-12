# EventSales Woo Order Index Feed

This plugin is the separate WordPress trust boundary for the historical WooCommerce
order-identity manifest. M3-01/02E1 adds the durable destination and lifecycle
behind that boundary. It does not discover or enumerate live WooCommerce orders.

The existing `eventsales-tickera-catalog-feed` remains catalog-only and is not
modified.

## E1 scope

E1 provides:

- two WordPress database tables using the active `$wpdb->prefix`;
- an internal API for a trusted builder to persist already-resolved identity rows;
- cryptographically random opaque tokens stored only as SHA-256 lookup hashes;
- immutable READY membership, deterministic hash evidence, and terminal metadata;
- 24-hour expiry with a seven-day hard maximum;
- directly callable bounded garbage collection, including abandoned BUILDING rows;
- authenticated, bounded READY manifest GET pages with authenticated cursors.

E1 does not:

- call `wc_get_orders`, `WC_Order_Query`, `wc_get_order`, `WP_Query`, HPOS, or
  legacy order storage;
- page the WooCommerce REST API or perform any source membership query;
- create a live manifest through the public POST endpoint;
- store customer, billing, shipping, payment, totals, line-item, notes, or raw
  WooCommerce payload data;
- change EventSales/Ash/Postgres code, `SyncRun`, `SyncCursor`, or the catalog
  plugin.

M3-01/02E2 owns the source-consistent Woo membership observation and atomic
builder that will supply rows to this storage API.

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

## Token and cursor security

Tokens are `bin2hex(random_bytes(32))`: 256 bits of cryptographic entropy. The
raw bearer token is returned only to the internal caller and is never persisted
or logged. The header stores only:

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

GET returns that stored evidence; a short page is not terminal proof.

## Endpoints

Both routes retain the M3-01/02D HMAC authentication contract:

```text
POST /wp-json/eventsales/v1/woo-order-index/manifests
GET  /wp-json/eventsales/v1/woo-order-index/manifests/{token}
```

### POST

POST remains deliberately fail-closed in E1. After the existing request-size,
HMAC, and scope validation it returns HTTP 501:

```json
{
  "error": "manifest_capability_unavailable",
  "schema_version": "2026-08-12.v1",
  "capability": "woo_order_index_manifest",
  "capability_status": "not_implemented"
}
```

It does not create a token, query WooCommerce, or write a BUILDING/READY row.

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
- terminal responses use stored `terminal_evidence`.

The response envelope remains limited to the locked metadata-only fields:

```text
schema_version
phase
boundary_token
manifest_hash
manifest_expires_at_gmt
source_observed_at_gmt
items
next_cursor
has_more
terminal_evidence
```

## Tests

The standalone D boundary harness remains available:

```bash
php -l integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-index-feed.php
php -l integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-index-manifest-store.php
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-test.php
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
enumeration reference is introduced and that the catalog plugin is unchanged.

## Next slice

**M3-01/02E2 — atomic Woo membership capture** will supply source-consistent
synthetic-to-real identity rows at the source observation boundary. It owns
HPOS/legacy membership mechanics and source atomicity; E1 remains the durable
WordPress destination.
