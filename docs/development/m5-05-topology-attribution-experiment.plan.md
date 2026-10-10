# M5-05D4 topology attribution experiment

~~~text
D4_PLAN_VERSION=v1
D4_NAME=C_TOPOLOGY_ATTRIBUTION_REPLAY
D4_AUTHORIZED=YES
D4_STATUS=AUTHORIZED_NOT_STARTED
D3_STATUS=COMPLETE_DESIGN_APPROVED
BASE_SHA=84cf6af8bca1c5af2a99ddad8c570bf14870bf4d
BASE_TREE=d82a473db35722a7253108211a1004592c7c04bc
~~~

## 1. Purpose and authority

D4 answers one question:

> Does the D1 observation that connection checkout dominated the failed dense 60-minute C50 latency remain attributable when the same deterministic reader workload is replayed through a verified representative non-production runtime topology?

D4 is a diagnostic experiment. It selects no remediation. It does not change D1 or D2 evidence, and it does not authorize production access, configuration changes, SQL or index changes, pool tuning, PgBouncer changes, finer durable buckets, cache, Redis, ETS, Cachex, VelocityReader, or E/F/G work.

Owner-approved decisions carried into this plan are:

~~~text
Q1_C_TOPOLOGY_ATTRIBUTION_REPLAY=APPROVED
Q2_FUTURE_PLAN_GATE=BOUNDED_APPROPRIATE_PLANNER_BEHAVIOR
Q2_NAMED_INDEX_MANDATORY_AT_ALL_RELATION_SIZES=NO
Q3_D4_REQUIRES_VERIFIED_REPRESENTATIVE_TOPOLOGY=YES
Q4_M5_08_EARLY_CANONICAL_CACHE_READER=NO
Q4_COLD_READER_ACCEPTANCE_REQUIRED_FIRST=YES
~~~

Historical D1 facts remain unchanged:

~~~text
D1_MEASUREMENT_VALID=YES
D1_INDEX_SELECTIVITY=FAIL
OPTION_A=NO_GO
M5_05D_STATUS=COMPLETE_NO_GO
D1_RERUN=NO
D2_EVIDENCE_CHANGED=NO
~~~

## 2. Topology conflict and proof gate

The repository records two different topology statements:

~~~text
TOPOLOGY_DOC_CONFLICT=YES
ARCHITECTURE_TARGET=DATABASE_URL through PgBouncer session pooling
HISTORICAL_DEPLOYMENT_STATE=PgBouncer not deployed for Slice 24; DATABASE_URL and DIRECT_DATABASE_URL used direct PostgreSQL
ACTUAL_CURRENT_PRODUCTION_RUNTIME_ROUTE=UNVERIFIED
ACTUAL_CURRENT_PRODUCTION_PGBOUNCER_MODE=UNVERIFIED
ACTUAL_CURRENT_DB_CONNECTION_BUDGET=UNVERIFIED
~~~

Do not use document precedence to decide which statement describes the current deployment. Do not assume PgBouncer exists. Do not infer connection capacity from a pool size, node count, or an old deployment note.

Before setup or measurement, the execution agent must collect safe, read-only, authoritative evidence for:

| Fact | Required evidence |
|---|---|
| Actual runtime route | Sanitized deployment/runtime configuration evidence showing direct PostgreSQL or PgBouncer session pooling |
| Relevant application node count | Current deployed runtime inventory for the model represented by the experiment |
| Application Ecto pool size | Sanitized running application configuration |
| PgBouncer presence | Route evidence; record `NO` for a direct route |
| PgBouncer pooling mode | Authoritative pooler configuration; if present it must be `SESSION` |
| Backend connection budget | Authoritative configured server/backend limit and allocation evidence, with its scope stated |
| Representative non-production route | Isolated non-production application and database route matching the verified connection path closely enough to study connection attribution |

Allowed route classifications:

~~~text
DIRECT_POSTGRES
PGBOUNCER_SESSION
~~~

