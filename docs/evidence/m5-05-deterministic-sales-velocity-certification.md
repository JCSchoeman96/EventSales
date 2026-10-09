# M5-05 deterministic sales velocity certification

~~~text
THIS_DOCUMENT_IS_CANONICAL_D2_EVIDENCE=YES
D1_RAW_EVIDENCE_IS_IGNORED_LOCAL_ARTIFACT=YES
M5_05D1_STATUS=COMPLETE_VALID
M5_05D2_STATUS=COMPLETE_NO_GO
M5_05D_STATUS=COMPLETE_NO_GO
OPTION_A=NO_GO
M5_05D2_AUTHORIZED=YES
M5_05D3_NAME=OPTION_A_NO_GO_REMEDIATION_DESIGN
M5_05D3_AUTHORIZED=NO
M5_05D3_STATUS=BLOCKED_PENDING_SEPARATE_ADMISSION
M5_05E_AUTHORIZED=NO
M5_05F_AUTHORIZED=NO
M5_05G_AUTHORIZED=NO
M5_05_IMPLEMENTATION_AUTHORIZED=NONE
~~~

## Authority and provenance

| Item | Evidence |
|---|---|
| D1 pull request | PR #315, merged |
| Reviewed head SHA | `70dd18176360e93624fe2a58d7975df18d69ff1d` |
| Reviewed head tree | `ffc0b83c12deb3d4f2091176017b1ca522f5b54d` |
| Exact-head CI | Run `37959876953`, event `pull_request`, attempt 1, 7/7 jobs passed |
| Merge SHA | `0f76f792e76379bba7c341ecc5cfc23ecfa7f612` |
| Merge tree | `ffc0b83c12deb3d4f2091176017b1ca522f5b54d` |
| Merge parents | `7dec4997ea80cb8add5cc1ddc7e82f90b21afbf9` and `70dd18176360e93624fe2a58d7975df18d69ff1d` |
| Merge tree identity | Merge tree equals reviewed head tree |
| GitHub signature verification | `verified=true`, `reason=valid` |
| Local signature verification | PASS with GitHub web-flow key fingerprint `968479A1AFF927E37D1A566BB5690EEEBB952194` in a temporary GPG home |
| Raw evidence SHA-256 | `d5b2861f51fedcf299155d4aa5bf929be33897ee0d22cb60a6261360b785672a` |
| D1 measurement date | 2026-10-09. The JSON has no capture-time field; the retained artifact mtime is `2026-10-09 18:40:44 +0200`. |
| TEST environment identity | Local EventSales PostgreSQL TEST cluster at `127.0.0.1:55433`, database `event_sales_test`, role `eventsales_test`, pool size 10. The JSON does not record the server version. |

The raw D1 file `tmp/m5_05_velocity_option_a_gate_evidence.txt` is ignored local output and remains untracked. This document is the canonical D2 record. The prior invalid overlap archive exists and its SHA-256 matches `b33c606fd4d3a7dfb44c185d9145b1e298da561311d0018c522412bf3765188f`. It reported a worker barrier lifetime as measured-call overlap and contributes no metric or decision here.

## Frozen measurement contract

D1 measured 200 normal-density facts per touched UTC hour and 20,000 high-density facts per touched UTC hour. It used 20,000 background facts split across unrelated event, currency, and time values as 6,667 / 6,667 / 6,666. Concurrency cohorts were 1, 20, and 50 callers, with 100 samples per case and cohort, 10 warmups per case, and a TEST pool size of 10.

The frozen C50 p99 limits were 100,000 us for normal density and 150,000 us for high density. The four read cases were unaligned 15m, unaligned 30m, unaligned 60m, and aligned 60m. EXPLAIN covered the three unaligned cases at both densities, for six plans. These inputs and thresholds are unchanged after measurement.

## Validity evidence

~~~text
MEASUREMENT_VALID=YES
ACTUAL_WORKERS=1,20,50
MAX_MEASURED_CALL_OVERLAP=1,20,50
ERRORS=0
NOT_READY=0
POOL_TIMEOUTS=0
RAW_SOURCE_READS=0
MEASUREMENT_ROWS=24/24
EXPLAIN_ROWS=6/6
QUERY_SHAPE=PASS
~~~

Every case/cohort row reports actual workers and maximum measured-call overlap equal to its requested cohort. All 24 rows report zero errors, not-ready results, pool timeouts, and raw-source reads. Every query-contract result is PASS.

