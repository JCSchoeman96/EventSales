# Oban Queue Backlog Runbook

## Purpose

Detect and respond to Oban queue saturation before webhook intake or reconciliation falls behind during a live sales period.

## Thresholds

| Signal | Default threshold | Config key | Telemetry event |
|--------|-------------------|------------|-----------------|
| `webhooks` available jobs | 100 | `:webhook_queue_backlog_threshold` | `[:event_sales, :oban, :queue_snapshot]` |
| Discarded Oban jobs | 1 | `:failed_job_alert_threshold` | `[:event_sales, :maintenance, :failed_job_alert, :stop]` |

Scheduled workers (production only):

| Worker | Interval | Queue |
|--------|----------|-------|
| `ObanQueueSnapshotWorker` | every 60 seconds | `:maintenance` |
| `FailedJobAlertWorker` | every 5 minutes | `:maintenance` |

## Check

1. Open Oban Web at `/admin/oban` (admin auth required).
2. Inspect queue depth for:
   - `webhooks`
   - `reconciliation`
   - `csv_imports`
   - `maintenance`
3. Review failed/discarded jobs by worker.
4. Confirm telemetry snapshots are emitting `event_sales.oban.queue_snapshot.count` with `queue` and `state` tags.
5. Check REST circuit breaker status in admin reconciliation/sync surfaces.

## Actions

1. Pause reconciliation first (`/admin/reconciliation`, `/admin/sync`).
2. Keep webhook processing prioritized.
3. Do **not** increase WooCommerce REST concurrency above `2` without explicit approval.
4. Inspect failed jobs and telemetry before triggering retry storms.
5. If webhook backlog remains high after worker recovery, verify Redis webhook buffer settings and Postgres pool health.
6. If discarded jobs exceed threshold, inspect root cause in Oban Web before bulk retry.

## Escalation

- **Warning:** `webhooks` available count above threshold but workers are draining the queue.
- **Critical:** `webhooks` backlog growing while workers are executing, or discarded job alert fires.
- **Rollback trigger:** sustained webhook backlog with duplicate-risk retries — follow [`live-webhook-cutover.md`](live-webhook-cutover.md) rollback section.
