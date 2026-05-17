# Slice 8.5 — Missing Catalog / Mapping Recovery Worker

## Purpose

Handle webhook ordering races where order arrives before product metadata/mapping.

## Implementation scope

```text
MissingCatalogResolutionWorker, MissingCatalogResolver, ProductMetadataCache, metadata fetch via client, remap retry, fallback unmapped.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 8.5 — Missing Catalog / Mapping Recovery Worker for EventSales. |
| Objective | Handle webhook ordering races where order arrives before product metadata/mapping. |
| Output | MissingCatalogResolutionWorker, MissingCatalogResolver, ProductMetadataCache, metadata fetch via client, remap retry, fallback unmapped. |
| Note | Queued, bounded, idempotent, observable. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Unknown product creates pending item
- Worker fetches metadata through client
- Worker respects REST cap
- Metadata cached
- Affected item remapped
- Still missing becomes unmapped
- Duplicate recovery jobs safe

## Architecture guardrails

Queued, bounded, idempotent, observable.

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
