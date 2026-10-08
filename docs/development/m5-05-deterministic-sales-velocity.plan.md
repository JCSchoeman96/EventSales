# M5-05 deterministic sales velocity planning and conformance audit

~~~text
PLAN_ID=m5-05-deterministic-sales-velocity
PLAN_VERSION=v1
BASE_SHA=7d81d317886c38327a3a4fdb42c72f4ab8d688cb
BASE_TREE=c5a001290977c553a8763c174c110c2862047dac

M5_02_STATUS=COMPLETE_PASS
M5_03_STATUS=COMPLETE_PASS
M5_04_STATUS=COMPLETE_PASS
M5_05A_STATUS=IN_REVIEW
M5_05_IMPLEMENTATION_AUTHORIZED=NO

VELOCITY_SEMANTIC_STATUS=OWNER_DECISION_REQUIRED
WINDOW_STATUS=LOCKED_15M_30M_60M
TREND_STATUS=OWNER_DECISION_REQUIRED

RAW_SCAN_DECISION=FORBIDDEN
HOT_STATE_CANONICAL_AUTHORITY=NO
VELOCITY_PRIMARY_METRIC=OWNER_DECISION_REQUIRED_RECOMMEND_GROSS_TICKET_QUANTITY_PER_HOUR
VELOCITY_SUPPORTING_METRICS=OWNER_DECISION_REQUIRED_NET_QTY_RATE_AND_REFUND_QTY_RATE;MONETARY_RATES_OWNER_DECISION_REQUIRED
VELOCITY_UNIT=PER_HOUR
WINDOWS=15M,30M,60M
PREVIOUS_EQUIVALENT_RULE=IMMEDIATELY_PRECEDING_EQUAL_DURATION
REFUND_TREATMENT=SALE_GROSS_AT_SALE_EFFECTIVE_TIME;REFUND_AT_REFUND_EFFECTIVE_TIME
TREND_RULE=ABSOLUTE_RATE_DELTA_AND_DIRECTION;PERCENTAGE_OWNER_DECISION_REQUIRED
ZERO_BASELINE_RULE=OWNER_DECISION_REQUIRED_REUSE_M5_04_STATES_WHERE_VALID
MULTI_CURRENCY_RULE=ONE_CURRENCY_PER_READ_NO_CROSS_CURRENCY_SUM
RAW_TABLE_INTERACTIVE_READS=NONE
M5_05_CACHE_DECISION=NO_CHANGE
M5_05_REDIS_DECISION=NO_CHANGE

PERIOD_BUCKET_REUSE_DECISION=REUSE
CONTRIBUTION_FACT_REUSE_DECISION=REUSE
PERIOD_READ_PLAN_DECISION=REUSE
READER_ARCHITECTURE_DECISION=EXTRACT_NARROW_EVENT_PROJECTION_KERNEL

CACHE_DECISION=NO_CHANGE
REDIS_DECISION=NO_CHANGE
PUBSUB_DECISION=NO_CHANGE

NEW_RESOURCE_REQUIRED=NO
NEW_INDEX_REQUIRED=NO
IMPLEMENTATION_READY=NO
~~~

This is a planning and conformance document only. It changes no production code, tests, migrations, resources, indexes, configuration, dependencies, workers, schedulers, cache behavior, PubSub behavior, or UI.

## Ultimate M5-05 outcome

Management must receive a deterministic, bounded, decision-grade measure of recent sales velocity and trend that:

- uses canonical M5 financial and time semantics;
- does not scan raw order or refund history at request time;
- remains currency-safe;
- handles refunds honestly;
- is coherent with ANALYTICS_READY and projection coverage;
- respects revenue visibility;
- supports the eventual decision dashboard;
- scales horizontally without creating a second financial truth model.

## Backward plan

The smallest correct system needs these parts, in order:

1. An owner-approved definition of what “velocity” means, including Gross versus Net, quantity versus value, rate display, and trend behavior.
2. Exact current and previous-equivalent UTC windows from one captured instant.
3. The existing period decomposition: complete UTC-hour buckets plus bounded partial-hour contribution edges.
4. A single coherent read of the three current windows and their three previous-equivalent windows from the existing event-period projection and contribution facts.
5. A derived Decimal rate and trend envelope. Persist neither.
6. The existing analytics readiness, event authorization, currency scope, and revenue-redaction rules.
7. Conformance and load evidence before any cache or Redis decision changes.

The late roadmap row “Hot summaries / Velocity metrics from aggregates/hot state” predates M5-04. It does not authorize legacy hot summaries as financial truth. M5-04 now provides durable fixed period buckets, exact contribution edges, a projection-only comparison reader, coherent read transactions, coverage checks, policy redaction, and load evidence. M5-05 should build on that authority.

### Current repository truth

- M5-02 certification records tax-inclusive Gross, historical Gross preservation, currency partitioning, readiness gating, and no raw financial aggregation on its certified management read.
- M5-03 certification records independent refund facts, exact refund binding, currency isolation, revenue redaction, and dimension/readiness parity.
- M5-04 is COMPLETE / PASS. Its plan and certification govern period windows, projection coverage, previous-equivalent comparisons, edge composition, reader isolation, and cache decisions.
- TimeRules already captures rolling comparison windows from one supplied instant. Its public comparison request set is currently today, yesterday, rolling 7 days, and rolling 30 days.
- PeriodReadPlan already decomposes half-open UTC periods into full UTC-hour interiors and at most two partial-hour edges per operand. Its comparison plan caps the pair at four edges.
- EventPeriodAggregateSnapshot stores event/currency UTC-hour and Johannesburg-day additive Gross and Refund primitives, semantic version, coverage identity, generation, and projection lifecycle state.
- AnalyticsContributionFact stores exact sale/refund additive contributions by event, currency, and effective time. The existing index is event, currency, effective time.
- A present CURRENT zero bucket proves covered zero activity. A missing bucket or non-current state does not mean zero.
- PeriodComparisonReader demonstrates identity validation, authorization, currency/request validation, ANALYTICS_READY, one captured time, period planning, an EventSnapshotRefreshFence coherent transaction, bucket and edge coverage checks, derived metrics, and revenue redaction.
- HotStateAggregator and EventAggregator.summary_for_event are not canonical M5 financial truth. Their legacy total_sold / total_revenue path uses current completed status, mapped ticket, positive quantity, and ex-tax line_total.

