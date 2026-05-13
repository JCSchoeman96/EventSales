# Runtime Configuration

## Database Paths

- `DATABASE_URL` is the pooled runtime path for Phoenix, Ecto, and Oban.
- `DIRECT_DATABASE_URL` is the preferred path for release migrations and session-sensitive maintenance.
- Slice `0.2` assumes PgBouncer session pooling. Transaction pooling is not configured here.

## Required Runtime Variables

```text
DATABASE_URL
DIRECT_DATABASE_URL
REDIS_URL
SECRET_KEY_BASE
PHX_HOST
PORT
EVENTSALES_BUSINESS_TIMEZONE=Africa/Johannesburg
EVENTSALES_DEFAULT_CURRENCY=ZAR
WOOCOMMERCE_BASE_URL
WOOCOMMERCE_CONSUMER_KEY
WOOCOMMERCE_CONSUMER_SECRET
WOOCOMMERCE_WEBHOOK_SECRET
WEBHOOK_PATH_TOKEN
REST_MAX_CONCURRENCY=2
```

## Local Test Requirement

- Postgres must be running for `mix test`.
- The default test database name is `event_sales_test`.
- Use `mix ecto.create` and `mix ecto.migrate`, or `mix ecto.setup`, before treating DB connection failures as code failures.
- Slice `0.2` does not require a local Redis service for test or CI.
