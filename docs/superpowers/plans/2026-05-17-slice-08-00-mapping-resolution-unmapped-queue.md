# Slice 8.0 Mapping Resolution and Unmapped Queue Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve local WooCommerce product mappings onto normalized order items and expose pending/unmapped rows in a protected read-only admin queue.

**Architecture:** `MappingResolver` performs pure local Ash reads against `ProductMapping`; `OrderItemMapper` applies results through existing `OrderItem` Ash actions and only mutates pending rows. The admin queue is read-only and protected by the existing internal admin pipeline.

**Tech Stack:** Elixir, Phoenix LiveView, Ash, AshPostgres, Oban test helpers.

---

## Task 1: MappingResolver

**Files:**
- Modify: `lib/event_sales/catalog/mapping_resolver.ex`
- Test: `test/event_sales/catalog/mapping_resolver_test.exs`

- [ ] Write resolver tests for product mapping, variation mapping, variation precedence, product fallback, inactive mappings, nil variation, and unknown products.
- [ ] Run `mix test test/event_sales/catalog/mapping_resolver_test.exs` and confirm the placeholder module fails the tests.
- [ ] Implement `EventSales.Catalog.MappingResolver.resolve/3` using only Ash reads against `ProductMapping`.
- [ ] Run `mix test test/event_sales/catalog/mapping_resolver_test.exs` and confirm it passes.

## Task 2: OrderItemMapper

**Files:**
- Modify: `lib/event_sales/sales/order_item_mapper.ex`
- Test: `test/event_sales/sales/order_item_mapper_test.exs`

- [ ] Write mapper tests proving pending rows map, unknown rows stay pending, and mapped/non_ticket/ignored/unmapped rows are unchanged.
- [ ] Write queue tests proving pending and unmapped rows are returned while mapped/non_ticket/ignored rows are excluded.
- [ ] Run `mix test test/event_sales/sales/order_item_mapper_test.exs` and confirm the placeholder module fails the tests.
- [ ] Implement `map_item/1`, `map_pending_items_for_order/1`, and `list_unmapped_queue/1` using existing Ash actions for state changes.
- [ ] Run `mix test test/event_sales/sales/order_item_mapper_test.exs` and confirm it passes.

## Task 3: OrderUpserter Integration

**Files:**
- Modify: `lib/event_sales/sales/order_upserter.ex`
- Modify: `test/event_sales/sales/order_upserter_test.exs`
- Modify: `test/event_sales/sales/status_rules_test.exs`

- [ ] Add tests proving mapped products are mapped after order upsert and unknown products stay pending.
- [ ] Add status-rule coverage for completed mapped ticket, pending, unmapped, and non-ticket exclusions.
- [ ] Run the focused tests and confirm the new integration expectations fail before implementation.
- [ ] Call `OrderItemMapper.map_pending_items_for_order/1` after durable child-row upsert succeeds.
- [ ] Run the focused tests and confirm they pass.

## Task 4: Read-Only Admin Queue

**Files:**
- Modify: `lib/event_sales_web/router.ex`
- Modify: `lib/event_sales_web/live/admin/mappings_live.ex`
- Test: `test/event_sales_web/live/admin/mappings_live_test.exs`

- [ ] Add LiveView route tests for unauthenticated rejection, non-admin rejection, admin loopback access, and non-loopback blocking.
- [ ] Add a route test proving a pending queue row renders for an admin.
- [ ] Run `mix test test/event_sales_web/live/admin/mappings_live_test.exs` and confirm the missing route/view fails.
- [ ] Add `GET /internal/mappings` under `pipe_through [:browser, :internal_admin_tools]`.
- [ ] Implement a fixed-limit read-only table in `MappingsLive`.
- [ ] Run `mix test test/event_sales_web/live/admin/mappings_live_test.exs` and confirm it passes.

## Task 5: Boundary and Quality Gates

**Files:**
- Modify tests only if existing boundary assertions need path coverage.

- [ ] Run `bash scripts/check_no_web_woocommerce_refs.sh`.
- [ ] Run all focused tests listed in the approved plan.
- [ ] Run `mix quality.pr` before opening or updating a PR.
- [ ] Run `mix quality.ci` before marking ready.
