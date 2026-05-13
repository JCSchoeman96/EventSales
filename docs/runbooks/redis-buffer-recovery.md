# Redis Webhook Buffer Recovery Runbook

## Rule

Redis buffer is a degraded-mode safety valve only. Buffered payloads must be drained into Postgres before processing.

## Check

- buffer length
- oldest buffered event age
- drainer job status
- Postgres availability
- duplicate/idempotency metrics

## Actions

- restore Postgres first
- run drainer
- verify WebhookEvent rows were persisted
- verify processing jobs were enqueued
