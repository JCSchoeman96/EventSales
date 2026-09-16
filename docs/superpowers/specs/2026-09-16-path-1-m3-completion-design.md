# Path 1 M3 completion design

Date: 2026-09-16
Status: Approved for implementation planning

## Decision summary

Complete M3 by finishing the existing source-safe historical ingestion design in
place. Extend `SyncRun` and the current `HistoricalCoverageCertifier` instead of
adding a separate certificate resource or merging the older unsafe pagination
implementation.

M3 completion means that bounded historical orders, order lines, refunds,
timestamps, attribution, and financial primitives are durably present and pass
the M1-08 completeness gates. M4 financial reconciliation and the final
`ANALYTICS_READY` projection remain outside this change.

## Context and current baseline

The current `main` branch is clean and synchronized with `origin/main` at the
M3-08D4B3.1 source-event-candidate checkpoint. It already contains:

- bounded M3 backfill start authority;
- durable `SyncRun` and `SyncCursor` resources with one-active-run protection;
- source-owned immutable manifest and catch-up execution;
- exact WooCommerce order fetches and idempotent order upserts;
- order-line tax primitives;
- durable refund, refund-line, and webhook integration;
- order, refund, attribution, and catalogue invalidation paths;
- a transport-oriented historical coverage certifier and current coverage
  resolver.

The current gap is that terminal manifest and catch-up evidence can certify a
transport boundary without proving the complete M3 data contract. The worker
must not mark a run complete on transport evidence alone.

The design follows these canonical documents:

- `docs/path-1/path-1-phase-breakdown.md`;
- `docs/path-1/m1-08-backfill-completeness-reconciliation-and-analytics-ready-contract.md`;
- `docs/path-1/m3-01-02c-historical-source-enumeration-contract.md`;
- `docs/EventSales_Hardened_V2_1_Domain_Mapping_Ash_Resource_Dossiers.md`.

## Goals

1. Make `ORDER_COMPLETE` and `REFUND_COMPLETE` durable, evidence-backed M3
   gates.
2. Preserve the source-safe manifest and catch-up boundary.
3. Preserve idempotent sole-writer behavior for orders, order lines, refunds,
   and refund lines.
4. Record bounded unresolved evidence and reason codes without putting a
   per-order ledger in cursor metadata.
5. Ensure later source, attribution, and catalogue mutations invalidate the
   current coverage certificate.
6. Prove the result with focused tests and the local integration workflow.

## Non-goals

- M4 financial reconciliation or exact source-to-EventSales money comparison.
- Setting the final `ANALYTICS_READY` projection.
- Changing dashboard or analytics query behavior.
- Replacing the WooCommerce source boundary.
- Applying catalogue changes or enabling catalogue auto-Apply.
- Production, Railway, VPS, public tunnel, payment, email, CRM, marketing, or
  customer-data work.

## Authority model

The existing source-safe sequence remains authoritative:

```text
queue one historical run
    -> create immutable source manifest
    -> enumerate exact manifest pages
    -> create immutable catch-up boundary
    -> fetch each exact source order ID
    -> write through existing sole writers
    -> checkpoint only after durable page work
    -> evaluate durable M3 evidence
    -> atomically certify and complete
```

The source manifest hash, source terminal proof, and checkpointed page sequence
prove membership and traversal. Page items are processed before their cursor is
advanced. The existing bounded evidence contract remains the source boundary;
the application does not add standard WooCommerce collection pagination or
silently skip a member.

`SyncRun` is the durable authority for the current M3 watermark and certificate
state. `SyncCursor` remains the authority for resumable source progress and
bounded terminal evidence. `OrderUpserter` remains the sole durable order and
order-line writer. The refund upsert and binding path remains the sole durable
refund writer.

## Durable evidence shape

Add a versioned, bounded `coverage_evidence` map to `SyncRun`. It contains only
certificate evidence and summary data, not raw source payloads or customer
information:

```text
{
  "schema_version": "...",
  "manifest_hash": "...",
  "manifest_terminal_evidence": "...",
  "catchup_hash": "...",
  "catchup_terminal_evidence": "...",
  "orders": {
    "manifest_members_seen": integer,
    "orders_durable": integer,
    "order_items_durable": integer,
    "blocking_unresolved_count": integer,
    "blocking_reasons": {"reason_code": integer}
  },
  "refunds": {
    "references_seen": integer,
    "details_complete": integer,
    "refund_lines_durable": integer,
    "blocking_unresolved_count": integer,
    "blocking_reasons": {"reason_code": integer}
  },
  "result": "certified | blocked",
  "evaluated_at": "UTC timestamp"
}
```

The map is bounded at 16 KiB and validated before persistence. Reason maps are
sorted and deterministic. Existing `SyncRun` scalar fields remain the indexed
watermark and status fields:

- `coverage_start`;
- `sales_covered_through`;
- `refunds_covered_through`;
- `order_coverage_status`;
- `refund_coverage_status`;
- `coverage_certified_at`;
- `coverage_invalidated_at`;
- `coverage_invalidation_reason`.

The exact unresolved inventory remains in durable domain records:

- `OrderItem.mapping_status` and `attribution_status_reason`;
- `Refund.detail_status` and `unresolved_reason`;
- `RefundLine.binding_reason` and `validation_reason`.

`SyncCursor.metadata` remains bounded at its current limit and does not receive
per-ID arrays, raw payloads, or customer data.

## Certification algorithm

Extend `HistoricalCoverageCertifier` so it evaluates the current run and
terminal cursor using Postgres truth only. It must not perform WooCommerce HTTP
calls.

