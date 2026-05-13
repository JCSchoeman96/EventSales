# Slice 9.7 — Historical Reporting Snapshots / Materialized Views

## Purpose

Prevent long-term reports from repeatedly scanning order_items.

## Implementation scope

```text
EventAggregateSnapshot, DailySalesAggregateSnapshot, materialized view strategy docs, refresh worker, indexes.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 9.7 — Historical Reporting Snapshots / Materialized Views for EventSales. |
| Objective | Prevent long-term reports from repeatedly scanning order_items. |
| Output | EventAggregateSnapshot, DailySalesAggregateSnapshot, materialized view strategy docs, refresh worker, indexes. |
| Note | Historical reporting path planned before data grows. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Dashboard no full order_items scan on mount
- Snapshot refresh idempotent
- Refresh scoped by event/date
- Snapshot query returns expected totals
- Refresh invalidates relevant cache

## Architecture guardrails

Historical reporting path planned before data grows.

## Completion checklist

- [ ] Files/modules for this slice are created in the approved folder structure.
- [ ] Relevant Ash resources/actions/policies are implemented only where this slice owns them.
- [ ] Oban worker behavior is tested if this slice includes async work.
- [ ] LiveView/controller behavior is tested if this slice includes web UI or intake.
- [ ] Telemetry is emitted where the slice touches ingestion, REST, Oban, cache, or hot state.
- [ ] Cache invalidation is handled where durable data changes affect dashboard state.
- [ ] The global acceptance command passes.

## Stop condition

Stop and report if implementing this slice would require a direct WooCommerce call from LiveView, an untested state transition, a hardcoded secret, a Redis-as-truth shortcut, or a skipped policy/test.