## Domain and concept map

All listed values are event-scoped and currency-partitioned where money is involved. Derived request values do not get their own persistence or lifecycle.

| Concept | Ownership and identity | Relationships and invariants | Durable or derived | Lifecycle |
|---|---|---|---|---|
| VelocityRequest | Analytics read boundary; event UUID, one currency, fixed window set, actor | Accept only the approved 15m, 30m, and 60m choices. Do not accept raw query parameters as domain input. | Request value | Stateless |
| CapturedNow | Analytics reader; one UTC DateTime for one response | Capture once, normalize to UTC, use as every current window end. Never use BEAM execution duration as denominator. | Request-scoped derived value | Stateless |
| CurrentVelocityWindow | TimeRules; identified by duration and current bounds | For duration D, bounds are [N-D, N). It is a continuous elapsed UTC window, not a Johannesburg civil day. | Derived Period | Stateless |
| PreviousEquivalentVelocityWindow | TimeRules; same duration as its current window | For D, bounds are [N-2D, N-D). It ends exactly where the current window begins. | Derived Period | Stateless |
| PeriodReadPlan | PeriodReadPlan; operand plus exact bucket/edge bounds | Reuse existing decomposition. No second edge algorithm. Missing envelope coverage makes the operand not ready. | Derived plan | Stateless |
| EventPeriodAggregateSnapshot | Period projection owner; event, currency, bucket kind, bucket start/end | Contains additive Gross/Refund quantity and value plus semantic and coverage identity. Only a CURRENT row with compatible metadata proves coverage, including an explicit all-zero row. | Durable projection | Existing states: current, stale, refresh_pending, rebuilding, unavailable |
| AnalyticsContributionFact | Period projection owner; contribution kind plus source contribution UUID | Sale facts use sale-effective time. Refund facts use refund-effective time and exact parent-line binding. Edge facts must match their bucket envelope’s coverage identity and semantic version. | Durable projection | Replaced by existing refresh/rebuild contract |
| VelocityPrimitives | VelocityRules; one event/currency/window operand | Four additive primitives: gross quantity, refund quantity, gross value, refund value. Net quantity/value derive by canonical subtraction. Never clamp negative Net. | Derived | Stateless |
| VelocityRate | VelocityRules; metric, currency if monetary, window duration | Canonical unit is per hour. Store no rate. Quantity and money calculations use Decimal and no floating point. | Derived | Stateless |
| VelocityTrend | VelocityRules; metric and current/previous operand pair | Absolute rate delta and direction derive from the two rates. Percentage behavior remains owner-controlled for zero and negative baselines. | Derived | Stateless |
| AnalyticsReadiness | AnalyticsReadinessResolver; event | ANALYTICS_READY remains derived from durable completeness/reconciliation evidence and is not a freshness signal. | Derived from durable evidence | Existing resolver states and blocking reasons |
| RevenueVisibility | Policies.can_view_revenue?/2; actor and event | Governs every monetary primitive, rate, delta, percentage, and monetary state. Quantity visibility still requires event access. | Derived policy result | Stateless |
| ProjectionCoverage | Period projection rows; event, currency, bucket identity, semantic version, coverage identity | Bucket and edge metadata must be current and compatible. Missing or stale coverage fails closed. | Durable projection metadata | Uses the snapshot lifecycle states above |
| OptionalHotMirror | No owner in the M5-05 correctness path | Not proposed for M5-05. If later load evidence justifies a mirror, the value must copy a completed canonical result and carry its event, currency, window set, semantic version, and coverage identity. | Not present or required | Conditional future model below |

### Conditional hot-mirror lifecycle

This is not an M5-05 implementation proposal. It records the minimum conformance contract if later measured evidence requests a separate cache decision.

| State | Entry and guard | Next state |
|---|---|---|
| MISSING | No mirror key exists, or the entry expired. | CURRENT only after copying a successful canonical read with matching event, currency, bounds, semantic version, and coverage identity. |
| CURRENT | Entry metadata matches the canonical projection result and the approved freshness limit. | STALE/INVALID after any relevant projection refresh, coverage change, policy-scope mismatch, semantic-version change, or expiration. |
| STALE/INVALID | Metadata is missing, mismatched, expired, or invalidated. The reader must use the canonical projection read or return its fail-closed result. | MISSING after deletion; REBUILDING only if a separately approved rebuild is needed. |
| REBUILDING | A single-flight rebuild has been separately approved and is in progress. | CURRENT only after a successful canonical read and metadata match; STALE/INVALID on failure or changed source identity. |

There is no raw-table fallback from any state. PubSub may notify clients after committed projection refreshes; it does not make a mirror current. No key, TTL, cache, Redis, stampede, or rebuild behavior is authorized by this plan.

## Semantic decision matrix