`PGBOUNCER_TRANSACTION` is outside this experiment and requires a separate architecture decision. Do not inspect or change a production PgBouncer admin console. The experiment does not connect to production.

Never print or persist `DATABASE_URL`, `DIRECT_DATABASE_URL`, passwords, host credentials, Railway secrets, private connection strings, or customer data. Record only verified sanitized facts, for example route kind, pool size, node count, non-secret software versions, and numeric connection limits. Redact connection URIs at collection time, before saving evidence or logs.

If any required fact is unavailable, contradictory, or cannot be verified without production load or a secret-bearing operation:

~~~text
D4_STATUS=INSUFFICIENT_EVIDENCE
D4_CANONICAL_EVIDENCE=NO
~~~

Stop. Do not create an invented pooler or call it representative.

## 3. Representative infrastructure gate

Canonical measurement may use isolated non-production infrastructure only. Production, workstation shared DEV, and workstation shared TEST are prohibited load targets. The repository's shared DEV/TEST PostgreSQL clusters do not represent D4 load infrastructure.

The isolated test route must match the verified current runtime route and relevant application connection configuration closely enough to attribute connection wait. Record any remaining difference before deciding whether the route qualifies. Do not claim production capacity or production latency from this experiment.

If suitable isolated infrastructure does not exist or the route cannot be shown representative:

~~~text
D4_STATUS=INSUFFICIENT_EVIDENCE
~~~

Stop without running the harness.

## 4. Frozen workload

Preserve D1's workload geometry and exact anchor instants:

| Window case | Anchor UTC | Window |
|---|---|---:|
| Unaligned 15m | `2026-05-17T10:17:33Z` | 15m |
| Unaligned 30m | `2026-05-17T10:17:33Z` | 30m |
| Unaligned 60m | `2026-05-17T10:17:33Z` | 60m |
| Aligned 60m | `2026-05-17T11:00:00Z` | 60m |

~~~text
WINDOW_CASES=UNALIGNED_15M,UNALIGNED_30M,UNALIGNED_60M,ALIGNED_60M
NORMAL_EDGE_FACTS_PER_TOUCHED_UTC_HOUR=200
HIGH_DENSITY_EDGE_FACTS_PER_TOUCHED_UTC_HOUR=20000
SELECTIVITY_BACKGROUND_FACTS=20000
CALLER_COHORTS=1,20,50
ACTUAL_CALLERS_NOT_CAPPED_TO_POOL=YES
SAMPLES_PER_CASE_PER_COHORT=100
WARMUPS_PER_CASE=10
CANONICAL_MEASUREMENT_ROWS=24
~~~

There are two densities, four window cases, and three caller cohorts, for 24 rows. All callers in a cohort must be real concurrent callers. Record the actual worker count and maximum simultaneous measured calls. Do not silently cap concurrency to pool size. This is an independent topology-attribution experiment, not a D1 rerun.

Freeze the verified representative application's pool size before the canonical run:

~~~text
D4_APP_POOL_SIZE=<verified value>
POOL_SIZE_SWEEP=NO
QUEUE_SETTING_SWEEP=NO
TIMEOUT_SWEEP=NO
~~~

Do not force pool size 10 because D1 used 10. If the verified target differs, record both values and the difference. Do not change pool, queue, or timeout settings during the experiment.

## 5. Reader and data invariants

Measure only the existing `EventSales.Analytics.ProjectionPeriodReader.read/3`, under its existing caller-owned coherent transaction:

~~~text
Repo.transaction
→ EventSnapshotRefreshFence.prepare_coherent_transaction!
→ ProjectionPeriodReader.read
~~~

Preserve `TimeRules`, `PeriodReadPlan`, `VelocityRules`, `MetricRules`, event and currency isolation, `ANALYTICS_READY`, coverage and version guards, and revenue redaction. Do not rewrite SQL, add another query implementation, or read raw `sales_orders`, `sales_order_items`, `sales_refunds`, or `sales_refund_lines` tables.

