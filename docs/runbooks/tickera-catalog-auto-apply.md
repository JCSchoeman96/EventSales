# Tickera Catalog Auto-Apply Runbook

This feature must remain disabled until a separately authorised rollout.

## Observe

Use the Catalog Sync admin page to inspect the latest bounded decision state for an authorised source and run. The page refreshes through run-scoped PubSub and does not poll. Durable truth is in the Catalog Sync run and its `TickeraCatalogAutoApplyDecision`.

## Incident stop hierarchy

1. Set the hard environment kill false.
2. Set durable global mode disabled.
3. Set the affected source mode disabled.
4. Remove the source from the allowlist.
5. Remove the policy version from enabled versions.

Any disabled scope wins. These operations do not disable Human Apply.

## Recovery

The recovery worker uses an indexed, source-scoped batch of at most 100 rows with `FOR UPDATE SKIP LOCKED`. It never inserts a replacement job after linkage. Available, scheduled, retryable, or executing linked jobs are left alone. Completed jobs reconcile against durable run/audit state. Discarded or cancelled jobs may retry the same job only after the recorded due time and complete revalidation. Missing linked jobs and attempt-20 failures become terminal and require operator review.

## Evidence to retain

Record bounded identifiers, state codes, versions, hashes, job linkage, test/query-plan results, and timestamps only. Never record customer data, order payloads, payment data, ticket tokens, credentials, raw WordPress payloads, or exception text.