Canonical M5 defines the additive facts and their clocks. It does not define which rate product owners mean when they say “sales velocity.” The recommendations below do not become implementation authority until the owner records the decisions.

| Candidate | M5-05 classification | Recommendation for owner decision | Trade-off or rule |
|---|---|---|---|
| Gross ticket quantity / time | OWNER_DECISION_REQUIRED | Make this the proposed primary rate. | It measures recognized sale activity and preserves the sale clock after later refunds. Alone, it does not show refunds or net ticket change. |
| Net ticket quantity / time | OWNER_DECISION_REQUIRED | Show as a supporting rate beside Gross, not as an undisclosed replacement. | Net may be negative when refund quantity exceeds Gross. Its value reflects refund-effective activity in the selected window. |
| Refund ticket quantity / time | OWNER_DECISION_REQUIRED | Approve as a separate supporting rate beside Gross and Net. | A later refund stays in its refund-effective window and never moves or rewrites historical Gross. |
| Gross ticket value / time | OWNER_DECISION_REQUIRED | Include only if value velocity is in the M5-05 product contract, and only as a currency-labeled supporting rate. | Gross value is tax-inclusive under M5 financial semantics. Revenue visibility applies. |
| Net ticket value / time | OWNER_DECISION_REQUIRED | Include only if value velocity is approved; retain negative Net. | It is Gross less refund value in the same effective-time window. It may be negative. Revenue visibility applies. |
| Refund ticket value / time | OWNER_DECISION_REQUIRED | Include with monetary rates if those rates are approved. | Omitting it while showing Gross/Net money would hide an explicit refund component. Revenue visibility applies. |

Until the owner resolves the primary metric and monetary-rate inclusion, the plan does not claim a final primary velocity definition. Do not silently equate Gross and Net.

### Refund treatment

- Sale Gross remains in its sale-effective period.
- Refund contribution remains in its refund-effective period.
- Refunds reduce the Net primitives for the period in which the refund became effective.
- A late refund never moves or rewrites historical Gross.
- Refund quantity and refund value stay separately visible wherever their associated rate family is approved and permitted.
- Negative Net remains negative. Do not clamp it, relabel it as zero, or move the refund to the original sale period.
- A value-only refund changes refund value only. Its refund quantity remains zero, as required by M5-03.

## Window matrix

M5 programme authority explicitly lists last 15, 30, and 60 minutes. M5-04 separately owns today, yesterday, rolling 7 days, and rolling 30 days. M5-05 MVP therefore uses exactly 15m, 30m, and 60m for velocity. It does not add arbitrary custom windows or reimplement M5-04 period choices.

For each duration D and one captured UTC instant N:

| Window | start_utc | end_utc | captured_now_utc | duration | timezone semantics | previous_start_utc | previous_end_utc |
|---|---|---|---|---|---|---|---|
| 15m | N - 15 minutes | N | N | 900 seconds | Exact elapsed UTC | N - 30 minutes | N - 15 minutes |
| 30m | N - 30 minutes | N | N | 1,800 seconds | Exact elapsed UTC | N - 60 minutes | N - 30 minutes |
| 60m | N - 60 minutes | N | N | 3,600 seconds | Exact elapsed UTC | N - 120 minutes | N - 60 minutes |

All intervals are half-open: [start, end). N is captured once for the complete three-window response. Durations use elapsed UTC time and are unaffected by Johannesburg daylight-saving or civil-day boundaries. All three current windows end at N; their previous-equivalent windows are the immediately preceding interval of equal duration. Custom arbitrary velocity windows are out of the MVP.

## Rate denominator, numeric type, and rounding

- The canonical unit is tickets per hour for quantity metrics and currency units per hour for monetary metrics.
- For a metric total X over duration D minutes, the exact normalized calculation is X × 60 / D.
- The only MVP durations are 15, 30, and 60 minutes, so the exact multipliers are 4, 2, and 1. This avoids a repeating Decimal division in the canonical rate calculation.
- Convert integer quantity totals to Decimal before rate arithmetic. Preserve Decimal money values and currency labels.
- Use Decimal only. Never convert to a float.
- Do not round additive totals or canonical rates. Round only at display formatting.
- Duration is fixed and positive. Zero-duration behavior is invalid input, not a numeric result. Never use process runtime as the denominator.
- The display precision and display rounding mode are OWNER_DECISION_REQUIRED. Recommendation: show two decimal places using an explicit Decimal rounding mode, while retaining the unrounded canonical Decimal result for calculations.

Example: 15 tickets over 30 minutes becomes 30 tickets/hour. It is not stored as 15 per “half-hour” and is not divided by request execution time.

## Trend semantics

The deterministic numeric trend candidate is:

- absolute delta per hour = current rate − previous-equivalent rate;
- direction = up when the absolute delta is positive, down when it is negative, unchanged when it is zero;
- direction describes numeric movement only. It does not label movement as good or bad.

Percentage rate change and its states are OWNER_DECISION_REQUIRED. M5-04 MetricRules already has explicit comparison states such as flat_zero, new_activity, baseline_zero, current_missing, comparison_missing, and not_comparable. It emits no infinity, NaN, divide-by-zero, or fabricated 100 percent result.

Recommendation for owner decision:

- Reuse the existing missing, flat-zero, new-activity, and zero-baseline distinctions where their exact preconditions apply.
- Derive a percentage only for a positive previous rate. Preserve the absolute delta and direction when the prior rate is zero or negative.
- For Net rates with a negative previous baseline, do not emit a percentage until its interpretation and state are approved. If approved, add an explicit state rather than encoding status as a numeric sentinel.
- Keep a negative current or previous Net rate intact. Do not use absolute-value denominators or reinterpret a negative Net rate as zero.

