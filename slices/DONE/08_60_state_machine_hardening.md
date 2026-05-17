# Slice 8.6 — State Machine Hardening

## Purpose

Apply and harden AshStateMachine across resources with status lifecycles.

## Implementation scope

```text
WebhookEvent.status, Order.status, OrderItem.mapping_status, SyncRun.status, CsvImportBatch.status.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 8.6 — State Machine Hardening for EventSales. |
| Objective | Apply and harden AshStateMachine across resources with status lifecycles. |
| Output | WebhookEvent.status, Order.status, OrderItem.mapping_status, SyncRun.status, CsvImportBatch.status. |
| Note | Clarifies and completes state machines beyond sales storage. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Invalid internal transitions rejected
- Webhook processed cannot move to received internally
- OrderItem mapped cannot move pending without remap action
- SyncRun cannot complete before running
- CSV cannot apply before dry-run success
- External source sync explicit and audited

## Architecture guardrails

Clarifies and completes state machines beyond sales storage.

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
