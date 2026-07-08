# Tickera Catalog Feed Contract

VS-26C adds a WordPress-side catalog feed for EventSales discovery. The feed is a sanitized source contract only. EventSales will consume it in VS-26D through a separate adapter.

## Endpoint

```text
GET /wp-json/eventsales/v1/tickera-catalog
```

Source:

```text
wordpress_tickera
```

Schema version:

```text
2026-07-08.v1
```

Rollout compatibility:

```text
EventSales temporarily accepts 2026-07-05.v1 while the WordPress plugin is being
upgraded. Legacy feeds do not include event metadata, so EventSales treats the
new event fields as nil until the feed returns 2026-07-08.v1.
```

## Authentication

Requests must include:

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

Rules:

- `METHOD` is uppercase.
- `PATH` is `/wp-json/eventsales/v1/tickera-catalog`.
- `CANONICAL_QUERY` is scalar query params sorted by key and RFC3986 percent-encoded.
- Timestamp skew greater than 300 seconds returns `401`.
- Signature format is `v1=<64 hex chars>`.
- Secrets may come from `EVENTSALES_TICKERA_CATALOG_SECRET` or the WordPress option `eventsales_tickera_catalog_secret`.
- Secrets, full signatures, raw headers, and raw request payloads must not be logged.

Auth failure:

```json
{"error":"unauthorized"}
```

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

Validation:

- Reject array/object query params.
- Reject natural-language `updated_since` values.
- Reject `page < 1`.
- Reject `per_page < 1` or `per_page > 500`.
- Reject non-positive IDs.

Invalid request:

```json
{
  "error": "invalid_request",
  "message": "Invalid product_id"
}
```

## Response Envelope

```json
{
  "schema_version": "2026-07-08.v1",
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

The compatibility fields for VS-26A are:

```text
source_snapshot_at
events
catalog_rows
```

## Event Fields

Each `events` item contains:

```text
tickera_event_id
event_title
event_slug
event_status
event_source_updated_at
event_start_at
event_end_at
event_location
booking_fee_type
booking_fee_value
linked_ticket_products
```

Default mode returns published Tickera events. Targeted lookups and `include_private=true` may include non-published events so later EventSales logic can review or skip them.

## Catalog Row Fields

Each `catalog_rows` item contains the VS-26A-compatible fields:

```text
tickera_event_id
event_title
event_slug
event_status
event_source_updated_at
woo_product_id
product_title
product_slug
product_status
product_source_updated_at
ticket_display_name
price
regular_price
ticket_template_id
woo_variation_id
variation_title
variation_status
variation_source_updated_at
```

Additional review fields:

```text
product_type
is_subscription
subscription_period
subscription_length
requires_review
review_reasons
```

Nulls are allowed for missing event and variation fields. Timestamps are UTC ISO8601 strings ending in `Z`.

Event metadata comes only from the safe Tickera event postmeta allowlist:

```text
booking_fee_type
booking_fee_value
event_date_time
event_end_date_time
event_location
```

Booking fee values are reported only as source metadata. They must not be used for checkout, revenue math, tax/VAT treatment, or reconciliation in this contract.

## Source Relationship

The plugin uses WordPress table handles, not hardcoded prefixes:

```text
$wpdb->posts
$wpdb->postmeta
```

Relationship:

```text
tc_events.ID
  <- product postmeta _event_name
Woo product.ID
  <- product postmeta _tc_is_ticket = yes
Optional variation.ID
  <- product_variation child rows under the Woo product
