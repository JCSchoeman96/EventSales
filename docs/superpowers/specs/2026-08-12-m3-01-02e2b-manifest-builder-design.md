# M3-01/02E2B Production Manifest Builder + POST Activation

## Goal

Activate the authenticated Woo order-index manifest POST so one validated,
non-concurrent request captures exactly one source-consistent membership set at
one InnoDB read-view boundary `D`, persists it into one immutable E1 manifest,
and returns only after that manifest is `READY`.

This slice remains source-side only. It does not modify EventSales Elixir
consumption, `SyncRun`, `SyncCursor`, modified catch-up `H`, order retrieval,
the catalog plugin, or PR #188.

## Architecture

The existing E2A source adapter remains the only component that reads Woo
membership. A new narrowly scoped manifest builder composes that adapter with
the existing E1 manifest store. The controller remains responsible for request
size limits, the existing HMAC authentication, UTC scope validation, and the
metadata-only response envelope; it does not contain capture orchestration.

The source adapter uses one dedicated source `wpdb` connection. It proves the
Woo-selected storage mode, same authoritative database/server identity, primary
and non-read-only status, effective `REPEATABLE READ`, InnoDB source/options
tables, required columns, and the primary identity key before opening:

```sql
SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ;
START TRANSACTION WITH CONSISTENT SNAPSHOT, READ ONLY;
```

The authoritative HPOS/legacy option marker is read from that same snapshot.
The selected mode and table definition remain bound to `D`. Source reads are
identity-only, use the primary-ID keyset, exact `shop_order` type, inclusive
`[B,C]`, and chunks no larger than 100.

## Source continuation state machine

The production adapter owns continuation. No REST request, HTTP field, or
orchestration caller supplies a source cursor.

```text
confirmed_cursor
    |
    | read_next_candidate()
    v
pending_candidate(start_cursor, rows, candidate_next_id)
    |
    | E1 append succeeds
    v
confirm_persisted(candidate_next_id)
    |
    v
confirmed_cursor = candidate_next_id
```

Only one candidate may be pending. Reading before confirmation returns the
same candidate. Confirmation must bind to the exact candidate start and end;
arbitrary forward jumps, stale acknowledgements, out-of-order acknowledgements,
and confirmations for another chunk fail closed. A duplicate confirmation is
deterministically rejected unless the exact already-confirmed candidate can be
shown to be safely idempotent.

An empty candidate is the explicit terminal observation. Terminal acceptance
is allowed only after all preceding non-empty candidates have been confirmed.
The source transaction cannot commit while a candidate is pending or before
terminal acceptance.

## Builder flow

For a validated `source_system`, `B`, `C`, and request response `limit`, the
builder performs:

1. Acquire the source-scoped MySQL named lock with zero wait.
2. Run E2A preflight.
3. Open `D` on the dedicated source connection.
4. Begin one E1 `BUILDING` manifest bound to source system, `B`, `C`, the
   source-observed UTC timestamp, and the locked membership predicate version.
5. Read one internal candidate at a time.
6. Append that candidate to E1 through a separate short transaction.
7. Confirm the exact candidate only after append success.
8. Repeat until the required empty terminal candidate is observed.
9. Commit the source snapshot.
10. Finalize E1 to `READY`.
11. Read the first response page through the existing E1 READY reader using
    the requested `limit`, and return its immutable metadata.

The source capture chunk size is an internal constant of at most 100 and is
independent of POST `limit`. POST `limit` means the number of READY manifest
items returned in the first response, from 1 through 100. It does not change
source chunk size, source transaction structure, or total capture work.

On every failure before successful READY publication, the builder rolls back
the source snapshot when open, marks the E1 `BUILDING` manifest `FAILED` when
possible, releases the named lock, and returns a bounded non-sensitive error.
It never exposes BUILDING, never reopens the failed source snapshot, and never
turns a post-source-commit finalization failure into success. A retry creates a
new manifest and a new `D`.

## Capture budget

