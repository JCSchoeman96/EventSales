# Slice 13.0 — Webhook Debug and Replay UI

## Purpose

Make webhook ingestion observable and recoverable.

## Implementation scope

```text
/admin/webhooks, filters, failed replay, metadata, raw payload admin-only, confirmation, audit.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 13.0 — Webhook Debug and Replay UI for EventSales. |
| Objective | Make webhook ingestion observable and recoverable. |
| Output | /admin/webhooks, filters, failed replay, metadata, raw payload admin-only, confirmation, audit. |
| Note | Raw payload handling must be explicit and admin-only. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Admin can view log
- List paginated/streamed
- Failed replay enqueues job
- Replay requires confirmation
- Replay rate-limited
- Replay audited
- Non-admin no raw payload

## Architecture guardrails

Raw payload handling must be explicit and admin-only.

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
