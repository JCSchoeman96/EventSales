# EventSales Tickera Catalog Feed Contract Checks

The producer emits native `2026-08-07.v3` pages. Live staging checks below now
target v3. Phoenix still parses `2026-07-22.v2`, `2026-07-08.v1`, and
`2026-07-05.v1` so a rollback to an older plugin build stays consumable; the v2
notes are kept at the end of this document as historical context.

Use these checks against a local or staging WordPress site with WooCommerce and
Tickera installed. Do not use production secrets or customer data while
verifying the feed.

## Locked constants

```text
schema_version              2026-08-07.v3
canonical_contract_version  source_risk.v3
producer_version            2026-08-07.1
source                      wordpress_tickera
rest namespace              eventsales/v1
rest route                  /tickera-catalog
snapshot generation option  eventsales_tickera_catalog_snapshot_generation
transient cache version     eventsales_tickera_catalog_feed_cache_version
native max per_page         100
max evidence per page       500
max catalog_rows per page   100
```

## Local checks

```bash
php -l integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php
php integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-feed-test.php
php integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-change-trigger-test.php
```

Expected:

```text
No syntax errors detected in integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php
catalog feed native v3 tests passed: <n> assertions, 0 failures
catalog change trigger tests passed: <n> assertions, 0 failures
```

## Auth Checks

Authentication and the signature protocol are unchanged by v3.

1. Request without `X-EventSales-Timestamp` and `X-EventSales-Signature`.
2. Request with timestamp skew greater than 300 seconds.
3. Request with a valid timestamp and an invalid `v1=` HMAC.

Expected for each:

```json
{"error":"unauthorized"}
```

HTTP status must be `401`.

The signed base string remains:

```text
<METHOD>\n<PATH>\n<CANONICAL_QUERY>\n<TIMESTAMP>
```

## Query Validation Checks

Requests:

```text
GET /wp-json/eventsales/v1/tickera-catalog?product_id[]=1
GET /wp-json/eventsales/v1/tickera-catalog?updated_since=yesterday
GET /wp-json/eventsales/v1/tickera-catalog?page=0
GET /wp-json/eventsales/v1/tickera-catalog?per_page=101
GET /wp-json/eventsales/v1/tickera-catalog?per_page=501
GET /wp-json/eventsales/v1/tickera-catalog?variation_id=-1
```

Expected:

```json
{"error":"invalid_request","message":"Invalid <param>"}
```

HTTP status must be `400`.

Native `per_page` is bounded to `1..100`. The legacy `2026-07-22.v2` bound of
`500` is never applied to a v3 page.

## Native envelope

Request:

```text
GET /wp-json/eventsales/v1/tickera-catalog?page=1&per_page=100
```

The response body contains exactly these fifteen keys and no others:

```text
schema_version
canonical_contract_version
producer_version
source
source_system_id
discovery_snapshot_id
source_snapshot_at
generated_at
page
per_page
has_more
filters
events
catalog_rows
evidence
```

`filters` contains exactly these keys:

```text
updated_since
product_id
variation_id
event_id
include_private
```

`page`, `per_page`, and any cursor state are never part of `filters`.

## SnapshotGeneration

The producer stores one option, `eventsales_tickera_catalog_snapshot_generation`,
holding:

```text
generation_token   opaque lowercase hex, at least 32 characters
generation_at      RFC3339 UTC with a trailing Z
```

Rules:

```text
The record is read, or created when missing or malformed.
Every catalogue-relevant invalidation replaces the whole record.
The token is random. It is never a counter and never derived from the old token.
Equality is compared on generation_token AND generation_at together.
```

Invalidation paths that bump the transient cache version and rotate the
SnapshotGeneration record:

```text
invalidate_cache()
invalidate_and_record()          via invalidate_cache()
save_post_product                via invalidate_cache()
save_post_product_variation      via invalidate_cache()
save_post_tc_events              via invalidate_cache()
transition_post_status
added_post_meta / updated_post_meta / deleted_post_meta on watched keys
trashed_post / untrashed_post / before_delete_post
```

