# Security Runbook

## Secret inventory

| Secret | Rotation surface |
|--------|------------------|
| `SECRET_KEY_BASE` | Railway env, requires redeploy |
| `WEBHOOK_PATH_TOKEN` | Railway env + WooCommerce webhook URL update |
| `WOOCOMMERCE_WEBHOOK_SECRET` | Railway env + WooCommerce webhook secret |
| `WOOCOMMERCE_CONSUMER_KEY` / `WOOCOMMERCE_CONSUMER_SECRET` | Railway env only |
| Admin bootstrap password | Railway env + admin login update |

## Rotation procedure

1. Generate new secret in Railway stdin/UI (never commit or log it).
2. Update WooCommerce webhook destination/secret when rotating webhook credentials.
3. Redeploy EventSales.
4. Run production smoke and cutover dry run.
5. Invalidate old credentials at the source system.

## Webhook abuse response

1. Confirm HTTP rate limiting is active (`429` before durable intake).
2. Review `event_sales.webhook.rate_limited.count` telemetry.
3. If attack persists, rotate `WEBHOOK_PATH_TOKEN` and update WooCommerce URL.
4. Do not publish full IPs, tokens, or signatures in incident notes.

## Audit review

1. Review admin manual actions in audit logs after incidents.
2. Confirm PII masking policies remain enabled for staff views.
3. Verify exports and reconciliation downloads are admin-only.

## Launch guardrails

- `EVENTSALES_LIVE_CUTOVER_ENABLED=true` requires valid HTTPS WooCommerce REST config at boot.
- Evidence artifacts must never contain secrets or customer PII.
