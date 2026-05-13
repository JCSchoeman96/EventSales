# Slice 2.5 — Protected AshAdmin Internal Console

## Purpose

Expose internal Ash resource visibility early, safely.

## Implementation scope

```text
AshAdmin route, admin-only protection, resource visibility settings.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 2.5 — Protected AshAdmin Internal Console for EventSales. |
| Objective | Expose internal Ash resource visibility early, safely. |
| Output | AshAdmin route, admin-only protection, resource visibility settings. |
| Note | AshAdmin is a super-admin/debug tool only. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Unauthenticated cannot access AshAdmin
- Non-admin cannot access AshAdmin
- Admin can access AshAdmin
- AshAdmin is not public/client UI

## Architecture guardrails

AshAdmin is a super-admin/debug tool only.

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
