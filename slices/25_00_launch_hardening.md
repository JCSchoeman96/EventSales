# Slice 25.0 — Launch Hardening

## Purpose

Make EventSales trustworthy during a real sales period.

## Implementation scope

```text
Launch checklist, incident/reconciliation/CSV/security runbooks, burst test, mapping review, alert thresholds.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 25.0 — Launch Hardening for EventSales. |
| Objective | Make EventSales trustworthy during a real sales period. |
| Output | Launch checklist, incident/reconciliation/CSV/security runbooks, burst test, mapping review, alert thresholds. |
| Note | Do not launch before this passes. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Webhook burst no duplicates
- REST cap never exceeds 2
- Manual sync rate limit
- Large CSV test
- Policy/PII tests pass
- Cache invalidation works
- Replay works
- Payload purge works
- HotState rebuild safe
- Telemetry emits critical events

## Architecture guardrails

Do not launch before this passes.

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
