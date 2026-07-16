# VS-26E.0 Acceptance Checklist

## Pack and baseline

- [ ] Exact `main` baseline recorded.
- [ ] Worktree and `origin/main` checks documented.
- [ ] Canonical source PR/head recorded externally.
- [ ] Pack semantic version recorded.
- [ ] Every pack file checksum verifies.
- [ ] ZIP archive listing inspected.
- [ ] ZIP SHA-256 recorded in Linear.
- [ ] Independent pack review approved.

## Repository truth

- [ ] `AGENTS.md` and canonical rules reviewed.
- [ ] PR #111 diff, migrations, code, and tests reviewed.
- [ ] Railway/release/runtime docs and code reviewed.
- [ ] WordPress feed plugin and EventSales adapter reviewed.
- [ ] Product decisions reviewed.
- [ ] Unknown production facts remain explicit.

## Plan

- [ ] Planning agent changed no code or production state.
- [ ] Read-only preflight commands are exact.
- [ ] Deployment/migration boundary is explicit.
- [ ] Dry-run boundary is explicit.
- [ ] Apply boundary is explicit.
- [ ] Evidence/redaction rules are exact.
- [ ] Rollback limitations are documented.
- [ ] Plan review states authorised phases.

## Railway and database preflight

- [ ] Current deployed commit identified.
- [ ] Railway service topology identified.
- [ ] Database variable names/presence checked without values.
- [ ] Pooler presence/absence established.
- [ ] Direct/session-capable migration route established.
- [ ] Backup/restore readiness considered.
- [ ] PR #111 migration status checked.
- [ ] Retry columns and constraints checked.
- [ ] Active-run index exists.
- [ ] Index is unique and valid.
- [ ] Index columns and predicate exactly match contract.
- [ ] Duplicate active-run query is clean or produces a stop.
- [ ] Relevant Oban queue/job state is understood.

## Feed preflight

- [ ] Correct source-system row identified.
- [ ] Feed enabled state established.
- [ ] Feed base host checked without credentials.
- [ ] WordPress plugin/version/schema established.
- [ ] HMAC secret presence/pairing checked without exposure.
- [ ] Paging/timeout/max-page limits established.
- [ ] No raw response or signed URL retained.

## Dry-run

- [ ] Dry-run phase explicitly authorised.
- [ ] No overlapping catalog/reconciliation/backfill work.
- [ ] Full public-feed scope queued once.
- [ ] Run id recorded safely.
- [ ] Lifecycle timestamps/statuses recorded.
- [ ] Retry/failure path recorded if encountered.
- [ ] Summary counts recorded.
- [ ] Finding counts/severities/codes recorded.
- [ ] Plan snapshot presence verified.
- [ ] Dry-run hash recorded.
- [ ] Preview reloaded from durable truth.
- [ ] Human review completed.
- [ ] Blocking/ambiguous/destructive findings prevent Apply.

## Apply/no-go

- [ ] Separate decision recorded.
- [ ] Decision references exact run id and hash.
- [ ] No-go/revoke recorded when appropriate.
- [ ] Apply queued only when explicitly approved.
- [ ] Exact hash passed.
- [ ] Run reaches truthful terminal state.
- [ ] No manual state rewrite occurred.

## Post-Apply, when applicable

- [ ] Events match approved identities/metadata.
- [ ] TicketTypes match approved product/variation identities.
- [ ] ProductMappings match approved keys.
- [ ] Created/reused/adopted/updated counts reconcile.
- [ ] Dashboard/admin visibility is truthful.
- [ ] Cache/PubSub/recovery side effects assessed.
- [ ] No unrelated catalog/order data changed.

## Security and evidence

- [ ] No secret/credential/signature/raw header.
- [ ] No raw feed/webhook payload.
- [ ] No customer PII/payment/token/QR data.
- [ ] Screenshots redacted.
- [ ] SQL evidence contains only safe metadata/counts.
- [ ] Operator and approvals recorded.
- [ ] Evidence template complete.

## Certification and closeout

- [ ] Independent evidence review complete.
- [ ] Verdict recorded.
- [ ] Accepted risks explicit.
- [ ] GitHub #113 and #114 updated.
- [ ] Linear JC-105..JC-112 updated.
- [ ] VS-26E.1 remains locked unless certified.
