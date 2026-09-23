# VS-26E.0 Rollback and Stop Conditions

## Important limitation

There is no single universal rollback for this slice:

- application deployment rollback does not undo migrations;
- migration rollback may be unsafe after writes;
- deployment rollback does not undo catalog Apply;
- catalog Apply writes multiple durable resources and triggers post-commit side effects;
- manual database rewrites are forbidden.

Prefer stop-before-write and no-go over rollback.

## Stop before deployment/migration

- unknown deployed SHA;
- unknown migration connection topology;
- pooler safety unresolved;
- no backup/restore confidence for a corrective migration;
- duplicate active runs;
- unexpected pending migration;
- unreviewed code/config/migration would deploy.

## Stop before dry-run

- migrations/index invalid;
- active/retryable catalog work unexplained;
- feed secret/config not safely verifiable;
- plugin/schema mismatch;
- source clocks/skew issue;
- paging limit likely insufficient;
- source scale unexpectedly exceeds bounds.

## Stop before Apply

- blocking finding;
- ambiguous/destructive/unexpected scope;
- missing expected live events;
- unexplained private/draft content;
- unclassified subscription/payment-plan/bundle/add-on rows;
- snapshot missing;
- hash mismatch;
- approval missing or stale;
- production state materially changed after review.

## Stop after Apply and escalate

- transactional Apply fails;
- run state inconsistent;
- catalog does not reconcile to snapshot;
- unrelated catalog/order data changed;
- duplicate mappings/identities;
- secret/PII leak;
- dashboard/admin state contradicts durable truth;
- recovery jobs explode or loop.

## Deployment rollback

Use Railway's reviewed rollback mechanism only after checking migration/data compatibility. Record target SHA and reason.

## Migration rollback

Use `EventSales.Release.rollback/2` only with a reviewed target version, current backup, and explicit data-compatibility decision. Never use it reflexively during an incident.

## Catalog correction

A required catalog correction after Apply needs a separate reviewed corrective plan. Do not delete or rewrite audit/run evidence.

## Evidence incident

If protected data enters evidence:

1. stop;
2. restrict/remove the exposed artifact through approved systems;
3. record an incident without repeating the value;
4. rotate affected credential when applicable;
5. do not continue certification until resolved.
