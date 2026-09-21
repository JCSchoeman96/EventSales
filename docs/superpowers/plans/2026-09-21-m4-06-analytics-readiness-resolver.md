# M4-06 derived analytics readiness resolver implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Derive a read-only `ANALYTICS_READY` result from the current M3 certificate and the newest terminal M4 reconciliation bound to that certificate.

**Architecture:** `AnalyticsReadinessResolver.resolve/1` validates the Event UUID, delegates current-certificate authority to `HistoricalCoverageResolver.resolve_current/1`, reads one newest terminal `FinancialReconciliationRun` for that exact certificate, and reads bounded findings only for the selected run. It returns an ordinary not-ready result for durable pending or failed evidence and never writes, caches, invalidates, or reconstructs M3 certification.

**Tech Stack:** Elixir 1.19, Ash 3.x, AshPostgres, Ecto UUID validation, PostgreSQL-backed `EventSales.DataCase`, ExUnit.

---

### Task 1: Add the focused resolver test contract

**Files:**
- Create: `test/event_sales/ingestion/analytics_readiness_resolver_test.exs`
- Read: `test/support/financial_reconciliation_helpers.ex`
- Read: `test/event_sales/ingestion/financial_reconciliation_runs_test.exs`

- [x] **Step 1: Write tests for the required durable outcomes.**

Cover invalid UUID errors, missing current M3, no terminal run, queued/running-only pending, latest PASS, active recheck preserving PASS, newest terminal mismatch/failure/superseded/cancelled overriding an older PASS, exact certificate and copied-scope binding, nil terminal `finished_at`, deterministic finding priority, PASS plus finding fail-closed, and certified boundaries.

- [x] **Step 2: Run the focused file before production code.**

Run `mix test test/event_sales/ingestion/analytics_readiness_resolver_test.exs`.

Expected result: the file fails because `EventSales.Ingestion.AnalyticsReadinessResolver` does not exist yet, while the test setup and fixture errors are corrected until the failure is specifically the missing resolver.

### Task 2: Implement the bounded read-only resolver

**Files:**
- Create: `lib/event_sales/ingestion/analytics_readiness_resolver.ex`
- Do not modify: existing M3/M4 resources, migrations, or readiness storage.

- [x] **Step 1: Add the explicit result and reason types.**

Return a map with `analytics_ready?`, `blocking_reason`, `event_id`, both run IDs, and the three M3 coverage boundaries. Keep terminal statuses and structural finding priority as module constants.

- [x] **Step 2: Delegate current M3 lookup and map errors.**

Call `HistoricalCoverageResolver.resolve_current/1` exactly once. Return `:invalid_event_id` as an error. Return fail-closed ordinary results for `:historical_coverage_not_current` and `:historical_coverage_lookup_failed`; never search older certificates.

- [x] **Step 3: Query one newest terminal M4 run.**

Filter by requested `event_id`, exact `historical_sync_run_id`, and terminal statuses. Sort `finished_at` descending with nils last, then `inserted_at` and `id` descending, and limit one. Inspect the selected row's status after selection. Validate event, source, certificate ID, and all copied scope fields against the current M3 run; nil `finished_at` or a mismatch fails closed.

- [x] **Step 4: Read selected-run findings and derive the result.**

Use a small bounded findings query. Refine only the four locked categories with an explicit priority. A selected PASS with any structural finding returns `:financial_reconciliation_evidence_invalid`; otherwise PASS is ready. MISMATCHED, FAILED, and SUPERSEDED return failed; CANCELLED and no terminal return pending. Active rows do not suppress an older terminal PASS.

- [x] **Step 5: Run focused tests and format.**

Run `mix test test/event_sales/ingestion/analytics_readiness_resolver_test.exs` and `mix format --check-formatted`. Fix implementation errors without changing the tests' locked expectations.

### Task 3: Regenerate repository indexes and verify the slice

**Files:**
- Generated: `INDEX.md`
- Generated: `docs/architecture/module_manifest.json`
- Existing contract documents remain unchanged because they already exist on the baseline.

- [x] **Step 1: Regenerate and check project indexes.**

Run `mix project.index` followed by `mix project.index --check`.

- [x] **Step 2: Run required static and test gates.**

Run `mix compile --warnings-as-errors`, `mix ash.codegen --dry-run`, `mix credo --strict`, the full `mix test`, `mix dialyzer`, `mix hex.audit`, `mix deps.audit`, `mix quality.fast`, `mix quality.pr`, and `git diff --check`.

- [x] **Step 3: Inspect the final diff.**

Confirm only the resolver, focused tests, plan, and generated indexes changed. Confirm there is no migration, Event field, resource, dependency, HTTP, cache, worker, PubSub, or mutation change.

- [ ] **Step 4: Commit the coherent implementation checkpoint.**

Run `git add lib/event_sales/ingestion/analytics_readiness_resolver.ex test/event_sales/ingestion/analytics_readiness_resolver_test.exs docs/superpowers/plans/2026-09-21-m4-06-analytics-readiness-resolver.md INDEX.md docs/architecture/module_manifest.json` and commit with `git commit -m "feat: derive analytics readiness from financial evidence"`.
