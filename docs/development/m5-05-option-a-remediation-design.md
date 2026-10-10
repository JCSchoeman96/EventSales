# M5-05D3 split-cause design and D4 admission

~~~text
D3_APPROACH=SPLIT_CAUSE
D3_STATUS=COMPLETE_DESIGN_APPROVED
D3_OWNER_REVIEW=PASS
D3_Q1_APPROVED=YES
D3_Q2_APPROVED=YES
D3_Q3_APPROVED=YES
D3_Q4_APPROVED=YES
D4_NAME=C_TOPOLOGY_ATTRIBUTION_REPLAY
D4_AUTHORIZED=YES
D4_STATUS=AUTHORIZED_NOT_STARTED
BASE_SHA=84cf6af8bca1c5af2a99ddad8c570bf14870bf4d
BASE_TREE=d82a473db35722a7253108211a1004592c7c04bc
PR_317_REVIEWED_HEAD=3cb089423acee459e211e5fa781b94658e970cae
PR_317_REVIEWED_TREE=d82a473db35722a7253108211a1004592c7c04bc
PR_317_MERGE_SHA=84cf6af8bca1c5af2a99ddad8c570bf14870bf4d
PR_317_MERGE_TREE=d82a473db35722a7253108211a1004592c7c04bc
PR_317_MERGE_TREE_EQUALS_REVIEWED_TREE=YES
PR_317_MERGE_SIGNATURE=VALID
PR_317_POST_MERGE_VERIFY=PASS
D2_CLOSEOUT_PROVENANCE=PR_316
D1_RERUN=NO
D2_EVIDENCE_CHANGED=NO
M5_05D4_EXECUTED=NO
M5_05_IMPLEMENTATION_AUTHORIZED=M5_05D4_DIAGNOSTIC_ONLY
REMEDIATION_SELECTED=NO
~~~

## 1. Authority and scope

This document records the owner-approved M5-05D3 architectural design after D2 recorded `OPTION_A=NO_GO`. It analyzes planner policy (P), connection and topology contention (C), cold query and data shape (Q), finer durable buckets (B), and earlier hot/warm acceleration (H). Owner review accepted the C experiment and Q1–Q4 decisions.

PR #317 closed D3 as `COMPLETE_DESIGN_APPROVED`. A separate D4 plan freezes one diagnostic experiment and authorizes that experiment only after this admission merges. It does not authorize remediation, production access, or changes to application code, configuration, schema, indexes, pools, PgBouncer, cache, Redis, reader, runtime, or infrastructure. D1 evidence remains frozen. D5 and E/F/G remain unauthorized. Nothing here changes D1's valid NO_GO under its then-frozen criteria.

The reviewed base is `363247e697bab361c31bc6b9d94e457fb7b25f35` with tree `ed05c89dd056931bb9d70e8008764772285056fe`. PR #316 closed D2. Its merged tree equals the reviewed head tree, and GitHub reports its merge signature as valid.

Evidence labels used below:

- **Proven** means directly recorded in canonical evidence or current repository authority.
- **Inferred** means a conclusion from those facts, with the reasoning stated.
- **Unknown** means the repository does not establish the claim.
- **Proposed** means a design choice for owner review, not an authorized change.

## 2. Frozen D1/D2 facts

D1 is valid and immutable. D2 certified that evidence and recorded `OPTION_A=NO_GO`.

| Frozen fact | Value |
|---|---:|
| `MEASUREMENT_VALID` | `YES` |
| `QUERY_SHAPE` | `PASS` |
| `INDEX_SELECTIVITY` | `FAIL` |
| Normal-density sequential scans | `3`, at unaligned 15m, 30m, and 60m |
| `NORMAL_C50_GATE` | `PASS` |
| `HIGH_DENSITY_C50_GATE` | `FAIL` |
| Dense 60m C50 end-to-end p99 | `183787 us` |
| Dense 60m C50 Repo-query p99 | `37531 us` |
| Dense 60m C50 pool-checkout p99 | `146488 us` |
| Frozen high-density p99 limit | `150000 us` |
| `RAW_SOURCE_READS` | `0` |
| `POOL_TIMEOUTS` | `0` |
| `OPTION_A` | `NO_GO` |

High-density plans already use `analytics_contribution_facts_event_currency_effective_at_idx`. D1's three failing plan rows are normal-density rows; normal-density C50 latency passed. The high-density 60m unaligned row exceeded its frozen p99 limit. No D1 measurement is revised here.

