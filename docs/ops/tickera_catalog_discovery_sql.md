# Tickera Catalog Discovery SQL

VS-26A uses Tickera Bridge catalog data as the source contract for EventSales catalog sync.

## Proven Relationship

```text
tc_events.ID
  <- oNgKhz_postmeta._event_name
Woo product.ID
  <- _tc_is_ticket = yes
Optional Woo product_variation.ID
  <- child product_variation rows under the Woo product
```

Hard invariant: only `tc_events.post_status = 'publish'` is eligible. A published Woo product linked to a private or draft Tickera event must be skipped.

## VWG Pretoria Proof Row

```text
Woo product: 109740
Product title: VWG - Pretoria
Linked Tickera event: 109316
Tickera event title: Vroue wat Glo-retreat - PTA
Tickera event status: publish
Variation: none
Ticket display name: Toegang
Price: 199
```

## Count Findings

The published-only raw query returned 149 rows. The grouped query returned 93 rows.

That proves two implementation facts:

- some ticket products use Woo variations
- duplicate postmeta rows can inflate raw output

Sync normalization must deduplicate by `{tickera_event_id, woo_product_id, woo_variation_id}`. Price must not be used as identity because repeated `_price` or other meta rows may exist.

## Publish-Only Discovery Query

This SQL is the discovery contract for docs/tests/manual exports. VS-26A does not execute this against WordPress directly.

```sql
SELECT
  p.ID AS woo_product_id,
  p.post_status AS product_status,
  p.post_title AS product_title,
  p.post_name AS product_slug,
  p.post_modified_gmt AS product_source_updated_at,

  ev.ID AS tickera_event_id,
  ev.post_status AS event_status,
  ev.post_title AS event_title,
  ev.post_name AS event_slug,
  ev.post_modified_gmt AS event_source_updated_at,

  MAX(CASE WHEN pm.meta_key = 'custom_produk_blad_toegang_naam' THEN pm.meta_value END) AS ticket_display_name,
  MAX(CASE WHEN pm.meta_key = '_price' THEN pm.meta_value END) AS price,
  MAX(CASE WHEN pm.meta_key = '_regular_price' THEN pm.meta_value END) AS regular_price,
  MAX(CASE WHEN pm.meta_key = '_ticket_template' THEN pm.meta_value END) AS ticket_template_id,

  variation.ID AS woo_variation_id,
  variation.post_status AS variation_status,
  variation.post_title AS variation_title,
  variation.post_modified_gmt AS variation_source_updated_at
FROM oNgKhz_posts p
JOIN oNgKhz_postmeta is_ticket
  ON is_ticket.post_id = p.ID
 AND is_ticket.meta_key = '_tc_is_ticket'
 AND is_ticket.meta_value = 'yes'
JOIN oNgKhz_postmeta event_meta
  ON event_meta.post_id = p.ID
 AND event_meta.meta_key = '_event_name'
JOIN oNgKhz_posts ev
  ON ev.ID = CAST(event_meta.meta_value AS UNSIGNED)
 AND ev.post_type = 'tc_events'
 AND ev.post_status = 'publish'
LEFT JOIN oNgKhz_postmeta pm
  ON pm.post_id = p.ID
 AND pm.meta_key IN (
   'custom_produk_blad_toegang_naam',
   '_price',
   '_regular_price',
   '_ticket_template'
 )
LEFT JOIN oNgKhz_posts variation
  ON variation.post_parent = p.ID
 AND variation.post_type = 'product_variation'
 AND variation.post_status = 'publish'
WHERE p.post_type = 'product'
  AND p.post_status = 'publish'
GROUP BY
  p.ID,
  p.post_status,
  p.post_title,
  p.post_name,
  p.post_modified_gmt,
  ev.ID,
  ev.post_status,
  ev.post_title,
  ev.post_name,
  ev.post_modified_gmt,
  variation.ID,
  variation.post_status,
  variation.post_title,
  variation.post_modified_gmt
ORDER BY ev.post_title, p.post_title, variation.ID;
```

## Published Event Summary Query

VS-26A discovery must also include Tickera event summaries, not only product-linked rows. This lets the planner warn on published Tickera events with zero eligible ticket products.

```sql
SELECT
  ev.ID AS tickera_event_id,
  ev.post_status AS event_status,
  ev.post_title AS event_title,
  ev.post_name AS event_slug,
  ev.post_modified_gmt AS event_source_updated_at,
  COUNT(DISTINCT p.ID) AS linked_ticket_products
FROM oNgKhz_posts ev
LEFT JOIN oNgKhz_postmeta event_meta
  ON event_meta.meta_key = '_event_name'
 AND CAST(event_meta.meta_value AS UNSIGNED) = ev.ID
LEFT JOIN oNgKhz_posts p
  ON p.ID = event_meta.post_id
 AND p.post_type = 'product'
 AND p.post_status = 'publish'
LEFT JOIN oNgKhz_postmeta is_ticket
  ON is_ticket.post_id = p.ID
 AND is_ticket.meta_key = '_tc_is_ticket'
 AND is_ticket.meta_value = 'yes'
WHERE ev.post_type = 'tc_events'
GROUP BY
  ev.ID,
  ev.post_status,
  ev.post_title,
  ev.post_name,
  ev.post_modified_gmt
ORDER BY ev.post_title;
```

Do not include secrets, customer data, webhook payloads, emails, phone numbers, tokens, raw order data, QR hashes, or provider payloads in manual exports.
