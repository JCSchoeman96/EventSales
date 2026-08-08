# Phase 5D Native-v3 E2E Run Report

| Field | Value |
|---|---|
| Document | Phase 5D durable native-v3 E2E run report |
| Status | Recorded from verified Phase 5D-02 evidence |
| Scope | Documentation of one authorized fresh native-v3 dry-run only |
| Authority | Exact verified Phase 5D run evidence; no re-discovery |
| Repository base | `9171d67246bdbe7d018565583d6dde8bda35498d` |
| Recorded run | `0814f5db-67c0-4371-8742-0fa75dbc627e` |
| Historical reference | `3efd208f-b148-4568-8591-13d968399081` |
| Last updated | 2026-08-08 |

### Revision log

- `v1` — initial durable sanitized report of the verified Phase 5D native-v3 E2E run

---

## 1. Executive Result

```text
Run:
0814f5db-67c0-4371-8742-0fa75dbc627e

TECHNICAL_EXECUTION:
PASS

DATA_REVIEW:
BLOCKING_FINDINGS_PRESENT
```

The native-v3 E2E pipeline completed successfully. The run reached `dry_run_ready`. No Apply or AutoApply path executed. No catalogue or mapping writes occurred. Blocking source-risk findings remain for human review. Those blocking findings are an expected fail-closed data-review outcome and do not themselves indicate transport or runtime failure.

---

## 2. Execution Identity

```text
repository main:
9171d67246bdbe7d018565583d6dde8bda35498d

run id:
0814f5db-67c0-4371-8742-0fa75dbc627e

inserted_at:
2026-08-08 15:44:39.910346Z

finished_at:
2026-08-08 15:44:40.596161Z

status:
dry_run_ready
```

Fresh invocation count: `1`.

No second discovery was executed for this report.

---

## 3. Runtime Preconditions

```text
WordPress target:
http://localhost:10059

Local source:
staging-voelgoed

source_system_id:
wordpress_tickera:763b07005f2ebe61495214f853ac388578229b40ee03d0d735d3414c1a0eb846
```

Source identity matched the locked derivation semantics for the configured local WordPress target.

No feed secrets, authorization headers, signatures, cookies, database passwords, WordPress salts, or other secret material are recorded in this report.

Runtime page configuration used by the certified path:

```text
TICKERA_CATALOG_FEED_PER_PAGE = 45
max_pages = 50
```

Infrastructure / performance review (administrative review-path data, not a checkout hot path):

```text
WordPress transient cache:
existing / unchanged

new cache TTL:
none

Redis source-risk authority:
none

ETS source-risk authority:
none

GenServer source-risk authority:
none

Cachex source-risk authority:
none

new PubSub:
none

new migration:
none

new DB index:
none
```

---

## 4. Native Contract Identity

```text
schema_version:
2026-08-07.v3

canonical_contract_version:
source_risk.v3

producer_version:
2026-08-07.1

plan snapshot:
tickera_catalog_plan.v3

evidence origin:
native
```

```text
Effective native mode:
native_v3_review
```

There is no separately persisted `normalization_mode` column. Native mode for this run is established by the exact durable v3 contract markers above, native evidence origin, and plan.v3. This report does not imply a dedicated normalization-mode column exists.

---

## 5. Discovery Integrity

```text
discovery_snapshot_id:
56e5f307944013342354b51e5d30d9f921a406e4a5944d0e3d5f14ca6e35f075

source_snapshot_at:
2026-08-08T15:44:40Z
```

Verified discovery integrity for this run:

- stable discovery identity;
- no generation mismatch;
- no transport/parser failure;
- no pagination-limit failure;
- Discover worker completed on first attempt;
- run completed with `last_error=nil`.

Discover attempt = `1`. No worker retry or recreation duplicate persistence was observed.

---

## 6. Bounded Pagination and Performance

Certified Phase 5D page boundaries:

```text
catalog rows/page <=45
events/page <=45
evidence/page <=500
```

Current certified worst-case variation density:

```text
45 × 11 = 495 evidence/page
```

`500` is a hard limit on `evidence[]` records **per page**.

It is **not** a limit on:

- total run evidence;
- total canonical facts;
- total findings;
- total catalogue size.

Theoretical bounded transport ceilings (mathematical only; not observed run quantities):

```text
catalog transport rows <= 2,250   (45 × 50)
event transport rows <= 2,250     (45 × 50)
raw evidence transport records <= 25,000  (500 × 50)
```

These ceilings describe bounded transport capacity. This report does **not** claim the run contained those quantities. The aggregate implementation is bounded accumulation, not streaming.

---

## 7. Canonical Source-Risk Summary

```text
canonical facts:
213
```

These are whole-run normalized/deduplicated canonical facts. They are **not** the raw per-page `evidence[]` count.

---

## 8. Findings Summary

```text
total findings = 119

info     = 0
warning  = 7
blocking = 112
```

Exact finding distribution:

```text
source_risk.add_on                    21
source_risk.bundle                    21
source_risk.membership                21
source_risk.payment_plan              21
source_risk.subscription_unresolved   19
source_risk.subscription               2
contract.contract_violation            7
variation_mapping_required             7
```