Future query-plan validation uses the approved policy:

~~~text
FUTURE_INDEX_SELECTION_POLICY=BOUNDED_APPROPRIATE_PLANNER_BEHAVIOR
~~~

Require bounded query shape; event, currency, and half-open time predicates; no raw-source scan; no pathological historical scan; and a plan appropriate to observed relation size and cardinality. Record node types, index names, rows examined, rows removed, buffers, and actual rows. Do not require `analytics_contribution_facts_event_currency_effective_at_idx` at every relation size. D1's historical index-selectivity failure remains unchanged.

## 6. Instrumentation and attribution

Measure each layer with authoritative instrumentation. Keep measurements separate; do not infer one layer by subtracting unrelated totals.

| Layer | Measurement |
|---|---|
| Caller/scheduler delay | Barrier release to measured-call entry |
| Application queue and checkout | Ecto/DBConnection-supported telemetry or an existing repository-supported equivalent, measured independently from SQL |
| Repo query execution | Repo/Ecto SQL telemetry for query, queue, and relevant decode duration; query count and cardinality |
| PgBouncer/proxy | When present, authoritative pooler evidence for client waiting, active client/server counts, saturation, backend allocation, or aggregate wait metrics |
| End to end | Measured-call entry through completion |

Do not infer checkout from end-to-end subtraction. Do not fabricate per-request proxy wait. Do not calculate `proxy_wait = e2e - checkout - query` unless independent evidence proves that derivation valid. If a pooler exists but its relevant wait or saturation cannot be observed well enough to distinguish layers, record `PROXY_ATTRIBUTION=UNOBSERVABLE` and make no pooler-focused claim.

## 7. Required output per measurement row

Report at least:

~~~text
density
window_case
requested_callers
actual_callers
max_simultaneous_measured_calls
e2e_p50_p95_p99_max
caller_delay_p50_p95_p99
application_queue_checkout_p50_p95_p99
repo_query_p50_p95_p99
query_count
edge_cardinality
errors
not_ready
pool_timeouts
raw_source_reads
~~~

When a pooler exists, separately report its verified aggregate saturation and wait evidence, or `PROXY_ATTRIBUTION=UNOBSERVABLE`. Include query-plan evidence required by section 5. Do not emit `REMEDIATION_SELECTED` from the experiment.

Permitted evidence classifications are:

~~~text
APPLICATION_CHECKOUT_DOMINANT
POOLER_BACKEND_DOMINANT
SQL_EXECUTION_DOMINANT
MIXED
INCONCLUSIVE
~~~

These labels describe evidence only. They do not select a fix.

## 8. Thresholds and validity gates

Keep the existing comparison limits:

~~~text
NORMAL_C50_P99_MAX_US=100000
HIGH_DENSITY_C50_P99_MAX_US=150000
~~~

Report whether every comparable row meets its threshold. A threshold failure does not choose remediation.

A canonical run is valid only when all gates pass:

~~~text
TOPOLOGY_VERIFIED=YES
REPRESENTATIVE_NON_PROD_ROUTE=YES
DB_CONNECTION_BUDGET_VERIFIED=YES
APP_POOL_CONFIG_VERIFIED=YES
FULL_24_ROW_MATRIX=YES
ACTUAL_WORKERS_MATCH_REQUESTED=YES
MAX_OVERLAP_MATCHES_REQUESTED=YES
ERRORS=0
NOT_READY=0
POOL_TIMEOUTS=0
RAW_SOURCE_READS=0
QUERY_SHAPE_BOUNDED=YES
SQL_UNCHANGED=YES
INDEXES_UNCHANGED=YES
POOL_CONFIG_UNCHANGED_DURING_RUN=YES
QUEUE_CONFIG_UNCHANGED_DURING_RUN=YES
~~~

If any mandatory gate fails, set `D4_CANONICAL_EVIDENCE=NO`. Do not interpret the run as remediation evidence.

