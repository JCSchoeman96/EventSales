# Slice 0.4 — Ash Ecosystem Baseline

## Purpose

Install and prove Ash ecosystem dependencies that prevent reinventing infrastructure.

## Implementation scope

```text
ash_authentication, ash_authentication_phoenix if needed, ash_admin, ash_state_machine, ash_paper_trail.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 0.4 — Ash Ecosystem Baseline for EventSales. |
| Objective | Install and prove Ash ecosystem dependencies that prevent reinventing infrastructure. |
| Output | ash_authentication, ash_authentication_phoenix if needed, ash_admin, ash_state_machine, ash_paper_trail. |
| Note | AshAdmin is not the product dashboard. Do not hand-roll auth. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Dependencies compile
- User resource can support AshAuthentication
- AshAdmin mounted behind protected/internal route
- AshStateMachine proven on sample/test resource
- AshPaperTrail proven on sample/test resource
- AshAdmin not publicly accessible

## Architecture guardrails

AshAdmin is not the product dashboard. Do not hand-roll auth.

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