The proposed positive-baseline rule avoids the sign inversion that a conventional percentage formula can produce when a Net baseline is negative. It is a recommendation, not a locked product decision.

## Currency and readiness behavior

- Each velocity read is scoped to one requested currency. Money rates include that currency in the result.
- Never add monetary rates across currencies or fabricate an exchange rate.
- Do not choose a default or alphabetical currency to represent a mixed-currency event.
- Until a separate product decision authorizes a combined quantity presentation across currencies, keep quantity rates in the same event/currency partitions used by the projection reader.
- Resolve ANALYTICS_READY before projection reads, using the existing AnalyticsReadinessResolver.
- ANALYTICS_READY does not replace per-bucket projection coverage checks. Every fixed bucket and every partial-edge envelope must be CURRENT and compatible with its semantic version and coverage identity.
- An explicit CURRENT zero bucket proves zero. Missing, stale, refresh_pending, rebuilding, or unavailable coverage returns not-ready/unavailable. It never triggers a source-table fallback.
- Edge facts are read only when their enclosing event bucket supplies current compatible coverage. A fact metadata mismatch fails the operand closed.

## REUSE / EXTEND / NEW decisions

| Component | Decision | Reason |
|---|---|---|
| TimeRules | EXTEND | Reuse the captured-now and half-open UTC rules. Add only the fixed 15m/30m/60m recent comparison requests after semantic approval. Do not generalize to arbitrary durations. |
| PeriodReadPlan | REUSE | Call the existing decomposition for each approved current/previous pair. Retain the existing fixed-hour plus bounded-edge algorithm and per-pair four-edge guard. |
| EventPeriodAggregateSnapshot | REUSE | It already stores event/currency fixed bucket primitives and coverage lifecycle. No new durable velocity resource is needed. |
| AnalyticsContributionFact | REUSE | It already stores exact sale/refund effective-time primitives and has the event/currency/effective-time index. |
| PeriodComparisonReader | EXTRACT | Extract the event-level projection composition into a narrow shared kernel so M5-04 and a multi-window M5-05 read share the bucket/edge query and coverage logic. Keep M5-04 response and behavior unchanged. |
| ProjectionPeriodReader | NEW | Internal event-level projection composition seam. It reads labeled plans and event/currency bucket and edge operands inside a caller-owned coherent transaction. It does not own time decomposition or derive product metrics. |
| VelocityReader | NEW | Analytics reader that captures one now, creates the three fixed plans, checks identity/auth/readiness, reads all plans through the shared kernel in one coherent transaction, derives approved rates/trend, and applies revenue redaction. |
| VelocityRules | NEW | Pure Decimal rate and trend calculations. It reuses MetricRules primitives and explicit comparison-state semantics where approved. |
| MetricRules | REUSE | Continue using canonical additive primitive validation, Net derivation, and existing comparison states. Extend only if the owner approves a needed state for negative-baseline percentage semantics. |
| HotStateAggregator | REUSE MECHANICS / NOT AUTHORITY | Existing recompute/cache mechanics may inform a future optional mirror. Legacy total_sold, total_revenue, today_sold, and today_revenue are not canonical velocity inputs. |
| DashboardCache | NO_CHANGE | No measured M5-05 need. It currently stores the legacy summary and has no required velocity correctness role. |
| Redis | NO_CHANGE | No measured M5-05 need and no correctness role. |
| PubSub | NO_CHANGE | Keep the existing post-refresh event signal. M5-04 evidence records no period-reader PubSub gap. |
| Oban | NO NEW READ WORK | Reuse existing projection refresh/coverage rebuild jobs. Do not enqueue request-time velocity work. |

### Reader architecture alternatives

| Option | Decision | Reason |
|---|---|---|
| A. Extend PeriodComparisonReader with rate derivation | Not selected | It reuses the existing coherent reader but would mix comparison projection assembly with velocity rate/trend semantics and enlarge an already large reader. Extending its accepted period inputs alone would not provide one coherent read for all three windows. |
| B. Add VelocityReader with copied projection queries | REJECT | It duplicates bucket coverage, exact edge aggregation, currency isolation, metadata checks, and race-sensitive query logic. |
| C. Extract a narrow event-level projection composition kernel | RECOMMENDED | M5-05 needs all three current/previous pairs under one captured now and one coherent transaction. A shared kernel avoids copied projection SQL and avoids fetching M5-04’s dimension families for an event-level velocity read. |

The extraction must be a behavior-preserving M5-04 change before VelocityReader depends on it. Exact M5-04 regression suites remain required. If a small seam cannot be extracted without changing certified behavior, stop and request an architecture decision rather than building a second query path.

### Extraction boundary and regression risk

Files for the future extraction slice:

- New: lib/event_sales/analytics/projection_period_reader.ex
- Modify: lib/event_sales/analytics/period_comparison_reader.ex
- Tests: new test/event_sales/analytics/projection_period_reader_test.exs plus the named comparison-reader, M5-04 concurrency/reconciliation, and coverage tests listed in the phase plan.

Move only event-level fixed bucket lookup, bounded event edge aggregation, coverage-envelope validation, metadata compatibility, and operand primitive composition. PeriodComparisonReader retains its dimension-family queries, comparison derivation, envelope, and public response shape. Both callers own their EventSnapshotRefreshFence coherent transaction; the shared kernel runs within that transaction and does not start a second transaction.

