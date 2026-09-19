# M3-F2 exact refund reference completeness implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist run-scoped refund discovery observations and references, then make historical certification prove the exact source refund set, durable detail, void evidence, and untracked-refund absence.

**Architecture:** Add two Ash/Postgres ingestion resources. Historical manifest and catch-up resolve the strict `order.refunds[]` set before source refund synchronization and write observations, reference states, memberships, and cursor progress in one transaction. The certifier starts from target historical memberships and joins only the observation/reference authority before validating existing Sales refund facts.

**Tech Stack:** Elixir, Ash 3.x, AshPostgres, Ecto/Postgres, ExUnit.

---

### Task 1: Add strict parsing and the observation/reference resources

**Files:**
- Modify `lib/event_sales/ingestion/parsers/woocommerce_refund_reference_parser.ex` and its focused test.
- Add `lib/event_sales/ingestion/resources/historical_refund_observation.ex`.
- Add `lib/event_sales/ingestion/resources/historical_refund_reference.ex`.
- Register both resources in `lib/event_sales/ingestion.ex`.
- Add resource tests and generated migration/snapshots.

- [x] Add `parse_historical/1` tests for missing, nil, explicit empty, duplicate, and malformed fields.
- [x] Implement the strict parser without changing permissive `parse/1` callers.
- [x] Add state machines: observation `manifest_resolved -> catchup_resolved`; reference `present -> absent_confirmed` with replay-safe present updates.
- [x] Generate the unique membership and observation/reference indexes.

### Task 2: Thread exact refund evidence through manifest and catch-up checkpoints

**Files:**
- Modify `lib/event_sales/ingestion/order_refund_sync.ex` only if a bounded result is needed.
- Modify `historical_manifest_execution.ex` and `historical_catchup_execution.ex`.
- Add focused execution tests for strict parsing, zero evidence, additions, confirmed/unconfirmed deletion, target changes, and checkpoint rollback.

- [x] Parse each exact Order's historical refund references before synchronization and fail closed on missing/nil fields.
- [x] Preserve HTTP and existing RefundUpserter writes outside the checkpoint transaction.
- [x] Persist or update one observation and its normalized references in the same transaction as memberships and cursor progress.
- [x] Require source deletion confirmation through `Refund.source_state == :voided`; retain `ABSENT_CONFIRMED` rows and reject reappearance.

### Task 3: Replace durable-refund-first certification with exact reference proof

**Files:**
- Modify `historical_coverage_certifier.ex` and `historical_coverage_evidence.ex`.
- Extend certifier tests and terminal catch-up tests.

- [x] Start refund completeness from current-run target memberships and require an observation for every target member.
- [x] Prove explicit zero sets, reference-count consistency, complete active details, valid voided details, and active durable refund anti-joins.
- [x] Keep existing line, currency, timestamp, and financial checks, but remove event-item attribution as the primary refund universe.
- [x] Keep coverage evidence aggregate-only without refund IDs or per-order maps.

### Task 4: Validate, review, and publish a dependent draft PR

**Files:** directly affected implementation, tests, migration/snapshots, and this plan.

- [x] Run focused parser/resource/execution/certifier tests, then format, compile, codegen, index, Credo, full tests, Dialyzer, audits, quality gates, and diff checks.
- [x] Verify no WooCommerce calls were added outside ingestion services and no D4C lock-order edge was introduced.
- [ ] Commit on `path1/m3-f2-refund-reference-proof`, push, and open exactly one draft PR against `path1/m3-completion`.
