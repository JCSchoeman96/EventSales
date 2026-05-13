# Oban Queue Backlog Runbook

## Check

- webhooks queue depth
- reconciliation queue depth
- imports queue depth
- failures by worker
- REST circuit breaker status

## Actions

- pause reconciliation first
- keep webhook processing prioritized
- do not increase WooCommerce REST concurrency above 2 without explicit approval
- inspect failed jobs and telemetry before retry storms
