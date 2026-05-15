# Redis Webhook Buffer Recovery Runbook

## Rule

Redis buffer is a degraded-mode safety valve only. Buffered payloads must be drained into Postgres before processing. Postgres remains durable truth.

## Keys (prefix `eventsales:webhook_buffer:v1`)

- `{prefix}:pending` — FIFO queue awaiting drain
- `{prefix}:processing` — in-flight entries claimed by the drainer

Push uses atomic reject-when-full (Lua `LLEN` check + `LPUSH`). The drainer claims with `LMOVE`/`RPOPLPUSH` style moves, persists `WebhookEvent`, calls `WebhookEnqueue.enqueue_processing_once/1`, then ACKs. Poison entries are ACKed and logged (not requeued).

## Check

- `LLEN` pending and processing (or app metrics `event_sales.webhook.buffered` / backpressure)
- `processing` depth > 0 for extended period (stuck in-flight)
- Postgres pool health and `DATABASE_URL` connectivity
- `WEBHOOK_REDIS_BUFFER_ENABLED` / `WEBHOOK_REDIS_BUFFER_DURABILITY_ACCEPTED` / `REDIS_URL`
- Oban `ProcessWebhookWorker` queue depth (after drain)

## Actions

1. Restore Postgres pool health first.
2. Ensure `REDIS_URL` is reachable when degraded mode is enabled.
3. Run `EventSales.Ingestion.Workers.RedisWebhookBufferDrainer` (manual `perform/1` or scheduled job — not triggered from saturated webhook requests).
4. Verify `ingestion_webhook_events` rows exist with `accepted_via = redis_buffer`.
5. Verify exactly one `ProcessWebhookWorker` job per `webhook_event_id` (enqueue_once).
6. If `processing` backlog grows, inspect logs for `redis_webhook_buffer_poison_entry` and transient requeue failures (`requeue_failed` telemetry).

## Config (production)

- `WEBHOOK_REDIS_BUFFER_ENABLED=true`
- `WEBHOOK_REDIS_BUFFER_DURABILITY_ACCEPTED=true` (explicit durability risk acceptance)
- `REDIS_URL` **required** when both above are true (boot fails otherwise)
- Optional: `WEBHOOK_REDIS_BUFFER_MAX_ENTRIES`, `WEBHOOK_REDIS_BUFFER_MAX_ENTRY_BYTES`
