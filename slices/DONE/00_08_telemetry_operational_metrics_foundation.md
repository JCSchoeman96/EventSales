# Slice 0.8 — Telemetry and Operational Metrics Foundation

## Purpose

Add observability before ingestion gets complicated.

## Implementation scope

```text
EventSalesWeb.Telemetry, custom telemetry event names, webhook/REST/Oban/HotStateAggregator metric placeholders, docs.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 0.8 — Telemetry and Operational Metrics Foundation for EventSales. |
| Objective | Add observability before ingestion gets complicated. |
| Output | EventSalesWeb.Telemetry, custom telemetry event names, webhook/REST/Oban/HotStateAggregator metric placeholders, docs. |
| Note | Metrics must exist before production debugging. No hard dependency on external SaaS metrics service. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Telemetry supervisor starts
- Custom telemetry event can be emitted and handled
- Webhook accepted/rejected counters defined
- REST latency/error telemetry defined
- Oban metrics documented

## Architecture guardrails

Metrics must exist before production debugging. No hard dependency on external SaaS metrics service.

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