## Complete 24-row measurement table

All latency and timing values are microseconds. Rows below are rendered directly from the frozen raw JSON.

| Density | Case | Cohort | Actual workers | Max measured-call overlap | Edge cardinality | E2E p50 us | E2E p95 us | E2E p99 us | E2E max us | Repo query p50 us | Repo query p95 us | Repo query p99 us | Repo queue p50 us | Repo queue p95 us | Repo queue p99 us | Pool checkout p50 us | Pool checkout p95 us | Pool checkout p99 us | Errors | Not ready | Pool timeouts | Query contract | Raw-source reads |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| normal | 15m_unaligned | 1 | 1 | 1 | 3 | 7567 | 8933 | 9798 | 10122 | 5316 | 6872 | 7257 | 0 | 0 | 0 | 68 | 745 | 1088 | 0 | 0 | 0 | PASS | 0 |
| normal | 15m_unaligned | 20 | 20 | 20 | 3 | 22343 | 28041 | 28822 | 29831 | 5592 | 10039 | 10709 | 0 | 0 | 0 | 12996 | 16086 | 18819 | 0 | 0 | 0 | PASS | 0 |
| normal | 15m_unaligned | 50 | 50 | 50 | 3 | 49144 | 58154 | 61989 | 65078 | 5682 | 9845 | 10379 | 0 | 0 | 0 | 40987 | 50150 | 53738 | 0 | 0 | 0 | PASS | 0 |
| normal | 30m_unaligned | 1 | 1 | 1 | 3 | 7923 | 9208 | 9928 | 11458 | 5496 | 7013 | 8375 | 0 | 0 | 0 | 69 | 672 | 718 | 0 | 0 | 0 | PASS | 0 |
| normal | 30m_unaligned | 20 | 20 | 20 | 3 | 21309 | 26180 | 29406 | 29757 | 5700 | 9630 | 10185 | 0 | 0 | 0 | 12319 | 16210 | 19453 | 0 | 0 | 0 | PASS | 0 |
| normal | 30m_unaligned | 50 | 50 | 50 | 3 | 51054 | 56483 | 58295 | 59004 | 5670 | 9678 | 10204 | 0 | 0 | 0 | 42046 | 47980 | 49821 | 0 | 0 | 0 | PASS | 0 |
| normal | 60m_unaligned | 1 | 1 | 1 | 4 | 8105 | 10507 | 12485 | 12649 | 5797 | 7528 | 9414 | 0 | 0 | 0 | 66 | 653 | 708 | 0 | 0 | 0 | PASS | 0 |
| normal | 60m_unaligned | 20 | 20 | 20 | 4 | 25246 | 30093 | 32636 | 32687 | 6569 | 11243 | 11988 | 0 | 0 | 0 | 14313 | 18637 | 21096 | 0 | 0 | 0 | PASS | 0 |
| normal | 60m_unaligned | 50 | 50 | 50 | 4 | 58836 | 64577 | 65482 | 66589 | 6395 | 10306 | 11350 | 0 | 0 | 0 | 48002 | 53797 | 54328 | 0 | 0 | 0 | PASS | 0 |
| normal | 60m_aligned | 1 | 1 | 1 | 0 | 966 | 1568 | 1893 | 1933 | 182 | 228 | 252 | 0 | 0 | 0 | 69 | 780 | 991 | 0 | 0 | 0 | PASS | 0 |
| normal | 60m_aligned | 20 | 20 | 20 | 0 | 4289 | 5512 | 5714 | 5858 | 254 | 367 | 500 | 0 | 0 | 0 | 3126 | 4318 | 4587 | 0 | 0 | 0 | PASS | 0 |
| normal | 60m_aligned | 50 | 50 | 50 | 0 | 7537 | 10403 | 10862 | 11091 | 211 | 286 | 301 | 0 | 0 | 0 | 6487 | 9433 | 9876 | 0 | 0 | 0 | PASS | 0 |
| high_density | 15m_unaligned | 1 | 1 | 1 | 3 | 7433 | 8616 | 8864 | 8949 | 5040 | 6749 | 7325 | 0 | 0 | 0 | 67 | 469 | 678 | 0 | 0 | 0 | PASS | 0 |
| high_density | 15m_unaligned | 20 | 20 | 20 | 3 | 20495 | 24031 | 24510 | 25538 | 5137 | 8691 | 9289 | 0 | 0 | 0 | 11928 | 14192 | 16745 | 0 | 0 | 0 | PASS | 0 |
| high_density | 15m_unaligned | 50 | 50 | 50 | 3 | 51533 | 60208 | 61562 | 62457 | 5399 | 9418 | 9899 | 0 | 0 | 0 | 41695 | 50399 | 51496 | 0 | 0 | 0 | PASS | 0 |
| high_density | 30m_unaligned | 1 | 1 | 1 | 3 | 12791 | 15620 | 18037 | 19016 | 9820 | 13037 | 15174 | 0 | 0 | 0 | 69 | 618 | 793 | 0 | 0 | 0 | PASS | 0 |
| high_density | 30m_unaligned | 20 | 20 | 20 | 3 | 36788 | 43997 | 50324 | 50462 | 10282 | 18033 | 18956 | 0 | 0 | 0 | 20830 | 25049 | 30652 | 0 | 0 | 0 | PASS | 0 |
| high_density | 30m_unaligned | 50 | 50 | 50 | 3 | 81890 | 92844 | 95353 | 98051 | 10208 | 16905 | 19603 | 0 | 0 | 0 | 67388 | 78378 | 79208 | 0 | 0 | 0 | PASS | 0 |
| high_density | 60m_unaligned | 1 | 1 | 1 | 4 | 24448 | 28087 | 29047 | 30216 | 20907 | 25154 | 26894 | 0 | 0 | 0 | 82 | 730 | 789 | 0 | 0 | 0 | PASS | 0 |
| high_density | 60m_unaligned | 20 | 20 | 20 | 4 | 63803 | 78197 | 87479 | 90748 | 21921 | 34424 | 41136 | 0 | 0 | 0 | 35422 | 46546 | 57104 | 0 | 0 | 0 | PASS | 0 |
| high_density | 60m_unaligned | 50 | 50 | 50 | 4 | 162200 | 177703 | 183787 | 188155 | 22297 | 33917 | 37531 | 0 | 0 | 0 | 132985 | 145173 | 146488 | 0 | 0 | 0 | PASS | 0 |
| high_density | 60m_aligned | 1 | 1 | 1 | 0 | 752 | 1321 | 1436 | 1497 | 152 | 184 | 199 | 0 | 0 | 0 | 48 | 629 | 716 | 0 | 0 | 0 | PASS | 0 |
| high_density | 60m_aligned | 20 | 20 | 20 | 0 | 4156 | 5660 | 6215 | 6455 | 229 | 391 | 455 | 0 | 0 | 0 | 3029 | 4259 | 5005 | 0 | 0 | 0 | PASS | 0 |
| high_density | 60m_aligned | 50 | 50 | 50 | 0 | 7933 | 10843 | 11335 | 11523 | 228 | 309 | 390 | 0 | 0 | 0 | 7045 | 9728 | 10156 | 0 | 0 | 0 | PASS | 0 |

