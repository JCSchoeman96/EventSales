# Slice 8.8 — PaperTrail and Operational Audit Split

## Purpose

Separate resource version history from operational audit events.

## Implementation scope

```text
AshPaperTrail on selected resources, AuditLog resource, Audit.Logger.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 8.8 — PaperTrail and Operational Audit Split for EventSales. |
| Objective | Separate resource version history from operational audit events. |
| Output | AshPaperTrail on selected resources, AuditLog resource, Audit.Logger. |
| Note | PaperTrail is not a replacement for operational audit events. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- ProductMapping change creates version
- EventAccessGrant change creates version
- Manual sync writes AuditLog
- Webhook replay writes AuditLog
- CSV apply writes AuditLog
- No secrets/full raw payload in audit metadata

## Architecture guardrails

PaperTrail is not a replacement for operational audit events.

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
