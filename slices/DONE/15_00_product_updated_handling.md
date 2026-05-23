# Slice 15.0 — Product Updated Handling

## Purpose

Use product updates to improve metadata without corrupting history.

## Implementation scope

```text
product.updated handler, ProductMetadataUpdater, label update, unknown alert, cache invalidation.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 15.0 — Product Updated Handling for EventSales. |
| Objective | Use product updates to improve metadata without corrupting history. |
| Output | product.updated handler, ProductMetadataUpdater, label update, unknown alert, cache invalidation. |
| Note | Product updates are metadata, not sales truth. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Known product refreshes current label
- Original order item label unchanged
- Unknown product alert/ignored status
- No revenue recalc unless mapping changed
- Worker idempotent
- Controller no inline REST

## Architecture guardrails

Product updates are metadata, not sales truth.

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
