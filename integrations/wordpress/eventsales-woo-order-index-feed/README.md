# EventSales Woo Order Index Feed

This plugin is the separate WordPress trust boundary for the future historical
WooCommerce order identity manifest. It authenticates a bounded source-side
scope and reserves the manifest creation/fetch routes required by the locked
M3-01/02C historical source enumeration contract.

The atomic identity manifest is deliberately not implemented in this slice.
The current boundary fails closed after authentication and request validation.

## Non-goals

This plugin does not:

- enumerate WooCommerce orders;
- page or offset through the standard WooCommerce REST collection;
- create, persist, expire, or garbage-collect a manifest;
- expose a manifest token, order identity, cursor, or terminal evidence;
- return full order payloads, customer data, billing/shipping data, payment
  data, totals, line items, notes, or raw WooCommerce JSON;
- write EventSales data or call `OrderUpserter`;
- implement webhooks, HPOS/legacy query adapters, or an EventSales client.

The existing `eventsales-tickera-catalog-feed` remains catalog-only and is not
modified by this plugin.

## Endpoints

Both routes are under the EventSales REST namespace:

```text
POST /wp-json/eventsales/v1/woo-order-index/manifests
GET  /wp-json/eventsales/v1/woo-order-index/manifests/{token}
```

The token route accepts an opaque-looking path token only so the later
manifest contract has a stable fetch boundary. It does not look up or create
state in this slice.

After successful authentication and validation, both routes return HTTP 501:

```json
{
  "error": "manifest_capability_unavailable",
  "schema_version": "2026-08-12.v1",
  "capability": "woo_order_index_manifest",
  "capability_status": "not_implemented"
}
```

This response contains no token, identities, cursor, `has_more`, or terminal
evidence. It is not a successful historical-boundary result.

Authentication failures return only `{"error":"unauthorized"}` with HTTP
401. Invalid requests return only `{"error":"invalid_request"}` with HTTP
400. A request whose combined raw body and encoded query exceeds the 16 KiB
boundary returns
`{"error":"request_too_large"}` with HTTP 413. No error response echoes
secrets, signatures, raw request bodies, or source/order data.

## Configuration and credential isolation

The order-index boundary has its own key ID and secret. It never falls back to
the catalog-feed secret.

Configure constants in `wp-config.php`:

```php
define('EVENTSALES_WOO_ORDER_INDEX_KEY_ID', 'replace-with-order-index-key-id');
define('EVENTSALES_WOO_ORDER_INDEX_SECRET', 'replace-with-a-long-random-secret');
```

Alternatively configure the separate WordPress options:

```bash
wp option update eventsales_woo_order_index_key_id 'replace-with-order-index-key-id'
wp option update eventsales_woo_order_index_secret 'replace-with-a-long-random-secret'
```

Constants take precedence over options. The catalog credential names are not
accepted:

```text
EVENTSALES_TICKERA_CATALOG_SECRET
eventsales_tickera_catalog_secret
```

Do not commit or log either credential.

## HMAC authentication

Every request must include:

```text
X-EventSales-Key-Id: <configured order-index key ID>
X-EventSales-Timestamp: <unix timestamp>
X-EventSales-Signature: v1=<64 lowercase hexadecimal characters>
```

The signature is HMAC-SHA256 with the order-index secret. Its exact canonical
input is:

```text
<uppercase HTTP method>
<request path including /wp-json>
query=<sorted RFC3986 query string>
body_sha256=<sha256 of the exact raw request body bytes>
timestamp=<timestamp header value>
key_id=<key ID header value>
```

The query string sorts parameter names lexicographically and percent-encodes
names and scalar values with RFC3986 encoding. Array/object query values are
authenticated as canonical JSON and then rejected by request validation when
they are not allowed. The body digest binds body tampering before validation.

Signature comparison uses `hash_equals`. The timestamp must be a strict
non-negative decimal Unix timestamp and must be within 300 seconds of the
WordPress clock. Missing/unknown key IDs, missing secrets, malformed
signatures, wrong secrets, and stale or future timestamps fail closed without
source work or source/order details.

## Manifest creation request validation

The creation body is a JSON object with exactly these fields:

```json
{
  "source_system": "wordpress_woo:source-scope",
  "backfill_start": "2026-08-01T00:00:00Z",
  "backfill_cutoff": "2026-08-12T00:00:00Z",
  "limit": 100
}
```

Rules:

- `source_system` is a non-empty bounded source-side scope string; the plugin
  does not invent or resolve EventSales database IDs;
- `backfill_start` (`B`) and `backfill_cutoff` (`C`) are strict UTC ISO8601
  values using `Z` (optional 1–6 digit fractional seconds);
- `B` must be less than or equal to `C`, and both are required, so an
  unbounded date request is rejected;
- `limit` must be a JSON integer from 1 through 100;
- arrays, objects, booleans, floats, malformed/natural-language dates, and
  unknown fields are rejected;
- query parameters are not accepted for creation, including `page`,
  `offset`, `total`, and other continuation/count controls;
- the combined raw body and encoded query are bounded to 16 KiB; this size
  check runs before HMAC hashing and validation.

The fetch route accepts only its bounded path token and no query parameters.
It also rejects `page` and `offset`; the token is not persisted or resolved
until the separately reviewed manifest slice.

## Future metadata-only response contract

The later manifest implementation may return at most 100 identity records per
page. Its versioned envelope is limited to:

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

Each `items` entry is limited to:

```text
source_order_id
source_created_at_gmt
source_modified_at_gmt
```

The future source contract must use opaque cursor/boundary metadata and
boundary-specific terminal evidence. It must not return total counts or treat
`items.length < limit` as terminal proof. It must not materialize full order
payloads or use standard Woo REST page/offset traversal to create the
manifest.

## Privacy and scaling guarantees

The size sanity check runs before authentication so oversized inputs cannot
force HMAC canonicalization. Authentication then runs before validation and
any future source work. This slice does no source database query, WooCommerce enumeration, caching, persistent
manifest state, Redis/ETS/Cachex access, or EventSales write. The only
credential scope is the order-index scope described above.

The current HTTP boundary enforces a 100-record future page maximum, a 16 KiB
combined body/query limit, finite explicit date bounds, no total-count option, no page or
offset continuation, and bounded error envelopes. The next manifest slice
will own source-consistent membership, bounded materialization, TTL/GC,
replayable cursors, and terminal evidence.

## Tests and next dependency

Run the standalone contract harness:

```bash
php -l integrations/wordpress/eventsales-woo-order-index-feed/eventsales-woo-order-index-feed.php
php -l integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-test.php
php integrations/wordpress/eventsales-woo-order-index-feed/tests/order-index-feed-test.php
```

The next dependency is **M3-01/02E atomic identity manifest**. That slice is
separately reviewed and must implement the source-consistent immutable
membership boundary before any historical Woo order identities are exposed.
