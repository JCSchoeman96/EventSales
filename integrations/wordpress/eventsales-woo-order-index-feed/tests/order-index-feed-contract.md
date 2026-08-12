# Woo Order Index Feed — M3-01/02E1 Contract Checks

These checks cover the M3-01/02D authenticated boundary plus the E1 durable
manifest storage/lifecycle foundation. The database suite uses only the active
local WordPress MySQL service. It refuses non-loopback database hosts and never
prints the supplied local credentials.

## Locked boundary

```text
namespace       eventsales/v1
create route    POST /wp-json/eventsales/v1/woo-order-index/manifests
fetch route     GET /wp-json/eventsales/v1/woo-order-index/manifests/{token}
schema version  2026-08-12.v1
max page        100
request bound   16 KiB combined raw body + encoded query
timestamp skew  300 seconds
default TTL     24 hours
maximum TTL     7 days
```

## Local commands

The D-only boundary test remains database-independent:

```bash
php -l integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-index-feed.php
php -l integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-index-manifest-store.php
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-test.php
```

The E1 database test requires local-only environment variables:

```bash
EVENTSALES_WP_ROOT=/path/to/local/wordpress \
EVENTSALES_WP_DB_HOST=localhost:/path/to/local/mysql.sock \
EVENTSALES_WP_DB_NAME=local \
EVENTSALES_WP_DB_USER=root \
EVENTSALES_WP_DB_PASSWORD=<local-only-secret> \
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-db-test.php
```

The actual local run uses the loopback WordPress database only. No production,
remote staging, EventSales Postgres, Redis, or WooCommerce source endpoint is
part of this test.

## Authentication and POST

Required headers remain:

```text
X-EventSales-Key-Id
X-EventSales-Timestamp
X-EventSales-Signature
```

The HMAC-SHA256 base string remains:

```text
<METHOD>
<PATH>
query=<canonical RFC3986 query>
body_sha256=<sha256(raw body bytes)>
timestamp=<timestamp>
key_id=<key ID>
```

The catalog credential cannot authenticate this boundary. The tests cover
missing/malformed credentials, unknown key IDs, wrong secrets, stale/future
timestamps, body/query tampering, malformed JSON, and request-size rejection.

POST continues to return HTTP 501 with
`manifest_capability_unavailable`. It never generates a token, creates a
manifest, queries WooCommerce, or returns source identities.

## Schema and database invariants

The store creates these prefixed InnoDB tables idempotently:

```text
{$wpdb->prefix}eventsales_order_manifests
{$wpdb->prefix}eventsales_order_manifest_items
```

The tests prove the required header fields and identity-only item fields,
unique token hash, `(status, expires_at_gmt)` cleanup index, primary
`(manifest_id, sequence)` paging key, and unique `(manifest_id,
source_order_id)` identity constraint.

Database triggers prove:

- only BUILDING manifests accept item inserts;
- BUILDING items are append-only;
- READY item insert/update/delete is rejected;
- READY membership-defining header mutation and deletion are rejected;
- FAILED and EXPIRED rows cannot be reopened;
- promotion to READY requires non-null terminal metadata and complete
  contiguous stored sequence invariants.

The application API also locks the header for every bounded append batch and
performs a short locked promotion after its streaming integrity pass. No
partially populated READY manifest is exposed.

## Lifecycle and expiry

The only states are:

```text
building
ready
expired
failed
```

BUILDING and FAILED manifests return no membership. READY is immutable and
readable only while unexpired. Expiry validation is mandatory on reads and
promotion; reads do not renew `expires_at_gmt`. `garbage_collect($batch_size)`
deletes at most 100 expired/failed/abandoned rows per call through indexed
status/expiry selection. Active READY manifests are retained.

## Token and cursor checks

Tokens use `bin2hex(random_bytes(32))` and are at least 128-bit entropy. The
manifest token is an opaque boundary/lookup identifier, not a standalone access
authority. The raw token is not stored in the header; only `sha256(raw_token)`
is persisted as defense-in-depth. Surrounding HTTP infrastructure may record
URLs, so HMAC order-index authentication remains mandatory before membership is
returned. The plugin does not deliberately log the raw token or echo it in
error bodies. Unknown tokens and all lifecycle errors fail closed without
exposing credentials.

GET cursors are not offsets. They contain an authenticated last sequence and
the exact manifest token hash. The domain-separated HMAC input is:

```text
eventsales/woo-order-index/cursor/v1
<newline>
<canonical cursor payload>
```

The existing order-index secret signs the cursor. The tests prove deterministic
sequence paging, maximum 100 records, same-cursor replay, cursor tamper
rejection, and cursor rejection when presented for another manifest. No total
count or short-page terminal assumption is used.

## Hash and terminal evidence

The final SHA-256 hash includes canonical deterministic evidence for:

```text
schema_version
source_system
backfill_start_gmt (B)
backfill_cutoff_gmt (C)
source_observed_at_gmt (D)
membership_predicate_version
item_count
ordered sequence, source_order_id, source_created_at_gmt,
source_modified_at_gmt records
```

The raw token, secret, current replay wall-clock, and full order payloads are
excluded. The stored terminal evidence is stable across replay and is returned
only from the finalized header on terminal HTTP pages. Nonterminal HTTP pages
omit `terminal_evidence`; a short page is not terminal proof.

## Privacy, performance, and source boundary

Items contain only source order identity plus the two observed timestamps. The
implementation uses bounded append/hash/read batches, the indexed sequence
keyset, a maximum 100-item HTTP response, and no total-count query. It does
not materialize a full order payload or require a giant PHP array.

The source scan is intentionally absent. The tests reject any implementation
reference to `wc_get_orders`, `wc_get_order`, `WP_Query`, direct Woo order
membership SQL, or Woo REST pagination. HPOS and legacy membership capture are
not started. M3-01/02E2 owns atomic source membership observation.

The Tickera catalog plugin remains byte-for-byte unchanged.
