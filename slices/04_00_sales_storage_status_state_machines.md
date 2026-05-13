# Slice 4.0 — Sales Storage and Status State Machines

## Purpose

Store normalized order and line-item data correctly and introduce sales state machines.

## Implementation scope

```text
Order, OrderItem, CouponSnapshot, Order status state machine, OrderItem mapping_status state machine.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 4.0 — Sales Storage and Status State Machines for EventSales. |
| Objective | Store normalized order and line-item data correctly and introduce sales state machines. |
| Output | Order, OrderItem, CouponSnapshot, Order status state machine, OrderItem mapping_status state machine. |
| Note | Slice 4.0 owns initial sales state machines. Slice 8.6 later hardens all state machines across domains. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Order unique by source + woo_order_id
- OrderItem unique by order + line item
- Quantity > 1 preserved
- Mixed-event orders supported
- Completed stored
- Other statuses visible but excluded
- Invalid internal transitions rejected
- External source sync can mirror newer Woo truth

## Architecture guardrails

Slice 4.0 owns initial sales state machines. Slice 8.6 later hardens all state machines across domains.

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
