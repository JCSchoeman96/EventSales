# Slice 5.0 — Webhook Security and Intake

## Purpose

Receive WooCommerce webhooks safely and return quickly.

## Implementation scope

```text
WebhookSignature, WebhookEvent, WebhookController, WEBHOOK_PATH_TOKEN, Oban enqueue, invalid metadata logging.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 5.0 — Webhook Security and Intake for EventSales. |
| Objective | Receive WooCommerce webhooks safely and return quickly. |
| Output | WebhookSignature, WebhookEvent, WebhookController, WEBHOOK_PATH_TOKEN, Oban enqueue, invalid metadata logging. |
| Note | Normal path: validate -> small durable insert -> enqueue -> return. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Valid signature accepted
- Invalid signature rejected
- Wrong path token rejected
- Only POST accepted
- Valid webhook stores WebhookEvent
- Valid webhook enqueues Oban job
- Controller does not call REST
- No inline business processing
- Invalid payload does not store full body

## Architecture guardrails

Normal path: validate -> small durable insert -> enqueue -> return.

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


## V2 Addendum

Webhook signature verification must use raw request body bytes. This slice may create the initial WebhookController, but Slice 5.1 owns the raw-body verification hardening. No controller may call WooCommerce REST.
