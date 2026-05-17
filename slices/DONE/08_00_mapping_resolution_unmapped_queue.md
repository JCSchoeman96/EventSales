# Slice 8.0 — Mapping Resolution and Unmapped Queue

## Purpose

Resolve order items or mark them for recovery/unmapped handling.

## Implementation scope

```text
MappingResolver, OrderItemMapper, mapping_status, unmapped query, admin mapping queue.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 8.0 — Mapping Resolution and Unmapped Queue for EventSales. |
| Objective | Resolve order items or mark them for recovery/unmapped handling. |
| Output | MappingResolver, OrderItemMapper, mapping_status, unmapped query, admin mapping queue. |
| Note | MappingResolver must not call WooCommerce REST. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Product-only mapping resolves
- Product + variation resolves
- Variation-specific wins
- Unknown becomes pending_mapping_resolution first
- Unmapped excluded from metrics
- Non-ticket excluded
- Mapping change enqueues recalculation

## Architecture guardrails

MappingResolver must not call WooCommerce REST.

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
