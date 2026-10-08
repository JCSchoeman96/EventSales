# M5-05 deterministic sales velocity — authority repair

~~~text
PLAN_ID=m5-05-deterministic-sales-velocity
PLAN_VERSION=v3
BASE_SHA=dfe6687369f284e97e5ffcca4a5e79d4c1c8479e
BASE_TREE=4f652702849493f6fd39b876d48120c2e4b68d42

M5_02_STATUS=COMPLETE_PASS
M5_03_STATUS=COMPLETE_PASS
M5_04_STATUS=COMPLETE_PASS
M5_05A_STATUS=AUTHORITY_REPAIR_IN_REVIEW
M5_05_IMPLEMENTATION_AUTHORIZED=NO
IMPLEMENTATION_READY=NO
OWNER_DECISION_REQUIRED=YES

PR_304_MERGED=YES
PR_304_MERGE_SHA=dfe6687369f284e97e5ffcca4a5e79d4c1c8479e
PR_304_INSTALLED_V2_PLAN=YES
PR_304_OWNER_SEMANTIC_LOCKS=NOT_DURABLY_PROVEN
PR_305_CORRECTION_REFERENCE=a72d678134f88b286a36d20b2e95541454b133fc
PR_305_CORRECTION_REVIEW=PASS

VELOCITY_SEMANTIC_STATUS=OWNER_DECISION_REQUIRED
WINDOW_STATUS=LOCKED_15M_30M_60M
TREND_STATUS=OWNER_DECISION_REQUIRED
VELOCITY_PRIMARY_METRIC=OWNER_DECISION_REQUIRED_RECOMMEND_GROSS_TICKET_QUANTITY_RATE
VELOCITY_SUPPORTING_METRICS=OWNER_DECISION_REQUIRED_NET_QTY_RATE_AND_REFUND_QTY_RATE;MONETARY_RATES_OWNER_DECISION_REQUIRED
VELOCITY_UNIT=OWNER_DECISION_REQUIRED_RECOMMEND_PER_HOUR
RATE_NUMERIC_RULE=RECOMMEND_DECIMAL_NO_FLOAT_NO_INTERMEDIATE_ROUNDING
DISPLAY_ROUNDING_RULE=OWNER_DECISION_REQUIRED
WINDOWS=15M,30M,60M
PREVIOUS_EQUIVALENT_RULE=OWNER_DECISION_REQUIRED_RECOMMEND_IMMEDIATELY_PRECEDING_EQUAL_DURATION
REFUND_TREATMENT=SALE_GROSS_AT_SALE_EFFECTIVE_TIME;REFUND_AT_REFUND_EFFECTIVE_TIME
TREND_RULE=OWNER_DECISION_REQUIRED_RECOMMEND_ABSOLUTE_RATE_DELTA_AND_DIRECTION;PERCENTAGE_OWNER_DECISION_REQUIRED
ZERO_BASELINE_RULE=OWNER_DECISION_REQUIRED
NEGATIVE_BASELINE_RULE=OWNER_DECISION_REQUIRED
MULTI_CURRENCY_RULE=ONE_CURRENCY_PER_READ;NO_CROSS_CURRENCY_MONEY_SUM;QUANTITY_COMBINATION_OWNER_DECISION_REQUIRED
RAW_SCAN_DECISION=FORBIDDEN
RAW_TABLE_INTERACTIVE_READS=NONE
HOT_STATE_CANONICAL_AUTHORITY=NO

PERIOD_BUCKET_REUSE_DECISION=REUSE
CONTRIBUTION_FACT_REUSE_DECISION=REUSE
PERIOD_READ_PLAN_DECISION=REUSE
READER_ARCHITECTURE_DECISION=EXTRACT_NARROW_EVENT_PROJECTION_KERNEL

CACHE_DECISION=NO_CHANGE
REDIS_DECISION=NO_CHANGE
PUBSUB_DECISION=NO_CHANGE
NEW_RESOURCE_REQUIRED=NO
NEW_INDEX_REQUIRED=NO
M5_05D_OPTION_A_GATE=BEFORE_PUBLIC_READER;GO_OR_NO_GO
IMPLEMENTATION_READY=NO
M5_05_IMPLEMENTATION_AUTHORIZED=NO
~~~

This version reconciles the merged PR #304 plan with JC-332 authority and the independently reviewed correction on PR #305. It is a planning and conformance artifact only. This change authorizes no production code, tests, migrations, resources, indexes, configuration, dependencies, cache behavior, Redis, PubSub behavior, workers, schedulers, or UI.

## Authority history

- The v1 plan recorded unresolved owner decisions and recommended defaults.
- PR #304 merged v2 into `main` and installed useful technical analysis, including the risk that sub-hour contribution-edge reads may be dense during flash sales. Its plan text also asserted that owner semantics were locked; that assertion is historical and superseded by v3.
- PR #304 is merged repository history. The owner-lock assertion is not durable owner acceptance: the PR has no review or discussion comments, and JC-332 has no recorded acceptance of those product choices. Merge status does not create product authority.
- PR #305's correction was independently reviewed clean, including its one-file scope and exact-head CI. It is retained as review evidence; it is not merged and is not the base for this repair.
- This v3 preserves useful technical findings from both plans and marks every unsupported product choice as `OWNER_DECISION_REQUIRED`. M5-05 implementation remains unauthorized until decisions are explicitly recorded in an authoritative product or issue record and a later implementation phase is separately admitted.

## Ultimate outcome and backward plan

Management must receive a deterministic, bounded, decision-grade measure of recent sales velocity and trend that:

- uses canonical M5 financial and time semantics;
- does not scan raw order or refund history at request time;
- remains currency-safe and does not create an exchange-rate model;
- places refunds honestly at refund-effective time;
- is coherent with `ANALYTICS_READY` and projection coverage;
- respects revenue visibility;
- supports a later decision dashboard; and
- scales horizontally without creating a second financial truth model.

Work backward from that outcome:

1. Product owners decide what “sales velocity” and trend mean, including the numerator, supporting signals, unit, comparison baseline, output shape, visibility, and formatting.
2. The supported current windows are 15m, 30m, and 60m from one captured UTC instant. Trend comparison operands remain conditional on owner approval.
3. Reuse `PeriodReadPlan` for half-open periods: complete UTC-hour buckets plus bounded sub-hour contribution edges.
4. Reuse `EventPeriodAggregateSnapshot` for fixed buckets and `AnalyticsContributionFact` for exact edge contributions.
5. Compose all approved operands under the M5-04 coherent-transaction law, fail closed on missing or stale coverage, and derive only owner-approved metrics.
6. Apply event authorization, `ANALYTICS_READY`, and revenue policy at the existing analytics boundary.
7. Prove query shape and local edge-density performance before public reader integration; then certify reconciliation and measured load before changing any acceleration decision.

The older “hot summaries” roadmap hint predates M5-04 and does not make the legacy hot summary canonical. `HotStateAggregator` may only be considered later as an acceleration mechanism after canonical velocity exists and measured evidence supports a separate decision.

