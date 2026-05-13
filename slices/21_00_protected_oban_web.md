# Slice 21.0 — Protected Oban Web

## Purpose

Expose job visibility safely.

## Implementation scope

```text
Oban Web route, admin-only protection, optional basic auth/IP restriction, job visibility.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 21.0 — Protected Oban Web for EventSales. |
| Objective | Expose job visibility safely. |
| Output | Oban Web route, admin-only protection, optional basic auth/IP restriction, job visibility. |
| Note | Operational controls must not be public. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Unauthenticated denied
- Non-admin denied
- Admin allowed
- Not mounted publicly by accident

## Architecture guardrails

Operational controls must not be public.

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
