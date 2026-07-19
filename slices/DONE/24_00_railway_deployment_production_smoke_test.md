# Slice 24.0 — Railway Deployment and Production Smoke Test

## Purpose

Deploy to Railway and prove production behavior.

## Implementation scope

```text
Railway config, Postgres/Redis, PgBouncer notes, env vars, health, migrations, Oban, webhook URL, smoke runbook.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 24.0 — Railway Deployment and Production Smoke Test for EventSales. |
| Objective | Deploy to Railway and prove production behavior. |
| Output | Railway config, Postgres/Redis, PgBouncer notes, env vars, health, migrations, Oban, webhook URL, smoke runbook. |
| Note | Railway is primary. VPS/systemd/Nginx not primary path. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Railway build succeeds
- Migrations run
- Health passes
- Postgres/Redis connect
- Oban starts
- Webhook HTTPS reachable
- Invalid rejected
- Valid test stored
- Admin dashboard accessible
- Oban Web protected

## Architecture guardrails

Railway is primary. VPS/systemd/Nginx not primary path.

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


## V2 Addendum

Production smoke test must include Oban job execution under the selected DB/PgBouncer topology and release migrations through a direct/safe DB URL.
