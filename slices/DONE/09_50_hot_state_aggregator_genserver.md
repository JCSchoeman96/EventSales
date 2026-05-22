# Slice 9.5 — HotStateAggregator GenServer

## Purpose

Create supervised hot-state process for dashboard counters.

## Implementation scope

```text
HotStateAggregator, AggregateEvent, DashboardCache, CacheKeys, ETS/Cachex write, Redis snapshot write, PubSub trigger.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 9.5 — HotStateAggregator GenServer for EventSales. |
| Objective | Create supervised hot-state process for dashboard counters. |
| Output | HotStateAggregator, AggregateEvent, DashboardCache, CacheKeys, ETS/Cachex write, Redis snapshot write, PubSub trigger. |
| Note | Postgres commit first, then hot update. No compensating hot-first totals. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Starts under supervision
- Accepts normalized order-change event
- Updates event/ticket/today totals
- Writes hot cache
- Writes Redis warm snapshot
- Broadcasts PubSub
- Duplicate aggregate event no double count
- Not durable truth

## Architecture guardrails

Postgres commit first, then hot update. No compensating hot-first totals.

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

Aggregate events require idempotency keys and are emitted only after durable sales writes commit. Hot state must never be updated before the durable write as the default path.