## Six EXPLAIN summaries

The buffer column lists non-zero counters recorded by the raw JSON. Zero-valued buffer counters are omitted.

| Density | Case | Result | Node types | Index names | Seq scans | Actual rows by plan node | Rows removed by filter | Non-zero buffer evidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| normal | 15m_unaligned | FAIL | Aggregate, Nested Loop, Function Scan, Materialize, Seq Scan | none | 1 | 3.0, 100.0, 3.0, 7266.0, 7266.0 | 13334 | Shared Hit Blocks=2748 |
| normal | 30m_unaligned | FAIL | Aggregate, Nested Loop, Function Scan, Materialize, Seq Scan | none | 1 | 3.0, 200.0, 3.0, 7266.0, 7266.0 | 13334 | Shared Hit Blocks=2748 |
| normal | 60m_unaligned | FAIL | Aggregate, Nested Loop, Function Scan, Materialize, Seq Scan | none | 1 | 4.0, 400.0, 4.0, 7266.0, 7266.0 | 13334 | Shared Hit Blocks=2748 |
| high_density | 15m_unaligned | PASS | Aggregate, Nested Loop, Function Scan, Bitmap Heap Scan, Bitmap Index Scan | analytics_contribution_facts_event_currency_effective_at_idx | 0 | 3.0, 10000.0, 3.0, 3333.33, 3333.33 | none | Exact Heap Blocks=335, Shared Hit Blocks=1485 |
| high_density | 30m_unaligned | PASS | Aggregate, Nested Loop, Function Scan, Bitmap Heap Scan, Bitmap Index Scan | analytics_contribution_facts_event_currency_effective_at_idx | 0 | 3.0, 20000.0, 3.0, 6666.67, 6666.67 | none | Exact Heap Blocks=668, Shared Hit Blocks=2908 |
| high_density | 60m_unaligned | PASS | Aggregate, Nested Loop, Function Scan, Index Scan | analytics_contribution_facts_event_currency_effective_at_idx | 0 | 4.0, 40000.0, 4.0, 10000.0 | none | Shared Hit Blocks=5346 |

