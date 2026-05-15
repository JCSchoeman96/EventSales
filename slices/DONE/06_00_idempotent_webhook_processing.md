# Slice 6.0 — Idempotent Webhook Processing

## Purpose

Ensure duplicate webhook deliveries do not duplicate data.

## Implementation scope

```text
ProcessWebhookWorker, WebhookProcessor, delivery/resource/hash idempotency, statuses, retry with jitter.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 6.0 — Idempotent Webhook Processing for EventSales. |
| Objective | Ensure duplicate webhook deliveries do not duplicate data. |
| Output | ProcessWebhookWorker, WebhookProcessor, delivery/resource/hash idempotency, statuses, retry with jitter. |
| Note | Every external event must be replay-safe. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Duplicate delivery_id no duplicates
- Same order.updated safe repeatedly
- Failed marks webhook failed
- Retry can succeed
- Unsupported topic handled safely
- Processing idempotent by source/resource/hash

## Architecture guardrails

Every external event must be replay-safe.

## Completion checklist

- [ ] Files/modules for this slice are created in the approved folder structure.
- [ ] Relevant Ash resources/actions/policies are implemented only where this slice owns them.
- [ ] Oban worker behavior is tested if this slice includes async work.
- [ ] LiveView/controller behavior is tested if this slice includes web UI or intake.
- [ ] Telemetry is emitted where the slice touches ingestion, REST, Oban, cache, or hot state.
- [ ] Cache invalidation is handled where durable data changes affect dashboard state.
- [ ] The global acceptance command passes.

## Stop condition

Stop and report if implementing this slice would require a direct WooCommerce call from LiveView, an untested state transition, a hardcoded secret, a Redis-as-truth shortcut, or a skipped policy/test.


## V2 Addendum

Add out-of-order webhook protection: newer WooCommerce source updated_at wins, older payloads are marked stale and must not regress order state or totals. Use delivery ID, resource ID, source_updated_at, and payload hash.
