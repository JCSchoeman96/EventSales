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
                 present with the template id, up to 64 bytes
                 absent only when the _ticket_template meta row is genuinely
                 missing (SQL NULL), never when an empty or whitespace value
                 was observed
                 invalid when the meta row exists but the raw value is empty
                 or whitespace-only; preserve the exact raw_producer_code
                 including ""
                 a stored value over 64 bytes or invalid UTF-8 fails the page
                 closed rather than emitting invalid, because the value bound
                 and the raw bound are both 64 bytes of valid UTF-8

event_link       event_product_relationship
                 present only when the raw _event_name is a positive integer AND
                 parses to exactly the resolved tickera_event_id
                 invalid for empty, whitespace-only, malformed, non-positive,
                 unresolved, or disagreeing references, raw code in provenance
                 (including raw_producer_code="")
                 absent only when _event_name is genuinely missing (SQL NULL)
                 and no event resolved; an existing empty meta row is never
                 absent
                 producer_error when an event resolved with no raw reference

subscription     parent_product
                 present for a positive subscription signal, no value
                 unknown otherwise; absent is never claimed

product_type     parent_product
                 present only with the supported value simple
                 invalid for an observed but undeclared runtime type such as
                 variable, grouped, or external, raw code in provenance
                 unsupported when no type could be observed at all, no raw code

payment_plan
membership
bundle
add_on           parent_product
                 unsupported only, value null, never present or absent
```

`invalid` and `unsupported` are not interchangeable. `invalid` means the producer
made a real observation that the closed contract rejects, so the raw token is
always carried in `raw_producer_code`. `unsupported` means the producer could not
evaluate the dimension at all, so there is nothing raw to carry. An undeclared
`product_type` such as `variable` is therefore `invalid`, never `unsupported`.

### ticket_template absence matrix

```text
SQL / raw observation              state
meta row absent (NULL)             absent
meta row exists, value ""          invalid, raw_producer_code=""
meta row exists, whitespace only   invalid, exact raw preserved
meta row exists, valid <=64 bytes  present, value=<trimmed id>
meta row exists, value >64 bytes   page fail closed
meta row exists, invalid UTF-8     page fail closed
```

Empty string is never classified as `absent`. Native evidence reads the raw SQL
`_ticket_template` observation separately from the legacy normalized structural
`ticket_template_id` (which still collapses empty → null for diagnostics only).

### event_link resolution matrix

```text
raw           resolved event_id   state
55501         55501               present, value 55501
"  55501  "   55501               present, value 55501 (trimmed)
""            nil                 invalid, raw_producer_code=""
" "           nil                 invalid, exact whitespace preserved
55501         nil                 invalid, raw_producer_code 55501
55501         55502               invalid, raw_producer_code 55501
55501abc      55501               invalid, raw_producer_code 55501abc
abc           nil                 invalid, raw_producer_code abc
0 | -1        nil                 invalid, raw code preserved
nil           nil                 absent
nil           55501               producer_error
```

Absence means the `_event_name` meta row does not exist. An existing empty or
whitespace meta value is `invalid`, never `absent`.

The `55501abc` row is the reason the producer never trusts the SQL join alone:
MySQL `CAST('55501abc' AS UNSIGNED)` yields `55501`, which would fabricate a
relationship that does not exist in the source. The raw reference is re-parsed in
PHP and must equal the resolved id before `present` is claimed.

### Completeness policy

```text
exhaustive   direct closed-authority reads and exhaustive no-reference proofs
             (lifecycle present/invalid, ticket_template present/absent,
             event_link present/absent/invalid, product_type present/invalid)
partial      lifecycle missing, subscription present
unknown      product_type unsupported, event_link producer_error,
             subscription unknown, all capability dimensions
```

### Variation observations

A variation lifecycle claim is always the variation's own `post_status`. Parent
status is never copied onto a variation. A variation target always carries both
`woo_variation_id` and `woo_product_id`.

### Deduplication and bounds

Parent-level and event-level observations repeat across the variation rows of the
same product on one page. The producer deduplicates on the complete canonical
fingerprint of the evidence record, so only fully identical records collapse.

```text
identical dimension/scope/target/state/value/completeness/provenance  collapses
any difference in state, value, completeness, or provenance           preserved
```

`(dimension, producer_scope, target)` is deliberately **not** the dedup key. When
one product carries two conflicting observations of the same identity — for
example a product that resolves to both event `10` and event `20` — both records
must reach Phoenix so it can collapse them or raise `blocking_conflict`. A
producer that kept only one would silently pick a winner and hide the conflict.
Two different malformed references for the same identity are likewise two
distinct `invalid` records, because their `raw_producer_code` differs.

If a page would exceed 500 evidence items the producer fails closed with HTTP
`500`. Evidence is never truncated. A page of fully distinct
product/variation/event triples costs eleven items per row, so choose a
`per_page` that fits the bound; `per_page=45` is safe in the worst case, and
larger pages are safe when products share events or carry several variations.
Conflict preservation can add items beyond the identity count, so the bound is
checked against the emitted records rather than the identity count.

### Oversized and malformed raw producer codes

`raw_producer_code` is bounded to 64 bytes and must be valid UTF-8. An
unemittable raw code is never truncated and never silently omitted, because an
evidence record missing its raw token is indistinguishable from a clean read.
The page fails closed instead:

```text
raw code longer than 64 bytes   RuntimeException oversized_raw_producer_code
raw code that is not UTF-8      RuntimeException invalid_raw_producer_code
```

Both surface as HTTP `500` with no body. This applies to every raw-carrying
dimension, including lifecycle statuses, ticket template ids, product types, and
event references. A raw code of exactly 64 bytes is emitted normally, and the
bound counts bytes rather than characters, so 33 two-byte characters fail closed.

### Full-catalogue relationship discovery

The catalogue query LEFT JOINs both relationship tables in every mode, so a
published ticket product with a missing, malformed, or unresolved `_event_name`
still reaches evidence generation instead of disappearing from discovery:

```text
LEFT JOIN <postmeta> event_meta ON event_meta.post_id = p.ID
                              AND event_meta.meta_key = '_event_name'
LEFT JOIN <posts> ev ON ev.post_type = 'tc_events'
                    AND event_meta.meta_value REGEXP '^[1-9][0-9]*$'
                    AND ev.ID = CAST(event_meta.meta_value AS UNSIGNED)
```

Rules:

```text
The joins are never switched to INNER based on targeting or include_private.
The REGEXP guard runs before the CAST so a malformed reference cannot resolve.
Public mode filters on (ev.ID IS NULL OR ev.post_status = 'publish'), which keeps
  products whose event is missing or unresolved while still excluding products
  attached to a non-published event.
Catalogue ORDER BY is a total order:
  ev.post_title ASC, p.post_title ASC, p.ID ASC, variation.ID ASC, ev.ID ASC
  The final ev.ID ASC tiebreaker keeps offset pages deterministic when the same
  product/variation appears for multiple events under LEFT JOIN relationships.
```

The consequence is that broken event links remain discoverable as `invalid` or
`absent` `event_link` evidence. Previously an unresolved reference removed the
whole product row from a public page, which reported a broken catalogue as a
clean one. The separate `events` listing query is unaffected: `tc_events` is its
base table, so public mode still restricts it to published events.

An existing empty `_event_name` or `_ticket_template` meta row is observed as
`invalid` with exact raw provenance (including `""`), never collapsed to
`absent`. Absence requires SQL NULL — proof the meta row does not exist.

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
- Private, draft, subscription, undeclared-type, variation, broken-event-link,
  and missing-template cases are expressed as typed evidence rather than raw
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
