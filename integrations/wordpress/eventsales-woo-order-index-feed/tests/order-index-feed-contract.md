# Woo Order Index Feed Boundary Contract Checks

These checks validate the M3-01/02D WordPress boundary without connecting to
WordPress, WooCommerce, a database, production credentials, or an EventSales
runtime.

## Locked boundary

```text
namespace       eventsales/v1
create route    POST /wp-json/eventsales/v1/woo-order-index/manifests
fetch route     GET /wp-json/eventsales/v1/woo-order-index/manifests/{token}
schema version  2026-08-12.v1
max limit       100
request bound   16 KiB combined raw body + encoded query
timestamp skew  300 seconds
```

The plugin uses only these credential scopes:

```text
EVENTSALES_WOO_ORDER_INDEX_KEY_ID
EVENTSALES_WOO_ORDER_INDEX_SECRET
eventsales_woo_order_index_key_id
eventsales_woo_order_index_secret
```

The catalog-feed credential is not an accepted fallback.

## Local commands

```bash
php -l integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-index-feed.php
php -l integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-test.php
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-test.php
```

Expected result:

```text
No syntax errors detected in .../eventsales-woo-order-index-feed.php
No syntax errors detected in .../order-index-feed-test.php
order-index feed tests passed: <n> assertions, 0 failures
```

## Authentication checks

Required headers:

```text
X-EventSales-Key-Id
X-EventSales-Timestamp
X-EventSales-Signature
```

The HMAC-SHA256 base string is:

```text
<METHOD>
<PATH>
query=<canonical RFC3986 query>
body_sha256=<sha256(raw body bytes)>
timestamp=<timestamp>
key_id=<key ID>
```

The signature header is `v1=<64 lowercase hex characters>`. The test harness
proves:

- valid signatures reach the authenticated capability result;
- missing and malformed signatures are HTTP 401;
- unknown key IDs, missing order-index secrets, stale timestamps, excessive
  future timestamps, and wrong secrets are HTTP 401;
- body and canonical-query tampering invalidates the signature;
- the catalog-feed secret cannot authenticate this route.

Authentication errors have the bounded body:

```json
{"error":"unauthorized"}
```

They do not disclose source/order information, credentials, signatures, or
raw request data.

## Validation checks

Manifest creation accepts only a JSON object with exactly:

```text
source_system
backfill_start
backfill_cutoff
limit
```

`backfill_start` (`B`) and `backfill_cutoff` (`C`) must be strict UTC `Z`
timestamps, with `B <= C`. `limit` is an integer in `1..100`. The test
harness proves rejection of:

- `B > C`, malformed and natural-language dates, and UTC offsets;
- limits `0`, `101`, strings, arrays, and objects;
- arrays/objects in scalar fields;
- `page`, `offset`, and total-count query controls;
- unknown body fields and missing date bounds;
- malformed JSON and body/query envelopes larger than 16 KiB, rejected before
  HMAC canonicalization.

The fetch route accepts only a bounded token path parameter and no query
parameters. It does not accept page or offset continuation.

## Privacy and fail-closed checks

The future response contract is closed to the following envelope fields only:

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

Future identity items are limited to:

```text
source_order_id
source_created_at_gmt
source_modified_at_gmt
```

The current authenticated response is always HTTP 501:

```json
{
  "error": "manifest_capability_unavailable",
  "schema_version": "2026-08-12.v1",
  "capability": "woo_order_index_manifest",
  "capability_status": "not_implemented"
}
```

The test harness proves that authenticated creation and fetch:

- never call standard Woo REST pagination or full-order retrieval;
- never create a fake token or return an order ID;
- never return a cursor, `has_more`, or terminal evidence;
- never echo customer, payment, billing, shipping, totals, line items,
  notes, raw Woo payload, secret, or signature fields;
- do not persist manifest state or use `$wpdb`, `WP_Query`, transients,
  `update_option`, Redis, ETS, or Cachex;
- leave the existing Tickera catalog plugin byte-for-byte unchanged.

This is an unavailable capability result, not a historical-boundary success or
terminal proof.

## Explicit non-coverage

The following remain for M3-01/02E or later reviewed slices:

- atomic source-consistent identity membership;
- manifest persistence, TTL, replay, terminal evidence, and GC;
- HPOS or legacy query adapters;
- Woo order enumeration or full-order retrieval;
- EventSales client, `SyncRun`, `SyncCursor`, migrations, Ash resources,
  webhooks, refunds, attribution, or analytics readiness.
