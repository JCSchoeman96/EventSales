# Reconciliation Runbook

## Purpose

Detect and repair missing, duplicate, or failed WooCommerce/Tickera ingestion without calling WooCommerce REST from LiveView or controllers.

## Missing ingestion

Symptoms:

- Dashboard totals lag known WooCommerce completed orders
- Reconciliation findings show missing Woo orders or Tickera attendees

Actions:

1. Open `/admin/reconciliation`.
2. Review latest reconciliation run status and findings export.
3. Confirm mappings are complete via [`mapping-review.md`](mapping-review.md).
4. Run scoped reconciliation from the admin UI during non-peak windows.
5. If REST is rate-limited or circuit-open, wait for pause to clear before retrying.

## Duplicate ingestion

Symptoms:

- Duplicate delivery IDs in `/admin/webhooks`
- Identical resource hash processed more than once

Actions:

1. Search webhook events by delivery ID in `/admin/webhooks`.
2. Confirm duplicate deliveries are marked `ignored` with duplicate guards.
3. Do not manually replay duplicate deliveries.
4. If duplicate orders exist, use reconciliation findings and audit history before corrective action.

## Failed ingestion

Symptoms:

- `WebhookEvent` status `failed` or `retryable`
- Oban discarded jobs for `ProcessWebhookWorker`

Actions:

1. Inspect failed jobs in Oban Web.
2. Review sanitized failure metadata only (no raw payload in tickets).
3. Fix root cause (mapping, catalog, transient REST/Tickera error).
4. Use admin webhook replay for verified single-event recovery.
5. Use CSV import fallback only after dry-run success.

## Operator surfaces

- `/admin/reconciliation`
- `/admin/sync`
- `/admin/webhooks`
- `/admin/imports`

## Guardrails

- WooCommerce REST concurrency remains `2`.
- Pause reconciliation first during flash-sale pressure.
- Redis buffer is degraded-mode only, not canonical truth.