The implementation uses:

```text
CAPTURE_BUDGET_SECONDS = 5
```

This is a server-controlled initial/default hard E2B operating budget, not a
client-controlled domain value. Elapsed time is checked between every bounded
source chunk and before another source read. Exceeding it immediately stops
source work, rolls back `D`, fails the BUILDING manifest, and prevents READY.
There is no automatic escalation, `set_time_limit(0)`, or global timeout
change.

The representative local HPOS and legacy benchmark is a mandatory gate. If an
enabled storage mode cannot complete its representative capture within five
seconds, E2B is blocked for that mode rather than increasing the budget or
weakening completeness. The benchmark records source mode, total identity
space, matching identities, rows examined, chunks, snapshot wall time, PHP
peak memory, largest emitted-ID gap, and query plan/key.

## Concurrency and replay

After authentication and request validation, but before source preflight or
snapshot work, the builder acquires:

```text
GET_LOCK("eventsales:woo-order-index:capture:<source identity>", 0)
```

The source identity is deterministic and specific to the exact Woo site/source
database, not a global EventSales lock. Acquisition is connection-scoped,
zero-wait, and released in `finally`; connection death releases it naturally.
The lock is load/concurrency control only and is never membership authority.
Failure to acquire it returns bounded `busy` without weakening `D`.

The current signed request has no idempotency key. Simultaneous duplicate
requests therefore fail closed as busy. A later authenticated replay after the
first request completes intentionally creates a new source snapshot, new `D`,
and new manifest. No weak or implicit idempotency is introduced.

## Public POST and GET contract

The existing HMAC authentication runs before source work and is unchanged.
Malformed scope also returns before source work. The validated POST body remains
exactly:

```text
source_system
backfill_start
backfill_cutoff
limit
```

Successful POST is possible only after E1 reports `READY`. The response uses
the existing E1 `read_page` semantics and contains:

```text
schema_version
phase = manifest_enumerate
boundary_token
manifest_hash
manifest_expires_at_gmt
source_observed_at_gmt
items (at most requested limit, never over 100)
has_more
next_cursor only when nonterminal
terminal_evidence only when terminal
```

It contains no total count, page/offset, PII, payment data, or full order
payload. GET remains authenticated and continues to use the same E1 READY
reader and authenticated manifest-bound cursor. BUILDING and FAILED manifests
remain unreadable.

## Error and privacy boundaries

Public errors are bounded codes such as `source_preflight_failed`,
`source_snapshot_failed`, `source_authority_changed`,
`manifest_storage_failed`, `capture_budget_exceeded`,
`manifest_finalize_failed`, and `busy`. Raw exceptions, SQL, credentials,
signatures, tokens, filesystem paths, customer data, and order payloads are not
returned.

The source and manifest carry only `source_order_id`,
`source_created_at_gmt`, and `source_modified_at_gmt` plus bounded manifest
metadata. Redis, ETS, Cachex, and process memory do not become correctness
authority. No full membership array is materialized in PHP.

## Testing and validation

Preserve all E2A adversarial proof tests and E1 lifecycle/reader tests. Add
production-builder and POST coverage for:

- complete HPOS and legacy capture where the five-second benchmark permits;
- inclusive B/C boundaries and refund exclusion;
- metadata-only responses and POST first-page use of the E1 reader;
- internal cursor replay, exact acknowledgement, jump rejection, terminal and
  commit guards;
- E1 append, source query, authority, budget, and finalization failures;
- authentication-before-source-work and malformed-scope fail-closed behavior;
- concurrent lock rejection, later replay/new-D behavior, public response
  field presence, terminal evidence rules, and maximum response size;
- GET continuation regression and unchanged catalog/PR #188 boundaries.

Run PHP lint on every changed PHP file, focused PHP tests, both local source
proof modes, the representative performance gate, `git diff --check`,
`mix quality.fast`, and `mix quality.pr` when verified local Postgres is
available. Open a draft PR only after local validation; do not mark it ready.
