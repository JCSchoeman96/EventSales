# M5-05 owner product authority

**Issue:** [JC-332](https://linear.app/jc-dev/issue/JC-332/eventsales-m5-05a-deterministic-sales-velocity-planning-and)  
**Recorded:** 2026-10-09  
**Owner acceptance:** explicit approval phrase `Approved — record this as M5-05 owner authority.`  
**Canonical plan:** `docs/development/m5-05-deterministic-sales-velocity.plan.md` (v4)  
**Peer implementation (not merged):** PR #306 on branch `feature/m5-05b-velocity-kernel` — reconcile only after this authority merges to `main`.

This file is the durable repository record of M5-05 product semantics. JC-332 carries the same acceptance for programme tracking.

## Windows

- Supported velocity windows: **15 minutes, 30 minutes, 60 minutes**.
- Windows use absolute UTC duration and one captured `now`.
- Current operand: `[now - duration, now)`.
- Previous operand: immediately preceding equal-duration interval `[now - 2×duration, now - duration)`.
- Windows are half-open `[start, end)`.
- API: `TimeRules.velocity_windows/2` (no timezone argument).

## Primary and supporting measures

Primary sales-velocity measure: **gross ticket quantity rate**.

Supporting quantity measures: refund ticket quantity rate, net ticket quantity rate.

Monetary velocity (complete currency-scoped family): gross ticket value rate, refund ticket value rate, net ticket value rate.

Average ticket value is **not** a velocity metric.

## Rate units and numeric rules

- Quantity: `tickets_per_hour`.
- Money: `currency_units_per_hour`.
- Canonical calculation: `Decimal` arithmetic; no floating point; no intermediate rounding; no rounding in the velocity kernel.
- Raw window totals and `window_duration_seconds` may be exposed alongside normalized rates.
- Display/UI rounding is deferred to a later presentation contract and must not alter canonical values.
- Locked multipliers for 15m / 30m / 60m: ×4 / ×2 / ×1 per hour.

## Trend

Per approved rate expose: `current_rate`, `previous_rate`, `absolute_delta`, `percentage_delta`, `direction`.

- Absolute delta: `current_rate - previous_rate`.
- Direction (exact sign): positive → `:faster`, zero → `:flat`, negative → `:slower`.
- No tolerance band or smoothing (`TREND_THRESHOLD = NONE`).

## Percentage behavior

Reuse existing M5-04 percentage-delta semantics via `MetricRules` (no semantic change to M5-04 primitives).

- When previous rate is zero: `percentage_delta = nil` (no infinity, 100%, or other sentinel).
- Negative net-rate baselines: preserve signed M5-04 arithmetic; do not clamp or reinterpret.
- Accepted counterintuitive case: e.g. `-50` → `-20` may be `:faster` with a negative percentage delta.

## Refund and net behavior

- Sales at canonical sale-effective time; refunds at canonical refund-effective time.
- Refunds do not move historical gross into the refund period.
- Net quantities and net values may be negative; negative net velocity is not clamped.

## Currency and scope

- MVP: **event + currency** scoped reads.
- No FX conversion; no cross-currency monetary aggregation; no cross-currency ticket quantity aggregation in M5-05 MVP.

## Revenue visibility

When revenue is redacted for an authorized analytics actor:

- **Visible:** gross/refund/net ticket quantities, quantity rates, quantity deltas, quantity direction.
- **Redacted:** all monetary raw values, monetary rates, monetary deltas, monetary percentages, monetary direction.

## Public result shape (reader phase)

Future reader returns one event/currency velocity result containing all three windows (15m, 30m, 60m) from one captured `now`. Pure kernel functions may compute one window at a time given the same anchor.

## Readiness and architecture

- `ANALYTICS_READY` mandatory; missing/stale/incompatible coverage fails closed; missing coverage is never zero.
- Canonical truth: `EventPeriodAggregateSnapshot` + bounded `AnalyticsContributionFact` edges + pure `TimeRules` / `VelocityRules`.
- No raw order/refund scans on interactive reads.
- `HotStateAggregator` / `EventAggregator.summary_for_event/2` are not semantic authority.
- No new cache, Redis, PubSub, index, or durable resource authorized by this decision batch.

## Implementation admission

```text
OWNER_DECISION_REQUIRED = NO
M5_05B_AUTHORIZED = YES
M5_05C_AUTHORIZED = NO
M5_05C_GATE = PENDING_M5_05B_MERGE_AND_POST_MERGE_VERIFY
```

M5-05C and later phases remain unauthorized until M5-05B merges and is independently verified on `main`.