## Current repository truth

- M5-02, M5-03, and M5-04 are certified complete/pass at the admitted base.
- `EventPeriodAggregateSnapshot` stores event/currency UTC-hour and Johannesburg-day Gross and Refund additive primitives, projection state, semantic version, and coverage identity. A current explicit zero bucket proves covered zero; absence or non-current state does not.
- `AnalyticsContributionFact` stores exact sale/refund contribution primitives by event, currency, and `effective_at`. Sale and refund facts retain their own effective times. The existing event/currency/effective-time index supports bounded edge predicates.
- `PeriodReadPlan` already decomposes arbitrary half-open periods into full UTC-hour interiors and at most two bounded sub-hour edges per operand. Do not implement a second decomposition algorithm.
- `PeriodComparisonReader` demonstrates identity validation, event authorization, request validation, `ANALYTICS_READY`, one captured `now`, projection composition, coverage checks, derived metrics, and revenue redaction.
- Its accepted transaction sequence includes both `EventSnapshotRefreshFence.coherent_transaction_opts/0` and `EventSnapshotRefreshFence.prepare_coherent_transaction!/0`; the latter runs inside the transaction before the first projection statement.
- The legacy `EventAggregator.summary_for_event/2` and `HotStateAggregator` financial summary uses current completed status, mapped tickets, positive quantity, and ex-tax `line_total`. That is not canonical M5 velocity truth.
- M5-04 owns today/yesterday/rolling 7d/rolling 30d comparison semantics. M5-05's 15m/30m/60m current windows are a distinct programme velocity request set; they do not revise M5-04 periods.

## Domain and concept map

These concepts belong under `EventSales.Analytics`. Derived request values have no persistence or fake lifecycle.

| Concept | Owner and identity | Relationships and invariants | Durable or derived | Lifecycle |
|---|---|---|---|---|
| `VelocityRequest` | Analytics read boundary; event UUID, one currency, fixed current-window set, actor | Typed request only. Fixed supported current windows are 15m/30m/60m. Comparison operands require owner approval. | Request value | Stateless |
| `CapturedNow` | Analytics reader; one UTC instant per response | Shared end for all current windows. Do not use process execution time as the denominator. | Derived | Stateless |
| `CurrentVelocityWindow` | `TimeRules`; duration and `[start,end)` bounds | For duration D and captured N: `[N-D,N)`. Elapsed UTC duration, not Johannesburg civil-day arithmetic. | Derived `Period` | Stateless |
| `PreviousEquivalentVelocityWindow` | `TimeRules`; only if a comparison baseline is approved | Recommendation for duration D: `[N-2D,N-D)`. No implementation may assume this baseline before approval. | Derived `Period` | Stateless |
| `PeriodReadPlan` | Existing planner; operand and exact bucket/edge bounds | Reuse existing decomposition and edge guard. A missing envelope is not zero. | Derived plan | Stateless |
| `EventPeriodAggregateSnapshot` | Period projection owner; event, currency, bucket kind/start/end | Holds fixed-bucket Gross/Refund primitives plus semantic and coverage identity. Only compatible `current` coverage, including an explicit zero, proves coverage. | Durable projection | Existing: current, stale, refresh_pending, rebuilding, unavailable |
| `AnalyticsContributionFact` | Period projection owner; contribution identity and event/currency/effective time | Sale uses sale-effective time; refund uses refund-effective time. Edge facts must match current envelope coverage and semantic version. | Durable projection | Existing projection replacement/rebuild lifecycle |
| `VelocityPrimitives` | Pure analytics rules; one event/currency/window operand | Additive Gross/refund quantity and value; Net is canonical subtraction. Never clamp negative Net. | Derived | Stateless |
| `VelocityRate` | Pure analytics rules; metric, unit, duration, and currency for money | Unit and display contract require owner approval. Keep rates derived; do not persist them. Decimal/no-float is the recommendation. | Derived | Stateless |
| `VelocityTrend` | Pure analytics rules; metric and owner-approved operand pair | Baseline, delta, direction, percentage, tolerance, and zero/negative baseline behavior require owner decisions. | Derived | Stateless |
| `AnalyticsReadiness` | Existing readiness resolver; event | `ANALYTICS_READY` is required before projection reads and does not replace per-bucket coverage checks. | Derived from durable evidence | Existing resolver behavior |
| `RevenueVisibility` | `Policies.can_view_revenue?/2`; actor and event | Governs every monetary value and derived monetary field. Ticket visibility under revenue redaction remains an owner decision. | Derived policy result | Stateless |
| `ProjectionCoverage` | Projection rows; event, currency, bucket, semantic version, coverage identity | Every bucket and edge envelope must be current and compatible. Missing/stale coverage fails closed. | Durable metadata | Uses snapshot lifecycle above |
| `OptionalHotMirror` | No M5-05 correctness owner | Not required or proposed now. A future mirror could only copy a completed canonical result under separate authority. | Absent | Conditional future model below |

### Conditional future hot-mirror lifecycle

This is a guard model, not a cache proposal or implementation authority. No key, value, TTL, Redis structure, or cache behavior is selected here.

| State | Entry guard | Transition and recovery |
|---|---|---|
| `MISSING` | No entry exists or a separately approved entry expired. | It can become `CURRENT` only from a successful canonical read with matching event, currency, approved windows, semantic version, and coverage identity. |
| `CURRENT` | Entry metadata matches the canonical result and any separately approved freshness bound. | Relevant projection refresh, coverage change, policy-scope mismatch, semantic-version change, or expiry makes it `STALE/INVALID`. |
| `STALE/INVALID` | Metadata is missing, mismatched, invalidated, or expired. | Delete to `MISSING`; do not serve as truth. A rebuild may enter `REBUILDING` only if separately necessary and admitted. |
| `REBUILDING` | A separately admitted single-flight rebuild is active. | Success plus matching source metadata produces `CURRENT`; failure or source-identity change produces `STALE/INVALID`. |

No state falls back to raw tables. PubSub notification does not make a mirror current. Any later mirror requires separate authority defining key/value/TTL, semantic version, coverage and readiness representation, invalidation, stampede protection, PubSub relation, and failure behavior.

## Semantic matrix and owner-decision ledger

M5 defines additive financial facts and their clocks. It does not yet define the product meaning of “sales velocity.” Every candidate below remains `OWNER_DECISION_REQUIRED`; recommendations are explicitly non-binding.