Regression risk is high because PeriodComparisonReader is M5-04 certified. Require byte-for-byte-equivalent semantic response assertions for existing comparison cases, unchanged revenue redaction, unchanged query scoping, unchanged repeatable-read behavior, and all existing M5-04 tests. Do not combine the extraction and velocity behavior in one review slice.

## No-raw-scan invariant and future proof

Interactive M5-05 code must not compute velocity financials from sales_orders, sales_order_items, sales_refunds, or sales_refund_lines. Those remain rebuild/source-of-truth inputs only.

There is no fallback. Missing or non-current projection coverage returns not-ready/unavailable.

Future certification must include:

1. A static boundary test that scans production velocity reader and shared projection reader source for direct raw sales/refund financial aggregation. Allowed projection reads are EventPeriodAggregateSnapshot and AnalyticsContributionFact.
2. SQL telemetry/query tests showing a successful velocity read touches approved analytics projection/fact tables plus bounded readiness, identity, authorization, and catalog support queries only.
3. A query-count bound showing statement count is independent of historical order/refund row count. Query results may scale with the fixed bucket/edge set and projection cardinality, not the underlying source history.
4. A selective EXPLAIN test for the actual projection and contribution-fact SQL. Do not add an index without before-change EXPLAIN evidence showing a selective-path problem and owner approval.

## Concurrency and coherence

The read must use EventSnapshotRefreshFence.coherent_transaction_opts() and the M5-04 repeatable-read pattern. Capture and plan the windows before the transaction. Read all six operands inside one fenced transaction so one response cannot combine different committed projection generations.

| Race | Required result |
|---|---|
| Projection refresh commits while a velocity response reads | The repeatable-read transaction sees one pre-commit or post-commit projection state. It must not combine partial replacement generations. |
| A late refund commits during the read | The current transaction sees either the old covered refund set or the committed new refund set. Refund effective time remains its own timestamp; historical Gross remains in the sale-effective bucket. |
| Exact sale/refund replay is processed | Existing idempotent source identity and projection replacement leave each contribution counted once. No read-side deduplication from raw source rows. |
| Coverage becomes stale before projection read | The projection read sees non-current coverage and returns not-ready/unavailable. No fallback scan. |
| Coverage becomes stale after the transaction snapshot begins | The response remains coherent with the transaction snapshot. The next request observes the new state. |
| Another event or currency refreshes concurrently | Event and currency predicates isolate this read. It cannot affect this event/currency result. |

Do not use sleeps as a correctness argument. Add barrier-controlled transaction tests, as M5-04 does, when this later slice is authorized.

## Security and redaction

Keep this order:

1. Cast and validate event identity.
2. Authorize event dashboard access.
3. Validate the typed window request, one currency, and fixed window choice.
4. Resolve ANALYTICS_READY.
5. Read projection buckets and bounded contribution edges.
6. Derive rate/trend fields.
7. Apply revenue redaction before returning the result.

No projection or financial query may precede authorization. Every money field, rate, delta, percentage, and money-related state must obey Policies.can_view_revenue?/2. Ticket quantity rates may be returned only when event dashboard access is authorized. Return no PII, source payloads, order identifiers, refund identifiers, or raw line identities.

If revenue is hidden, redact Gross, refund, and Net monetary rates and every comparison field derived from them. Do not leak whether a monetary rate is zero through a status or error detail. Keep the existing M5-04 policy tests as a regression gate.

## Performance & Scaling Review

- Source truth: PostgreSQL Orders, OrderItems, Refunds, and RefundLines. These are not interactive velocity inputs.
- Durable read model: EventPeriodAggregateSnapshot and AnalyticsContributionFact.
- Hot: none required for correctness.
- Warm: none required for correctness.
- PubSub: existing event refresh signal unless a reproducible M5-05 gap is proven.
- Oban: existing projection rebuild and coverage work only. No new read jobs.

Expected period-plan shape:

| Window pair | Interior buckets | Edge bound |
|---|---|---|
| 15m current + previous | Usually none | At most two sub-hour edges per operand, four total |
| 30m current + previous | Usually none | At most two sub-hour edges per operand, four total |
| 60m current + previous | One exact UTC-hour bucket per operand when aligned; otherwise no complete hour and at most two partial-hour edges | At most two partial edges per operand, four total |

All three pairs use a fixed six-operand plan set. The shared reader should issue set-based bucket and edge reads with query count bounded by that plan and the readiness/security support reads, not by historical source row count. Do not use per-bucket or per-currency N+1 reads. Deduplicate identical bucket specs across windows before fetching them. Keep contribution facts bounded by the selected edge intervals and the existing event/currency/effective-time index.

No request reads or holds memory proportional to historical order or refund rows.

M5-04 load evidence reports the 30-day period reader at concurrency 20 and a 292ms p99 on its certified fixture, with no queue wait or pool timeout. This is not an M5-05 load result. It supports keeping cache and Redis unchanged until M5-05’s own multi-window read is measured. Do not claim sub-100ms or production-scale capacity from the M5-04 measurement.

No new index is planned. If M5-05 telemetry or selective EXPLAIN shows a query defect, stop and request a separate index decision with before-EXPLAIN evidence. Do not add Cachex, ETS mirror logic, Redis, PubSub messages, a worker, or a scheduler from roadmap language alone.

## Folder and naming

Keep new code under lib/event_sales/analytics/:

- velocity_rules.ex for pure approved rate/trend calculations;
- projection_period_reader.ex for shared event-level period projection composition;
- velocity_reader.ex for the authorized projection-backed velocity read.

Do not create EventSales.Reporting, EventSales.Velocity, or EventSales.Management domains. Do not create a durable velocity resource. Derived rates and trends do not need persistence.

