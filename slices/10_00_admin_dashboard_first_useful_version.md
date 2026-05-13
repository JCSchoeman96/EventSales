# Slice 10.0 — Admin Dashboard First Useful Version

## Purpose

Give internal admins a useful dashboard from EventSales data only.

## Implementation scope

```text
/admin/dashboard, KPI cards, tickets/revenue/statuses/by event/by type, recent orders, alerts, manual refresh.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 10.0 — Admin Dashboard First Useful Version for EventSales. |
| Objective | Give internal admins a useful dashboard from EventSales data only. |
| Output | /admin/dashboard, KPI cards, tickets/revenue/statuses/by event/by type, recent orders, alerts, manual refresh. |
| Note | Dashboard reads cache/Postgres only. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Admin can view
- Unauthenticated cannot
- Completed tickets/revenue rendered
- Statuses rendered
- Unmapped alerts rendered
- Manual refresh does not call Woo
- Manual refresh rate-limited

## Architecture guardrails

Dashboard reads cache/Postgres only.

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
