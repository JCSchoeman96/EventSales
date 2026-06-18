# Production Smoke Test

## Purpose and safety boundary

This runbook proves a Slice 24.0 Railway deployment. It uses a unique PII-free signed payload with the unsupported topic `eventsales.smoke`, ensuring the webhook is durably ingested without triggering WooCommerce REST or mutating sales truth.

It does not change WooCommerce or Tickera webhook destinations and does not certify flash-sale readiness.

## Preconditions

- Slice 24.0 is merged to and deployed from `main`.
- The Railway project is linked and the `EventSales` service is active.
- PostgreSQL, Redis, runtime variables, admin bootstrap variables, and source bootstrap variables are configured.
- `/health` is the Railway deployment healthcheck.
- The operator is authenticated with `railway login`.

Confirm deployment state without printing variables:

```bash
railway status
railway deployment list --service EventSales
railway logs --service EventSales --deployment --lines 100
```

Do not run `railway variable list --kv` in captured evidence because it may expose secret values.

## Run

```bash
bash scripts/smoke_test_railway_release.sh
```

The wrapper enters the running service with Railway SSH, removes `PHX_SERVER` for the short-lived release evaluator, and runs `EventSales.Maintenance.ProductionSmoke.run!/0`. Secrets remain inside the service environment and are never command-line arguments or output.

Expected safe labels:

```text
production smoke: application passed
production smoke: migrations passed
production smoke: postgres passed
production smoke: redis passed
production smoke: oban passed
production smoke: health passed
production smoke: oban protection passed
production smoke: invalid webhook passed
production smoke: valid webhook storage passed
production smoke: admin dashboard and Oban Web passed
production smoke: complete
```

The script exits non-zero at the first failed check and names only the failed check. It does not print response bodies, payloads, cookies, signatures, passwords, path tokens, database URLs, Redis URLs, or secret key material.

## Acceptance evidence

Record only:

```text
UTC timestamp:
Git commit SHA:
Railway project/service:
Railway deployment ID:
Generated HTTPS hostname:
Build status:
Pre-deploy migration/bootstrap status:
Health status:
Smoke completion status:
Operator initials:
```

Do not record variable values, admin email, customer data, request bodies, headers, or credentials.

## Failure handling

1. Note the safe failed-check label and deployment ID.
2. Inspect bounded build or deployment logs with `railway logs --lines 200`; do not paste secret-bearing output into tickets.
3. For migration/bootstrap failure, verify required variable names and database reachability without displaying values.
4. For Redis failure, confirm `HOT_STATE_REDIS_SNAPSHOTS_ENABLED=true` and the Redis service reference exists.
5. For Oban failure, inspect queue configuration and PostgreSQL connectivity; do not switch notifier or add PgBouncer during incident response.
6. For HTTP/auth/webhook failure, confirm the generated domain, `PHX_HOST`, admin bootstrap status, and source bootstrap status.
7. Redeploy the last known-good commit or use Railway rollback only after checking migration compatibility.

Do not bypass a failing pre-deploy command or healthcheck to force activation.

## Completion statement

A passing run proves that the Railway build, release migrations, application startup, direct PostgreSQL, managed Redis, Oban execution/retry, HTTPS health, protected admin surfaces, HMAC rejection, and durable signed webhook intake work in production. PgBouncer, live webhook cutover, load testing, and flash-sale certification remain deferred.