`eventsales_tickera_catalog_feed_cache_version` remains transient-only cache
bookkeeping and is a separate option from the SnapshotGeneration record.

Verification on a live site:

```text
1. Read both options.
2. Save a ticket product.
3. Read both options again.
4. The cache version increased by one and the generation_token changed.
```

## Snapshot timestamps

```text
source_snapshot_at   equals generation_at exactly, for every page of a run
generated_at         page materialization time, may differ per page
```

## Mid-page generation check

Each page reads the SnapshotGeneration record before building the body and again
after. If either the token or `generation_at` changed, the page fails closed
with HTTP `500` and no body is emitted. A page materialized across a catalogue
change is never returned.

## source_system_id

Derive-only. There is no override constant, option, or filter.

```text
home              = normalize(home_url())
source_system_id  = "wordpress_tickera:" + sha256_hex(home)
```

URL normalization:

```text
lowercase scheme and host
strip a default port (:80 for http, :443 for https)
preserve a non-default port
strip trailing slashes from the path
preserve a meaningful path
drop the query string and fragment
```

This matches `DiscoveryIntegrity.normalize_base_url/1` on the Phoenix side, so
`verify_source_system_id/2` succeeds against the registered SourceSystem
`base_url`.

## discovery_snapshot_id

```text
discovery_snapshot_id = sha256_hex(canonical_json({
  schema_version,
  canonical_contract_version,
  producer_version,
  source,
  source_system_id,
  generation_token,
  filters
}))
```

Canonical JSON:

```text
object keys sorted lexicographically, recursively
null encoded explicitly
booleans as true / false
integers as integers
UTF-8, unescaped slashes
no insignificant whitespace
```

`page`, `per_page`, and cursor state are never inputs to snapshot identity, so
every page of one run carries the same `discovery_snapshot_id`.

## Cached pages

Transient pages are keyed on the cache version, the SnapshotGeneration token,
the generation timestamp, and the validated query parameters. A rotated
generation can never serve a page that was materialized under the previous
generation. Cache TTL bounds are unchanged: default 120 seconds, clamped to
30..300 seconds.

## Typed evidence

Every `evidence` item has exactly these keys, with `value` present only when the
observation carries one:

```text
dimension
producer_scope
target
state
producer_source_key
completeness
provenance
value?
```

Policy fields are never emitted by the producer:

```text
origin
authority
authority_slot
translation_rule_id
alias_id
severity
disposition
qualified_finding_id
automation_eligible
```

`provenance` uses this allowlist only:

```text
discovery_snapshot_id
producer_version
producer_source_key
raw_producer_code
woo_product_id
woo_variation_id
tickera_event_id
```

Target maps use positive integers and the exact key set for the scope:

```text
event                        tickera_event_id
parent_product               woo_product_id
variation                    woo_variation_id + woo_product_id
event_product_relationship   woo_product_id
```

`producer_source_key` per dimension:

```text
lifecycle                              wp_posts.post_status
ticket_template                        postmeta:_ticket_template
event_link                             postmeta:_event_name+tc_events.resolve
subscription                           wc_product_type+subscription_evidence
product_type                           wc_get_product.type
payment_plan/membership/bundle/add_on  product_semantics_capability
```

`event_link` uses the fully qualified `postmeta:_event_name+tc_events.resolve`
key because `ContractRegistry.producer_source_key_for_authority/1` requires an
exact match for `auth.event_name_meta`.

### Emitted dimension states

```text
lifecycle        event | parent_product | variation
                 present with publish|private|draft|trash|deleted
                 missing when the status was not observed
                 invalid for any undeclared WordPress status, raw code in provenance

ticket_template  parent_product
                 present with the template id
                 absent after an exhaustive no-reference observation
                 invalid when the stored value exceeds the value bound

event_link       event_product_relationship
                 present with the resolved tickera_event_id as an integer value
                 invalid when a reference exists but does not resolve
                 absent only after an exhaustive no-reference observation

subscription     parent_product
                 present for a positive subscription signal, no value
                 unknown otherwise; absent is never claimed

product_type     parent_product
                 present only with the supported value simple
                 unsupported for any other declared type, raw code in provenance
                 unknown when the type cannot be observed

payment_plan
membership
bundle
add_on           parent_product
                 unsupported only, value null, never present or absent
```

