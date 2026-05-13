# Slice 19.0 — PII Masking and Access Safety

## Purpose

Prevent accidental customer-data exposure.

## Implementation scope

```text
PIIPolicy, CustomerPresenter, role-based masking, export rules, admin/client component separation.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 19.0 — PII Masking and Access Safety for EventSales. |
| Objective | Prevent accidental customer-data exposure. |
| Output | PIIPolicy, CustomerPresenter, role-based masking, export rules, admin/client component separation. |
| Note | Do not reuse admin components in client dashboard later. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Admin sees full email
- Staff configured/masked
- Event owner no email by default
- Event staff no email
- Aggregates no PII
- Raw payload admin-only
- Exports respect PII

## Architecture guardrails

Do not reuse admin components in client dashboard later.

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
