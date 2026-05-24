# Slice 22.0 — Maintenance Jobs

## Purpose

Keep system healthy over time.

## Implementation scope

```text
PurgeRawPayloadsWorker, cache cleanup, stale sync cleanup, failed job alert foundation.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 22.0 — Maintenance Jobs for EventSales. |
| Objective | Keep system healthy over time. |
| Output | PurgeRawPayloadsWorker, cache cleanup, stale sync cleanup, failed job alert foundation. |
| Note | Purge raw payload only, not sales truth. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Payload older than 90 days purged/redacted
- Recent payload kept
- Normalized orders not deleted
- Purge idempotent
- Maintenance telemetry emitted

## Architecture guardrails

Purge raw payload only, not sales truth.

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
