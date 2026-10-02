# WP-SOURCE-01 — Woo order-line Tickera event identity

**Plan ID:** wp-order-line-event-identity  
**Plan version:** v1  
**Status:** active  
**Scope:** WordPress producer for `tickera_event_id` order-item metadata  
**Authority:** This file is the active contract for WP-SOURCE-01.  
**Last updated:** 2026-10-02  
**Change summary (v1):** Initial plan after localhost:10059 reconnaissance and producer implementation.

### Revision log

- `v1` — initial plan locked to `_event_name` → `tc_events` authority and checkout/new-order-item hooks.

## Goal

Persist authoritative Tickera event post IDs on qualifying WooCommerce ticket order lines using meta key `tickera_event_id`, without a second EventSales transport.

## Baseline

- EventSales already parses `tickera_event_id` into `source_tickera_event_id` (`woocommerce_order_parser.ex`).
- Catalogue producer already documents authority as `postmeta:_event_name+tc_events.resolve`.
- Local WordPress at `http://localhost:10059` had zero `tickera_event_id` order-item meta rows before this slice.

## Authoritative relationship (discovered)

| Question | Answer |
|----------|--------|
| Source record | Parent Woo product `_event_name` meta stores a positive integer string equal to a `tc_events` post ID. |
| Ticket guard | Parent product `_tc_is_ticket` meta must be exactly `yes`. |
| Variations | Event authority lives on the parent product; variation lines resolve through `post_parent`. |
| Multiple events | Multiple distinct resolved IDs → `CONFLICT` (no write). |
| Non-ticket | `NOT_APPLICABLE` (no write). |
| Existing WP meta key | No `tickera_event_id` / tickera event keys found on historical order items locally. |
| Webhook exposure | Woo order item meta is included in REST/webhook `line_items[].meta_data` when persisted. |

Names, titles, slugs, and labels are never used.

## Producer contract

- **Key:** `tickera_event_id`
- **Value:** positive Tickera `tc_events` post ID (stored as string meta)

### Resolution states

`NOT_APPLICABLE` | `RESOLVED` | `UNRESOLVED` | `CONFLICT`

### Lifecycle

| From | To | Guard | Side effect | Terminal |
|------|-----|-------|-------------|----------|
| UNSEEN | NOT_APPLICABLE | line product authority is not `_tc_is_ticket=yes` | none | yes |
| UNSEEN | UNRESOLVED | ticket line but no single valid `tc_events` ID | none | yes |
| UNSEEN | CONFLICT | multiple authoritative event IDs | none | yes |
| UNSEEN | RESOLVED | exactly one valid `tc_events` ID | write `tickera_event_id` | yes |

### Idempotency

| Condition | Outcome |
|-----------|---------|
| existing meta equals resolved ID | idempotent no-op |
| existing valid meta differs from resolved ID | `CONFLICT_EXISTING`, no overwrite |
| invalid/non-positive resolved ID | no write |

## Woo hooks

- `woocommerce_checkout_create_order_line_item` (priority 20) — meta attached before initial order save.
- `woocommerce_new_order_item` (priority 20) — admin/REST paths; persists via item `save()` when meta was missing.

No EventSales HTTP in either hook.

## Files

```text
integrations/wordpress/eventsales-woo-order-line-identity/
docs/development/wp-order-line-event-identity.plan.md
docs/ops/woocommerce_order_payload_contract.md
```

## Tests

- `integrations/wordpress/eventsales-woo-order-line-identity/tests/order-line-identity-test.php`
- Existing catalog and order-index PHP boundary tests (unchanged plugins).
- EventSales `woocommerce_order_parser_test.exs` and `order_item_mapper_test.exs`.

## Non-goals

Custom EventSales order transport, webhook replacement, analytics/M5, catalogue/order-index plugin changes, production deploy.