## M5-05 serial phase design

Every phase below is future work. The owner decisions listed at the end must be recorded before M5-05B starts. The current JC-332 task authorizes only this planning document.

### M5-05B — Owner-approved windows and pure velocity rules

- Objective: encode only the approved fixed windows, exact per-hour Decimal rate, and trend contract.
- Exact writable production files: lib/event_sales/analytics/time_rules.ex; new lib/event_sales/analytics/velocity_rules.ex.
- Exact tests: test/event_sales/analytics/time_rules_test.exs; new test/event_sales/analytics/velocity_rules_test.exs.
- Dependencies: written owner decisions for primary numerator, money-rate inclusion, quantity presentation, percentage semantics including negative Net, and display formatting.
- Invariants: one captured now; [start,end); 15/30/60 only; exact previous-equivalent bounds; no floating point; no rounding before display; preserve negative Net.
- Performance review: pure CPU work over six bounded operands; no database, cache, Redis, PubSub, worker, or index.
- STOP: any owner decision is absent; any custom duration is requested; a formula requires changing M5 financial semantics.

### M5-05C — Extract event-level projection composition

- Objective: share M5-04’s exact bucket, edge, coverage, and metadata logic with a multi-window reader without changing the certified comparison response.
- Exact writable production files: new lib/event_sales/analytics/projection_period_reader.ex; lib/event_sales/analytics/period_comparison_reader.ex.
- Exact tests: new test/event_sales/analytics/projection_period_reader_test.exs; test/event_sales/analytics/period_read_plan_test.exs; test/event_sales/analytics/period_comparison_reader_test.exs; test/event_sales/analytics/period_comparison_reader_correctness_test.exs; test/event_sales/analytics/period_comparison_reader_policy_test.exs; test/event_sales/analytics/period_comparison_reader_query_plan_test.exs; test/event_sales/analytics/period_comparison_reader_concurrency_test.exs; test/event_sales/analytics/period_comparison_reader_isolation_test.exs; test/event_sales/analytics/period_comparison_reader_matrix_test.exs; test/event_sales/analytics/m5_04_period_concurrency_test.exs; test/event_sales/analytics/m5_04_period_backfill_churn_test.exs; test/event_sales/analytics/m5_04_period_query_plan_test.exs; test/event_sales/analytics/m5_04_period_isolation_regression_test.exs; test/event_sales/analytics/m5_04_period_reconciliation_test.exs; test/event_sales/analytics/period_coverage_gap_test.exs; test/event_sales/analytics/period_coverage_closure_test.exs.
- Dependencies: M5-05B owner decisions recorded; extraction boundary reviewed before implementation.
- Invariants: existing M5-04 response semantics unchanged; same coherent transaction; no raw sales/refund read; no dimension query moved into the event-level kernel; no new period decomposition.
- Performance review: preserve current set-based bucket and edge query shapes. Capture SQL telemetry before and after; query count must not grow with source history.
- STOP: extraction changes current M5-04 behavior, requires a competing projection history, or needs an index without selective before-EXPLAIN evidence.

### M5-05D — Multi-window projection-backed VelocityReader

- Objective: read all 15m/30m/60m current and previous operands at one captured now and derive the approved velocity envelope.
- Exact writable production files: new lib/event_sales/analytics/velocity_reader.ex; reuse TimeRules, PeriodReadPlan, ProjectionPeriodReader, MetricRules, and VelocityRules.
- Exact tests: new test/event_sales/analytics/velocity_reader_test.exs; new test/event_sales/analytics/velocity_reader_policy_test.exs; new test/event_sales/analytics/velocity_reader_query_plan_test.exs; test/event_sales/analytics/period_read_plan_test.exs and test/event_sales/analytics/projection_period_reader_test.exs.
- Dependencies: M5-05B and M5-05C.
- Invariants: one actor, event, currency, captured now, and RR projection snapshot per response; all six operands keep their labels; fail closed on any missing/stale coverage; no raw fallback; no persisted derived rate.
- Performance review: at most three pair plans, at most four edges per pair, fixed query-count ceiling, one event/currency scope, no N+1.
- STOP: one coherent transaction cannot cover all six operands; projection metadata cannot prove edge coverage; velocity requires a new durable resource.

### M5-05E — Existing analytics facade and visibility policy

- Objective: expose the read through the existing event-scoped analytics facade with the same actor and revenue policy contract.
- Exact writable production file: lib/event_sales/analytics/event_scoped_dashboard.ex, delegating to VelocityReader without using its legacy hot summary.
- Exact tests: new test/event_sales/analytics/event_scoped_dashboard_velocity_test.exs.
- Dependencies: M5-05D.
- Invariants: identity cast, authorization, readiness, projection read, then redaction; money velocity and money trend are fully redacted; quantity remains event-authorized; no PII.
- Performance review: facade performs no per-window or per-dimension query; VelocityReader owns one bounded read.
- STOP: facade must source any financial value from HotStateAggregator, or authorization/readiness order changes.

### M5-05F — Conformance and reconciliation certification

