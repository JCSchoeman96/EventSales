# Live Webhook Cutover Runbook

## Purpose

Controlled cutover of WooCommerce webhook delivery to EventSales with an explicit rollback path.

## Pre-cutover checklist

1. Production smoke passed: `bash scripts/smoke_test_railway_release.sh`
2. Cutover dry run passed: `bash scripts/cutover_dry_run.sh`
3. Mapping review completed: [`mapping-review.md`](mapping-review.md)
4. Database backup timestamp recorded: [`database-backup-restore.md`](database-backup-restore.md)
5. `WOOCOMMERCE_REST_*` credentials configured and `WooCommerceRestConfig.validate_for_live_cutover!/0` passes
6. `WEBHOOK_PATH_TOKEN` and `WOOCOMMERCE_WEBHOOK_SECRET` configured
7. Oban queue backlog within thresholds: [`oban-queue-backlog.md`](oban-queue-backlog.md)

## Cutover steps

1. Set `EVENTSALES_LIVE_CUTOVER_ENABLED=true` in Railway (requires valid REST credentials at boot).
2. Deploy the known-good release.
3. Confirm `/health`, admin dashboard, and Oban Web are reachable.
4. Update WooCommerce webhook destination URL to:
   `https://<PHX_HOST>/webhooks/woocommerce/<WEBHOOK_PATH_TOKEN>`
5. Send a synthetic `eventsales.smoke` webhook and confirm exactly one `WebhookEvent` without new `Order` rows.
6. Monitor `webhooks` queue depth and reconciliation dashboard for 15 minutes.

## Rollback

Use rollback when webhook intake is unstable, queue backlog is growing uncontrollably, or incorrect sales truth is detected.

1. Revert WooCommerce webhook URL to the previous endpoint immediately.
2. Set `EVENTSALES_LIVE_CUTOVER_ENABLED=false` (or unset).
3. Railway redeploy the last known-good commit.
4. Verify EventSales stops receiving new live webhooks (check `WebhookEvent` insert rate).
5. Run reconciliation for the cutover gap window from `/admin/reconciliation`.
6. Record incident notes using [`incident-response.md`](incident-response.md).

## Post-cutover monitoring

- Oban Web `/admin/oban` — `webhooks` queue depth and failures
- Telemetry `event_sales.oban.queue_snapshot.count`
- Reconciliation dashboard for missing/duplicate ingestion
- Redis webhook buffer depth if degraded mode is enabled
