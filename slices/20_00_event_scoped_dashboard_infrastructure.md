# Slice 20.0 — Event-Scoped Dashboard Infrastructure

## Purpose

Prepare future client dashboards without launching them.

## Implementation scope

```text
EventDashboardSetting, EventAccessGrant hardening, visibility settings, aggregate-only query path, token placeholder if needed.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 20.0 — Event-Scoped Dashboard Infrastructure for EventSales. |
| Objective | Prepare future client dashboards without launching them. |
| Output | EventDashboardSetting, EventAccessGrant hardening, visibility settings, aggregate-only query path, token placeholder if needed. |
| Note | Build infrastructure only, not client portal UI. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Event owner assigned aggregate access
- Unassigned denied
- Event staff no revenue by default
- Revenue setting controls access
- Expired grant denied
- Aggregate path excludes PII

## Architecture guardrails

Build infrastructure only, not client portal UI.

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