## 3. Claims supported by evidence

- **Proven:** The measured query shape passed, and the measured runs had zero pool timeouts and zero raw-source reads.
- **Proven:** The three normal-density plans selected sequential scans. D1 therefore failed its predeclared index-selectivity gate.
- **Proven:** Normal-density C50 latency passed despite those scans.
- **Proven:** In the local dense 60m C50 run, checkout p99 (146488 us) exceeded Repo-query p99 (37531 us) and was the dominant observed component of the 183787 us end-to-end p99.
- **Proven:** The high-density edge plan used the existing event/currency/effective-time index. The 60m case had more measured query time than the 15m and 30m cases.
- **Inferred:** The checkout result makes connection/topology isolation the highest-value next diagnostic. The measured checkout component is larger than SQL time in the failed cohort, while the repository has not established the production pool path or connection budget.
- **Proven:** The intended deployment architecture documents `DATABASE_URL` as PgBouncer session pooling and a separate direct path for session-sensitive work. That is repository design authority, not proof of the live Railway connection path.

## 4. Claims explicitly not supported

D1/D2 do not prove that:

- A sequential scan is a latency or user-visible defect for a small relation.
- The existing index is defective, needs replacement, or should be selected for every relation size.
- `POOL_SIZE=10`, Ecto queue settings, or any timeout is wrong.
- PgBouncer is active in production or would improve this workload.
- PostgreSQL lacks capacity, or that adding database connections would improve total throughput.
- Dense 60m SQL needs a query rewrite, a new index, or finer durable buckets.
- Redis, ETS, Cachex, or a GenServer is needed before M5-08.
- The reader is safe for 100k concurrent users.

## 5. Problem decomposition

| Track | D1 signal | Question to resolve | D3 stance |
|---|---|---|---|
| P, planner policy | Three normal-density Seq Scans; normal C50 passes | Is named-index selection a valid invariant across relation sizes? | Review acceptance policy; do not reinterpret D1. |
| C, connection/topology | Checkout dominates the failed local dense 60m C50 p99 | Does this attribution persist through a verified representative runtime topology and connection budget? | Recommend one topology-attribution experiment. |
| Q, cold query/data shape | Dense 60m query time is higher; high-density plan uses existing index | Is there a bounded SQL cost after connection wait is isolated? | Measure separately before proposing SQL changes. |
| B, finer buckets | Current reader combines durable snapshot interiors and contribution-fact edges | Would smaller durable buckets lower edge work enough to justify durable write and lifecycle costs? | No evidence currently justifies changing granularity. |
| H, earlier hot/warm acceleration | Later M5-08 expects process-local hot and Redis warm state | Is a correct cold reader insufficient after C is understood? | Keep M5-08 later unless evidence and a separate admission justify moving it. |

## 6. Domain/resource map

| Domain/resource | Responsibility and ownership | Layer, source of truth, concurrency role, failure mode | D3 boundary proposal |
|---|---|---|---|
| `TimeRules` | Pure sale/refund clocks and period semantics; no storage writes | Rule layer; semantics are canonical inputs to every read. Incorrect clocks misattribute contributions. | None. Preserve sale and refund clocks independently. |
| `PeriodReadPlan` | Derives fixed-bucket and bounded edge fragments | Read planning; no durable truth or connection ownership. Bad bounds can omit or duplicate time ranges. | None. Keep deterministic windows and bounded fragments. |
| `ProjectionPeriodReader` | Reads event snapshots and edge contribution facts | Cold Postgres reader; Ecto calls run through `Repo`. Checkout wait and SQL execution are distinct. Readiness/coverage failure must remain fail-closed. | None. No transaction ownership change. |
| `EventAggregateSnapshot` | Durable event-level aggregate projection | Postgres durable truth for its certified snapshot facts. Refresh and reader races can expose stale or mixed generations without existing coherence rules. | None. No second financial truth. |
| `AnalyticsContributionFact` | Durable exact sale/refund contributions used for partial edges | Postgres durable truth for edge facts, isolated by event and currency. Stale or duplicate facts risk incorrect totals. | Keep current identity and exact currency/event predicates. No index or bucket change authorized. |
| `EventSnapshotRefreshFence` | Provides caller transaction preparation and refresh coordination | Postgres transaction/lock coordination. Incorrect ordering can admit incoherent snapshots or race with refresh. | Preserve caller-owned transaction preparation before projection SQL. |
| `Repo` / DBConnection / Ecto pool | Owns checked-out database connections and queues application callers | Connection boundary; local pool configuration records size 10. Saturation queues callers before SQL, and can cause checkout latency/timeouts. | Measure queue, checkout, and query independently. No pool-setting change. |
| PgBouncer / deployment boundary | Intended runtime route is session pooling; direct URL is for migrations and session-sensitive work | Shared connection boundary. Transaction pooling has different session and prepared-statement semantics. Actual live topology and connection budget are unverified. | No topology/config change. D4 must use a verified representative non-production route. |
| Future `VelocityReader` | Proposed M5-05 reader integration, not implemented/authorized | Would call accepted canonical projection behavior; durability remains Postgres. A new path could diverge from accepted semantics. | No reader work before separate admission. |
| Future M5-08 hot/warm cache layers | Roadmap expectation: process-local/GenServer/ETS hot, Redis warm, Postgres cold | Cache is derived state; stale/incoherent cache can hide readiness or multiply misses across nodes. | Remain later. A cache must accelerate an accepted cold reader. |

