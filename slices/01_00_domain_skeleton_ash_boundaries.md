# Slice 1.0 — Domain Skeleton and Ash Boundaries

## Purpose

Create domain boundaries before implementation spreads across the app.

## Implementation scope

```text
Accounts, Catalog, Sales, Ingestion, Analytics, Audit domain modules and folders.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 1.0 — Domain Skeleton and Ash Boundaries for EventSales. |
| Objective | Create domain boundaries before implementation spreads across the app. |
| Output | Accounts, Catalog, Sales, Ingestion, Analytics, Audit domain modules and folders. |
| Note | Workers orchestrate; Ash actions own durable domain mutation. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Each domain compiles
- Each domain is registered
- No resource in web layer
- No LiveView calls WooCommerce modules

## Architecture guardrails

Workers orchestrate; Ash actions own durable domain mutation.

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
