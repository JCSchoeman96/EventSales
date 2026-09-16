# Path 1 M3 Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]` syntax for tracking.

**Goal:** Complete Path 1 M3 by making historical coverage certification prove durable orders, order lines, refunds, attribution, financial primitives, and effective timestamps, then persist bounded certificate evidence and finish or fail the bounded run atomically.

**Architecture:** Extend the existing Ash resources, historical manifest/catch-up execution, and sole-writer order/refund upserters. Add a versioned bounded evidence map to SyncRun, derive certification facts from local Postgres inside a read-only snapshot, and make terminal certification, cursor completion, or bounded failure one transaction. Keep M4 reconciliation and final ANALYTICS_READY out of scope.

**Tech Stack:** Elixir, Phoenix, Ash 3.x, AshPostgres, Ecto/Postgres, Oban, ExUnit, existing local Docker Postgres/Redis runtime.

---

## Task 1: Add the bounded coverage-evidence contract and SyncRun persistence

**Files:**

- Add \`lib/event_sales/ingestion/historical_coverage_evidence.ex\`
- Add \`priv/repo/migrations/20260916100000_m3_08e_historical_coverage_evidence.exs\`
- Modify \`lib/event_sales/ingestion/resources/sync_run.ex\`
- Add \`test/event_sales/ingestion/historical_coverage_evidence_test.exs\`
- Add \`test/support/historical_coverage_helpers.ex\`
- Modify direct certificate fixtures in the existing ingestion, catalog, and sales tests to include valid evidence.

- [ ] Write failing unit tests for valid certified and blocked evidence, malformed hashes, missing nested keys, negative counters, unsupported results, and the 16 KiB encoded-size limit.
- [ ] Implement \`HistoricalCoverageEvidence\` with a versioned exact schema, bounded proof strings, normalized reason counts, UTC timestamps, validation, and \`certified?/1\` / \`blocked?/1\` predicates.
- [ ] Add the non-null Postgres map column with an empty-map default.
- [ ] Add \`coverage_evidence\` to SyncRun and require certified evidence in \`record_coverage_certification\`.
- [ ] Add the SyncRun \`fail_coverage\` action for blocked terminal evidence. It must persist the bounded evidence and boundaries, mark order/refund coverage failed, finish the run as failed, and release the active-run guard.
- [ ] Run the focused evidence and SyncRun tests.

Expected command and result:

~~~bash
MIX_ENV=test mix test test/event_sales/ingestion/historical_coverage_evidence_test.exs test/event_sales/ingestion/resources/sync_run_test.exs
~~~

Expected result: all focused tests pass, with no migration or resource validation errors.

## Task 2: Certify durable historical facts from Postgres

**Files:**

- Modify \`lib/event_sales/ingestion/historical_coverage_certifier.ex\`
- Modify \`test/event_sales/ingestion/historical_coverage_certifier_test.exs\`
- Add focused fixture helpers under \`test/support/\` only if the existing resource factories cannot express the required facts.

- [ ] Add failing tests covering a complete order and ticket line, tax-inclusive line primitive, sale effective time, exact event attribution, complete refund details and lines, refund effective time, and certified aggregate counts.
- [ ] Add failing blocked tests for incomplete order history, missing tax primitive, missing sale effective time, pending or unmapped attribution, source-event identity conflict, incomplete refund details, missing refund timestamp, wrong-parent refund binding, missing refund-line binding, validation conflicts, and missing refund financial primitives.
- [ ] Implement parameterized aggregate queries scoped by source system, event identity, and bounded timestamps. Do not load raw payloads or per-ID ledgers into evidence.
- [ ] Preserve existing authority, range, terminal-proof, and invalidation guards.
- [ ] Return \`{:ok, summary}\`, \`{:blocked, summary}\`, \`{:retry, :coverage_evidence_read_failed}\`, or the existing authority error shape. The summary must include scalar boundaries and the bounded evidence map.
- [ ] Keep the evaluation read-only and do not perform source HTTP while database locks are held.
- [ ] Run the focused certifier tests.

Expected command and result:

~~~bash
MIX_ENV=test mix test test/event_sales/ingestion/historical_coverage_certifier_test.exs
~~~

Expected result: complete fixtures certify, incomplete fixtures block with stable reason codes, and database read failures return the retry outcome.

## Task 3: Make terminal completion, blocked failure, and retry atomic

**Files:**

- Modify \`lib/event_sales/ingestion/historical_catchup_execution.ex\`
- Modify \`lib/event_sales/ingestion/workers/backfill_orders_worker.ex\`
- Modify \`test/event_sales/ingestion/historical_catchup_execution_test.exs\`
- Modify \`test/event_sales/ingestion/workers/backfill_orders_worker_test.exs\` or the closest existing worker test file.

- [ ] Write failing terminal tests for certified completion, blocked coverage, retryable evidence reads, and replay/idempotency.
- [ ] Extend terminal transaction handling so certification evidence is written before cursor and run completion. A blocked result writes failed cursor/run evidence in the same transaction. A retry result performs no terminal writes and is retried by Oban.
- [ ] Preserve row-lock ordering and run authority checks; never hold locks while making WooCommerce requests.
- [ ] Add bounded failure metadata and worker handling for blocked and retry outcomes. Do not run the normal failure path again after the transaction has already marked a blocked run failed.
- [ ] Run the focused catch-up and worker tests.

Expected command and result:

~~~bash
MIX_ENV=test mix test test/event_sales/ingestion/historical_catchup_execution_test.exs test/event_sales/ingestion/workers/backfill_orders_worker_test.exs
~~~

Expected result: terminal success, bounded failure, and retry paths pass without duplicate rows or inconsistent run/cursor status.

## Task 4: Require valid evidence when resolving current historical coverage

**Files:**

- Modify \`lib/event_sales/ingestion/historical_coverage_resolver.ex\`
- Modify \`test/event_sales/ingestion/historical_coverage_resolver_test.exs\`
- Modify \`test/event_sales/ingestion/historical_coverage_invalidator_test.exs\`
- Modify \`test/event_sales/ingestion/historical_refund_coverage_invalidator_test.exs\`
- Modify any existing historical-coverage certificate fixtures that construct completed runs directly.

- [ ] Add failing tests proving empty, malformed, and blocked evidence cannot make a run current.
- [ ] Require valid certified evidence in the resolver while preserving the existing status, timestamp, boundary, and invalidation checks.
- [ ] Confirm invalidation keeps audit evidence and certificate timestamps but makes the resolver reject the run.
- [ ] Run all historical coverage resolver and invalidator tests.

Expected command and result:

~~~bash
MIX_ENV=test mix test test/event_sales/ingestion/historical_coverage_resolver_test.exs test/event_sales/ingestion/historical_coverage_invalidator_test.exs test/event_sales/ingestion/historical_refund_coverage_invalidator_test.exs
~~~

Expected result: only runs with valid certified evidence and valid non-invalidated coverage resolve as current.

## Task 5: Run the M3 regression set and resolve concrete failures

**Files:**

- Modify only directly affected implementation, migration, tests, and test support files.

- [ ] Run the complete focused M3 ingestion and sales regression set.
- [ ] If a test fails, use the existing systematic-debugging workflow: reproduce one failure, inspect the direct cause, make the smallest fix, and rerun the smallest relevant test before continuing.
- [ ] Run the architecture boundary check and compile with warnings as errors.
- [ ] Verify no new source WooCommerce calls were introduced outside approved ingestion services/workers.

Expected commands and results:

~~~bash
MIX_ENV=test mix test test/event_sales/ingestion test/event_sales/sales
mix compile --warnings-as-errors
bash scripts/check_no_web_woocommerce_refs.sh
~~~

Expected result: the focused M3 test directories pass, compilation passes without warnings, and the boundary script reports no violations.

## Task 6: Update M3 status, run quality gates, and create the implementation checkpoint

**Files:**

- Modify \`docs/path-1/path-1-phase-breakdown.md\`
- Modify \`docs/roadmap/current-state-and-path-handoff.md\`
- Modify \`docs/superpowers/plans/2026-09-16-path-1-m3-completion.md\` to mark completed checkboxes.

- [ ] Record M3-01 through M3-08 as complete with the actual tests and evidence implemented. Leave M4 and ANALYTICS_READY explicitly pending.
- [ ] Run the canonical local-runtime diagnostics. If WordPress is unavailable, preserve the exact localhost-only blocker and use the local Postgres-backed focused proof already available; do not contact a remote target.
- [ ] Run \`mix quality.fast\` after all implementation and documentation changes.
- [ ] Inspect the final diff for scope, secrets, and unrelated changes.
- [ ] Commit the coherent implementation checkpoint on \`path1/m3-completion\`.

Expected commands:

~~~bash
bash scripts/dev_local.sh doctor
bash scripts/dev_local.sh status
mix quality.fast
git diff --check
git status --short
git diff --stat
git add lib priv test docs
git commit -m "feat: complete Path 1 M3 historical coverage"
~~~

Expected result: quality.fast passes, local diagnostics report only the known localhost WordPress availability issue if it remains, the diff is focused, and a coherent local commit exists.

## Self-review checklist

- [ ] No raw payloads, customer data, or per-ID arrays are persisted in coverage evidence.
- [ ] Evidence is bounded and validated before it is stored.
- [ ] Order and refund sole-writer ownership is preserved.
- [ ] Sale and refund effective-time rules fail closed.
- [ ] Exact event and variation identities remain intact.
- [ ] Terminal success, blocked failure, and retry behavior are idempotent and race-safe.
- [ ] Resolver rejects legacy or invalid certificates without evidence.
- [ ] M4 reconciliation and final analytics readiness remain out of scope.
- [ ] No secrets are present in tracked files or command output.