## 7. Lifecycle/state model

D3 follows this lifecycle:

```text
BLOCKED_PENDING_SEPARATE_ADMISSION
  → AUTHORIZED_DESIGN
  → EVIDENCE_SYNTHESIS
  → CANDIDATES_COMPARED
  → NEXT_EXPERIMENT_RECOMMENDED
  → DESIGN_IN_REVIEW
  → COMPLETE_DESIGN_APPROVED
```

PR #317 records owner acceptance: `M5_05D3_STATUS=COMPLETE_DESIGN_APPROVED`. The D4 plan records the separately admitted experiment. D4 remains `AUTHORIZED_NOT_STARTED`; E, F, and G remain blocked. Implementation authorization is limited to the D4 diagnostic experiment.

## 8. Track P: planner and acceptance policy

D1 made index selection a mandatory gate, so the three normal-density sequential scans correctly caused the historical `INDEX_SELECTIVITY=FAIL`. That result remains unchanged. The evidence also says normal-density C50 latency passed and explicitly does not establish that the index failed or caused latency failure.

PostgreSQL may choose a sequential scan when scanning a small relation costs less than index lookup plus heap access. Requiring the index name for every table size can reject a valid plan. Conversely, latency alone can hide unbounded work when fixture size is small.

**Accepted Q2 policy:** Future plan acceptance uses `BOUNDED_APPROPRIATE_PLANNER_BEHAVIOR`, not a named index mandatory at all relation sizes. Judge bounded query shape and examined rows/buffers under representative cardinality, latency, and absence of pathological full-source scans. Require an index-backed plan when selectivity and measured plan cost make it materially appropriate. Do not force a planner choice. This does not retroactively pass D1 or change a frozen threshold.

## 9. Track C: connection and topology contention

The failed local dense 60m C50 p99 decomposes into 146488 us pool checkout and 37531 us Repo-query time, against 183787 us end-to-end. This directly supports checkout pressure as the dominant observed component in that local run. It does not identify why checkout was slow or prove the same share in production.

The repository sets runtime `POOL_SIZE` to 10 by default. The deployment design docs select PgBouncer session pooling for normal runtime traffic and a direct URL for migrations/session-sensitive tasks. The repository also records that live Railway PgBouncer use is unverified. No authoritative runtime database connection budget was found.

```text
TOPOLOGY_DOC_CONFLICT=YES
ARCHITECTURE_TARGET=DATABASE_URL through PgBouncer session pooling
HISTORICAL_DEPLOYMENT_STATE=PgBouncer not deployed for Slice 24; DATABASE_URL and DIRECT_DATABASE_URL used direct PostgreSQL
ACTUAL_CURRENT_PRODUCTION_RUNTIME_ROUTE=UNVERIFIED
ACTUAL_CURRENT_PRODUCTION_PGBOUNCER_MODE=UNVERIFIED
ACTUAL_CURRENT_DB_CONNECTION_BUDGET=UNVERIFIED
```

These statements describe different states. Neither establishes the current runtime route. Do not resolve the conflict by document precedence, assume PgBouncer is live, or infer a connection budget. D4 execution must prove the route from safe read-only evidence before measuring.

