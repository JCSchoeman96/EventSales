# Slice 17.0 — CSV Apply Worker

## Purpose

Apply validated CSV imports asynchronously and audibly.

## Implementation scope

```text
ProcessCsvImportWorker, ApplyImport, idempotent upsert, row statuses, cache invalidation, audit.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 17.0 — CSV Apply Worker for EventSales. |
| Objective | Apply validated CSV imports asynchronously and audibly. |
| Output | ProcessCsvImportWorker, ApplyImport, idempotent upsert, row statuses, cache invalidation, audit. |
| Note | CSV uses same domain rules as webhook/reconciliation. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Only valid dry-run applies
- Runs through Oban
- Idempotent
- Duplicates no double-count
- Updates aggregates
- Invalidates cache
- Writes audit
- Retry safe

## Architecture guardrails

CSV uses same domain rules as webhook/reconciliation.

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