| Candidate measure | Current classification | Recommendation only | Trade-off |
|---|---|---|---|
| Gross ticket quantity / time | OWNER_DECISION_REQUIRED | Proposed primary selling-pace rate. | Measures new sale activity; it does not show refunds or net movement by itself. |
| Net ticket quantity / time | OWNER_DECISION_REQUIRED | Proposed supporting rate beside Gross. | Can be negative when refund quantity exceeds Gross in the window. |
| Refund ticket quantity / time | OWNER_DECISION_REQUIRED | Proposed separate supporting rate. | Makes refund-effective activity visible and distinct from sale pace. |
| Gross ticket value / time | OWNER_DECISION_REQUIRED | Consider only if monetary velocity is approved; always currency-labeled. | Tax-inclusive canonical Gross; obeys revenue visibility. |
| Refund ticket value / time | OWNER_DECISION_REQUIRED | If monetary rates are approved, consider the explicit refund component. | Omitting it can conceal why Net money changed. |
| Net ticket value / time | OWNER_DECISION_REQUIRED | If monetary rates are approved, consider as a separate signal. | May be negative; never collapse currencies or clamp it. |

### Owner-decision ledger

No row below is accepted product authority. Before M5-05B, record the decisions in an authoritative product or issue record. Implementation phases may not infer approval from this plan, PR merge, or a recommendation.

| Decision | Current authority | Recommendation only | Alternatives | Trade-off | Owner status |
|---|---|---|---|---|---|
| Primary sales-velocity numerator | Canonical primitives exist; product numerator is undefined. | Gross ticket quantity rate. | Net quantity; monetary value; more than one primary measure. | Gross is new sale pace; Net includes refund-time movement; money adds price/mix and policy constraints. | OWNER_DECISION_REQUIRED |
| Whether Net ticket quantity is displayed | Net derives from Gross less refund quantity. | Show separately as a supporting measure. | Omit; primary; support. | Showing it makes negative movement explicit; omitting it simplifies output but hides net movement. | OWNER_DECISION_REQUIRED |
| Whether Refund ticket quantity is displayed | Refund quantity is canonical and refund-effective. | Show separately beside Gross/Net if those are approved. | Omit; show as support; primary. | A separate signal is honest about refunds; additional measures increase result and UI complexity. | OWNER_DECISION_REQUIRED |
| Whether monetary velocity is included | Money is currency-safe and revenue-protected in M5. | Include Gross/Refund/Net value rates only as a complete, currency-labeled family when visible. | Exclude; Gross only; another explicitly selected subset; all three. | Monetary rates aid value pacing but invoke visibility, currency-label, and formatting requirements. | OWNER_DECISION_REQUIRED |
| Canonical rate normalization unit | Programme names recent windows but does not choose a rate unit. | `tickets/hour` and `currency units/hour`. If accepted, 15m/30m/60m multipliers are exactly 4/2/1. | Per minute; raw window total only; another explicit unit. | Per-hour is comparable across supported durations; raw totals are intuitive but not normalized. | OWNER_DECISION_REQUIRED |
| Whether raw window values are public output | Additive window primitives are available internally. | Return only if useful alongside approved rates. | Rates only; raw values only; both. | Raw values help interpret a rate but expand the public contract. | OWNER_DECISION_REQUIRED |
| Previous/trend comparison baseline | No M5-05 baseline is accepted. | Immediately preceding equal-duration interval: current `[N-D,N)`, previous `[N-2D,N-D)`. | No comparison; another named baseline. | Adjacent intervals are easy to explain; other baselines answer different questions. | OWNER_DECISION_REQUIRED |
| Whether absolute delta is part of trend | M5-04 has comparison math but does not select M5-05 trend output. | Current approved rate minus previous approved rate, in matching units. | No delta; another approved change metric. | Absolute change preserves units but can be hard to compare across scales. | OWNER_DECISION_REQUIRED |
| Whether direction is part of trend | No M5-05 direction contract exists. | Derive direction from the sign of an approved delta. | No direction; direction only; delta plus direction. | Direction is compact but loses magnitude if shown alone. | OWNER_DECISION_REQUIRED |
| Direction naming | No product wording is accepted. | Neutral `up/down/unchanged`. | `faster/slower/flat`; other owner language. | Neutral labels avoid implying good/bad; pace-specific terms may be clearer after metric selection. | OWNER_DECISION_REQUIRED |
| Whether percentage trend is included | No percentage trend is accepted. | Omit until a safe, useful baseline contract is selected. | Include with explicit baseline states; omit. | Percentage aids relative comparison but is ambiguous around zero and negative values. | OWNER_DECISION_REQUIRED |
| Zero-baseline percentage behavior | M5-04 comparison states exist, but M5-05 mapping is undecided. | Reuse an existing state only if its preconditions match; never synthesize infinity or 100%. | Explicit state; omit percentage; another approved definition. | A numeric sentinel would misstate an undefined ratio. | OWNER_DECISION_REQUIRED |
| Negative-baseline percentage behavior | Negative Net can be mathematically correct; trend interpretation is undefined. | Preserve the signed baseline and use an explicit approved state or omit percentage. | Signed ratio; state/no percentage; another defined formula. | Signed ratios can be unintuitive when direction crosses zero. | OWNER_DECISION_REQUIRED |
| Trend threshold/tolerance | No threshold is specified. | Exact comparison only if direction is approved; do not assume a tolerance. | No direction; exact sign; owner-set tolerance. | A tolerance dampens noise but adds an unsupported classification boundary. | OWNER_DECISION_REQUIRED |
| Display precision and rounding | No M5-05 display contract exists. | Keep canonical Decimal unrounded; round only for display after a chosen policy. | Owner-selected precision/mode; expose full precision; raw units. | More decimals preserve detail but can make a dashboard noisy; rounding mode affects displayed values. | OWNER_DECISION_REQUIRED |
| Combining ticket quantity across currencies | Projection reads partition by event and currency; no combined-quantity presentation is accepted. | Keep per-currency partitions in MVP. | Sum counts across currencies; require one currency; omit cross-currency combined value. | Tickets are countable, but a mixed-currency aggregate can conceal different event/catalog contexts. | OWNER_DECISION_REQUIRED |
| Public three-window result shape | Programme names three windows; it does not prescribe one response envelope. | One event/currency result containing all three current windows. | One requested window per call; separate values; another typed shape. | One call avoids repeated `now` and transaction overhead; larger response may be unnecessary for some consumers. | OWNER_DECISION_REQUIRED |
| Ticket visibility when revenue is redacted | Event access allows analytics reads; M5-05 visibility choice is unrecorded. | Keep approved quantity measures visible under event access while stripping all money. | Hide all velocity; expose quantities; other policy. | Quantity is not money, but its display may still be a product decision. | OWNER_DECISION_REQUIRED |

### Refund and Net invariants

These are canonical financial-time invariants, not product presentation choices:

- Sale Gross remains in its sale-effective period.
- Refund contribution remains in its refund-effective period.
- A later refund never moves or rewrites historical Gross.
- Net is derived by canonical subtraction and remains negative where mathematically correct; do not clamp or reinterpret it as zero.
- A value-only refund changes refund value only; refund quantity remains zero under M5-03.
- Whether Gross, Refund, or Net is presented as a velocity measure remains an owner decision.

## Window, denominator, and trend contract

### Current windows