**Proposed next diagnostic:** Replay the frozen reader workload through one verified, non-production representative runtime topology. Hold velocity semantics, window geometry, fixture cardinality, sample count, caller cohorts, SQL, indexes, and threshold history fixed. Keep pool configuration fixed within each explicitly defined topology case; do not sweep pool sizes or queue settings. Report caller wait, application connection checkout, PgBouncer/proxy wait when present, PostgreSQL execution, and end-to-end latency as separate distributions. Do not compare a direct route with an invented pooler setup and call it production evidence. If the actual target topology/budget cannot be verified, stop the experiment as insufficient evidence.

## 10. Track Q: cold query and data-shape cost

`ProjectionPeriodReader` obtains fixed-period `EventAggregateSnapshot` rows and aggregates edge ranges from `AnalyticsContributionFact` through a bounded `UNNEST` query. The fact relation has the existing `(event_id, currency, effective_at)` index. D1's high-density plans used that index. D1 also reports zero extra query-shape violations and zero raw-source reads.

Dense 60m has higher edge work and query time than the shorter windows, so larger dense edge cost remains plausible. The evidence does not show whether that SQL cost independently violates an accepted gate after checkout pressure is removed. M5-04 query-plan evidence separately documents bounded unnest edge reads, coverage planner reads, and the selective fact index. Coverage planner/materializer work is a separate path from this reader's measured edge SQL and should not be conflated with it.

**Finding:** Cold SQL remediation is not yet established. Preserve current SQL and index. The selected C experiment must retain the SQL timing measure. Only a material, repeatable cold-query problem after checkout is separated would support proposing a Q experiment.

## 11. Track B: finer durable projection buckets

Smaller durable buckets might reduce edge facts read for a dense 60m request, but the repository evidence does not establish that edge SQL is the dominant residual cost. Finer buckets would change canonical durable representation and require an explicit semantic and lifecycle design.

Any later B proposal must account for:

- **Durability and truth:** Bucket snapshots remain derived from contribution facts; they must not become a second financial truth.
- **Write amplification and refresh cost:** More bucket rows and boundary updates increase writes and refresh work.
- **Coverage and reconciliation:** Coverage identities, readiness, gap detection, and reconciliation must describe the new grain exactly.
- **Invalidation and historical backfill:** Every affected old/new bucket must be invalidated across sale and refund effective clocks; historical corrections must replay safely.
- **Concurrency:** Readers and writers must retain coherent transaction/MVCC behavior and resist stale-generation races.
- **Storage and future reuse:** Storage grows with finer granularity and event history. Reuse for velocity windows is plausible but unmeasured.

No bucket size, schema, migration, or implementation is selected.

## 12. Track H: earlier M5-08 hot/warm acceleration

The roadmap's later model places hot state in process-local/GenServer/ETS, warm state in Redis, and cold state in Postgres. D1 has no cache evidence. A cache can reduce repeated calls only after a cold read is correct and acceptable; otherwise it can hide a slow or incorrect canonical path.

No evidence justifies advancing M5-08 now. If later evidence supports earlier acceleration, a separate owner decision must define cache keys, readiness/coverage identity, invalidation, staleness behavior, multi-node coherence, miss concurrency, and fallback behavior. This document implements none of them.

## 13. Candidate comparison matrix

