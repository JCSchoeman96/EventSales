# VS-26E.0 Apply and Verification

## Separate approval

Approval must state:

- run id;
- exact dry-run hash;
- reviewed finding summary;
- approved scope;
- approver;
- timestamp;
- accepted risks.

Any changed run/hash invalidates approval.

## Queue Apply

Use the existing admin action for the exact run/hash. Do not call the applier directly from an ad-hoc console unless a reviewed incident runbook explicitly requires it.

Expected durable path:

```text
dry_run_ready -> applying -> applied
```

The applier:

- rechecks status/hash/snapshot/blocking findings;
- claims and writes in one transaction;
- applies stored Event/TicketType/ProductMapping changes;
- marks applied;
- performs post-commit dashboard invalidation/PubSub and recovery-job insertion.

## Immediate stop/fail-closed outcomes

- `stale_dry_run_hash`
- `missing_plan_snapshot`
- `blocking_findings`
- `run_not_ready`
- `not_found`
- unexpected failed terminal state

Do not retry by editing the run.

## Post-Apply durable verification

Using admin facades/read-only database metadata where approved, reconcile:

### Run

- status `applied`;
- hash unchanged;
- finished timestamp;
- no unsafe error;
- no duplicate active run.

### Events

For each created/adopted/updated event sample:

- source system;
- external Tickera event id/kind;
- name/slug;
- source status;
- source-updated time;
- starts/ends;
- venue;
- booking-fee metadata;
- last synced.

### Ticket types

- event relationship;
- external product/variation identity;
- kind;
- source status/time;
- active state;
- name.

### Product mappings

- source;
- Woo product id;
- nullable variation id;
- event;
- ticket type;
- active state;
- labels;
- uniqueness.

### Side effects

- touched event dashboard invalidation/notification observed;
- open admin view becomes truthful without manual data rewrite;
- missing-catalog resolution jobs are bounded and expected;
- no unrelated orders/order items changed.

## Reconciliation

Counts in durable catalog must reconcile to approved plan actions. Explain every mismatch. Do not call partial success certified.

## No-go

When Apply is not approved, preserve/revoke the ready run using the existing admin cancellation path and record reason. Do not delete evidence.