The programme explicitly supports 15m, 30m, and 60m as recent velocity windows. These current-window definitions are supported; the comparison baseline is not.

| Window | `start_utc` | `end_utc` | `captured_now_utc` | Duration | Timezone semantics | Recommended previous start | Recommended previous end |
|---|---|---|---|---:|---|---|---|
| 15m | `N - 15 minutes` | `N` | `N` | 900 seconds | Elapsed UTC | `N - 30 minutes` | `N - 15 minutes` |
| 30m | `N - 30 minutes` | `N` | `N` | 1,800 seconds | Elapsed UTC | `N - 60 minutes` | `N - 30 minutes` |
| 60m | `N - 60 minutes` | `N` | `N` | 3,600 seconds | Elapsed UTC | `N - 120 minutes` | `N - 60 minutes` |

All periods use half-open `[start,end)` boundaries. Capture one `N` for the complete set of current windows. Use UTC absolute duration, not Johannesburg civil-day arithmetic. Previous bounds are the recommended immediately preceding equal-duration comparison only; do not construct or read them before owner approval. Custom arbitrary current velocity windows are outside the MVP unless separately admitted.

### Rate unit and numeric rules

Canonical unit remains `OWNER_DECISION_REQUIRED`. Recommendation only: tickets per hour and currency units per hour. If accepted, `X` over a fixed duration `D` minutes normalizes as `X × 60 / D`; the exact multipliers are 4, 2, and 1 for 15m, 30m, and 60m. This example is not accepted product contract until approved.

Architectural recommendations: use Decimal arithmetic for rate values, avoid floating point, keep canonical values unrounded, and apply an owner-approved rounding/precision rule only at display. The fixed windows have positive duration. Never use BEAM execution time as a denominator. Do not round additive primitives or intermediate rate math.

### Trend and zero/negative baselines

Baseline, absolute delta, direction inclusion and naming, percentage inclusion, threshold/tolerance, and zero/negative baseline behavior are all `OWNER_DECISION_REQUIRED`. If selected by the owner, an absolute delta would be current approved rate minus previous approved rate using matching units; a numeric direction could follow its sign. These are recommendations, not implementation invariants.

`MetricRules` has explicit comparison states such as `flat_zero`, `new_activity`, `baseline_zero`, `current_missing`, `comparison_missing`, and `not_comparable`. Reuse a state only where its existing preconditions match and an owner decision selects that meaning. Never emit infinity, NaN, divide-by-zero, or a fabricated percentage. Negative Net remains signed regardless of presentation.

## REUSE / EXTEND / NEW decisions

| Component | Decision | Reason |
|---|---|---|
| `TimeRules` | EXTEND | Reuse one captured UTC instant and half-open rules for the three current windows. Add comparison bounds only after baseline approval. |
| `PeriodReadPlan` | REUSE | Call the existing decomposition for each approved operand. Do not duplicate its full-hour plus bounded-edge algorithm. |
| `EventPeriodAggregateSnapshot` | REUSE | Existing durable event/currency bucket primitives and coverage lifecycle suffice for the proposed read model. |
| `AnalyticsContributionFact` | REUSE | Existing exact sale/refund effective-time contributions support bounded edges. |
| `PeriodComparisonReader` | EXTRACT FROM | Move only shared event-level projection composition if M5-04 behavior remains unchanged. Keep its dimension-family behavior and public response. |
| `ProjectionPeriodReader` | NEW internal seam | Own fixed-bucket fetch, bounded event edge aggregation, coverage-envelope validation, semantic-version/coverage-identity checks, and event-level operand primitive composition. |
| `VelocityReader` | NEW | Later public analytics reader, after owner decisions, extraction, and pre-reader performance gate. |
| `VelocityRules` | NEW | Pure approved Decimal rate/trend rules only. |
| `MetricRules` | REUSE / narrowly extend | Reuse canonical primitives and compatible explicit comparison states; any new trend state needs owner approval. |
| `HotStateAggregator` | REUSE MECHANICS / NOT AUTHORITY | Legacy totals are not canonical. A later mirror may only accelerate an already-computed canonical result under separate authority. |
| `DashboardCache` | NO_CHANGE | No measured M5-05 need or correctness role. |
| Redis | NO_CHANGE | No measured need or selected structure. |
| PubSub | NO_CHANGE | Existing event-scoped post-refresh signal remains sufficient unless a reproducible gap is proved. |
| Oban | NO NEW READ WORK | Existing projection rebuild and coverage jobs only; no request-time velocity job. |

### Reader architecture alternatives

| Option | Decision | Reason |
|---|---|---|
| Extend `PeriodComparisonReader` with velocity derivation | NOT SELECTED | Would mix comparison and velocity semantics and cannot safely multiply independent reads for all windows. |
| New `VelocityReader` with copied projection SQL | REJECT | Duplicates edge query, bucket coverage, currency and metadata checks, and race-sensitive logic. |
| Extract a narrow shared event projection composition seam | RECOMMENDED, CONDITIONAL | Lets M5-04 and later velocity reads share query/coverage mechanics while keeping period planning, product semantics, dimensions, auth, response shape, and transaction ownership outside the seam. |

The seam must not own time decomposition, product velocity semantics, dimensions, authorization, public response shape, or transaction creation. If a behavior-preserving extraction is unsafe, stop with `SHARED_PROJECTION_EXTRACTION_NOT_SAFE`; do not retain a second copied query implementation as fallback.

### Extraction boundary and M5-04 risk

Candidate future files are `lib/event_sales/analytics/projection_period_reader.ex` and `lib/event_sales/analytics/period_comparison_reader.ex`, with a focused new projection-period-reader test file and all existing M5-04 reader, coverage, query-plan, isolation, concurrency, and reconciliation regression suites. Move only event-level fixed bucket lookup, bounded event edge aggregation, coverage-envelope checks, metadata compatibility, and operand primitive composition. Leave dimension-family SQL, M5-04 comparison derivation, response envelope, and policy behavior in their accepted owner.

The regression risk is high because M5-04 is certified. Preserve semantic responses, policy redaction, scope predicates, and the exact coherent-transaction order below. Stop if the extraction changes M5-04 semantics or requires a second query implementation.

## Coherent transaction law

The accepted M5-04 transaction contract applies to the extraction and every future velocity projection read.

~~~text
TRANSACTION_OWNER=PeriodComparisonReader / future VelocityReader caller
TRANSACTION_OPTS=EventSnapshotRefreshFence.coherent_transaction_opts/0
PRE_FIRST_PROJECTION_ACTION=EventSnapshotRefreshFence.prepare_coherent_transaction!/0
PREPARE_LOCATION=INSIDE Repo.transaction
PREPARE_ORDER=BEFORE FIRST PROJECTION STATEMENT
PREPARE_BEFORE_FIRST_PROJECTION=YES
SHARED_KERNEL_STARTS_TRANSACTION=NO
SECOND_TRANSACTION=FORBIDDEN
~~~

