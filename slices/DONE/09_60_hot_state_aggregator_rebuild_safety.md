# Slice 9.6 — HotStateAggregator Rebuild Safety

## Purpose

Prevent cache stampede and blocking boot after restart/crash.

## Implementation scope

```text
Warming state, Redis-first restore, async Postgres rebuild, anti-stampede lock, bounded rebuild worker, telemetry.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 9.6 — HotStateAggregator Rebuild Safety for EventSales. |
| Objective | Prevent cache stampede and blocking boot after restart/crash. |
| Output | Warming state, Redis-first restore, async Postgres rebuild, anti-stampede lock, bounded rebuild worker, telemetry. |
| Note | Never run heavy aggregate queries in GenServer init. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Starts warming
- Redis snapshot restores quickly
- Missing Redis schedules async rebuild
- GenServer init no heavy query
- Only one rebuild runs
- Dashboard shows warming/stale safely
- Rebuild telemetry emitted

## Architecture guardrails

Never run heavy aggregate queries in GenServer init.

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