The required index is `analytics_contribution_facts_event_currency_effective_at_idx`.

## Decision summary

~~~text
QUERY_SHAPE=PASS
INDEX_SELECTIVITY=FAIL
SEQ_SCAN_COUNT=3
NORMAL_C50_GATE=PASS
HIGH_DENSITY_C50_GATE=FAIL
OPTION_A=NO_GO
~~~

Two independent frozen gates failed. First, the normal-density 15m, 30m, and 60m unaligned plans selected a sequential scan, so the required index-selectivity criterion failed. This is a predeclared plan gate failure. Normal-density C50 latency still passed. The evidence does not show that the index is broken, inadequate, or caused a latency failure.

The frozen high-density C50 measurements were:

~~~text
HIGH_DENSITY_C50_15M_P99_US=61562
HIGH_DENSITY_C50_30M_P99_US=95353
HIGH_DENSITY_C50_60M_P99_US=183787
HIGH_DENSITY_C50_60M_ALIGNED_P99_US=11335
HIGH_DENSITY_C50_P99_MAX_US=150000
HIGH_DENSITY_C50_GATE=FAIL
~~~

The unaligned 60m case exceeded the frozen limit.

For dense 60m C50, end-to-end p99 was 183,787 us, Repo-query p99 was 37,531 us, and pool-checkout p99 was 146,488 us. In this local D1 environment, connection checkout pressure is the dominant observed component of the failing dense 60-minute C50 end-to-end latency. This result does not prove that the current pool size is wrong or that PgBouncer will fix the result.

D2 does not conclude that PostgreSQL is too slow, that the contribution query is the primary bottleneck, that the current index is insufficient, or that production will fail. The normal-density sequential scans failed the declared query-plan gate while the normal C50 latency gate passed.

## D2 non-certifications

~~~text
100K_CONCURRENT_USERS_CERTIFIED=NO
PRODUCTION_LATENCY_CERTIFIED=NO
PRODUCTION_POOL_SIZE_CERTIFIED=NO
PGBOUNCER_TRANSACTION_MODE_CERTIFIED=NO
READ_REPLICA_REQUIREMENT_PROVEN=NO
NEW_INDEX_REQUIREMENT_PROVEN=NO
CACHE_REQUIREMENT_PROVEN=NO
REDIS_REQUIREMENT_PROVEN=NO
FINER_BUCKET_REQUIREMENT_PROVEN=NO
~~~

## Remediation-design boundary

`M5_05D3_NAME=OPTION_A_NO_GO_REMEDIATION_DESIGN` is a proposed separate design slice. It is not authorized and remains `BLOCKED_PENDING_SEPARATE_ADMISSION`. D2 records the questions below without choosing or recommending a physical solution.

- R1: How much C50 latency comes from application-pool checkout pressure versus SQL execution?
- R2: How should production PgBouncer transaction-mode topology alter the relevant concurrency model, if at all?
- R3: Is mandatory index selection at low fixture density a suitable acceptance criterion when PostgreSQL can prefer a sequential scan and latency remains within target?
- R4: Would finer durable projection buckets materially reduce dense 60-minute edge-read cost without creating a second financial truth model?
- R5: Would another existing-index/query shape improve dense reads, given that high-density plans already use the current compound index?
- R6: Should M5-08 warm/hot acceleration be pulled forward, or must canonical cold-path reader integration remain blocked until a non-cache solution passes?
- R7: What future test topology best represents flash-sale readiness without weakening the existing D1 evidence?

D2 authorizes no pool-size or queue tuning, checkout-timeout change, PgBouncer configuration, index change, planner forcing, finer bucket, cache, Redis, ETS, GenServer, Cachex, PubSub, Oban, read replica, resource, migration, VelocityReader, threshold change, D1 rerun, or implementation work. E, F, and G remain unauthorized and blocked. No remediation architecture is selected.
