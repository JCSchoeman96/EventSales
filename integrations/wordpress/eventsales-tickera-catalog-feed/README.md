# EventSales Tickera Catalog Feed

WordPress plugin artifact for VS-26C. It exposes a sanitized Tickera/WooCommerce catalog feed that EventSales can consume in a later adapter slice.

This plugin does not send order, customer, payment, webhook, ticket delivery, QR, token, or raw provider payload data.

## Endpoint

```text
GET /wp-json/eventsales/v1/tickera-catalog
```

## Install

1. Copy `eventsales-tickera-catalog-feed` into the WordPress `wp-content/plugins/` directory.
2. Configure the shared secret.
3. Activate **EventSales Tickera Catalog Feed** in WordPress.
4. Verify the endpoint with an authenticated request.

## Configuration

Set the secret with a constant in `wp-config.php`:

```php
define('EVENTSALES_TICKERA_CATALOG_SECRET', 'replace-with-a-long-random-secret');
```

Alternatively, set the WordPress option:

```bash
wp option update eventsales_tickera_catalog_secret 'replace-with-a-long-random-secret'
```

The constant wins when both are present.

Cache TTL defaults to 120 seconds and is clamped to 30-300 seconds:

```php
define('EVENTSALES_TICKERA_CATALOG_CACHE_TTL', 120);
```

or:

```bash
wp option update eventsales_tickera_catalog_cache_ttl 120
```

## Authentication

Required headers:

```text
X-EventSales-Timestamp: <unix timestamp>
X-EventSales-Signature: v1=<hex_hmac_sha256>
```

Signature base string:

```text
METHOD + "\n" +
PATH + "\n" +
CANONICAL_QUERY + "\n" +
TIMESTAMP
```

Example base string:

```text
GET
/wp-json/eventsales/v1/tickera-catalog
page=1&per_page=100&product_id=109740
1780000000
```

Rules:

- Timestamp skew greater than 300 seconds is rejected.
- Query params are sorted by key and percent-encoded with RFC3986 encoding.
- Signature format is `v1=<64 hex chars>`.
- The plugin uses `hash_equals`.
- The plugin never logs the secret, full signature, headers, or raw payloads.

## Query Params

```text
updated_since    optional strict ISO8601/RFC3339 datetime
product_id       optional positive integer
variation_id     optional positive integer
event_id         optional positive integer
page             optional positive integer, default 1
per_page         optional positive integer, default 100, max 500
include_private  optional boolean, default false
```

Array/object query params are rejected with `400 invalid_request`. Natural-language dates such as `yesterday` are rejected.

## Example Signing Helper

```bash
SECRET='replace-with-a-long-random-secret'
METHOD='GET'
PATH='/wp-json/eventsales/v1/tickera-catalog'
QUERY='page=1&per_page=100'
TIMESTAMP="$(date +%s)"
BASE="${METHOD}
${PATH}
${QUERY}
${TIMESTAMP}"
SIGNATURE="v1=$(printf '%s' "$BASE" | openssl dgst -sha256 -hmac "$SECRET" -hex | awk '{print $2}')"

curl -sS "https://example.test${PATH}?${QUERY}" \
  -H "X-EventSales-Timestamp: ${TIMESTAMP}" \
  -H "X-EventSales-Signature: ${SIGNATURE}"
```

## Example Requests

Full feed:

```text
GET /wp-json/eventsales/v1/tickera-catalog?page=1&per_page=100
```

Target product:

```text
GET /wp-json/eventsales/v1/tickera-catalog?product_id=109740
```

Target variation:

```text
GET /wp-json/eventsales/v1/tickera-catalog?variation_id=109741
```

Incremental lookup:

```text
GET /wp-json/eventsales/v1/tickera-catalog?updated_since=2026-07-05T10:00:00Z
```

Unauthorized response:

```json
{"error":"unauthorized"}
```

## Response Shape

```json
{
  "schema_version": "2026-07-05.v1",
  "source": "wordpress_tickera",
  "source_snapshot_at": "2026-07-05T10:00:00Z",
  "generated_at": "2026-07-05T10:00:00Z",
  "page": 1,
  "per_page": 100,
  "has_more": false,
  "filters": {
    "updated_since": null,
    "product_id": null,
    "variation_id": null,
    "event_id": null,
    "include_private": false
  },
  "events": [],
  "catalog_rows": []
}
```

`catalog_rows` preserves the EventSales VS-26A manual discovery field names and adds review hints:

```text
product_type
is_subscription
subscription_period
subscription_length
requires_review
review_reasons
```

## Pagination Note

For full-feed pagination, the future VS-26D EventSales adapter must fetch all pages and aggregate `events` and `catalog_rows` before passing them to the EventSales catalog planner/normalizer. Page-at-a-time normalization can create false `published_event_without_ticket_products` findings.

## Cache

Successful authorized responses are cached with WordPress transients. Cache keys include:

```text
schema_version
updated_since
product_id
variation_id
event_id
page
per_page
include_private
```

The plugin increments a cache-version option on:

```text
save_post_product
save_post_product_variation
save_post_tc_events
```

## Manual Verification

Run syntax validation from the EventSales repo:

```bash
php -l integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php
```

Then follow `tests/catalog-feed-contract.md` against a staging WordPress site.

## Non-Goals

- No EventSales HTTP discovery adapter.
- No auto-apply.
- No order webhook shaping.
- No OrderUpserter changes.
- No MappingResolver changes.
- No sales parser changes.
- No dashboard or unmapped alert UI.
- No Woo order catch-up sync.
- No Phoenix runtime changes.