`EventSnapshotRefreshFence.coherent_transaction_opts/0` alone is insufficient. The caller starts `Repo.transaction/2` with those options. The first coherence action inside its callback is `EventSnapshotRefreshFence.prepare_coherent_transaction!/0`. Only after it succeeds may the first projection SQL run. `ProjectionPeriodReader` is called only inside that already-prepared transaction; it must not call `Repo.transaction/2` or issue projection SQL before preparation.

`PeriodComparisonReader` retains the accepted sequence unchanged. Future `VelocityReader` uses the same caller-owned sequence for every approved operand. This architectural pseudocode shows the required order, not implementation code:

~~~elixir
Repo.transaction(
  fn ->
    :ok = EventSnapshotRefreshFence.prepare_coherent_transaction!()
    # Then and only then read all approved projection operands.
  end,
  EventSnapshotRefreshFence.coherent_transaction_opts()
)
~~~

Any implementation using only `coherent_transaction_opts/0`, preparing after projection SQL, removing preparation, nesting a second transaction, or letting `ProjectionPeriodReader` own a transaction is incorrect.

## No-raw-scan invariant

Interactive M5-05 reads must not calculate velocity financials from `sales_orders`, `sales_order_items`, `sales_refunds`, or `sales_refund_lines`. Those remain source/rebuild truth only.

Approved interactive operands are the existing analytics projections/facts plus bounded readiness, identity, authorization, and catalog support reads. Missing, stale, or incompatible projection coverage returns `NOT_READY` or `UNAVAILABLE`; never fall back to raw tables.

Future certification must prove:

1. Static production boundary: the velocity reader and shared projection seam do not aggregate financials directly from raw order/refund tables.
2. SQL telemetry table boundary: successful velocity reads query only approved analytics projection/fact tables plus bounded policy/readiness/catalog support queries.
3. Query-count independence: statement count does not rise with historical source order/refund row count; no N+1 per bucket, operand, or currency.
4. Selective `EXPLAIN` for actual projection/fact queries. A new index requires selective before-change evidence and separate approval.

## Security, readiness, and visibility

Preserve the public read order:

1. Cast and validate event identity.
2. Authorize with the existing event-dashboard policy.
3. Validate the typed currency/window request and resolve `ANALYTICS_READY`; fail closed if false.
4. Capture one `now`, build only approved plans, and read projections under the coherent transaction law.
5. Derive only owner-approved fields.
6. Apply `Policies.can_view_revenue?/2` before returning money fields.

No financial projection query may precede authorization/readiness. Every monetary primitive, rate, delta, percentage, and money-derived status obeys revenue visibility. Whether ticket quantity velocity remains visible when revenue is redacted is an owner decision; if approved, it still requires event access. Return no PII, source payloads, order identifiers, refund identifiers, or raw line identities.

`ANALYTICS_READY` does not replace per-bucket coverage checks. A current explicit zero can prove covered zero. Missing, stale, refresh-pending, rebuilding, unavailable, or mismatched semantic/coverage identity is not zero and fails closed.

## Concurrency and coherence review

All approved current and comparison operands for one response use one captured `now`, one actor, one event, one currency, and one caller-owned prepared projection transaction. Do not use sleeps as a correctness argument.

| Race | Required result |
|---|---|
| Projection refresh commits during the read | Repeatable-read sees one coherent pre-commit or post-commit projection state; never a mixture. |
| Late refund commits during the read | Result sees either the old or committed new covered refund contribution; refund remains at refund-effective time and historical Gross stays unchanged. |
| Exact source replay occurs | Existing source identity/projection replacement counts each contribution once; no raw-row read-side deduplication. |
| Coverage is stale before the read | Return not-ready/unavailable; no raw fallback. |
| Coverage changes after the transaction snapshot begins | Current response remains coherent with its transaction snapshot; a later request observes the new state. |
| Another event or currency refreshes | Event and currency predicates isolate the read. |

Future tests use barriers or explicit transaction coordination, never timing sleeps.

## Performance & scaling review

| Layer | M5-05 position |
|---|---|
| Source truth | PostgreSQL Orders, OrderItems, Refunds, RefundLines; never interactive velocity inputs. |
| Durable read model | `EventPeriodAggregateSnapshot` and `AnalyticsContributionFact`. |
| Hot | None required for correctness. |
| Warm | None required for correctness. |
| PubSub | Existing event-scoped post-refresh signal unless a reproducible M5-05 gap is proven. |
| Oban | Projection rebuild and coverage work only; no new read work. |

Expected period geometry:

| Operand | Fixed UTC-hour interiors | Contribution edges |
|---|---:|---:|
| 15m | 0 | Up to 2 bounded sub-hour fragments. |
| 30m | 0 | Up to 2 bounded sub-hour fragments. |
| 60m aligned to a UTC-hour boundary | 1 | 0. |
| 60m unaligned | 0 | Up to 2 bounded sub-hour fragments. |

An approved current/previous equal-duration pair has at most four edge fragments. Three current windows are a fixed-size plan set; if the baseline is approved, the three pairs are also fixed-size. Deduplicate bucket/envelope specs and use set-based queries. Do not claim the edge row count is constant: contribution rows can be dense inside touched UTC-hour envelopes during a flash sale. Reads are bounded by selected envelope time and projection/fact cardinality, not total historical order/refund history.

The existing `(event_id, currency, effective_at)` index is the starting query shape. No new index is authorized without selective before-`EXPLAIN` evidence. No N+1. Do not add a cache or Redis because the roadmap mentions hot summaries.

PR #304's performance analysis identified sub-hour edge density as a risk, not as a solved or certified property. The pre-reader M5-05D gate must measure the intended query shape using representative normal and high-density fixtures, all supported windows, aligned/unaligned 60m cases, query count, rows/edge cardinality, plans, pool/queue behavior, and concurrency cohorts 1/20/50. A proposed 100ms normal-density p99 at concurrency 50 is a target only, not certification or an already accepted GO threshold. The D admission must set its pass criteria and fixtures before measurement. D must return `OPTION_A=NO_GO` before public reader integration if evidence is unacceptable. A NO_GO does not authorize finer buckets, a resource, or an index; those require a separate architecture admission.

Do not claim 100K concurrent users, sub-100ms behavior, or flash-sale safety as certified without M5-05 evidence. M5-04 latency results are not M5-05 certification.

### Cache, Redis, and invalidation decision

~~~text
CACHE_DECISION=NO_CHANGE
REDIS_DECISION=NO_CHANGE
PUBSUB_DECISION=NO_CHANGE
NEW_RESOURCE_REQUIRED=NO
NEW_INDEX_REQUIRED=NO
~~~

No cache, TTL, Redis key/value structure, invalidation path, stampede mechanism, new PubSub broadcast, worker, or scheduler is selected. A future measured-load proposal must be a separate authority decision with a complete design. Existing unrelated cache configuration is not M5-05 authority.

## Folder and naming