## 9. Execution file, opt-in, and canonical run

Expected tracked execution file:

~~~text
test/event_sales/analytics/m5_05_velocity_topology_attribution_test.exs
~~~

Expected ignored evidence output:

~~~text
tmp/m5_05_velocity_topology_attribution_evidence.json
~~~

Use one self-contained explicit harness. Do not modify the frozen D1 gate test, production source, `test/test_helper.exs`, application configuration, scripts, or support modules. The harness must refuse execution without its explicit guard and a verified isolated database target. If the harness requires a production, configuration, script, or support-module change, stop and return for scope review.

The exact narrow invocation is:

~~~bash
M5_05D4_EXPLICIT=1 mix test test/event_sales/analytics/m5_05_velocity_topology_attribution_test.exs --only m5_05d4
~~~

The execution environment must supply the isolated non-production database connection through a secret-managed environment. Do not put connection strings in the command, shell history, output, or evidence. The explicit guard is mandatory and the harness must refuse ordinary-suite execution.

Before canonical measurement, only non-load harness contract checks, instrumentation self-tests, fixture-count validation, and topology preflight are allowed. Once the harness and topology pass:

~~~text
ONE_CANONICAL_D4_RUN=YES
~~~

Do not repeat a valid canonical run to seek a better result. If independent review proves the harness invalid, stop; a corrected run requires explicit review and admission.

## 10. Lifecycle and downstream boundaries

~~~text
AUTHORIZED_NOT_STARTED
  → TOPOLOGY_VERIFICATION
      ├── INSUFFICIENT_EVIDENCE
      └── READY_TO_RUN
            → HARNESS_VALIDATION
            → MEASUREMENT_RUNNING
            → D4_EVIDENCE_READY
~~~

Terminal states are `INSUFFICIENT_EVIDENCE` and `D4_EVIDENCE_READY`. Neither authorizes remediation.

~~~text
M5_05D5_NAME=TOPOLOGY_ATTRIBUTION_REVIEW_AND_REMEDIATION_SELECTION
M5_05D5_AUTHORIZED=NO
M5_05D5_STATUS=BLOCKED_PENDING_D4_EVIDENCE_REVIEW
M5_05E_AUTHORIZED=NO
M5_05F_AUTHORIZED=NO
M5_05G_AUTHORIZED=NO
M5_05D4_EXECUTED=NO
REMEDIATION_SELECTED=NO
~~~

D5 may review whether evidence warrants investigation of application pool behavior, PgBouncer/backend topology, cold SQL/data shape, mixed causes, or no remediation. D5 itself is not admitted here. No production configuration or application architecture changes are authorized. Path 2 remains paused.

## 11. Non-certifications and cache order

~~~text
100K_CONCURRENT_USERS_CERTIFIED=NO
PRODUCTION_LATENCY_CERTIFIED=NO
PRODUCTION_CAPACITY_CERTIFIED=NO
POOL_SIZE_REMEDIATION_PROVEN=NO
PGBOUNCER_REMEDIATION_PROVEN=NO
SQL_REWRITE_REQUIRED=NO
NEW_INDEX_REQUIRED=NO
FINER_BUCKETS_REQUIRED=NO
CACHE_REQUIRED=NO
REDIS_REQUIRED=NO
~~~

~~~text
COLD=Postgres snapshots + contribution facts + existing reader
WARM=Redis later; no D4 change
HOT=ETS/GenServer/Cachex later; no D4 change
COLD_READER_ACCEPTANCE_REQUIRED_FIRST=YES
M5_08_EARLY_CANONICAL_CACHE_READER=NO
~~~

## 12. Future D4 implementation scope

The later execution change is limited to the explicit test and ignored evidence output named above. SQL, indexes, application configuration, pool and queue settings, PgBouncer, production source, and the ordinary D1 gate remain unchanged. D4 must remain a diagnostic of the existing cold reader and must not choose or implement remediation.
