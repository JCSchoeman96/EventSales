# Slice 16.0 — CSV Import Dry-Run

## Purpose

Allow safe event-scoped CSV validation before mutation.

## Implementation scope

```text
CsvImportBatch, CsvImportRow, CSV parser, dry-run validator, errors, duplicate preview, admin screen.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 16.0 — CSV Import Dry-Run for EventSales. |
| Objective | Allow safe event-scoped CSV validation before mutation. |
| Output | CsvImportBatch, CsvImportRow, CSV parser, dry-run validator, errors, duplicate preview, admin screen. |
| Note | Dry-run before apply. No automatic event/ticket creation in MVP. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Requires event scope
- Missing columns fail
- Invalid money/quantity fail
- Unknown mapping fails
- Duplicate detected
- Large CSV streamed/chunked
- Dry-run no sales mutation
- Non-admin denied

## Architecture guardrails

Dry-run before apply. No automatic event/ticket creation in MVP.

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
