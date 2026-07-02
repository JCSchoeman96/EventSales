# Incident Response

## Severity levels

| Level | Example | First response |
|-------|---------|----------------|
| SEV-1 | Live sales totals wrong or webhook intake down | Page on-call, start rollback checklist immediately |
| SEV-2 | Growing Oban backlog or reconciliation paused | Pause reconciliation, inspect Oban Web and telemetry |
| SEV-3 | Single failed job or delayed dashboard refresh | Monitor, inspect root cause before bulk retry |

## First 15 minutes

1. Confirm `/health` and admin login still work.
2. Check Oban Web `/admin/oban` for `webhooks`, `reconciliation`, and `maintenance` queue depth.
3. Review recent `WebhookEvent` intake rate and failures in `/admin/webhooks`.
4. Open reconciliation dashboard `/admin/reconciliation` for missing/duplicate findings.
5. If Redis degraded-mode buffer is enabled, review [`redis-buffer-recovery.md`](redis-buffer-recovery.md).
6. Record incident start time and last known-good deploy commit.

## Stabilization actions

- Pause reconciliation and manual sync before retry storms.
- Never raise WooCommerce REST concurrency above `2`.
- Use webhook replay only for verified failed deliveries.
- Prefer CSV import only after dry-run success.

## Rollback

For live cutover incidents, follow the **Rollback** section in [`live-webhook-cutover.md`](live-webhook-cutover.md).

## Evidence hygiene

Do not paste secrets, webhook signatures, raw payloads, customer emails, or phone numbers into tickets or chat. Use delivery IDs, queue names, and worker names only.
