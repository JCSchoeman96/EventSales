# Slice 11.0 — PubSub and Cache Integration

## Purpose

Update dashboard after processed orders without polling.

## Implementation scope

```text
PubSub topics, LiveView subscriptions, cache invalidation, handle_info updates, manual fallback.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 11.0 — PubSub and Cache Integration for EventSales. |
| Objective | Update dashboard after processed orders without polling. |
| Output | PubSub topics, LiveView subscriptions, cache invalidation, handle_info updates, manual fallback. |
| Note | No polling. No WooCommerce calls. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Processed order invalidates cache
- Processed order broadcasts update
- Dashboard receives PubSub
- Assigns update without reload
- Manual refresh fallback
- Cache keys include event scope

## Architecture guardrails

No polling. No WooCommerce calls.

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
