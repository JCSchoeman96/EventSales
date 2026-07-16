# VS-26E.0 Apply and Verification

## Separate approval

Approval must state the run id, exact dry-run hash, reviewed finding summary, approved scope, approver, timestamp, and accepted risks. Any changed run or hash invalidates approval.

## Queue Apply

Use the existing admin action for the exact run and hash. Do not call the applier directly from an ad-hoc console unless a reviewed incident runbook explicitly requires it.

Expected durable path:

```text
dry_run_ready -> applying -> applied
```

The applier rechecks status, hash, snapshot, and blocking findings; claims and writes in one transaction; applies stored Event, TicketType, and ProductMapping changes; marks the run applied; and performs post-commit dashboard invalidation, PubSub, and recovery-job insertion.

## Immediate stop or fail-closed outcomes

- `stale_dry_run_hash`
- `missing_plan_snapshot`
- `blocking_findings`
- `run_not_ready`
- `not_found`
- unexpected failed terminal state

Do not retry by editing the run.

## Post-Apply durable verification

Using admin facades or approved read-only database metadata, reconcile the run, Events, TicketTypes, ProductMappings, and bounded side effects.

### Run

- status `applied`;
- hash unchanged;
- finished timestamp;
- no unsafe error;
- no duplicate active run.

### Events

For each created, adopted, or updated event sample verify source system, external Tickera event identity, name and slug, source status and timestamp, start and end dates, venue, booking-fee metadata, and last-synced timestamp.

### Ticket types

Verify event relationship, product or variation identity, kind, source status and timestamp, active state, and name.

### Product mappings

Verify source, Woo product id, nullable variation id, event, ticket type, active state, labels, and uniqueness.

### Side effects

- touched-event dashboard invalidation or notification observed;
- open admin view becomes truthful without manual data rewrite;
- missing-catalog resolution jobs are bounded and expected;
- no unrelated orders or order items changed.

## Reconciliation

Counts in durable catalog must reconcile to approved plan actions. Explain every mismatch. Do not call partial success certified.

## No-go

When Apply is not approved, preserve or revoke the ready run using the existing admin cancellation path and record the reason. Do not delete evidence.