- Objective: prove exact financial parity, refund-time placement, coverage behavior, query bounds, and concurrency safety for the three windows.
- Exact writable test files: new test/event_sales/analytics/m5_05_velocity_reconciliation_test.exs; new test/event_sales/analytics/m5_05_velocity_concurrency_test.exs; new test/event_sales/analytics/m5_05_velocity_raw_boundary_test.exs; new test/event_sales/analytics/m5_05_velocity_query_plan_test.exs.
- Exact evidence file: only in its separately authorized certification task, docs/evidence/m5-05-deterministic-sales-velocity-certification.md.
- Dependencies: M5-05D and M5-05E.
- Invariants: sale Gross stays at sale time; refund stays at refund time; exact replay counts once; over-refund leaves negative Net; current zero requires current coverage; stale/missing fails closed; raw tables are absent from successful read SQL.
- Performance review: selective EXPLAIN for projection/fact paths; static boundary, telemetry, and row-count-independent query-count proof; no new index without before-EXPLAIN evidence.
- STOP: parity fails, a raw financial read appears, or any race can produce mixed projection generations.

### M5-05G — Load evidence and cache decision gate

- Objective: measure the real three-window reader and decide whether existing PostgreSQL projections meet expected management load.
- Exact writable test/evidence files: separately authorized test/event_sales/analytics/m5_05_velocity_load_evidence_test.exs and docs/evidence/m5-05-deterministic-sales-velocity-certification.md.
- Dependencies: M5-05F passes.
- Invariants: use project-isolated load infrastructure; report concurrency, p50/p95/p99, query count, DB pool/queue, edge cardinality, and event/currency fixture bounds; do not extrapolate beyond the tested cohort.
- Performance review: keep CACHE=NO_CHANGE and REDIS=NO_CHANGE unless measured M5-05 evidence demonstrates a need. Any mirror proposal must separately define key, value, TTL, semantic version, coverage identity, readiness representation, invalidation, stampede protection, PubSub relation, and failure behavior before implementation authority.
- STOP: performance evidence is missing or cache/Redis/PubSub behavior is proposed without measured need and separate approval.

No M5-05 phase authorizes UI changes, new resources, migrations, indexes, workers, schedulers, cache behavior, Redis, or new PubSub behavior.

## TOON prompts for later authorized phases

These prompts do not authorize execution. Do not run them while the owner decisions remain unresolved.

### Scaffolding TOON — M5-05B pure contract

| Field | Content |
|---|---|
| Task | Create the approved M5-05 time-window and pure velocity-rule foundation. |
| Objective | Give later readers fixed exact recent windows and deterministic Decimal per-hour rates/trends without adding persistence. |
| Output | Modify lib/event_sales/analytics/time_rules.ex; create lib/event_sales/analytics/velocity_rules.ex; update test/event_sales/analytics/time_rules_test.exs; create test/event_sales/analytics/velocity_rules_test.exs. |
| Note | Begin only after the product owner records the primary metric, monetary-rate inclusion, percentage and negative-baseline behavior, and display precision. Support only 15m, 30m, 60m. Capture now once. Use half-open UTC periods and adjacent equal-duration comparison periods. Keep canonical rates Decimal and unrounded. Do not touch resources, migrations, indexes, raw sales tables, cache, TTL, Redis, PubSub, Oban, or UI. Stop if the approved decisions conflict with M5-02/M5-03/M5-04 semantics. |

### M5-05C micro-prompt — shared projection kernel

| Field | Content |
|---|---|
| Task | Extract event-level period projection composition from PeriodComparisonReader. |
| Objective | Let the existing comparison reader and a future multi-window velocity reader share the same bucket, edge, coverage, and metadata rules. |
| Output | Create lib/event_sales/analytics/projection_period_reader.ex; modify lib/event_sales/analytics/period_comparison_reader.ex; add test/event_sales/analytics/projection_period_reader_test.exs; run test/event_sales/analytics/period_comparison_reader_test.exs, test/event_sales/analytics/period_comparison_reader_correctness_test.exs, test/event_sales/analytics/period_comparison_reader_policy_test.exs, test/event_sales/analytics/period_comparison_reader_isolation_test.exs, test/event_sales/analytics/period_comparison_reader_query_plan_test.exs, test/event_sales/analytics/period_comparison_reader_concurrency_test.exs, test/event_sales/analytics/period_comparison_reader_matrix_test.exs, test/event_sales/analytics/period_read_plan_test.exs, the M5-04 regression files listed above, test/event_sales/analytics/period_coverage_gap_test.exs, and test/event_sales/analytics/period_coverage_closure_test.exs. |
| Note | Preserve the existing public comparison response and RR/EventSnapshotRefreshFence behavior. Keep dimension-family queries in PeriodComparisonReader. Reuse PeriodReadPlan. Do not add raw source queries, new index, resource, cache, TTL, Redis, PubSub, worker, or UI. Stop if extraction changes M5-04 behavior or requires a second projection history. |

### M5-05D micro-prompt — VelocityReader

| Field | Content |
|---|---|
| Task | Add a projection-only VelocityReader for the fixed three-window set. |
| Objective | Return current and immediately preceding equivalent rates for 15m, 30m, and 60m from one captured now and one coherent projection snapshot. |
| Output | Create lib/event_sales/analytics/velocity_reader.ex; add test/event_sales/analytics/velocity_reader_test.exs, test/event_sales/analytics/velocity_reader_policy_test.exs, and test/event_sales/analytics/velocity_reader_query_plan_test.exs. |
| Note | Build each operand with existing PeriodReadPlan, label the three plans so edges cannot collide, and send the combined plans through ProjectionPeriodReader in one fenced RR transaction. Use one event and one requested currency. Fail closed on missing/stale coverage. No raw sales/refund fallback, no persisted velocity resource, no N+1, no cache, TTL, Redis, PubSub, worker, or UI. Stop if six operands cannot share one coherent transaction. |

### M5-05E micro-prompt — event-scoped facade and redaction