Keep future code under `lib/event_sales/analytics/`. Candidate responsibilities are `velocity_rules.ex`, `projection_period_reader.ex`, and `velocity_reader.ex`. Do not create new reporting/velocity/management domains. Do not create a durable velocity resource; rates and trends remain derived unless separate evidence and authority prove otherwise.

## M5-05 serial phase design

All phases below are future work and each requires its own later admission. M5-05B cannot start until all decisions needed by B are explicitly accepted. Recommendations in v3 do not satisfy that dependency.

### M5-05B — owner-approved pure windows and velocity rules

- **Objective:** implement only accepted current-window, numerator, unit, rate, and trend rules as pure calculations.
- **Exact writable files:** `lib/event_sales/analytics/time_rules.ex`; new `lib/event_sales/analytics/velocity_rules.ex`; `test/event_sales/analytics/time_rules_test.exs`; new `test/event_sales/analytics/velocity_rules_test.exs`.
- **Dependencies:** authoritative decisions for primary numerator; supporting quantity/refund measures; monetary-rate inclusion; canonical unit; whether raw window values are public; baseline; absolute-delta and direction inclusion/naming; percentage behavior for zero and negative baselines; tolerance; display precision/rounding; cross-currency ticket presentation; and public three-window result shape if B depends on it.
- **Invariants:** one captured UTC `now`; current windows remain 15m/30m/60m and half-open; no previous baseline without approval; implement no recommendation as contract; Decimal/no-float and no intermediate rounding if accepted; preserve signed Net.
- **Performance review:** bounded pure CPU work; no DB, cache, Redis, PubSub, worker, scheduler, or index.
- **STOP:** any B dependency is missing; arbitrary current windows are requested; code assumes an unapproved metric, unit, baseline, percentage, or display rule; M5 financial semantics would change.

### M5-05C — behavior-preserving shared projection extraction

- **Objective:** extract event-level bucket/edge/coverage composition for reuse without changing certified M5-04 behavior.
- **Exact writable files:** new `lib/event_sales/analytics/projection_period_reader.ex`; modify `lib/event_sales/analytics/period_comparison_reader.ex`; add `test/event_sales/analytics/projection_period_reader_test.exs`. Regression tests to run include `period_comparison_reader_test.exs`, `period_comparison_reader_correctness_test.exs`, `period_comparison_reader_policy_test.exs`, `period_comparison_reader_query_plan_test.exs`, `period_comparison_reader_concurrency_test.exs`, `period_comparison_reader_isolation_test.exs`, `period_comparison_reader_matrix_test.exs`, `m5_04_period_concurrency_test.exs`, `m5_04_period_backfill_churn_test.exs`, `m5_04_period_query_plan_test.exs`, `m5_04_period_isolation_regression_test.exs`, `m5_04_period_reconciliation_test.exs`, `period_coverage_gap_test.exs`, and `period_coverage_closure_test.exs`.
- **Dependencies:** M5-05B passes and merges; separate C admission; extraction boundary and transaction owner reviewed before coding.
- **Invariants:** move only event-level bucket fetch, bounded contribution edges, coverage-envelope validation, metadata compatibility, and operand primitive composition; preserve dimensions and public comparison behavior; preserve `Repo.transaction` → `prepare_coherent_transaction!` → shared projection composition; no raw table read or second decomposition/query implementation.
- **Performance review:** compare SQL and query count before/after; statement count stays bounded independently of historical source rows.
- **STOP:** extraction changes M5-04 behavior; preparation is removed/moved late; shared kernel starts a transaction; a nested transaction appears; projection metadata cannot prove coverage; a new index is needed without selective before-`EXPLAIN` evidence.

### M5-05D — pre-reader Option A query-plan and load gate

- **Objective:** measure the shared bucket/edge query shape before any public `VelocityReader` integration and issue `OPTION_A=GO` or `OPTION_A=NO_GO`.
- **Exact writable files:** add `test/event_sales/analytics/m5_05_velocity_option_a_gate_test.exs`; update `docs/evidence/m5-05-deterministic-sales-velocity-certification.md` only in a separately admitted evidence task.
- **Dependencies:** M5-05C passes; approved test fixtures, cohorts, and pass criteria; current product decisions do not broaden projection SQL.
- **Invariants:** measure existing projections/facts only; include sub-hour dense-edge cases, normal and high-density fixtures, 15m/30m/60m, aligned/unaligned 60m, selective `EXPLAIN`, telemetry, query count, rows scanned, pool/queue, and cohorts 1/20/50; report target versus measured result separately.
- **Performance review:** a normal-density p99 target of 100ms at concurrency 50 is a candidate target, not certified. The D admission must confirm the acceptance threshold before claiming GO. A high-density NO_GO blocks public reader integration.
- **STOP:** missing approved pass criteria or representative fixture; unacceptable edge density or plan; selective index evidence absent; any attempt to auto-add a finer bucket/resource/index/cache. `OPTION_A=NO_GO` requires separate architecture admission before redesign.

### M5-05E — projection-backed VelocityReader and existing facade integration

- **Objective:** add the approved read through the existing event-scoped analytics facade, using the extracted kernel and accepted policy contract.
- **Exact writable files:** add `lib/event_sales/analytics/velocity_reader.ex`; modify `lib/event_sales/analytics/event_scoped_dashboard.ex`; add `test/event_sales/analytics/velocity_reader_test.exs`, `test/event_sales/analytics/velocity_reader_policy_test.exs`, `test/event_sales/analytics/velocity_reader_query_plan_test.exs`, and `test/event_sales/analytics/event_scoped_dashboard_velocity_test.exs`.
- **Dependencies:** B owner decisions and pure rules accepted; C extraction passes; D returns `OPTION_A=GO`; response shape and comparison operands are approved.
- **Transaction law:** the reader caller owns `Repo.transaction/2`; pass `EventSnapshotRefreshFence.coherent_transaction_opts/0`; first inside-callback action is `:ok = EventSnapshotRefreshFence.prepare_coherent_transaction!/0`; only then read all approved projection operands. ProjectionPeriodReader owns no transaction.
- **Invariants:** identity validation → authorization → ANALYTICS_READY → projection read → approved derivation → revenue redaction; one captured now/event/currency/transaction; no raw fallback; fail closed on missing coverage; quantity under revenue redaction follows its recorded owner decision; no PII.
- **Performance review:** query count is bounded by the fixed approved plan set; set-based reads, no N+1; any SQL-shape change repeats relevant D evidence.
- **STOP:** preparation missing or late; nested/second transaction; shared kernel owns a transaction; raw source read; stale coverage becomes zero; M5-04 behavior changes; D did not pass.

### M5-05F — reconciliation, concurrency, and raw-boundary certification