| Candidate | Supporting evidence / evidence against | Unknowns and diagnostic value | Complexity, reversibility, performance upside | Integrity, concurrency, operations, isolation, durable truth | 100k scaling fields |
|---|---|---|---|---|---|
| **P: revise future planner/index acceptance** | Supports: three Seq Scans fail the named-index gate while normal C50 passes. Against: high-density case still has a latency failure, so P alone cannot close NO_GO. | Unknown: relation-size/cost point where each plan is appropriate. High value for avoiding false plan failures, but does not isolate the high-density p99. | Low design complexity; acceptance-only change is reversible. It may stop rejecting appropriate scans, with no guaranteed speedup. | Low data-integrity/concurrency/operational risk. Event/currency isolation is unchanged. Does not alter durable truth or require production-like infrastructure. | `WHAT_LAYER=cold`; `SAFE_AT_100K_USERS=NOT_CERTIFIED`; `DB_CALLS_PER_READ=unchanged`; `CONNECTION_AMPLIFICATION=unchanged`; `REDIS_REPRESENTATION=none`; `STREAMABLE_OR_BOUNDED=existing bounded read`; `CACHE_STAMPEDE_RISK=none`; `HORIZONTAL_NODE_BEHAVIOR=unchanged`. |
| **C: topology-attribution experiment** | Supports: checkout p99 is the largest measured component of the failing local run. Against: topology and connection budget differ or remain unknown versus production. | Unknown: whether attribution holds through the verified runtime route and what share belongs to application queue, pooler wait, or database time. Highest diagnostic value for current failed p99. | Experiment design is moderate; result is reversible because no runtime setting is changed. It may identify the responsible waiting layer; no performance gain is assumed. Requires isolated production-representative infrastructure. | No durable data change. Concurrency risk is limited to isolated replay; prevent load on DEV/TEST or production. Tenant/event/currency identity stays fixed. Operational risk if the target topology is misidentified. | `WHAT_LAYER=cold`; `SAFE_AT_100K_USERS=NOT_CERTIFIED`; `DB_CALLS_PER_READ=existing fixed read count`; `CONNECTION_AMPLIFICATION=measured per caller/topology`; `REDIS_REPRESENTATION=none`; `STREAMABLE_OR_BOUNDED=existing bounded read`; `CACHE_STAMPEDE_RISK=none`; `HORIZONTAL_NODE_BEHAVIOR=not measured by one-topology replay`. |
| **Q: cold SQL/data-shape experiment** | Supports: dense 60m query cost is higher. Against: pool checkout dominates the failed local p99; high-density plan uses the existing index and query shape passes. | Unknown: residual SQL cost after checkout is controlled. Diagnostic value is lower until C is isolated. | Moderate investigation; query-only experiments can be reversible. Potential upside is bounded edge execution, not established. | SQL changes risk missed/double-counted edges or currency/event leakage. Concurrency/operations risk depends on query. No durable truth change if read-only. Requires representative isolated data/cardinality. | `WHAT_LAYER=cold`; `SAFE_AT_100K_USERS=NOT_CERTIFIED`; `DB_CALLS_PER_READ=currently one edge aggregate when edge fragments exist`; `CONNECTION_AMPLIFICATION=one checkout per caller path, measure`; `REDIS_REPRESENTATION=none`; `STREAMABLE_OR_BOUNDED=bounded by plan edges, fact rows may vary`; `CACHE_STAMPEDE_RISK=none`; `HORIZONTAL_NODE_BEHAVIOR=database contention shared across nodes`. |
| **B: finer durable buckets** | Supports: finer boundaries may shorten dense edge ranges. Against: no evidence that cold SQL is the cause after checkout; current durable reader already combines fixed snapshots and bounded edges. | Unknown: row growth, reduced edge cardinality, refresh cost, coverage/reconciliation interactions, and future reuse. Low immediate diagnostic value because it changes the data model. | High schema/lifecycle complexity; reversible only with migration/backfill and careful compatibility. Upside is speculative until measured. | High integrity and read/write race risk; more invalidation, write amplification, backfill, and operational burden. Event/currency isolation must be encoded at every grain. Alters durable projection truth representation, not financial source truth. Requires isolated migration/performance infrastructure. | `WHAT_LAYER=cold`; `SAFE_AT_100K_USERS=NOT_CERTIFIED`; `DB_CALLS_PER_READ=unknown, likely same logical reads unless path changes`; `CONNECTION_AMPLIFICATION=not established`; `REDIS_REPRESENTATION=none`; `STREAMABLE_OR_BOUNDED=durable rows grow with finer grain`; `CACHE_STAMPEDE_RISK=none`; `HORIZONTAL_NODE_BEHAVIOR=shared Postgres reads/writes and invalidation`. |
| **H: advance hot/warm acceleration** | Supports: repeated reads may benefit from hot/warm layers in the later M5-08 design. Against: D1 has no cache evidence and cold-reader acceptance is unresolved. | Unknown: hit rate, freshness, invalidation fanout, cross-node coherence, and miss behavior. Low value for diagnosing cold SQL or checkout unless misses are separately measured. | Moderate-to-high distributed-state complexity; reversible in principle, but cache state/invalidation bugs can persist operationally. Upside depends on hit rate. | Staleness can conceal readiness or violate currency/event isolation. Thundering-herd/cache-stampede and cross-node incoherence risks. Adds operational dependencies and does not change Postgres truth only if strictly derived. Requires production-like multi-node/cache testing. | `WHAT_LAYER=hot|warm`; `SAFE_AT_100K_USERS=NOT_CERTIFIED`; `DB_CALLS_PER_READ=0 on a hit, existing cold path on a miss`; `CONNECTION_AMPLIFICATION=miss-cohort dependent`; `REDIS_REPRESENTATION=not designed in D3`; `STREAMABLE_OR_BOUNDED=bounded only if cache payload and miss query remain bounded`; `CACHE_STAMPEDE_RISK=present`; `HORIZONTAL_NODE_BEHAVIOR=process-local hot state differs by node, Redis warm state is shared`. |

