# EventSales Tickera Catalog Feed Contract Checks

Use these checks against a staging WordPress site with WooCommerce and Tickera installed.
Do not use production secrets or customer data while verifying the feed.

## Static Check

```bash
php -l integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php
```

Expected:

```text
No syntax errors detected in integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php
```

## Auth Checks

1. Request without `X-EventSales-Timestamp` and `X-EventSales-Signature`.
2. Request with timestamp skew greater than 300 seconds.
3. Request with a valid timestamp and an invalid `v1=` HMAC.

Expected for each:

```json
{"error":"unauthorized"}
```

HTTP status must be `401`.

## Query Validation Checks

Requests:

```text
GET /wp-json/eventsales/v1/tickera-catalog?product_id[]=1
GET /wp-json/eventsales/v1/tickera-catalog?updated_since=yesterday
GET /wp-json/eventsales/v1/tickera-catalog?page=0
GET /wp-json/eventsales/v1/tickera-catalog?per_page=501
GET /wp-json/eventsales/v1/tickera-catalog?variation_id=-1
```

Expected:

```json
{"error":"invalid_request","message":"Invalid <param>"}
```

HTTP status must be `400`.

## Full Feed Check

Request:

```text
GET /wp-json/eventsales/v1/tickera-catalog?page=1&per_page=100
```

Expected response fields:

```text
schema_version
source
source_snapshot_at
generated_at
page
per_page
has_more
filters
events
catalog_rows
```

Every `catalog_rows` item must include the VS-26A fields:

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

Every `events` item must include the safe event metadata fields:

```text
event_start_at
event_end_at
event_location
booking_fee_type
booking_fee_value
```

## Targeted Lookup Checks

Product lookup:

```text
GET /wp-json/eventsales/v1/tickera-catalog?product_id=109740
```

Variation lookup:

```text
GET /wp-json/eventsales/v1/tickera-catalog?variation_id=109741
```

Expected:

- The response is bounded to matching product or variation rows.
- Private, draft, subscription, payment-plan, variation, missing-event, and missing-template cases return `requires_review` and `review_reasons` instead of exposing raw WordPress data.

## Incremental Lookup Check

Request:

```text
GET /wp-json/eventsales/v1/tickera-catalog?updated_since=2026-07-05T10:00:00Z
```

Expected:

- Rows are included when the Tickera event, Woo product, or Woo variation changed after `updated_since`.
- Natural-language timestamps are rejected.

## Forbidden Data Check

Response bodies must not include:

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
webhook payloads
raw serialized provider payloads
ticket URLs
QR token hashes
delivery tokens
access codes
secrets
```
