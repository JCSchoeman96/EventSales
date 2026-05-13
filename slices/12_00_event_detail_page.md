# Slice 12.0 — Event Detail Page

## Purpose

Give admins a per-event sales view.

## Implementation scope

```text
/admin/events, /admin/events/:id, capacity, sold/remaining, type/status breakdown, recent orders, unmapped items, export/import buttons.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 12.0 — Event Detail Page for EventSales. |
| Objective | Give admins a per-event sales view. |
| Output | /admin/events, /admin/events/:id, capacity, sold/remaining, type/status breakdown, recent orders, unmapped items, export/import buttons. |
| Note | Paginate/stream rows. Do not load all order items. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Admin event list/detail
- Nil capacity safe
- Remaining count with capacity
- Mixed-event orders filtered
- Unmapped visible
- Event policy enforced

## Architecture guardrails

Paginate/stream rows. Do not load all order items.

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