- **Objective:** certify financial parity, refund placement, coverage, transaction coherence, policy, and no-raw-read behavior.
- **Exact writable files:** add `test/event_sales/analytics/m5_05_velocity_reconciliation_test.exs`, `test/event_sales/analytics/m5_05_velocity_concurrency_test.exs`, `test/event_sales/analytics/m5_05_velocity_raw_boundary_test.exs`, and `test/event_sales/analytics/m5_05_velocity_query_plan_test.exs`; add `docs/evidence/m5-05-deterministic-sales-velocity-certification.md` only in its separate evidence admission.
- **Dependencies:** M5-05E passes.
- **Invariants:** sale Gross remains at sale time; refund stays at refund time; replay counts once; negative Net is preserved; current zero requires current coverage; stale/missing fails closed; all operands share one prepared coherent transaction; raw financial tables absent from successful reader SQL.
- **Performance review:** selective `EXPLAIN`, static boundary, SQL telemetry, query-count independence, no new index without before-`EXPLAIN` evidence.
- **STOP:** mismatch, raw financial read, mixed projection generation, authorization/redaction leak, or unsupported infrastructure mechanism.

### M5-05G — measured full-reader load and acceleration decision

- **Objective:** measure the integrated reader under bounded representative load and decide whether a separate acceleration design is justified.
- **Exact writable files:** add `test/event_sales/analytics/m5_05_velocity_load_evidence_test.exs`; update `docs/evidence/m5-05-deterministic-sales-velocity-certification.md` only in its separate evidence admission; any cache/Redis implementation needs a later independent admission.
- **Dependencies:** M5-05F passes; representative cohorts and output format are approved for the measurement.
- **Invariants:** report cohort sizes, fixture bounds, windows/edges, query count, rows, p50/p95/p99, pool/queue, and errors; distinguish normal and dense-edge outcomes; do not extrapolate beyond tested results.
- **Performance review:** keep CACHE/REDIS/PUBSUB `NO_CHANGE` absent measured need. A future mirror requires separate authority describing key/value/TTL, semantic and coverage identity, readiness, invalidation, stampede control, PubSub relation, and failure behavior. Do not select a Redis data structure speculatively.
- **STOP:** absent or inconclusive evidence; cache/Redis/PubSub change proposed without measured need and separate authority; claims exceed tested cohorts.

No phase authorizes a UI, new durable resource, migration, index, worker, scheduler, cache behavior, Redis structure, or new PubSub behavior.

## Project-level Scaffolding TOON — M5-05 Deterministic Sales Velocity

| Field | Content |
|---|---|
| Task | Plan the complete M5-05 programme from accepted owner decisions through measured acceleration review. |
| Objective | Preserve serial order: owner decisions → M5-05B pure windows/rate/trend rules → M5-05C shared projection extraction → M5-05D pre-reader query-plan/load gate → M5-05E VelocityReader and existing facade → M5-05F conformance certification → M5-05G full-reader load and acceleration decision. |
| Output | This v3 authority-repair plan only. Future B-G work each needs exact files, dependencies, tests, invariants, performance review, STOP conditions, and its own later admission. |
| Note | THIS SCAFFOLD DOES NOT AUTHORIZE IMPLEMENTATION. Owner decisions precede B. Each serial phase requires separate admission. Indexes: existing only; no new index without selective BEFORE EXPLAIN. Cache: NO_CHANGE. TTL: none introduced. Redis structure: none selected. Invalidation: existing projection lifecycle and coverage identity only; no new mechanism. PubSub: existing event-scoped post-refresh signal only; no new broadcast. Concurrency: preserve the caller-owned coherent transaction law; preparation precedes projection SQL and the shared kernel starts no transaction. STOP: missing owner authority/admission; raw fallback; M5-04 semantic change; or unapproved resource, index, cache, Redis, PubSub, worker, scheduler, or UI scope. |

## M5-05B micro-prompt — pure approved velocity rules

| Field | Content |
|---|---|
| Task | Implement one owner-approved pure time/rate/trend contract. |
| Objective | Make accepted current windows and approved rate/trend arithmetic deterministic without persistence or I/O. |
| Output | Modify `lib/event_sales/analytics/time_rules.ex`; add `lib/event_sales/analytics/velocity_rules.ex`; update `test/event_sales/analytics/time_rules_test.exs`; add `test/event_sales/analytics/velocity_rules_test.exs`. |
| Note | Do not begin until primary numerator; supporting measures; monetary inclusion; canonical unit; raw-value output; comparison baseline; delta/direction/naming; percentage zero/negative rules; threshold; precision/rounding; cross-currency quantity and public three-window shape dependencies are authoritative. Current windows remain 15m/30m/60m. Indexes: existing only; no new index. Cache: NO_CHANGE. TTL: none introduced. Redis structure: none. Invalidation: none; pure rules. PubSub: existing signal only; no new behavior. Concurrency: pure deterministic computation, no shared state or DB transaction. STOP: any dependency unresolved or a recommendation is treated as accepted. |

## M5-05C micro-prompt — shared projection composition

| Field | Content |
|---|---|
| Task | Extract the event-level projection composition used by the accepted M5-04 reader. |
| Objective | Reuse fixed-bucket, bounded-edge, coverage, and metadata checks for a future velocity reader without changing M5-04 behavior. |
| Output | Add `lib/event_sales/analytics/projection_period_reader.ex`; modify `lib/event_sales/analytics/period_comparison_reader.ex`; add `test/event_sales/analytics/projection_period_reader_test.exs`; run the M5-04 regression tests listed in the phase definition. |
| Note | Move only event-level composition. Name both required calls: `EventSnapshotRefreshFence.coherent_transaction_opts/0` and `EventSnapshotRefreshFence.prepare_coherent_transaction!/0`. The caller starts the transaction; `prepare_coherent_transaction!/0` runs inside it before first projection SQL. Indexes: existing only; no new index without selective BEFORE EXPLAIN. Cache: NO_CHANGE. TTL: none introduced. Redis structure: none. Invalidation: existing projection lifecycle/coverage identity only. PubSub: existing event-scoped post-refresh signal only; no new broadcast. Concurrency: preserve `Repo.transaction` → preparation → shared composition; shared kernel starts no transaction. STOP: preparation removed/late, nested transaction, M5-04 change, copied query path, raw read, or unsafe extraction. |

## M5-05D micro-prompt — pre-reader performance gate

| Field | Content |
|---|---|
| Task | Measure the shared Option A bucket/edge query shape before public reader integration. |
| Objective | Return `OPTION_A=GO` or `OPTION_A=NO_GO` from approved query-plan and load evidence, including dense sub-hour edge cases. |
| Output | Add `test/event_sales/analytics/m5_05_velocity_option_a_gate_test.exs`; update `docs/evidence/m5-05-deterministic-sales-velocity-certification.md` only in its separate admission; no reader integration. |
| Note | Measure 15m/30m/60m, aligned/unaligned 60m, normal/high-density edges, selective EXPLAIN, telemetry, query count, rows, pool/queue, and cohorts 1/20/50. Indexes: existing only; a proposed index needs selective BEFORE EXPLAIN and separate authority. Cache: NO_CHANGE. TTL: none introduced. Redis structure: none. Invalidation: existing projection lifecycle/coverage identity only. PubSub: existing signal only; no new broadcast. Concurrency: bounded measured cohorts; no extrapolation. STOP: criteria/fixtures unapproved, edge density unacceptable, or a finer bucket/resource/index/cache is proposed automatically; NO_GO needs separate architecture admission. |

