# M3-08D4R OrderItem to Refund Allocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Invalidate Refund coverage when a canonical OrderItem mutation changes an existing Refund's Event allocation, while preserving D3A's separate Refund source-truth semantics.

**Architecture:** Add a read-only allocation authority beside `HistoricalRefundMutationDetector`. It evaluates one Refund snapshot against parent OrderItem evidence and returns an allocation mode plus bounded Event IDs. A parent mutation captures all affected Refunds before and after OrderItem writes, compares those values, and calls the existing D3B invalidator for the sorted before/after Event union inside the writer's outer transaction. Source-absent deletion must preserve exact allocation evidence through a durable tombstone or immutable evidence record before it can be certified.

**Tech Stack:** Elixir, Ash 3.x, Ecto/Postgres, ExUnit, Phoenix application services.

**Status:** D4R1 through D4R4 implemented. Direct OrderItem actions were
audited and have no current production caller outside the covered writers, so
they remain future hardening rather than an implementation slice.

---

### Task 1: Shared allocation authority

**Files:**
- Create: `lib/event_sales/ingestion/historical_refund_order_item_impact_resolver.ex`
- Modify: `lib/event_sales/ingestion/historical_refund_mutation_detector.ex`
- Test: `test/event_sales/ingestion/historical_refund_order_item_impact_resolver_test.exs`
- Test: `test/event_sales/ingestion/historical_refund_mutation_detector_test.exs`

- [x] Write focused tests for exact mapped allocation, parent-wide fallback, no-ticket allocation, missing OrderItem evidence, and deterministic before/after Event unions.
- [x] Run the focused resolver tests before implementation, then implement the read-only resolver that consumes a captured Refund snapshot and returns `%{refund_id: id, allocation_mode: mode, event_ids: ids}`. Reuse the detector's exact-bound and parent-wide rules without changing `compare/2` or `certificate_truth/1`.
- [x] Add an impact comparison that reports `changed?` when allocation mode or Event IDs differ and returns the sorted union of before and after Events.
- [x] Run the resolver and detector tests until green, then format and compile with warnings as errors.
- [x] Commit the shared authority and tests.

### Task 2: OrderUpserter integration

**Files:**
- Modify: `lib/event_sales/sales/order_upserter.ex`
- Modify: `lib/event_sales/ingestion/historical_refund_coverage_invalidator.ex` only if a transaction-aware entry point is required
- Test: `test/event_sales/sales/order_upserter_refund_allocation_test.exs`
- Test: `test/event_sales/sales/order_upserter_historical_coverage_test.exs`

- [x] Write focused integration tests for mapped Event A to B, source-absent FK NILIFY, and rollback when Refund allocation invalidation fails.
- [x] Run the new focused tests before implementation, then integrate OrderUpserter with parent-scoped BEFORE/AFTER Refund allocation capture.
- [x] Preserve deterministic Refund ordering and the existing parent Order transaction owner.
- [x] Capture after evidence, compare every Refund, union all changed before/after Event IDs, and call D3B through the existing D4C1 fence before the outer transaction commits.
- [x] Allow the real `ON DELETE NILIFY` behavior to run. Do not manually rewrite RefundLines to avoid the FK. The BEFORE snapshot retains the deleted OrderItem and Event evidence; if D3B fails, the caller's outer transaction rolls back the deletion and the FK effect.
- [x] Run focused tests, format, compile, and commit.

### Task 3: MissingCatalogResolver integration

**Files:**
- Modify: `lib/event_sales/catalog/missing_catalog_resolver.ex`
- Test: `test/event_sales/catalog/missing_catalog_resolver_refund_allocation_test.exs`

- [x] Write focused tests for pending to mapped and pending to unmapped transitions on an Order with existing Refunds.
- [x] Run the focused tests before implementation, then add the same parent-scoped before/after Refund allocation capture to `recover_order/5`, preserving the existing Order lock and transaction owner.
- [x] Call D3B for the sorted Event union when allocation changes and roll back the recovery on failure.
- [x] Run focused tests, format, compile, and commit.

### Task 4: OrderAttributionCorrection integration

**Files:**
- Modify: `lib/event_sales/sales/order_attribution_correction.ex`
- Test: `test/event_sales/sales/order_attribution_correction_refund_allocation_test.exs`

- [x] Write a focused test for an audited Event A to Event B correction with a RefundLine bound to the corrected OrderItem.
- [x] Run the focused test before implementation, then capture all parent Refund allocation evidence before the correction, apply the existing correction action, capture after evidence, and call D3B for the before/after Event union inside the correction transaction.
- [x] Preserve the existing Order lock, audit write, and D4C1 fence behavior.
- [x] Run focused tests, format, compile, and commit.

### Task 5: Direct OrderItem action hardening and deletion evidence

**Files:**
- Modify: `lib/event_sales/sales/resources/order_item.ex` only if direct actions must be restricted
- Modify: `lib/event_sales/sales/order_item_mapper.ex` only if direct callers need routing
- Create or modify the smallest durable evidence resource and migration only after a failing deletion-certification test proves it is required
- Test: focused OrderItem action and FK deletion tests

Audit result: no current production caller bypasses the covered parent Order
transaction. `:remap`, `:mark_non_ticket`, and `:mark_ignored` remain unused
direct actions and are future hardening only. Real FK NILIFY is covered by the
OrderUpserter transaction tests, so no tombstone resource or migration is
required for this slice.

### Completion checks

- [x] Run all focused D4R tests and the directly affected existing tests.
- [x] Run `mix quality.fast`.
- [x] Verify `bash scripts/check_no_web_woocommerce_refs.sh` passes.
- [x] Review the complete diff for unrelated changes and secret exposure.
- [ ] Use the finishing-a-development-branch workflow before merge, push, or worktree cleanup.