```

Duplicate postmeta rows are collapsed by grouping on:

```text
tickera_event_id + woo_product_id + woo_variation_id
```

Price is not part of identity.

## Filtering Behavior

Default full feed:

- published Tickera events
- published Woo ticket products
- published variations when present

Targeted `product_id` or `variation_id` lookup:

- returns the requested product or variation rows
- may return private/draft/problem rows
- uses review flags instead of silently dropping missing/private/draft relationships

`updated_since`:

- includes a row when the Tickera event, Woo product, or Woo variation `post_modified_gmt` is after the supplied timestamp
- requires strict ISO8601/RFC3339 input

## Full-Feed Pagination Rule

VS-26D must fetch all pages and aggregate `events` and `catalog_rows` before passing data to the EventSales catalog planner/normalizer.

Do not normalize one full-feed page at a time. The EventSales normalizer can report `published_event_without_ticket_products` if it sees an event on one page while the related product rows are on another page.

Targeted lookups may be normalized independently because their filters intentionally narrow the result set.

## Review Reasons

```text
private_product
private_event
draft_product
draft_event
subscription_product
payment_plan_product
variation_mapping_required
missing_tickera_event
missing_ticket_template
```

These reasons are advisory. The WordPress plugin reports facts and review hints only. EventSales mapping decisions remain in later slices.

## Caching

Successful authorized responses are cached with WordPress transients.

TTL:

```text
default 120 seconds
minimum 30 seconds
maximum 300 seconds
```

Cache key inputs:

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

Invalidation increments `eventsales_tickera_catalog_feed_cache_version` on:

```text
save_post_product
save_post_product_variation
save_post_tc_events
```

Auth failures and invalid requests are not cached.

## Forbidden Data

The feed must never select or return:

```text
customer names
emails
phone numbers
billing/shipping addresses
orders
order item IDs
payment methods
transaction IDs
Paystack data
Woo webhook payloads
raw serialized provider payloads
ticket URLs
QR token hashes
delivery tokens
access codes
secrets
```

## Example Full Feed Response

```json
{
  "schema_version": "2026-07-08.v1",
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
  "events": [
    {
      "tickera_event_id": 109316,
      "event_title": "Vroue wat Glo-retreat - PTA",
      "event_slug": "vroue-wat-glo-retreat-pta",
      "event_status": "publish",
      "event_source_updated_at": "2026-06-01T10:00:00Z",
      "event_start_at": "2026-08-01T16:00:00Z",
      "event_end_at": "2026-08-01T18:00:00Z",
      "event_location": "Pretoria",
      "booking_fee_type": "fixed",
      "booking_fee_value": "25.00",
      "linked_ticket_products": 1
    }
  ],
  "catalog_rows": [
    {
      "tickera_event_id": 109316,
      "event_title": "Vroue wat Glo-retreat - PTA",
      "event_slug": "vroue-wat-glo-retreat-pta",
      "event_status": "publish",
      "event_source_updated_at": "2026-06-01T10:00:00Z",
      "woo_product_id": 109740,
      "product_title": "VWG - Pretoria",
      "product_slug": "vwg-pretoria",
      "product_status": "publish",
      "product_source_updated_at": "2026-06-01T10:05:00Z",
      "ticket_display_name": "Toegang",
      "price": "199",
      "regular_price": "199",
      "ticket_template_id": "103945",
      "woo_variation_id": null,
      "variation_title": null,
      "variation_status": null,
      "variation_source_updated_at": null,
      "product_type": "simple",
      "is_subscription": false,
      "subscription_period": null,
      "subscription_length": null,
      "requires_review": false,
      "review_reasons": []
    }
  ]
}
```

## Example Targeted Product Lookup

```text
GET /wp-json/eventsales/v1/tickera-catalog?product_id=109740
```

The response contains matching rows for product `109740`. If the product is private, draft, subscription-like, missing its Tickera event, or missing its ticket template, the row remains sanitized and includes `requires_review: true`.

## Example Targeted Variation Lookup

```text
GET /wp-json/eventsales/v1/tickera-catalog?variation_id=109741
```

The response contains the parent Woo product and matching variation row. Variation rows include `variation_mapping_required`.

## Example Incremental Lookup

```text
GET /wp-json/eventsales/v1/tickera-catalog?updated_since=2026-07-05T10:00:00Z
```

The response includes rows where the event, product, or variation changed after the supplied timestamp.

## Example Unauthorized Response

```json
{"error":"unauthorized"}
```