## M5-05E micro-prompt — VelocityReader and facade

| Field | Content |
|---|---|
| Task | Expose the owner-approved projection-backed velocity read through the existing analytics facade. |
| Objective | Return only approved measures under event access, readiness, revenue visibility, and one coherent projection snapshot. |
| Output | Add `lib/event_sales/analytics/velocity_reader.ex`; modify `lib/event_sales/analytics/event_scoped_dashboard.ex`; add `test/event_sales/analytics/velocity_reader_test.exs`, `test/event_sales/analytics/velocity_reader_policy_test.exs`, `test/event_sales/analytics/velocity_reader_query_plan_test.exs`, and `test/event_sales/analytics/event_scoped_dashboard_velocity_test.exs`. |
| Note | Requires B decisions, C pass, D `OPTION_A=GO`, and approved output shape. Name `EventSnapshotRefreshFence.coherent_transaction_opts/0` and `EventSnapshotRefreshFence.prepare_coherent_transaction!/0`; `prepare_coherent_transaction!/0` executes inside the caller transaction before first projection SQL. Indexes: existing only; no new index without selective BEFORE EXPLAIN. Cache: NO_CHANGE. TTL: none introduced. Redis structure: none. Invalidation: existing projection lifecycle/coverage identity only. PubSub: existing event-scoped post-refresh signal only. Concurrency: one captured now and caller-owned prepared transaction for all operands; kernel starts no transaction. STOP: preparation missing/late, second transaction, raw fallback, stale-as-zero, policy-order change, or M5-04 semantic change. |

## M5-05F micro-prompt — conformance certification

| Field | Content |
|---|---|
| Task | Certify refund/time reconciliation, raw boundary, query bounds, policy, and transaction coherence. |
| Objective | Prove the approved reader uses canonical M5 projections and stays coherent under refresh and late-refund races. |
| Output | Add `test/event_sales/analytics/m5_05_velocity_reconciliation_test.exs`, `test/event_sales/analytics/m5_05_velocity_concurrency_test.exs`, `test/event_sales/analytics/m5_05_velocity_raw_boundary_test.exs`, and `test/event_sales/analytics/m5_05_velocity_query_plan_test.exs`; add the certification evidence document only in its separate admission. |
| Note | Include static production boundary, SQL telemetry, query-count independence, exact replay, negative Net, current zero, missing/stale coverage, currency/event isolation, and barrier-controlled races. Indexes: existing only; no new index without selective BEFORE EXPLAIN. Cache: NO_CHANGE. TTL: none introduced. Redis structure: none. Invalidation: existing projection lifecycle/coverage identity only. PubSub: existing post-refresh signal only. Concurrency: same prepared transaction; no sleeps. STOP: raw read, mixed generations, mismatch, leakage, or unapproved mechanism. |

## M5-05G micro-prompt — measured load and acceleration decision

| Field | Content |
|---|---|
| Task | Measure the fully integrated reader and decide whether acceleration merits a separate design. |
| Objective | Base any cache/Redis proposal on M5-05 evidence rather than roadmap wording or M5-04 measurements. |
| Output | Add `test/event_sales/analytics/m5_05_velocity_load_evidence_test.exs`; update `docs/evidence/m5-05-deterministic-sales-velocity-certification.md` only in its separate admission; no cache/Redis implementation. |
| Note | Report tested cohorts, fixture bounds, edge cardinality, query count, p50/p95/p99, pool/queue, and errors without extrapolation. Indexes: existing only; no new index without selective BEFORE EXPLAIN. Cache: NO_CHANGE pending evidence. TTL: none selected. Redis structure: none selected. Invalidation: no new mechanism selected. PubSub: existing signal only; no new broadcast. Concurrency: bounded representative load with the prepared coherent transaction. STOP: evidence absent/inconclusive or a mirror proposed without separate authority defining key/value/TTL/semantic and coverage identity/readiness/invalidation/stampede/PubSub/failure semantics. |

## Source authority reviewed

- `docs/path-1/path-1-phase-breakdown.md`
- `docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md`
- `docs/roadmap/EVENTSALES_LIVE_SALES_PROGRAMME.md`
- `docs/development/pre-m5-02-metrics-foundation.plan.md`
- `docs/development/m5-04-period-comparisons.plan.md`
- `docs/evidence/m5-02-ticket-product-variation-aggregates-certification.md`
- `docs/evidence/m5-03-revenue-refund-dimensional-aggregates-certification.md`
- `docs/evidence/m5-04-period-comparisons-certification.md`
- `lib/event_sales/analytics/time_rules.ex`
- `lib/event_sales/analytics/period_read_plan.ex`
- `lib/event_sales/analytics/period_comparison_reader.ex`
- `lib/event_sales/analytics/event_snapshot_refresh_fence.ex`
- `lib/event_sales/analytics/resources/event_period_aggregate_snapshot.ex`
- `lib/event_sales/analytics/resources/analytics_contribution_fact.ex`
- `lib/event_sales/analytics/hot_state_aggregator.ex`
- `lib/event_sales/analytics/dashboard_cache.ex`
- `lib/event_sales/analytics/aggregators/event_aggregator.ex`
- `lib/event_sales/analytics/metric_rules.ex`
- PR #304 metadata (merged; no reviews or discussion comments) and PR #305 correction review identity.

## Authority self-review

| Check | Result |
|---|---|
| PR #304 history retained without treating merge as owner acceptance | YES |
| Unresolved product choices remain recommendations only | YES |
| Gross, refund, and Net remain distinct; refund stays at refund-effective time | YES |
| Negative Net is preserved | YES |
| 15m/30m/60m current windows remain supported | YES |
| Legacy HotState financial data is canonical velocity authority | NO |
| PeriodReadPlan algorithm duplicated | NO |
| Raw source-table fallback allowed | NO |
| New durable velocity resource or index authorized | NO |
| Cache, Redis, or PubSub changes authorized | NO |
| Dense edge performance risk described as certified | NO |
| Pre-reader D gate can return NO_GO before reader integration | YES |
| Coherent transaction options and preparation both named and ordered | YES |
| Shared kernel starts a transaction or a second transaction is permitted | NO |
| Every phase requires later admission | YES |
| Implementation authorized with owner decisions outstanding | NO |

~~~text
PR_304_MERGED=YES
PR_304_OWNER_SEMANTIC_LOCKS=NOT_DURABLY_PROVEN
OWNER_DECISION_REQUIRED=YES
IMPLEMENTATION_READY=NO
M5_05_IMPLEMENTATION_AUTHORIZED=NO
~~~
