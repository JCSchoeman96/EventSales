# Slice 0.0 — Project Bootstrap

## Purpose

Create the clean Phoenix/Ash application foundation.

## Implementation scope

```text
Phoenix, Ash 3.x, AshPostgres, LiveView, Tailwind, Mishka Chelekom, Bandit, Oban, Postgres/Redis config, Railway runtime config, health route, test support.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 0.0 — Project Bootstrap for EventSales. |
| Objective | Create the clean Phoenix/Ash application foundation. |
| Output | Phoenix, Ash 3.x, AshPostgres, LiveView, Tailwind, Mishka Chelekom, Bandit, Oban, Postgres/Redis config, Railway runtime config, health route, test support. |
| Note | No business logic. No WooCommerce calls. Config must include dev/prod/test/runtime. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Application boots in test
- Repo connects
- Redis config loads safely
- Oban starts in test mode
- Health route returns 200
- No secrets are hardcoded
- Runtime config reads env vars

## Architecture guardrails

No business logic. No WooCommerce calls. Config must include dev/prod/test/runtime.

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
