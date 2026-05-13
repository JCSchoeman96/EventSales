# Idempotency and Out-of-Order Webhook Handling

WooCommerce webhooks may arrive more than once and may arrive out of chronological order.

## Rules

- Use delivery ID, resource ID, source updated timestamp, and payload hash for idempotency.
- Newer `updated_at` from WooCommerce wins.
- Older payloads must not regress order state or totals.
- Stale events may be retained for audit/debug but must not mutate current sales truth.
- Aggregate events require idempotency keys.

## Required Tests

- duplicate delivery does not duplicate orders/items/totals
- older update after newer update is ignored or marked stale
- order.created after order.updated does not regress status
- aggregate event idempotency prevents double-counting
