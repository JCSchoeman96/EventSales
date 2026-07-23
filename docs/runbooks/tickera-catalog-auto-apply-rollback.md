# Tickera Catalog Auto-Apply Rollback

Automation is additive and defaults disabled.

## Code rollback

Disable automation first, then roll back application code while retaining additive database schema and audit rows. Legacy code safely receives `legacy_unknown` for omitted run origins; that origin is permanently ineligible.

## Schema posture

Do not automatically drop decision/configuration tables or delete audit rows. Schema rollback is permitted only under separate authority after proving no decision rows or dependent jobs exist. Existing snapshots and hashes must never be rewritten.

## Stop conditions

Stop rollout or implementation when hash linkage disagrees, Human Apply regresses, source risk can disappear, a duplicate job is possible, retry can exceed attempt 20, configuration can default enabled, a query becomes unbounded, source isolation fails, or protected data reaches a decision, log, PubSub payload, or UI.