The evaluator returns either a complete summary or all blocking findings:

```text
{:ok, summary}
{:blocked, summary}
{:retry, reason}
```

It evaluates the following gates.

### Run and source authority

- The run is a deep historical backfill for the expected source system and
  event.
- The event remains in the required backfill-pending state while certification
  is evaluated.
- `date_from` equals the event backfill start authority and is not after
  `date_to`.
- Manifest and catch-up evidence are valid, terminal, source-bound, and
  parent-bound.
- The sales and refund coverage boundaries are independently present and
  ordered.
- The run has no open transport, write, or cursor failure.

### Order completeness

- Every immutable manifest member has been fetched by exact source order ID and
  passed through the durable order writer before its page was checkpointed.
- Every relevant persisted order line has exact product and variation identity,
  quantity, currency context, gross value, and tax-inclusive primitive data.
- `line_total_tax` is present for every M3 financial line.
- `mapped`, explicit `non_ticket`, and explicit `ignored` lines are represented
  without silently disappearing.
- Pending or unmapped ticket candidates have explicit durable reason codes and
  block certification when they can affect the scoped event.
- Sale time follows the authoritative precedence `paid_at` then
  `completed_at`. A sale that has neither is withheld from recognition and is a
  blocking M3 finding when it is in the covered analytical population.

### Refund completeness

- Every refund reference returned for the covered source orders is durable.
- Every reference is either fully detailed, explicitly voided/corrected, or
  durably marked unresolved with a reason.
- Refund amounts, currency, and `source_created_at` are present when the refund
  is financially relevant.
- Every refund line is durable and either bound to the exact order item or
  explicitly unresolved with a durable reason.
- Relevant unresolved detail or binding failures block certification. Explicit
  non-ticket, void, and correction outcomes remain visible and are classified
  by reason rather than discarded.
- No pending refund-detail backlog remains at the refund boundary.

### Outcome and state transitions

On `{:ok, summary}`, one Postgres transaction locks the active run and cursor,
revalidates their authority, persists the summary and watermarks, sets both
coverage statuses to `complete`, records certification time, marks the cursor
done, and transitions the run to `completed`.

On `{:retry, reason}`, the worker leaves the run active and relies on Oban
retry. No cursor, coverage boundary, or certificate advances.

On `{:blocked, summary}`, the summary and blocking reasons are durable, the
certificate remains absent, and the run never transitions to `completed`. The
affected coverage status is marked `failed`, the cursor is marked failed with
bounded failure metadata, and the run transitions to `failed` so the active-run
guard is released. The evidence remains available for diagnosis and a new
controlled run can be queued after repair.

Transport terminality alone never completes a run.

## Failure, replay, and concurrency behavior

- A page write failure never advances its cursor.
- A duplicate Oban delivery or source replay is handled by existing identity
  constraints and upsert paths.
- The final certification transaction locks the run and cursor and rechecks
  `coverage_certified_at` and current run status before writing.
- The existing one-active historical-run partial unique index remains in force.
- A concurrent mutation cannot leave a valid certificate behind because
  certification and invalidation use the same durable authority and the
  invalidated state is rejected by `HistoricalCoverageResolver`.
- Invalidations preserve historical audit fields, but current coverage is
  non-current until a later run is certified.
- No source HTTP call occurs while a Postgres row lock is held.

## Expected implementation areas

The implementation plan will inspect and modify only the directly affected
areas:

- `lib/event_sales/ingestion/resources/sync_run.ex`;
- the migration for the bounded coverage evidence field;
- `lib/event_sales/ingestion/historical_coverage_certifier.ex`;
- `lib/event_sales/ingestion/historical_coverage_resolver.ex`;
- `lib/event_sales/ingestion/historical_catchup_execution.ex`;
- `lib/event_sales/ingestion/workers/backfill_orders_worker.ex` if terminal
  outcome handling requires it;
- focused sales and refund query/helpers only where the current Ash resources
  do not expose the needed evidence;
- focused ingestion tests and M3 contract tests;
- the current Path 1 roadmap and handoff documentation.

No separate historical certificate resource or general-purpose reconciliation
abstraction is planned.

## Verification design

Focused automated tests will prove:

- a fully complete historical run is certified;
- missing order lines, tax, sale time, or ticket attribution block it;
- missing refund detail, refund time, refund lines, or binding evidence block
  it;
- void and correction outcomes are represented correctly;
- malformed or nonterminal source evidence blocks it;
- retryable failures do not advance the cursor;
- duplicate delivery remains idempotent;
- final certification is atomic and race-safe;
- post-certification order, refund, attribution, and catalogue mutations
  invalidate current coverage.

At slice completion, run the focused tests, compile with warnings as errors,
the relevant architecture boundary check, and `mix quality.fast`. Start and
inspect the local integration environment only through:

```bash
bash scripts/dev_local.sh doctor
bash scripts/dev_local.sh status
bash scripts/dev_local.sh
```

The local check must use localhost-only services and must not Apply catalogue
changes or activate unrelated WordPress integrations.

## Completion criteria

M3 is reported complete only when:

1. all M3 gates in the Path 1 roadmap and M1-08 contract are implemented;
2. focused tests and `mix quality.fast` pass;
3. one relevant local integration check passes;
4. no architecture boundary is violated;
5. no unrelated files or runtime integrations are changed;
6. a coherent feature-branch commit exists;
7. the roadmap records M3 complete and M4 remains the next gate.
