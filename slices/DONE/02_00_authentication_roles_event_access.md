# Slice 2.0 — Authentication, Roles, and Event Access

## Purpose

Create safe internal admin access and future event-scoped access.

## Implementation scope

```text
User, Role, UserRole, EventAccessGrant, AshAuthentication password strategy, role helpers, policies.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 2.0 — Authentication, Roles, and Event Access for EventSales. |
| Objective | Create safe internal admin access and future event-scoped access. |
| Output | User, Role, UserRole, EventAccessGrant, AshAuthentication password strategy, role helpers, policies. |
| Note | Auth must use AshAuthentication. Event scoping must live in policies, not routes. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Admin can authenticate
- Unauthenticated rejected
- Admin accesses global admin
- Staff restricted
- Event owner only assigned event
- Event staff cannot see revenue by default
- Expired grants deny access

## Architecture guardrails

Auth must use AshAuthentication. Event scoping must live in policies, not routes.

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