No arbitrary numeric candidate scores are used. The qualitative ordering favors C because it tests the largest measured component without changing a planner, SQL, durable representation, or cache behavior. P remains a separate acceptance-policy decision, not the selected performance experiment.

## 14. Performance and scaling review

The D1 benchmark does not certify 100k concurrency. All candidates have `SAFE_AT_100K_USERS=NOT_CERTIFIED`. Current cold reads use a fixed set of snapshot reads and, when edges exist, one bounded aggregate query rather than a query per edge. Actual connection amplification is the number of concurrent callers reaching Repo, not the requested caller cohort alone. D1 measured checkout separately and must retain that separation.

| Candidate | Layer | DB calls/read | Connection amplification | Redis representation | Bounded/streamable | Stampede risk | Horizontal nodes |
|---|---|---|---|---|---|---|---|
| P | Cold | Existing reader calls, unchanged | Existing Repo checkout behavior | None | Existing bounded plan | None from P | Shared DB contention unchanged |
| C | Cold | Existing reader calls, fixed during experiment | Measure simultaneous callers and pooler/backend allocation separately | None | Existing bounded read | None from C | Experiment must state node count; no multi-node claim unless modeled |
| Q | Cold | Preserve and record query count; no N+1 | Measure separately from SQL time | None | Bound edge fragments and examined rows | None from Q | DB remains shared across nodes |
| B | Cold | Not established until a design exists | Not established | None | More durable rows; bounds require proof | None from B | Shared Postgres writes, reads, and invalidation |
| H | Hot/warm over cold | Zero DB calls on a valid hit; existing calls on miss | Miss bursts can amplify checkouts | Not designed or authorized | Cache payload and fallback must be bounded | Present on synchronized miss/expiry | ETS/GenServer is node-local; Redis is shared |

The eventual architecture may include ETS/GenServer hot state, Redis warm state, Postgres cold truth, Phoenix PubSub, asynchronous Oban, and PgBouncer session pooling. This review does not move any of them into M5-05. Session-pool documentation does not establish transaction-pool compatibility. D3 cannot certify production topology, 100k callers, or horizontal-scale behavior.

## 15. Security, isolation, and integrity review

Any future experiment must use synthetic data and project-isolated performance infrastructure. It must not contact production, Railway, DEV/TEST databases, or shared Redis. The workload must preserve event and currency predicates, exact deterministic windows, Decimal semantics, `ANALYTICS_READY` and coverage fail-closed behavior, and zero raw WooCommerce financial reads.

The reader continues to use a caller-prepared coherent transaction. `ProjectionPeriodReader` does not own a transaction. Postgres remains durable truth. Sale and refund clocks remain independent. No candidate may introduce float arithmetic, polling, cross-currency aggregation, a second financial truth, or unbounded in-memory fact loading.

No D3 mitigation is authorized. Candidate-specific controls belong in a later experiment design and require owner admission.

## 16. Recommended next experiment

```text
SELECTED_NEXT_EXPERIMENT=C_TOPOLOGY_ATTRIBUTION_REPLAY
```

Replay the frozen deterministic reader workload on an isolated non-production database/runtime that matches a verified current runtime connection path and verified connection budget. Hold velocity semantics, window geometry, fixture cardinality, sample count, caller cohorts, SQL, indexes, and threshold history fixed. Keep the verified application pool configuration fixed; do not sweep pool sizes or queue settings. Collect separate distributions for caller delay, application queue/checkout, PgBouncer/proxy evidence where present, PostgreSQL query execution, end-to-end latency, pool timeouts, errors, and query shape. The D4 plan admits this diagnostic experiment. It is not a D1 rerun and must not write D1 evidence.

`WHY_THIS_FIRST=` It targets the largest observed component of the failed local C50 latency without changing pool settings, SQL, indexes, projection grain, or cache architecture. It also tests whether local checkout attribution survives a representative topology.

`WHAT_IT_FALSIFIES=` That the failing C50 latency can be meaningfully attributed without modelling connection topology separately. The experiment tests whether caller wait, application checkout, proxy/PgBouncer effects, and SQL execution can be separated on a verified topology.

