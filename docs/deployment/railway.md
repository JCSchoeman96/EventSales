# Railway Deployment

Slice 24.0 deploys EventSales as one Docker-based OTP release with Railway-managed PostgreSQL and Redis. It proves deployability and production behavior; it does not certify flash-sale readiness.

## Provision the project

Run from a clean checkout of `main` after the Slice 24.0 pull request is merged:

```bash
railway login
railway init --name EventSales
railway add --service EventSales
railway add --database postgres
railway add --database redis
railway service link EventSales
railway status
```

Railway normally names the managed services `Postgres` and `Redis`. Confirm the names in the dashboard before applying service references; substitute the actual service name if it differs.

Generate the Railway HTTPS domain and retain only its non-secret hostname:

```bash
railway domain --service EventSales --json
```

Do not add a custom domain in this slice.

## Configure service references

These values are Railway references, not credentials committed to Git:

```bash
railway variable set --service EventSales --skip-deploys \
  'DATABASE_URL=${{Postgres.DATABASE_URL}}' \
  'DIRECT_DATABASE_URL=${{Postgres.DATABASE_URL}}' \
  'REDIS_URL=${{Redis.REDIS_URL}}' \
  HOT_STATE_REDIS_SNAPSHOTS_ENABLED=true \
  EVENTSALES_BUSINESS_TIMEZONE=Africa/Johannesburg \
  EVENTSALES_DEFAULT_CURRENCY=ZAR
```

Set `PHX_HOST` to the generated hostname without `https://` or a path. Set the source metadata to the real WooCommerce site, but do not change that site’s webhook destination:

```bash
railway variable set --service EventSales --skip-deploys \
  PHX_HOST=generated-hostname.up.railway.app \
  EVENTSALES_BOOTSTRAP_SOURCE_NAME='Production WooCommerce' \
  EVENTSALES_BOOTSTRAP_SOURCE_BASE_URL=https://shop-hostname.example
```

## Set secrets without command-line values

Use stdin so values are not stored in shell history or shown in process arguments:

```bash
mix phx.gen.secret | railway variable set --service EventSales --skip-deploys --stdin SECRET_KEY_BASE
openssl rand -hex 24 | railway variable set --service EventSales --skip-deploys --stdin WEBHOOK_PATH_TOKEN
openssl rand -base64 48 | railway variable set --service EventSales --skip-deploys --stdin WOOCOMMERCE_WEBHOOK_SECRET
railway variable set --service EventSales --skip-deploys --stdin EVENTSALES_BOOTSTRAP_ADMIN_EMAIL
railway variable set --service EventSales --skip-deploys --stdin EVENTSALES_BOOTSTRAP_ADMIN_PASSWORD
railway variable set --service EventSales --skip-deploys --stdin EVENTSALES_BOOTSTRAP_ADMIN_NAME
```

The admin password must contain at least 16 characters with uppercase, lowercase, numeric, and non-alphanumeric characters. Never print or copy secret values into logs, documentation, issue comments, commits, or pull-request text.

WooCommerce REST credentials are required before live ingestion or reconciliation is enabled, but are not needed by the PII-free unsupported-topic smoke delivery. Configure them by stdin before live cutover.

## Deploy from `main`

`railway.toml` is authoritative for the Docker builder, pre-deploy command, start command, healthcheck, and restart policy. Config-as-code intentionally overrides conflicting dashboard values.

```bash
git switch main
git pull --ff-only origin main
railway up --service EventSales --detach --message 'Slice 24.0 production deployment'
railway deployment list --service EventSales
railway logs --service EventSales --build --latest
railway logs --service EventSales --deployment --latest
```

The deployment becomes active only after the pre-deploy migration/bootstrap command exits successfully and Railway receives HTTP `200` from `/health` on its injected `PORT`.

After activation, run `bash scripts/smoke_test_railway_release.sh` and follow `docs/runbooks/production-smoke-test.md`.

## Scope boundary

- No live WooCommerce or Tickera webhook destination is changed.
- No PgBouncer, multi-region deployment, replica, autoscaling, or queue admission control is introduced.
- PostgreSQL remains durable truth; Redis is a hot/warm read model.
- Slice 25.0 owns launch and flash-sale hardening.
