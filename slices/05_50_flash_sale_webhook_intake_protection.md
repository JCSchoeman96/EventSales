# Slice 5.5 — Flash-Sale Webhook Intake Protection

## Purpose

Protect webhook intake during high-concurrency bursts.

## Implementation scope

```text
PgBouncer-safe notes, DB pool saturation handling, optional Redis buffer fallback, RedisWebhookBuffer, RedisWebhookBufferDrainer, backpressure telemetry.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 5.5 — Flash-Sale Webhook Intake Protection for EventSales. |
| Objective | Protect webhook intake during high-concurrency bursts. |
| Output | PgBouncer-safe notes, DB pool saturation handling, optional Redis buffer fallback, RedisWebhookBuffer, RedisWebhookBufferDrainer, backpressure telemetry. |
| Note | Redis fallback is a degraded-mode safety valve, not canonical durable truth. Return 2xx only after Postgres persistence or after an explicitly enabled, bounded, monitored Redis degraded-mode buffer accepts the payload and its durability risk has been accepted. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Normal webhook persists to Postgres
- DB saturation + Redis fallback buffers payload
- Buffered payload later persists to Postgres
- If neither path accepts, return non-2xx
- Redis buffer bounded
- Drainer idempotent
- DB saturation does not crash app
- Backpressure telemetry emitted

## Architecture guardrails

Redis fallback is a degraded-mode safety valve, not canonical durable truth. Return 2xx only after Postgres persistence or after an explicitly enabled, bounded, monitored Redis degraded-mode buffer accepts the payload and its durability risk has been accepted.

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

Redis buffering is optional degraded-mode behavior and must be explicitly enabled. If Redis durability/persistence is not accepted, return non-2xx when Postgres intake fails so WooCommerce retries.
