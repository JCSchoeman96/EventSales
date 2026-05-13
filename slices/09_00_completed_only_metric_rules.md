# Slice 9.0 — Completed-Only Metric Rules

## Purpose

Make sales math deterministic.

## Implementation scope

```text
MetricRules, completed-only sold/revenue, status breakdown, today vs total, timezone.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 9.0 — Completed-Only Metric Rules for EventSales. |
| Objective | Make sales math deterministic. |
| Output | MetricRules, completed-only sold/revenue, status breakdown, today vs total, timezone. |
| Note | Pure functions first; no dashboard shortcut math. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Completed counts sold
- Pending/processing/failed/cancelled/refunded not sold
- Refunded visible but excluded MVP revenue
- Revenue uses completed ticket line total after discounts
- Unmapped/non-ticket not counted
- Today respects timezone

## Architecture guardrails

Pure functions first; no dashboard shortcut math.

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
