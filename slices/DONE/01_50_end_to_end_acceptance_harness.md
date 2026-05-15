# Slice 1.5 — End-to-End Acceptance Harness

## Purpose

Create the failing/pending E2E test early to prevent architectural drift.

## Implementation scope

```text
Woo fixtures, webhook signing helper, Oban drain helper, mapping setup helper, E2E test skeleton.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 1.5 — End-to-End Acceptance Harness for EventSales. |
| Objective | Create the failing/pending E2E test early to prevent architectural drift. |
| Output | Woo fixtures, webhook signing helper, Oban drain helper, mapping setup helper, E2E test skeleton. |
| Note | Do not wait until the end to write E2E intent. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- E2E test describes valid webhook -> dashboard path
- Duplicate webhook expectation captured
- Pending order does not count as sold expectation captured
- Test can be tagged pending until implementation arrives

## Architecture guardrails

Do not wait until the end to write E2E intent.

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