| Field | Content |
|---|---|
| Task | Add an event-scoped facade method that delegates to VelocityReader. |
| Objective | Expose the read through the existing analytics boundary while retaining event authorization and revenue visibility. |
| Output | Modify lib/event_sales/analytics/event_scoped_dashboard.ex; add test/event_sales/analytics/event_scoped_dashboard_velocity_test.exs; retain the M5-05D reader policy test. |
| Note | Do not route velocity through HotStateAggregator or DashboardCache. Preserve identity validation, authorization, readiness, projection read, then redaction. Hide every monetary operand, rate, delta, percentage, and related state when revenue is not visible. Return no PII or source payloads. No UI, cache, TTL, Redis, PubSub, worker, or index. |

### M5-05F micro-prompt — conformance evidence

| Field | Content |
|---|---|
| Task | Certify projection parity, refund placement, raw-read boundary, query bounds, and coherent races. |
| Objective | Prove the implementation follows existing M5 financial and period authority for realistic velocity windows. |
| Output | Add the focused M5-05 reconciliation, concurrency, raw-boundary, and query-plan tests named in this plan. Write only the separately authorized docs/evidence/m5-05-deterministic-sales-velocity-certification.md in that later task. |
| Note | Include late refund during read, exact replay, missing/current-zero/stale coverage, mixed currency isolation, negative Net, cross-event isolation, SQL telemetry, constant query count, and selective EXPLAIN. No sleeps. Do not add an index without before-EXPLAIN evidence. Stop on raw source financial reads or mixed generations. |

### M5-05G micro-prompt — measured scale gate

| Field | Content |
|---|---|
| Task | Measure the three-window reader under bounded concurrency and decide whether acceleration is needed. |
| Objective | Base cache or Redis decisions on M5-05 read and pool evidence. |
| Output | Add the separately authorized test/event_sales/analytics/m5_05_velocity_load_evidence_test.exs and update the M5-05 certification evidence file. |
| Note | Report fixture bounds, window/edge counts, query count, p50/p95/p99, queue/pool use, and concurrency. Preserve NO_CHANGE for cache and Redis unless measured need and a separate design approval exist. If proposing a mirror, define key, value, TTL, semantic version, coverage identity, readiness, invalidation, stampede protection, PubSub relation, and failure/fallback first. Never fall back to raw tables. |

## Owner decisions required before implementation

1. Primary velocity numerator: confirm Gross ticket quantity per hour as primary, or choose a different primary.
2. Quantity and refund-rate presentation: confirm whether Net and Refund quantity rates appear beside Gross, and whether quantity can ever combine across currency partitions.
3. Monetary velocity: decide whether Gross, Refund, and Net value rates are included as supporting measures when revenue visibility permits.
4. Percentage trend: approve behavior for zero and negative previous rates, especially negative Net baselines. Confirm any new explicit comparison state before extending MetricRules.
5. Display: choose displayed decimal precision and rounding mode. Canonical rates remain unrounded Decimal values.
6. Public facade result shape: confirm that the proposed event-scoped facade method returns all three windows together. This plan recommends one captured now and one coherent transaction for the full set.

Until these decisions are recorded in authoritative product/Linear scope:

~~~text
IMPLEMENTATION_READY=NO
M5_05_IMPLEMENTATION_AUTHORIZED=NO
~~~

## Source authority reviewed

- docs/path-1/path-1-phase-breakdown.md
- docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md
- docs/roadmap/EVENTSALES_LIVE_SALES_PROGRAMME.md
- docs/development/pre-m5-02-metrics-foundation.plan.md
- docs/development/m5-04-period-comparisons.plan.md
- docs/evidence/m5-02-ticket-product-variation-aggregates-certification.md
- docs/evidence/m5-03-revenue-refund-dimensional-aggregates-certification.md
- docs/evidence/m5-04-period-comparisons-certification.md
- lib/event_sales/analytics/time_rules.ex
- lib/event_sales/analytics/period_read_plan.ex
- lib/event_sales/analytics/period_comparison_reader.ex
- lib/event_sales/analytics/resources/event_period_aggregate_snapshot.ex
- lib/event_sales/analytics/resources/analytics_contribution_fact.ex
- lib/event_sales/analytics/hot_state_aggregator.ex
- lib/event_sales/analytics/dashboard_cache.ex
- lib/event_sales/analytics/aggregators/event_aggregator.ex
- lib/event_sales/analytics/metric_rules.ex
- Focused tests and query/concurrency evidence listed above.

## Audit self-review

| Question | Result |
|---|---|
| Did this plan invent velocity semantics? | NO. Recommendations are labeled and unresolved owner choices block implementation. |
| Did it confuse Gross and Net? | NO. Both remain distinct, with separate refund rates and negative Net preserved. |
| Did it move refunds into sale-effective periods? | NO. Refunds stay in refund-effective windows. |
| Did it use legacy HotState financial semantics as authority? | NO. |
| Did it create a second period-planning algorithm? | NO. It reuses PeriodReadPlan. |
| Did it create a new durable velocity resource without necessity? | NO. Rates and trends remain derived. |
| Did it allow raw source fallback? | NO. Missing coverage fails closed. |
| Did it merge currencies? | NO. Each read is currency-scoped; no FX or cross-currency money sum. |
| Did it persist a derived rate unnecessarily? | NO. |
| Did it add cache, Redis, or PubSub without evidence? | NO. All remain NO_CHANGE. |
| Did it overstate scale certification? | NO. M5-04 measurements are not presented as M5-05 evidence. |
| Did it authorize implementation with unresolved owner decisions? | NO. IMPLEMENTATION_READY=NO. |
