# VS-26E.0 Redacted Evidence Pack

## Evidence policy

Allowed:

- commit/deployment identifiers;
- migration versions;
- schema object names;
- booleans;
- counts;
- safe statuses/codes;
- timestamps;
- run UUID and dry-run hash when treated as internal operational metadata;
- redacted screenshots;
- operator approvals and notes.

Forbidden:

- database URLs/credentials;
- API keys/secrets;
- HMAC signatures or raw headers;
- raw WordPress/feed/webhook payloads;
- signed URLs;
- admin passwords/cookies/session tokens;
- customer name/email/phone/address;
- payment transaction data;
- ticket/QR/delivery tokens.

## A. Identity

- Pack version:
- ZIP SHA-256:
- Baseline:
- Canonical source PR/head:
- Operator:
- Reviewer:
- Environment:
- Evidence timestamp range:

## B. Deployment

- GitHub main SHA:
- Railway active deployment SHA:
- Deployment identifier:
- Pre-deploy result:
- Health result:
- Redaction reviewed:

## C. Database topology

- Railway Postgres service:
- Pooler present: yes/no/unknown
- `DATABASE_URL` present: yes/no
- `DIRECT_DATABASE_URL` present: yes/no
- Direct/session-capable route verified: yes/no
- Values captured: no

## D. Migrations and schema

| Check | Expected | Observed | Pass |
|---|---|---|---|
| migration 20260714100000 | applied | | |
| migration 20260714100100 | applied | | |
| retry columns | present | | |
| bounds constraints | present | | |
| active-run index | present | | |
| unique/valid/ready | true | | |
| key | source_system_id | | |
| predicate | exact active statuses | | |
| duplicate active sources | zero | | |

Attach safe query output or screenshots.

## E. Oban/catalog preflight

- `tickera_sync` concurrency:
- discover jobs by state:
- apply jobs by state:
- unexplained active/retryable work:
- source-system alias/id:
- feed enabled:
- plugin/schema:
- paging limits:
- raw payload retained: no

## F. Dry-run

- Authorisation reference:
- Run id:
- Scope:
- Lifecycle timeline:
- Retry attempts:
- Summary:
  - event changes:
  - ticket-type changes:
  - mapping changes:
  - findings:
- Finding counts by severity/code:
- Snapshot present:
- Dry-run hash:
- Source snapshot time:
- Human review decision:
- Blocking/ambiguous items:

## G. Apply/no-go

- Separate decision:
- Approver:
- Decision timestamp:
- Exact run/hash match:
- Apply queued:
- Terminal state:
- Revoke/no-go reason:

## H. Post-Apply verification

| Resource | Planned create/adopt/update/reuse | Observed | Reconciled |
|---|---:|---:|---|
| Events | | | |
| TicketTypes | | | |
| ProductMappings | | | |

- Identity samples:
- Dashboard/admin state:
- PubSub/cache observations:
- Recovery jobs:
- Unrelated data changes: none / explain

## I. Security and scope

- [ ] No protected values.
- [ ] No WordPress content changed.
- [ ] No manual DB state rewrite.
- [ ] No unapproved action.
- [ ] No later-slice feature implemented.
- [ ] Evidence access is appropriate.

## J. Findings and verdict

- Blockers:
- Major findings:
- Minor findings:
- Accepted risks:
- Reviewer verdict:
- VS-26E.1 unlocked: yes/no
- Next Linear gate:
