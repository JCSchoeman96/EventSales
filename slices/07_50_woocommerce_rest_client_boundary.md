# Slice 7.5 — WooCommerce REST Client Boundary

## Purpose

Create a safe worker-only REST boundary before reconciliation and recovery.

## Implementation scope

```text
WooCommerceClient, WooCommerceError, order/product fetch, pagination, timeouts, typed errors, telemetry.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 7.5 — WooCommerce REST Client Boundary for EventSales. |
| Objective | Create a safe worker-only REST boundary before reconciliation and recovery. |
| Output | WooCommerceClient, WooCommerceError, order/product fetch, pagination, timeouts, typed errors, telemetry. |
| Note | Only workers may use this client. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Fetch order by ID
- Fetch product by ID
- Handle 401/403/404/429/500/timeout
- Typed errors
- No LiveView calls client
- MappingResolver does not call client
- REST concurrency cap remains 2

## Architecture guardrails

Only workers may use this client.

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
