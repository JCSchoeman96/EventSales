# Slice 3.0 — Catalog Resources and Product Mapping

## Purpose

Model events, ticket types, and WooCommerce mappings.

## Implementation scope

```text
SourceSystem, Event, TicketType, ProductMapping, EventDashboardSetting.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 3.0 — Catalog Resources and Product Mapping for EventSales. |
| Objective | Model events, ticket types, and WooCommerce mappings. |
| Output | SourceSystem, Event, TicketType, ProductMapping, EventDashboardSetting. |
| Note | Mapping changes must enqueue recalculation and invalidate caches. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Event belongs to SourceSystem
- TicketType belongs to Event
- ProductMapping supports product and optional variation
- Duplicate active mapping rejected
- Capacity may be nil
- Dashboard settings store revenue visibility

## Architecture guardrails

Mapping changes must enqueue recalculation and invalidate caches.

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