Arithmetic check:

```text
84 capability blockers
+19 subscription unresolved
+2 subscription present/risk
+7 contract violations
=112 blocking

+7 variation warnings
=119 total
```

### `contract.contract_violation` clarification

The seven `contract.contract_violation` records are blocking **policy** findings produced by native `FindingPolicy`.

They must **not** be described as transport/parser failures merely because their qualified ID contains `contract`.

The merged policy can emit `contract.contract_violation` for canonical claims that fail safe-contract policy, including contract-error conditions.

Parser failures have a separate `contract.parser_error` finding path.

This run showed:

```text
transport/parser failure = NO
contract.contract_violation policy findings = 7
```

This report does **not** speculate about the precise underlying reason for those seven findings beyond what Phase 5D-02 verified. Detailed causal review is reserved for Phase 5E.

### Finding durability

```text
durable findings = 119
plan findings    = 119
```

Plan and durable findings:

- total count matches;
- severity/code multiset matches.

Repeated run-scoped finding codes are **not** classified as duplicate persistence merely because target IDs may be nil.

---

## 9. Plan.v3 Action Summary

```text
actions total = 66
```

Breakdown:

```text
event create           = 10
ticket_type create     = 28
product_mapping create = 28
```

These are proposed dry-run actions. They were **not** executed.

Plan hash:

```text
6add9ef1a6eaf1cef1fe10681fb9a70c1fb07cdfac125db12ea62c490e94d310
```

The hash was recomputed from the persisted plan snapshot and matched the persisted dry-run/canonical hash. No additional source discovery was performed to test determinism for this report.

---

## 10. Apply and AutoApply Safety

Verified results for this run:

```text
EvaluateTickeraCatalogAutoApplyWorker jobs for run = 0

Apply jobs for run = 0

AutoApply decisions for hash = 0
```

The run remained `dry_run_ready`.

No of the following occurred:

```text
applying
applied
Apply-induced failed status
```

---

## 11. Side-Effect Verification

Zero-write verification attributable to Phase 5D:

```text
catalogue events = 0
product mappings = 0
ticket types = 0
```

Variation mappings are represented by the applicable existing product-mapping model and remained zero.

Aggregate result:

```text
catalogue/mapping writes attributable to Phase 5D = 0
```

Transient WordPress caching reads/writes are not catalogue mutations and are not implied by this zero-write result.

---

## 12. Historical Run Supersession

Historical run:

```text
3efd208f-b148-4568-8591-13d968399081
```

State change during the authorized fresh invocation:

```text
Before 5D-01 preflight: dry_run_ready
After authorized fresh run: cancelled
```

Classification:

```text
historical dry-run superseded/cancelled by the authorized fresh-run workflow
```

This is **not** Apply. The historical run was not restored or modified beyond that supersession outcome. The new Phase 5D run is now the newest run. No third or newer run exists.

Do **not** claim the historical run remained `dry_run_ready` after the fresh invocation.

---

## 13. Security and Sanitization

This durable report contains **no**:

```text
feed secret
authorization headers
signatures
cookies
database password
WordPress salts
raw native payload
raw arbitrary evidence maps
customer PII
order PII
```

Aggregate finding counts/codes and non-secret identifiers are recorded only.

---

## 14. Known Unpersisted / Unverified Telemetry

```text
page_count:
UNVERIFIED — not persisted

raw event count:
UNVERIFIED — discovery aggregate not persisted

raw catalogue-row count:
UNVERIFIED — discovery aggregate not persisted

raw evidence count:
UNVERIFIED — raw native page evidence not persisted
```

These values are **not** estimated from planned actions.

Discovery completeness for Phase 5D was established through the persisted successful workflow state and the absence of failure paths, not through reconstructing raw pages. Phase 5E must not rerun Phase 5D merely to obtain this unavailable raw page telemetry.

---

## 15. Technical Classification

```text
TECHNICAL_EXECUTION = PASS
```

Reasons:

- exact native contract;
- unique run;
- completed dry-run;
- stable discovery identity;
- no parser/transport failure;
- no pagination-limit failure;
- plan.v3 persisted;
- durable findings consistent;
- no unexpected third run;
- no AutoApply;
- no Apply;
- zero catalogue/mapping writes.

---

## 16. Data-Review Classification

```text
DATA_REVIEW = BLOCKING_FINDINGS_PRESENT
```

112 blocking findings require human review.

This classification does **not** reverse technical PASS. The pipeline succeeded precisely by refusing to treat unresolved or risky source evidence as safe.

---

## 17. Phase 5E Handoff

Phase 5E must review:

```text
7 contract.contract_violation findings
84 capability blockers
21 subscription-related blockers
7 variation_mapping_required warnings
66 proposed actions
```

Phase 5E should determine the source-data and business meaning of those findings.

Phase 5E must **not** rerun Phase 5D merely to obtain unavailable raw page telemetry.

This report does not start Phase 5E analysis.