### Completeness policy

```text
exhaustive   direct closed-authority reads and exhaustive no-reference proofs
             (lifecycle present/invalid, ticket_template, event_link, product_type
             present/unsupported)
partial      lifecycle missing, subscription present
unknown      product_type unknown, subscription unknown, all capability dimensions
```

### Variation observations

A variation lifecycle claim is always the variation's own `post_status`. Parent
status is never copied onto a variation. A variation target always carries both
`woo_variation_id` and `woo_product_id`.

### Deduplication and bounds

Parent-level and event-level observations repeat across the variation rows of the
same product on one page. The producer emits each
`(dimension, producer_scope, target)` identity once per page. All values behind a
deduplicated identity come from the same aggregated SQL columns, so no
observation is lost.

If a page would exceed 500 evidence items the producer fails closed with HTTP
`500`. Evidence is never truncated. A page of fully distinct
product/variation/event triples costs eleven items per row, so choose a
`per_page` that fits the bound; `per_page=45` is safe in the worst case, and
larger pages are safe when products share events or carry several variations.

## Structural transport rows

`events` and `catalog_rows` keep their existing structural fields. On native
pages the legacy row fields, including `risk_codes`, `review_reasons`,
`product_semantics`, and `target_observation`, are non-authoritative
diagnostics. Native `evidence` is the only source-risk authority.

Every `catalog_rows` item still includes:

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
product_status_classification
product_source_updated_at
ticket_display_name
price
regular_price
ticket_template_id
woo_variation_id
variation_title
variation_status
variation_status_classification
variation_source_updated_at
product_type
ticket_template_present
subscription_classification
product_semantics
target_observation
risk_codes
is_subscription
subscription_period
subscription_length
requires_review
review_reasons
```

Every `events` item still includes:

```text
tickera_event_id
event_title
event_slug
event_status
event_status_classification
target_observation
risk_codes
event_source_updated_at
event_start_at
event_end_at
event_location
booking_fee_type
booking_fee_value
linked_ticket_products
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
- `filters` echoes the applied identifiers, so `discovery_snapshot_id` differs
  from a full-catalogue run.
- Private, draft, subscription, unsupported-type, variation, missing-event, and
  missing-template cases are expressed as typed evidence rather than raw
  WordPress data.

## Incremental Lookup Check

Request:

```text
GET /wp-json/eventsales/v1/tickera-catalog?updated_since=2026-07-05T10:00:00Z
```

Expected:

- Rows are included when the Tickera event, Woo product, or Woo variation
  changed after `updated_since`.
- Natural-language timestamps are rejected.
- `filters.updated_since` is echoed as RFC3339 UTC with a trailing `Z`.

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

## Historical: 2026-07-22.v2 notes

Kept for rollback context only. Phoenix still parses these pages and routes them
to `legacy_v2_operational`; they are never native evidence.

The v2 envelope carried:

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

`2026-07-22.v2` was the only legacy feed version capable of supplying auto-Apply
risk proof. The Human-only `2026-07-08.v1` and `2026-07-05.v1` schemas remain
parseable but were never automation eligible. v2 `per_page` was bounded to
`1..500`.

Every v2 catalog row carried deterministic, bounded risk fields:

```text
product_status_classification
variation_status_classification
product_type
ticket_template_present
subscription_classification
product_semantics
target_observation
risk_codes
```

`product_semantics` contained the closed keys `payment_plan`, `membership`,
`bundle`, and `add_on`. Until a deterministic reviewed source existed, each was
`unknown` and `risk_codes` included `unknown_product_semantics`; names, slugs,
descriptions, categories, and arbitrary metadata keys were never used to infer
them. Native v3 replaces these row-level classifications with typed
capability evidence in the `unsupported` state.
