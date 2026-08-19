# M3-08A Durable Historical Coverage Watermark Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add durable historical coverage watermark fields and controlled certification/invalidation actions to `SyncRun` without certifying existing runs or integrating terminal execution.

**Architecture:** Reuse `EventSales.Ingestion.Resources.SyncRun` as the certification identity and keep `SyncCursor` as transport evidence. Persist nullable boundaries, independent order/refund coverage statuses, and audit timestamps/reason on `ingestion_sync_runs` through one additive migration; keep all authority evaluation and callers for later slices.

**Tech Stack:** Elixir, Ash 3.x, AshPostgres, Ecto migrations, ExUnit, PostgreSQL.

---

### Task 1: Add the failing coverage-model tests

**Files:**
- Modify: `test/event_sales/ingestion/resources/sync_run_test.exs`

- [ ] **Step 1: Add test helpers and default coverage assertions**

Create historical and ordinary `SyncRun` fixtures using the existing
`SalesHelpers`, then assert a newly persisted run has
`order_coverage_status == :incomplete`, `refund_coverage_status == :not_started`,
and nil coverage boundaries/audit timestamps.

- [ ] **Step 2: Add failing certification and invalidation examples**

Add focused tests for:

```elixir
record_coverage_certification: exact boundaries, both statuses complete,
  certified_at set, later refund boundary accepted
coverage_start > sales_covered_through: rejected
non-historical run: rejected
second certification: rejected
invalidate_order_coverage: both statuses incomplete and original audit retained
invalidate_refund_coverage: refund incomplete, order unchanged, audit retained
invalid reason: rejected
existing ordinary run: remains uncertified
```

Use `Ash.update/4` with the named actions and assert `Ash.Error.Invalid` for
rejections. Keep the tests in the existing resource test module.

- [ ] **Step 3: Run the new focused tests to verify the expected red failure**

Run:

```bash
mix test test/event_sales/ingestion/resources/sync_run_test.exs
```

Expected: the pre-existing 15 tests pass and the new coverage tests fail
because the attributes/actions do not yet exist.

### Task 2: Implement the SyncRun watermark attributes and actions

**Files:**
- Modify: `lib/event_sales/ingestion/resources/sync_run.ex`

- [ ] **Step 1: Add the contract constants**

Define private module constants for order coverage statuses, refund coverage
statuses, and the exact invalidation reason vocabulary:

```elixir
@order_coverage_statuses [:incomplete, :complete, :failed]
@refund_coverage_statuses [:not_started, :incomplete, :complete, :failed]
@coverage_invalidation_reasons [
  :source_identity_conflict,
  :historical_attribution_changed,
  :source_range_gap,
  :historical_order_changed,
  :historical_refund_changed,
  :historical_fact_corrected,
  :currency_conflict,
  :financial_reconciliation_failed
]
```

- [ ] **Step 2: Add the narrowly scoped update actions**

Add private/internal actions that accept only their declared attributes:

```elixir
update :record_coverage_certification do
  accept [:coverage_start, :sales_covered_through, :refunds_covered_through]
  require_atomic? false
  validate &__MODULE__.validate_coverage_certification/2
  change &__MODULE__.record_coverage_certification/2
end

update :invalidate_order_coverage do
  accept [:coverage_invalidation_reason]
  require_atomic? false
  validate present(:coverage_invalidation_reason)
  change &__MODULE__.invalidate_order_coverage/2
end

update :invalidate_refund_coverage do
  accept [:coverage_invalidation_reason]
  require_atomic? false
  validate present(:coverage_invalidation_reason)
  change &__MODULE__.invalidate_refund_coverage/2
end
```

Use the resource’s existing action visibility convention to keep these actions
out of public UI/operator authority.

- [ ] **Step 3: Add the attributes with defaults and constraints**

Add the five nullable UTC attributes, non-null order/refund status attributes
with the specified defaults and `one_of` constraints, and the nullable reason
attribute with its narrow `one_of` constraint. Keep all watermark attributes
out of the default create accepts so ordinary run creation cannot claim
coverage.

- [ ] **Step 4: Add resource-local validation and changes**

Implement validation that requires `sync_type == :historical_backfill`, all
three certification boundaries, `coverage_start <= sales_covered_through`,
and a nil existing certification timestamp. Implement changes that set both
statuses complete and server UTC certification time while clearing invalidation
fields; invalidation changes preserve all original boundaries/certification
time and set the requested status scope plus server UTC invalidation time.

Ensure invalidation reason constraints reject values outside the contract
vocabulary.

### Task 3: Add the additive migration and verify green

**Files:**
- Create: `priv/repo/migrations/20260819120000_m3_08a_historical_coverage_watermark.exs`
- Modify: `test/event_sales/ingestion/resources/sync_run_test.exs` only if the migration/default assertion needs a database-level check

- [ ] **Step 1: Write the one additive migration**

Alter `ingestion_sync_runs` with the five nullable timestamp/reason columns
and two status columns. Give the status columns non-null database defaults
matching the resource defaults. Do not add an index, table, or data update.

- [ ] **Step 2: Run the migration and focused tests**

Run:

```bash
mix ecto.migrate
mix test test/event_sales/ingestion/resources/sync_run_test.exs
```

Expected: all focused tests pass, including proof that an ordinary existing
run remains uncertified.

- [ ] **Step 3: Format and compile the changed code**

Run:

```bash
mix format
mix compile --warnings-as-errors
```

Expected: both commands exit successfully with no warnings-as-errors.

### Task 4: Run repository quality gates and review scope

**Files:**
- No additional production files.

- [ ] **Step 1: Run Ash and project consistency checks**

Run:

```bash
mix format --check-formatted
mix ash.codegen --dry-run
mix project.index
mix project.index --check
```

- [ ] **Step 2: Run focused/full quality checks**

Run:

```bash
mix credo --strict
mix test
mix dialyzer
mix hex.audit
mix quality.fast
mix quality.pr
```

- [ ] **Step 3: Inspect the final diff and boundary compliance**

Run:

```bash
git diff --check
git diff main...HEAD --stat
git diff main...HEAD -- lib/event_sales/ingestion/resources/sync_run.ex priv/repo/migrations test/event_sales/ingestion/resources/sync_run_test.exs
```

Confirm no changes to historical execution, workers, order/refund writers,
webhooks, event state, cursor metadata, indexes, caches, or new resources.

- [ ] **Step 4: Commit the coherent slice**

```bash
git add docs/superpowers/specs/2026-08-19-m3-08a-coverage-watermark-model-design.md docs/superpowers/plans/2026-08-19-m3-08a-coverage-watermark-model.md lib/event_sales/ingestion/resources/sync_run.ex priv/repo/migrations/20260819120000_m3_08a_historical_coverage_watermark.exs test/event_sales/ingestion/resources/sync_run_test.exs
git commit -m "feat: add historical coverage watermark model"
```

- [ ] **Step 5: Push and open one draft PR**

```bash
git push -u origin path1/m3-08a-coverage-watermark-model
gh pr create --draft --base main --head path1/m3-08a-coverage-watermark-model --title "Path 1 M3-08A: add durable historical coverage watermark" --body-file /tmp/m3-08a-pr-body.md
```

The PR body must state that certification evaluation, terminal integration,
invalidation hooks, financial reconciliation, `ANALYTICS_READY`, M4, M5,
Redis/ETS/Cachex, and Path 2 are not implemented.