`ADVANCE_CONDITION=` Topology-aware evidence demonstrates reproducible attribution and identifies the dominant constrained layer, while correctness and query-shape gates pass. Advancing permits only a later owner-reviewed remediation design; it authorizes no change.

`REJECT_CONDITION=` The experiment cannot distinguish application checkout, proxy/topology effects, and SQL execution sufficiently to support a remediation choice, or the verified topology/budget is unavailable, or correctness/query-shape gates fail. No remediation is selected from an inconclusive result.

`WHAT_RESULT_WOULD_REJECT_IT=` The experiment is rejected as inconclusive if the actual connection path or connection budget cannot be verified, topology differs from the documented target path, instrumentation cannot separate caller wait, application checkout, proxy wait, and SQL execution, or correctness/query-shape gates fail. It is rejected as support for a checkout-focused remediation if checkout is not a material component in the representative run.

`WHAT_RESULT_WOULD_ADVANCE_IT=` D5 may consider a later C remediation investigation if the valid D4 run shows checkout or an observable connection-topology wait as a material component, correctness and query-shape gates pass, and the evidence records the verified topology and budget. Any further experiment or change requires separate admission.

The experiment recommendation alone did not authorize D4. PR #317 accepted the design and the separate D4 plan records the admission. D4 remains unrun until its execution preflight verifies a representative isolated non-production route. If that route or its connection budget cannot be verified safely, stop with `INSUFFICIENT_EVIDENCE`.

## 17. Accepted D4 criteria

The D4 plan freezes the accepted experiment criteria. They do not alter D1's historical gates.

### A. Correctness gates

Always require the same deterministic windows, existing Decimal semantics, strict event/currency isolation, and independent sale/refund clocks. Require `ANALYTICS_READY` and coverage failure to remain fail-closed. Require zero raw WooCommerce financial scans, no second financial truth, no stale projection acceptance, no read errors, and no pool timeouts. Preserve caller-owned coherent transaction preparation.

### B. Query-shape gates

Require the existing bounded read shape, no N+1, no unbounded in-memory fact loading, no extra raw-source reads, and bounded examined rows/buffers at representative fixture cardinalities. `INDEX_NAME_MUST_APPEAR_AT_ALL_RELATION_SIZES=NO`. Require an index-backed plan when the plan is selective and materially beneficial; permit a sequential scan when planner cost is appropriate for measured relation size and bounded work. Query shape, examined work, and latency remain separate checks. This accepted policy does not pass D1's frozen `INDEX_SELECTIVITY=FAIL`.

### C. Performance gates

Keep the already frozen M5-05 product targets where they apply: normal-density C50 p99 at most 100 ms and high-density C50 p99 at most 150 ms. Require zero pool timeouts and zero read errors. No D3 proposal changes these thresholds. A separate D4 diagnostic may report distributions by timing layer, but it cannot invent a replacement acceptance threshold; any new threshold must be marked `PROPOSED_FOR_OWNER_REVIEW`.

### D. Concurrency topology

State caller concurrency, application node count, Ecto pool size and queue settings, actual PgBouncer presence and mode if verified, backend connection budget, pooler wait, database execution time, and queue pressure separately. Do not equate caller cohort with available database connections. Do not treat transaction-mode pooling as compatible with the current session-sensitive design. If the production-shaped topology/budget is unknown, the run cannot certify production behavior.

## 18. Rejected alternatives

- **Increase pool size now:** D1 does not prove pool size 10 is wrong, and a larger application pool can exceed the database connection budget.
- **Add or replace an index now:** the high-density plan already uses the existing index; a named-index rule may be too strict at low density. No selective evidence supports a new index.
- **Add PgBouncer or switch pooling mode now:** the live production topology and budget are unverified. Transaction pooling changes session behavior and has documented compatibility risks.
- **Rewrite cold SQL now:** the measured checkout component dominates the failed local p99, so SQL changes would not isolate the leading observed component.
- **Add finer buckets now:** this changes durable projection shape before edge SQL is established as the residual bottleneck.
- **Pull Redis/ETS/Cachex forward now:** cache hit rates and invalidation behavior are unknown, and a cache could hide an unaccepted cold reader.
- **Change frozen D1 criteria or rerun D1:** this would rewrite certified history rather than explain it.

## 19. Risks and failure modes

