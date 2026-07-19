# Slice 23.0 — Full Webhook-to-Dashboard Acceptance

## Purpose

Prove the MVP core value end-to-end.

## Implementation scope

```text
Final E2E acceptance: webhook, Oban, upsert, mapping, aggregate, dashboard, duplicate check.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 23.0 — Full Webhook-to-Dashboard Acceptance for EventSales. |
| Objective | Prove the MVP core value end-to-end. |
| Output | Final E2E acceptance: webhook, Oban, upsert, mapping, aggregate, dashboard, duplicate check. |
| Note | This is the final green version of Slice 1.5 intent. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Completed webhook returns 2xx
- WebhookEvent stored
- Oban processes
- Order/Item created
- Item maps
- Tickets/revenue increment
- Dashboard renders
- Duplicate no total change
- Pending same order not sold
- Completed update counts once

## Architecture guardrails

This is the final green version of Slice 1.5 intent.

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
