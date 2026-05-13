# Slice 18.0 — Exports

## Purpose

Allow admins to export event sales summaries.

## Implementation scope

```text
Event summary CSV, order list CSV, reconciliation report CSV grouped by event/ticket type/mismatch status/payment method, PII-aware policy, streamed response, audit.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 18.0 — Exports for EventSales. |
| Objective | Allow admins to export event sales summaries. |
| Output | Event summary CSV, order list CSV, reconciliation report CSV grouped by event/ticket type/mismatch status/payment method, PII-aware policy, streamed response, audit. |
| Note | Do not load entire export into memory. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Admin exports summary/list
- Admin exports reconciliation report
- Event scope respected
- PII policy respected
- Unmapped excluded from metrics
- Reconciliation export includes payment method
- Large reconciliation export streamed/paginated
- Large export streamed/paginated
- Audit written

## Architecture guardrails

Do not load entire export into memory.

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