| Risk | Relevance to D3/D4 |
|---|---|
| Connection-pool starvation | Callers can queue before SQL; report application queue and checkout separately. More connections may exceed a database budget. |
| Thundering herd | Many callers released together can saturate Repo or PgBouncer. Keep cohorts and observed overlap explicit. |
| Cache stampede | Applies only to H, which is not selected. A synchronized miss/expiry could amplify cold reads. |
| Planner variability by relation size | A Seq Scan may be correct at small cardinality and wrong at large cardinality; assess bounded work and latency as well as plan nodes. |
| Planner variability by PostgreSQL version/statistics | Plans can change with version, statistics, and data distribution. Record them in any future plan evidence. |
| Finer-bucket write amplification | B increases refresh, invalidation, and storage work. No change is authorized. |
| Snapshot invalidation complexity | A finer grain increases the number of identities affected by corrections and refresh races. |
| Historical backfill interaction | New durable grains would need explicit replay and coverage semantics across existing history. |
| Read/write races | Preserve caller transaction preparation and existing coherence semantics; stale generations must fail closed. |
| Cross-node cache incoherence | ETS/GenServer state is process-local; Redis would be shared. No cache design is accepted here. |
| Tenant/event isolation | Every experiment and future query must remain event-scoped. Do not infer tenant safety from one event. |
| Currency isolation | Preserve currency in predicates and identities. Cross-currency aggregation is forbidden. |
| Analytics replica lag | No reader replica is authorized. A lagging replica could serve stale or incomplete projections. |
| PgBouncer transaction/session semantics | Repository authority selects session pooling; transaction pooling is not selected and can break session-dependent behavior. |
| Prepared-statement compatibility | Do not infer compatibility with transaction pooling or unnamed statements without separate proof. |
| Measurement topology differs from production | The live path is unverified; a local direct connection cannot certify a pooler path. |

The D4 plan covers these risks. It does not authorize mitigations.

## 20. Owner-review questions (closed)

1. `C_TOPOLOGY_ATTRIBUTION_REPLAY` is approved as the single next experiment, subject to the D4 plan and a verified representative non-production topology.
2. Future query-plan certification uses bounded appropriate planner behavior, not a named index at every relation size.
3. D4 requires a verified representative topology before measurement.
4. Cold-reader acceptance is required before M5-08 cache work. An early canonical cache reader is not approved.

The owner approved all four decisions. The experiment plan records their exact values.

## 21. Explicit non-authorization

~~~text
M5_05D3_AUTHORIZED=YES
M5_05D3_STATUS=COMPLETE_DESIGN_APPROVED
M5_05D3_OWNER_REVIEW=PASS
M5_05D3_Q1_APPROVED=YES
M5_05D3_Q2_APPROVED=YES
M5_05D3_Q3_APPROVED=YES
M5_05D3_Q4_APPROVED=YES
M5_05D4_NAME=C_TOPOLOGY_ATTRIBUTION_REPLAY
M5_05D4_AUTHORIZED=YES
M5_05D4_STATUS=AUTHORIZED_NOT_STARTED
M5_05D5_AUTHORIZED=NO
M5_05D5_STATUS=BLOCKED_PENDING_D4_EVIDENCE_REVIEW
M5_05E_AUTHORIZED=NO
M5_05F_AUTHORIZED=NO
M5_05G_AUTHORIZED=NO
M5_05_IMPLEMENTATION_AUTHORIZED=M5_05D4_DIAGNOSTIC_ONLY
IMPLEMENTATION_READY=D4_DIAGNOSTIC_ONLY
OPTION_A_DECISION=NO_GO
M5_05D_STATUS=COMPLETE_NO_GO
TOPOLOGY_DOC_CONFLICT=YES
ACTUAL_CURRENT_PRODUCTION_RUNTIME_ROUTE=UNVERIFIED
ACTUAL_CURRENT_PRODUCTION_PGBOUNCER_MODE=UNVERIFIED
ACTUAL_CURRENT_DB_CONNECTION_BUDGET=UNVERIFIED
D1_RERUN=NO
D2_EVIDENCE_CHANGED=NO
M5_05D4_EXECUTED=NO
REMEDIATION_SELECTED=NO
POOL_OR_QUEUE_CHANGE=NONE
INDEX_OR_SCHEMA_CHANGE=NONE
CACHE_OR_REDIS_CHANGE=NONE
PGBOUNCER_CHANGE=NONE
VELOCITY_READER_CHANGE=NONE
~~~
