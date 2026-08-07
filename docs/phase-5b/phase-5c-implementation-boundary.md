# Phase 5C — Source-Risk Implementation Boundary

| Field | Value |
|---|---|
| Plan / document ID | `phase-5c-source-risk-implementation-boundary` |
| Document version | `v3` |
| Status | Draft for independent Phase 5C boundary re-review (PR #154) |
| Scope | Implementation boundary, module ownership, tests, PR slices, and cutover rules for merged Phase 5B contracts — **design only** |
| Authority | Subordinate to locked Phase 5B domain model, native contract, and v2 compatibility adapter |
| Locked domain model | `docs/phase-5b/source-risk-domain-model.md` — SHA256 `16563ee02f58a12d2fde1e6995da3cb4d1be89dfd9ecbb8e07eb76ba5d8a6375` |
| Locked native contract | `docs/phase-5b/source-risk-contract.md` — SHA256 `87dec4238e5c7ea04fe8d2a9735980a35f2bf542324a851686d60fead1d0785c` |
| Locked v2 adapter | `docs/phase-5b/v2-compatibility-adapter.md` — SHA256 `8236b6c1ddcd908a9a602f9b25bbe248323f3e117b20f63410e5cf348aaf30f5` |
| Base main | `b384ed48f0cd644005e7762c496f341a0d7269de` |
| Last updated | 2026-08-07 |
| Change summary | Finalize DiscoveryResult carrier, durable findings, source-key MVP, native page bounds, self-contained 5C-06 |

### Revision log

- `v1` — initial implementation boundary after PR #153 merge
- `v2` — PR #154 REQUEST CHANGES: three-mode cutover; envelope/generation/carrier; skip v3 AutoApply enqueue; expand TOONs
- `v3` — PR #154 REQUEST CHANGES: lock DiscoveryResult-only carrier; durable TickeraCatalogSyncFinding; remove source-key override; native per_page≤100 / evidence≤500; enumerate 5C-06 files

### Conflict rule

```text
locked Phase 5B docs win on semantics/invariants
this boundary wins on module ownership, sequence, file paths, and cutover guards
```

---

## 1. Status and Authority

Phase 5B Gates B/C/D are merged on `main`.

This document unlocks **Phase 5C boundary design only**.

```text
Actual Phase 5C implementation: LOCKED
until this boundary PR is independently approved and merged.
```

Forbidden now:

- Elixir/PHP/migration/test/config implementation
- rewriting historical `tickera_catalog_plan.v2`
- enabling v3 AutoApply / Human Apply / variation Apply
- Phase 5D fresh dry-run (`catalogue-dry-run --fresh`)

---

## 2. Ultimate Outcome (work backwards)

### Target outcome

```text
A native 2026-08-07.v3 WordPress producer
can feed EventSales through source_risk.v3,
with deterministic typed canonical facts,
correct blocking findings,
stable discovery integrity,
read-only compatibility interpretation of historical v2,
and a new dry-run snapshot,
without weakening Apply safety,
without changing live v2 operational behaviour,
and without rewriting v2 history.
```

### Phase 5D success dependency (reserved)

```text
exactly one fresh native-v3 end-to-end dry-run
→ deterministic reviewable plan
→ no false-safe evidence
→ no oversold/automatic variation behaviour
→ independent Phase 5E review
```

### Backward dependency map

| Dependency | Why required before Phase 5D |
|---|---|
| Three explicit execution modes (§5) | Keep live v2 operational unchanged |
| Immutable `source_risk.v3` ContractRegistry + structs | Typed canonical model |
| Finding-policy + conflict pipeline | Correct dispositions |
| Dual-mode Phoenix: operational v2 + native v3 | Fail closed on unknown/mixed |
| Historical-only compatibility adapter | Review projection without cutover |
| Stable WP discovery generation + snapshot id | Reject mid-discovery change |
| Extended `DiscoveryResult` carrier | Planner has no hidden side channels |
| Planner emits `tickera_catalog_plan.v3` | Separate from immutable v2 |
| Explicit v3 Apply + AutoApply-evaluation denial | Preserve Apply safety |
| Native WP `2026-08-07.v3` producer | Typed evidence primary |
| Contract/regression tests | Prove fail-closed cutover |

---

## 3. Locked Conceptual Resources → Concrete Ownership

| Concept | Responsible module | File path | Input | Output | Owns validation? | Owns policy? | Persistence? | Layer |
|---|---|---|---|---|---|---|---|---|
| ContractRegistry | `SourceRiskV3.ContractRegistry` | `lib/event_sales/catalog/tickera_catalog/source_risk_v3/contract_registry.ex` | compile-time tables | lookup/reject | yes | no | none | hot code |
| RawProducerEvidence | `SourceRiskV3.Evidence` | `lib/event_sales/catalog/tickera_catalog/source_risk_v3/evidence.ex` | wire page/evidence | validated evidence | transport only | no | optional bounded refs | warm/run |
| CanonicalEvidenceFact | `SourceRiskV3.CanonicalFact` | `lib/event_sales/catalog/tickera_catalog/source_risk_v3/canonical_fact.ex` | validated evidence / adapter | facts + identity | identity/equality | no | via plan snapshot | cold |
| CompatibilityTranslation | `SourceRiskV3.Compatibility.V2Adapter` | `lib/event_sales/catalog/tickera_catalog/source_risk_v3/compatibility/v2_adapter.ex` | historical v2 only | translation + candidates | Gate D | no | computed MVP | cold compute |
| SourceRiskFinding | `SourceRiskV3.FindingPolicy` → `Finding` shape → durable rows | `lib/event_sales/catalog/tickera_catalog/source_risk_v3/finding_policy.ex` + `lib/event_sales/catalog/tickera_catalog/finding.ex` + `lib/event_sales/ingestion/resources/tickera_catalog_sync_finding.ex` | facts/errors | dispositions + persisted findings | disposition codes | yes | plan snapshot **and** `TickeraCatalogSyncFinding` | cold |
| PlannerDecision / Action | `Planner` | `lib/event_sales/catalog/tickera_catalog/planner.ex` | mode-specific inputs from DiscoveryResult / legacy Normalizer | plan v2 or v3 | planner structural | planner status | plan snapshot | cold |
| Discovery integrity | `SourceRiskV3.DiscoveryIntegrity` | `lib/event_sales/catalog/tickera_catalog/source_risk_v3/discovery_integrity.ex` | page envelopes | accept/reject | integrity | no | run aggregation | warm/run |
| Native normalizer | `SourceRiskV3.Normalizer` | `lib/event_sales/catalog/tickera_catalog/source_risk_v3/normalizer.ex` | validated evidence | `DiscoveryResult.canonical_source_risk_facts` | semantic construction | no | via plan snapshot | cold compute |
| Discovery carrier (sole) | `DiscoveryResult` | `lib/event_sales/catalog/tickera_catalog/discovery_result.ex` | discovery + normalize outputs | sole planner input carrier | field presence | no | no | warm |
| Durable finding projection | `DiscoverTickeraCatalogWorker` + `TickeraCatalogSyncFinding` | `lib/event_sales/ingestion/workers/discover_tickera_catalog_worker.ex` + `lib/event_sales/ingestion/resources/tickera_catalog_sync_finding.ex` | plan findings | DB rows | existing bounds | no | yes | cold |
| Legacy v2 SourceRisk | `SourceRisk` | `lib/event_sales/catalog/tickera_catalog/source_risk.ex` | live/historical v2 | v2 facts | legacy | legacy | historical v2 snapshots | preserve |
| Legacy v2 Normalizer | `Normalizer` | `lib/event_sales/catalog/tickera_catalog/normalizer.ex` | live v2 rows | v2 plan inputs | legacy | legacy | via plan.v2 | preserve |

---

## 4. Proposed Module Namespace and Folder Structure

### Namespace lock

```text
EventSales.Catalog.TickeraCatalog.SourceRiskV3
```

### Folder structure (create only during later implementation PRs)

```text
lib/event_sales/catalog/tickera_catalog/source_risk_v3/
  contract_registry.ex
  evidence.ex
  canonical_fact.ex
  normalizer.ex
  finding_policy.ex
  discovery_integrity.ex
  compatibility/
    v2_adapter.ex
```

### Legacy preservation

```text
EventSales.Catalog.TickeraCatalog.SourceRisk
EventSales.Catalog.TickeraCatalog.Normalizer
```

remain historical/live **v2 operational** behaviour.

Do **not** rename them into the v3 canonical model.

Avoid: generic rule engines, DI frameworks, runtime vocabulary GenServers, metaprogrammed registries.

Prefer: immutable maps/constants, small structs, pure functions, explicit pattern matching, closed registries.

---

## 5. Three Explicit Execution Modes (cutover lock)

Do **not** route live `2026-07-22.v2` operational discovery through the compatibility adapter.

### A. `legacy_v2_operational`

```text
live producer schema: 2026-07-22.v2

route:
lib/event_sales/catalog/tickera_catalog/wordpress_feed_response.ex
→ lib/event_sales/catalog/tickera_catalog/normalizer.ex
→ lib/event_sales/catalog/tickera_catalog/planner.ex
→ tickera_catalog_plan.v2
→ existing Human Apply + AutoApplyPolicy behaviour unchanged
```

Preserves:

```text
Human Apply behaviour
AutoApplyPolicy behaviour
snapshot semantics
dry-run hashes
legacy SourceRisk semantics
```

Forbidden on this route:

```text
SourceRiskV3.Compatibility.V2Adapter as replacement runtime path
tickera_catalog_plan.v3 emission for ordinary live v2 discovery
```

### B. `historical_v2_compatibility_review`

```text
historical / explicitly requested persisted v2 representation
→ legacy validation
→ SourceRiskV3.Compatibility.V2Adapter (compat.v2_to_source_risk_v3.v1)
→ compatibility-derived canonical projection
→ human review / read model only
```

Never:

```text
operational Apply proof
native automation completeness
tickera_catalog_plan.v2 rewrite
tickera_catalog_plan.v3 as substitute for live operational v2
```

### C. `native_v3_review`

```text
producer schema: 2026-08-07.v3
→ native v3 parser (WordPressFeedResponse v3 path + SourceRiskV3.Evidence)
→ SourceRiskV3.DiscoveryIntegrity
→ SourceRiskV3.Normalizer
→ FindingPolicy
→ Planner
→ tickera_catalog_plan.v3
→ review-only
→ Apply denied
→ AutoApply evaluation not enqueued
```

Unknown / mixed versions / mixed discovery identities → fail closed.

### Mode summary

| Mode | Producer | Adapter? | Snapshot | Apply | AutoApply evaluate |
|---|---|---|---|---|---|
| `legacy_v2_operational` | live `2026-07-22.v2` | no | `tickera_catalog_plan.v2` | existing | existing |
| `historical_v2_compatibility_review` | historical v2 only | yes | projection only (no operational plan cutover) | never | never |
| `native_v3_review` | `2026-08-07.v3` | no | `tickera_catalog_plan.v3` | denied | not enqueued |

Primary dispatch owners:

```text
lib/event_sales/catalog/tickera_catalog/wordpress_feed_discovery_source.ex
lib/event_sales/catalog/tickera_catalog/wordpress_feed_response.ex
lib/event_sales/catalog/tickera_catalog/source_risk_v3/discovery_integrity.ex
lib/event_sales/ingestion/workers/discover_tickera_catalog_worker.ex
```

Forbidden routing:

```text
"latest"
string-prefix guessing
fallback-to-newest
best-effort mixed schema interpretation
live v2 → V2Adapter → plan.v3 as operational replacement
```

---

## 6. Raw Producer Evidence Boundary

Parser may validate only transport:

```text
required keys
primitive types
closed wire enums
bounds
page envelope
target shape
exact provenance keys
pagination shape
version stamps
discovery snapshot identity fields
```

Parser must **not** decide semantic authority, safe/risky disposition, scope correction, finding severity, or automation eligibility.

`SourceRiskV3.Normalizer` owns construction of native canonical facts.

---

## 7. ContractRegistry Implementation Boundary

Path:

```text
lib/event_sales/catalog/tickera_catalog/source_risk_v3/contract_registry.ex
```

Immutable compile-time tables for dimensions, scopes, states, completeness, authorities, authority slots, allowed values (`product_type` MVP = `simple` only), dispositions, finding ownership, producer→canonical bindings, empty native safe-negative allowlist.

```text
No DB
No Redis
No Cachex
No GenServer
No runtime admin mutation
```

---

## 8. Canonical Fact Identity and Conflict Pipeline

Identity:

```text
run/discovery
+ dimension
+ semantic_scope
+ canonical target
+ authority slot/group
```

Never include state, value, legacy code, finding code, translation_rule_id, or source_emitter in identity.

Owners: `CanonicalFact` + `Normalizer` for collapse/conflict/provenance merge.

Known lossy derivatives follow Gate D precedence and must not manufacture conflicts.

Ordering before hash:

```text
dimension, scope, canonical target, authority slot, origin, state, value, completeness
```

---

## 9. Finding-Policy Boundary

Path:

```text
lib/event_sales/catalog/tickera_catalog/source_risk_v3/finding_policy.ex
```

Dispositions: safe_positive_proof, safe_negative_proof, blocking_unknown/missing/unsupported/invalid/error/conflict/contract_error, explicit_risk, not_applicable.

Locks: native safe-negative allowlist empty; dimension-local safe proof only; never imply row/target/plan/run/Apply safety.

---

## 10. Compatibility Adapter Implementation Boundary

Path:

```text
lib/event_sales/catalog/tickera_catalog/source_risk_v3/compatibility/v2_adapter.ex
```

Used **only** for `historical_v2_compatibility_review`.

Locks: `compat.v2_to_source_risk_v3.v1`; `origin=compatibility_derived`; automation-ineligible; source_emitter rules; Gate D hardening matrix; computed MVP (no required persistence); no dynamic rules engine; no Redis.

---

## 11. Native WordPress v3 Producer Boundary

Paths:

```text
integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php
integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-feed-contract.md
integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-feed-test.php
integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-change-trigger-test.php
```

### Required native page envelope (complete)

Every native page must include and agree across pages on:

```text
schema_version
canonical_contract_version
producer_version
source
source_system_id
discovery_snapshot_id
source_snapshot_at
generated_at
page
per_page
has_more
filters
events
catalog_rows
evidence
```

Native typed `evidence[]` is primary.

Native pagination/evidence bounds (do not inherit legacy PHP `MAX_PER_PAGE = 500` for v3):

```text
per_page <= 100
evidence.length <= 500 per page
```

Legacy flat risk strings, if retained, are **non-authoritative diagnostics only**; Phoenix native normalization ignores them for canonical proof.

### `producer_version` (exact lock)

Constant:

```text
EVENTSALES_TICKERA_CATALOG_PRODUCER_VERSION
```

First native-v3 value (locked):

```text
2026-08-07.1
```

Must be emitted on every v3 page. Contract-significant. Do not invent alternate stamps during 5C-05.

Plugin marketing header Version may move separately (e.g. `0.2.0`) but must not diverge from documenting the locked producer stamp in contract tests.

### `source_system_id` / producer-local source key (exact lock)

Wire field name remains `source_system_id` per locked contract.

Producer value is a **stable producer-local source key**, not the EventSales database UUID.

**Phase 5C MVP: derived normalize-url hash only. No override constants/config.**

Algorithm (locked):

```text
home = normalize_url(home_url())
// normalize: lowercase scheme/host; strip default ports; strip trailing slash; no fragment/query
producer_source_key = "wordpress_tickera:" <> sha256_hex(home)
```

Phoenix verification:

```text
expected_key = "wordpress_tickera:" <> sha256_hex(normalize_url(source_system.base_url))
reject page if page.source_system_id != expected_key
→ source_system_id mismatch (fail closed)
```

Do **not** implement `EVENTSALES_TICKERA_CATALOG_SOURCE_KEY` or Phoenix env/app-config overrides in Phase 5C.

If a real installation later needs an override, that requires a separately reviewed design change.

Properties: stable across pages/restarts; different per WP installation; non-secret; bounded; deterministic.

---

## 12. DiscoveryResult / v3 Carrier (FINAL lock)

Path:

```text
lib/event_sales/catalog/tickera_catalog/discovery_result.ex
```

**FINAL decision:** extend `DiscoveryResult`. Do **not** replace it. Do **not** introduce an adjacent result struct, alternative carrier, process dictionary, ETS side channel, or deferred ownership.

Preserve all existing v2 fields/semantics:

```text
schema_version
auto_apply_proof_complete?
origin
events
catalog_rows
source_snapshot_at
```

Add optional native-v3 carrier fields (nil/default for `legacy_v2_operational`):

```text
canonical_contract_version
producer_version
source_system_id
discovery_snapshot_id
normalization_mode
evidence_origin
canonical_source_risk_facts
canonical_source_risk_findings
```

`normalization_mode` values:

```text
:legacy_v2_operational
:native_v3_review
```

`evidence_origin` values:

```text
:native
nil   // operational v2
```

### Field ownership (locked)

| Field group | Owner |
|---|---|
| Transport/envelope fields (`schema_version`, `canonical_contract_version`, `producer_version`, `source_system_id`, `discovery_snapshot_id`, `source_snapshot_at`, events/rows) | `WordPressFeedResponse` / `WordPressFeedDiscoverySource` (+ `DiscoveryIntegrity` checks) |
| `canonical_source_risk_facts` | `SourceRiskV3.Normalizer` only |
| `canonical_source_risk_findings` | `SourceRiskV3.FindingPolicy` only |
| Planner | **read-only consumer** of `DiscoveryResult` |

Pipeline:

```text
WordPressFeedResponse / DiscoverySource accumulate pages
→ DiscoveryIntegrity validates agreement
→ SourceRiskV3.Normalizer writes canonical_source_risk_facts onto DiscoveryResult
→ SourceRiskV3.FindingPolicy writes canonical_source_risk_findings onto DiscoveryResult
→ Planner reads DiscoveryResult only
```

`historical_v2_compatibility_review` uses adapter outputs in a separate human-review read-model path; it does not replace operational `DiscoveryResult` for live dry-runs and does not invent a second operational carrier.

---

## 13. WordPress Discovery Snapshot Integrity (exact lock)

### SnapshotGeneration record

Producer-side logical generation record (WordPress option JSON or equivalent single option payload):

```text
SnapshotGeneration = {
  generation_token,   // opaque string (UUID v4 or 32+ byte hex); NOT an arithmetic counter
  generation_at       // RFC3339 Z timestamp set when generation is created
}
```

Option name (locked):

```text
eventsales_tickera_catalog_snapshot_generation
```

Every catalogue-relevant invalidation **must replace** the whole record with a new opaque `generation_token` and new `generation_at`.

Do **not** use arithmetic `CACHE_VERSION_OPTION` alone as the contract snapshot identity.

Existing:

```text
eventsales_tickera_catalog_feed_cache_version
```

may continue solely for transient cache-key invalidation.

### Page materialization safety

For each native page build:

```text
read generation_before
→ build page body
→ read generation_after
require generation_before == generation_after
else fail/retry page; do not return a supposedly stable native page
```

### `source_snapshot_at`

```text
source_snapshot_at = generation_at
```

for every page in one generation.

Never use page request time for `source_snapshot_at`.

`generated_at` remains page materialization time and may differ by page.

### Canonical discovery filters (identity)

Exact keys only (locked contract §4.1):

```text
updated_since
product_id
variation_id
event_id
include_private
```

Deterministic null/boolean normalization required.

Explicitly **exclude** from discovery identity:

```text
page
per_page
cursor
next_cursor
```

### `discovery_snapshot_id`

Deterministic composition:

```text
discovery_snapshot_id = sha256_hex(canonical_json({
  schema_version,
  canonical_contract_version,
  producer_version,
  source,
  source_system_id,          // producer-local key
  generation_token,
  filters                    // canonical filters object only
}))
```

Use deterministic canonical JSON serialization (sorted keys; nulls explicit; bools lowercase).

Do not include page-specific values.

### Completeness honesty

If mutation coverage / source stability cannot be proven:

```text
do not claim exhaustive
use partial/unknown
automation remains impossible
```

### Required generation tests (later)

```text
same generation across multiple pages
same source_snapshot_at across pages
page/per_page exclusion from identity
different filters → different snapshot ids
generation change between pages → Phoenix reject
generation change during a page → WP fail/retry
repeated/concurrent invalidations → new opaque tokens
```

---

## 14. Page Processing / Memory Boundary

Native v3 bounds (locked contract; stricter than legacy PHP `MAX_PER_PAGE = 500`):

```text
per_page <= 100
evidence.length <= 500 per page
catalog rows/page <= 100
```

Legacy `2026-07-22.v2` producer bounds remain unchanged until the producer cutover.

Processing:

```text
validate page → canonicalize bounded evidence → incremental aggregate → finalize
```

Redis: none. Cachex: none. New GenServer: none.

---

## 15. Plan Snapshot Version Lock

```text
native_v3_review dry-run output → tickera_catalog_plan.v3
legacy_v2_operational dry-run output → tickera_catalog_plan.v2 (unchanged)
```

Never serialize new source-risk semantics under `tickera_catalog_plan.v2`.

Owners:

```text
lib/event_sales/catalog/tickera_catalog/planner.ex
lib/event_sales/catalog/tickera_catalog/snapshot_canonicalizer.ex
```

---

## 16. Persistence / DB Decision

```text
Does tickera_catalog_plan.v3 require a DB migration?
NO
```

Existing `tickera_catalog_sync_runs.plan_snapshot` (:map) stores versioned JSON. No historical v2 rewrite. CompatibilityTranslationRecord: not persisted for MVP.

### Durable findings (locked)

Native v3 findings persist in **both**:

```text
A. tickera_catalog_plan.v3 findings (immutable audit artifact)
B. existing TickeraCatalogSyncFinding rows (durable query/admin projection)
```

Paths:

```text
lib/event_sales/ingestion/resources/tickera_catalog_sync_finding.ex
lib/event_sales/ingestion/workers/discover_tickera_catalog_worker.ex
```

No second finding table.

No migration unless later static proof shows existing bounds cannot store a valid locked v3 finding. Expected Phase 5C design:

```text
migration = NO
```

5C-04 must verify:

```text
qualified v3 finding codes fit code max_length=120
metadata remains bounded
severity maps to existing :info | :warning | :blocking
retry cleanup/recreation via destroy_for_retry remains transactional
historical v2 finding representation unchanged
```

---

## 17. Index Review

Prefer existing indexes only. No new index without a demonstrated critical query path. No order/sales table scans for source-risk discovery.

---

## 18. Apply and AutoApply Evaluation Boundary (critical)

Phase 5C builds discovery → normalize → plan → dry-run → human review for native v3.

Phase 5C does **not** unlock native-v3 Apply.

### AutoApplyPolicy

Path:

```text
lib/event_sales/catalog/tickera_catalog/auto_apply_policy.ex
```

Remains semantically unchanged and v2-only (`tickera_catalog_plan.v2` / `conservative_auto_apply.v1`).

### AutoApply evaluation enqueue (stronger lock)

Path:

```text
lib/event_sales/ingestion/workers/discover_tickera_catalog_worker.ex
```

```text
tickera_catalog_plan.v2 ready → existing EvaluateTickeraCatalogAutoApplyWorker enqueue unchanged
tickera_catalog_plan.v3 ready → do NOT enqueue EvaluateTickeraCatalogAutoApplyWorker
```

Do not rely on accidental unsupported-snapshot rejection as the primary review-only gate.

### Human Apply / queue_apply

Paths:

```text
lib/event_sales/ingestion/tickera_catalog_sync.ex
lib/event_sales_web/live/admin/catalog_sync_live.ex
```

```text
tickera_catalog_plan.v3 → reject before Apply job enqueue
```

Backend denial is authoritative; UI must not present Apply as available for v3.

### Applier.apply

Path:

```text
lib/event_sales/catalog/tickera_catalog/applier.ex
```

Explicit snapshot-version validation **before any catalogue write**:

```text
tickera_catalog_plan.v3 → {:error, :unsupported_snapshot_version}
```

Do not rely on alternate change-key shape mismatch.

### Direct / stale Apply worker

Path:

```text
lib/event_sales/ingestion/workers/apply_tickera_catalog_worker.ex
```

For v3:

```text
reject/discard
zero catalogue writes
do not mark run applied
prefer leave dry_run_ready review-only plan intact
```

`Applier` remains sole catalogue writer.

Variations remain ineligible for automatic Apply.

---

## 19. Planner Boundary

```text
lib/event_sales/catalog/tickera_catalog/planner.ex
```

- `legacy_v2_operational`: consumes legacy Normalizer outputs as today.
- `native_v3_review`: **read-only** consumes `DiscoveryResult.canonical_source_risk_facts` and `DiscoveryResult.canonical_source_risk_findings`.
- Must not embed Gate D alias translation / authority inference / scope correction.
- Must not invent an alternate carrier.
- `variation_mapping_required` stays outside canonical source-risk evidence.

---

## 20. Structural vs Source-Risk Ownership

| Namespace | Owner |
|---|---|
| `source_risk.*` | `SourceRiskV3.FindingPolicy` |
| `contract.*` | FindingPolicy / DiscoveryIntegrity |
| `structural.*` | Planner / legacy Normalizer structural path |
| `planner.status.*` / `planner.action.*` | Planner |

`unknown_product_semantics` remains derived-only.

---

## 21. Security Boundary

Exact-key envelopes; bounded strings/provenance; no dynamic atoms from producer strings; no arbitrary nested maps; no auth headers/signatures/cookies/credentials/PII/full WP payloads persisted; unknown/oversized → fail closed; no truncate-then-alias; digest only as digest + byte length when needed.

Signature path:

```text
lib/event_sales/catalog/tickera_catalog/wordpress_feed_signature.ex
```

---

## 22. Concurrency / Failure-Mode Matrix

| Failure mode | Detect | Fail-closed | Retry/idempotency | Finding/status | Persistence |
|---|---|---|---|---|---|
| Source changes between pages | discovery_snapshot_id / generation mismatch | reject discovery | new run | integrity | no ready plan |
| Generation change during page | before≠after | WP fail/retry page | retry page | none returned | none |
| Page duplicate/gap | page set | reject | retry | integrity | none |
| Mixed schema versions | version set | reject | retry | integrity | none |
| Producer source key mismatch | expected_key check | reject | fix config | contract | none |
| Duplicate/conflict facts | identity+claim | collapse/conflict | n/a | findings | plan + TickeraCatalogSyncFinding |
| Unknown producer code | registry | blocking | n/a | finding | plan + rows |
| Oversized provenance | bounds | reject | no truncate-alias | contract | none |
| Adapter unknown emitter | Gate D | weaker diagnostic | n/a | review only | projection |
| Finding code > 120 chars | length check | reject/fail closed finding persist | n/a | contract | no ready |
| Snapshot finalization crash | worker | failed/retry_scheduled | Oban | last_error | no false ready |
| AutoApply eval for v3 | discover worker | skip enqueue | n/a | none | ready review-only |
| queue_apply v3 | Sync | reject | no job | error | no write |
| Applier/worker v3 | Applier/worker | unsupported_snapshot_version / discard | no write | keep ready | no applied |
| source_system_id mismatch | hash compare | reject discovery | fix base_url | contract | none |
| native per_page > 100 | producer/parser bounds | reject page | n/a | contract | none |
| native evidence > 500 | producer/parser bounds | reject page | n/a | contract | none |

---

## 23. Performance & Scaling Review

| Component | Layer | Redis |
|---|---|---|
| ContractRegistry | compile-time | none |
| Canonical facts | cold plan snapshot | none |
| Compatibility translation | pure compute | none |
| Discovery aggregation | bounded run state | none |
| Historical snapshots | Postgres `plan_snapshot` | none required |

No Cachex/Redis/GenServer/PubSub introduced for source-risk vocabulary. Existing catalog sync PubSub may notify UI only. Administrative path; isolate from checkout hot path.

---

## 24. Test Architecture

### Registry / normalizer / conflict / adapter

```text
test/event_sales/catalog/tickera_catalog/source_risk_v3/contract_registry_test.exs
test/event_sales/catalog/tickera_catalog/source_risk_v3/canonical_fact_test.exs
test/event_sales/catalog/tickera_catalog/source_risk_v3/normalizer_test.exs
test/event_sales/catalog/tickera_catalog/source_risk_v3/finding_policy_test.exs
test/event_sales/catalog/tickera_catalog/source_risk_v3/discovery_integrity_test.exs
test/event_sales/catalog/tickera_catalog/source_risk_v3/compatibility/v2_adapter_test.exs
```

### Parser / discovery carrier

```text
test/event_sales/catalog/tickera_catalog/wordpress_feed_response_test.exs
test/event_sales/catalog/tickera_catalog/wordpress_feed_discovery_source_test.exs
test/event_sales/catalog/tickera_catalog/discovery_result_test.exs
```

### Planner / snapshot / Apply safety / durable findings

```text
test/event_sales/catalog/tickera_catalog/snapshot_canonicalizer_test.exs
test/event_sales/catalog/tickera_catalog/planner_applier_test.exs
test/event_sales/catalog/tickera_catalog/auto_apply_policy_test.exs
test/event_sales/ingestion/tickera_catalog_auto_apply_test.exs
test/event_sales/ingestion/workers/discover_tickera_catalog_worker_test.exs
test/event_sales/ingestion/workers/apply_tickera_catalog_worker_test.exs
test/event_sales/ingestion/tickera_catalog_sync_test.exs
test/event_sales/ingestion/resources/tickera_catalog_sync_finding_test.exs
```

### WordPress

```text
php integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-feed-test.php
php integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-change-trigger-test.php
```

(contract markdown updated in-place under same tests directory)

### Forbidden during Phase 5C implementation

```text
bash scripts/dev_local.sh catalogue-dry-run --fresh
```

---

## 25. Implementation Sequence

| Slice | Outcome |
|---|---|
| **5C-01** | Canonical v3 core only |
| **5C-02** | Historical compatibility adapter only |
| **5C-03** | Dual-mode ingestion: keep operational v2; add native v3 parser + DiscoveryResult carrier + integrity |
| **5C-04** | Planner plan.v3 review-only; skip v3 AutoApply enqueue; deny Human/Applier/worker Apply |
| **5C-05** | Native WP producer + SnapshotGeneration |
| **5C-06** | Regression/security/performance closure then STOP |

Deploy order: Phoenix dual-mode (through 5C-04) **before** WP v3 (5C-05).

Each slice: fresh main → fresh branch → tests → draft PR → review → merge → next.

---

## 26. Folder/File Ownership Map

| Concern | Existing path(s) | Proposed path(s) | Action later | Reason |
|---|---|---|---|---|
| legacy v2 SourceRisk | `lib/event_sales/catalog/tickera_catalog/source_risk.ex` | — | preserve | operational + historical v2 |
| legacy v2 Normalizer | `lib/event_sales/catalog/tickera_catalog/normalizer.ex` | — | preserve operational path | live v2 unchanged |
| contract registry | — | `lib/event_sales/catalog/tickera_catalog/source_risk_v3/contract_registry.ex` | add | immutable v3 |
| evidence | — | `lib/event_sales/catalog/tickera_catalog/source_risk_v3/evidence.ex` | add | transport |
| canonical fact | — | `lib/event_sales/catalog/tickera_catalog/source_risk_v3/canonical_fact.ex` | add | identity |
| v3 normalizer | — | `lib/event_sales/catalog/tickera_catalog/source_risk_v3/normalizer.ex` | add | native only |
| finding policy | — | `lib/event_sales/catalog/tickera_catalog/source_risk_v3/finding_policy.ex` | add | dispositions |
| discovery integrity | — | `lib/event_sales/catalog/tickera_catalog/source_risk_v3/discovery_integrity.ex` | add | page/snapshot |
| v2 adapter | — | `lib/event_sales/catalog/tickera_catalog/source_risk_v3/compatibility/v2_adapter.ex` | add | historical review only |
| DiscoveryResult carrier (sole) | `lib/event_sales/catalog/tickera_catalog/discovery_result.ex` | same | extend only | sole v3 carrier |
| Durable findings | `lib/event_sales/ingestion/resources/tickera_catalog_sync_finding.ex` | same | reuse | plan + rows |
| Finding shape | `lib/event_sales/catalog/tickera_catalog/finding.ex` | same | reuse | shared |
| Discover worker | `lib/event_sales/ingestion/workers/discover_tickera_catalog_worker.ex` | same | skip v3 auto-eval; persist findings rows | review-only |
| feed response | `lib/event_sales/catalog/tickera_catalog/wordpress_feed_response.ex` | same | update | dual-mode parse |
| discovery source | `lib/event_sales/catalog/tickera_catalog/wordpress_feed_discovery_source.ex` | same | update | mode dispatch |
| feed client/signature | `lib/event_sales/catalog/tickera_catalog/wordpress_feed_client.ex`, `lib/event_sales/catalog/tickera_catalog/wordpress_feed_signature.ex` | same | preserve | transport |
| planner | `lib/event_sales/catalog/tickera_catalog/planner.ex` | same | update | plan.v2 and plan.v3 |
| snapshot canonicalizer | `lib/event_sales/catalog/tickera_catalog/snapshot_canonicalizer.ex` | same | update | add v3; keep v2 |
| Plan struct | `lib/event_sales/catalog/tickera_catalog/plan.ex` | same | update if needed | carry snapshot |
| AutoApplyPolicy | `lib/event_sales/catalog/tickera_catalog/auto_apply_policy.ex` | same | unchanged semantics | v2-only |
| AutoApply orchestration | `lib/event_sales/ingestion/tickera_catalog_auto_apply.ex` | same | regression | v2 |
| Sync | `lib/event_sales/ingestion/tickera_catalog_sync.ex` | same | reject v3 queue_apply | gate |
| Apply worker | `lib/event_sales/ingestion/workers/apply_tickera_catalog_worker.ex` | same | discard/reject v3 | no writes |
| Applier | `lib/event_sales/catalog/tickera_catalog/applier.ex` | same | explicit v3 denial | sole writer |
| Sync run resource | `lib/event_sales/ingestion/resources/tickera_catalog_sync_run.ex` | same | no migration | JSON snapshot |
| Admin UI | `lib/event_sales_web/live/admin/catalog_sync_live.ex` | same | hide Apply for v3 | UX |
| WP producer | `integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php` | same | native v3 + SnapshotGeneration | typed evidence |
| WP tests | `integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-feed-test.php`, `integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-change-trigger-test.php`, `integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-feed-contract.md` | same | extend | contract |
| Fixtures | `test/support/tickera_catalog_fixtures.ex` | same | extend | v2+v3 fixtures |

---

## 27. Persistence Matrix

| Resource | Persist? | Store | Version | Mutable? | Migration? | Retention |
|---|---|---|---|---|---|---|
| v2 operational plan | yes | `plan_snapshot` | `tickera_catalog_plan.v2` | no rewrite | no | historical |
| native RawProducerEvidence | preferably no full raw | bounded provenance only | v3 | run-scoped | no | bounded |
| CanonicalEvidenceFact | yes in plan.v3 | `plan_snapshot` | `source_risk.v3` inside plan.v3 | immutable when ready | no | audit |
| CompatibilityTranslationRecord | no MVP | computed | `compat.v2_to_source_risk_v3.v1` | n/a | no | computed |
| SnapshotGeneration | WP option | `eventsales_tickera_catalog_snapshot_generation` | opaque token | replace on invalidate | WP-side only | current generation |
| findings (plan) | yes | plan snapshot findings | v2 or v3 | finalized | no | audit |
| findings (durable rows) | yes | `ingestion_tickera_catalog_sync_findings` via `TickeraCatalogSyncFinding` | same codes/severity | recreated on retry | no | admin/query |

---

## 28. State-Machine / Flow Diagrams

### legacy_v2_operational

```text
live 2026-07-22.v2 pages
→ WordPressFeedResponse (legacy)
→ Normalizer + SourceRisk (legacy)
→ Planner
→ tickera_catalog_plan.v2
→ dry_run_ready
→ existing AutoApply evaluation enqueue
→ existing Human/Auto Apply semantics
```

### historical_v2_compatibility_review

```text
historical/persisted v2
→ validate
→ V2Adapter
→ compatibility-derived projection
→ human review only
→ never Apply proof
```

### native_v3_review

```text
2026-08-07.v3 pages
→ native parse + source key check (derive-only hash)
→ DiscoveryIntegrity (generation/snapshot/pages)
→ DiscoveryResult transport fields
→ SourceRiskV3.Normalizer → DiscoveryResult.canonical_source_risk_facts
→ SourceRiskV3.FindingPolicy → DiscoveryResult.canonical_source_risk_findings
→ Planner (read-only DiscoveryResult)
→ tickera_catalog_plan.v3
→ DiscoverTickeraCatalogWorker persists TickeraCatalogSyncFinding rows
→ dry_run_ready review-only
→ no AutoApply evaluation enqueue
→ queue_apply/Applier/worker Apply denied
```

### Apply

```text
tickera_catalog_plan.v2 → existing behaviour unchanged
tickera_catalog_plan.v3 → reject Apply; no catalogue writes
```

---

## 29. Phase 5C Scaffolding TOON

| Field | Content |
| --- | --- |
| Task | Design/implement the complete source-risk.v3 execution path from versioned producer evidence to review-only plan v3 while preserving live v2 operational behaviour and v2 history. |
| Objective | Enable future Phase 5D native-v3 dry-run without changing live v2 Apply semantics. |
| Output | Exact implementation slice map, files, dependencies, tests, rollout/cutover rules. |
| Note | Indexes: existing only / none new by default. Caching: WP transient cache_version separate from SnapshotGeneration. TTL: existing WP cache TTL bounds. Redis: none for source-risk. Invalidation: replace SnapshotGeneration token+at. PubSub: existing catalog preview notify only. Version rules: three modes exact. Security: fail closed. No Phase 5D fresh run. v3 Apply denied. |

Do not execute as implementation in this design task.

---

## 30. Granular TOON Micro-Prompts

### 5C-01 — Canonical v3 core

| Field | Content |
| --- | --- |
| Task | Implement SourceRiskV3 contract registry, evidence/canonical-fact structs, identity/equality helpers, finding-policy primitives, and pure normalizer helpers with unit tests. No production discovery cutover. No live v2 behaviour change. |
| Objective | Establish immutable compile-time source_risk.v3 core so later slices cannot invent dimensions/states/scopes. |
| Output | Create `lib/event_sales/catalog/tickera_catalog/source_risk_v3/contract_registry.ex`, `lib/event_sales/catalog/tickera_catalog/source_risk_v3/evidence.ex`, `lib/event_sales/catalog/tickera_catalog/source_risk_v3/canonical_fact.ex`, `lib/event_sales/catalog/tickera_catalog/source_risk_v3/normalizer.ex`, `lib/event_sales/catalog/tickera_catalog/source_risk_v3/finding_policy.ex`. Create `test/event_sales/catalog/tickera_catalog/source_risk_v3/contract_registry_test.exs`, `test/event_sales/catalog/tickera_catalog/source_risk_v3/canonical_fact_test.exs`, `test/event_sales/catalog/tickera_catalog/source_risk_v3/normalizer_test.exs`, `test/event_sales/catalog/tickera_catalog/source_risk_v3/finding_policy_test.exs`. Dependency: none. |
| Note | Minimal tools: git, rg, mix format, mix test with the exact test paths above. Indexes: none. Caching: none. TTL: n/a. Redis: none. Invalidation: none. PubSub: none. Security: closed registries; no dynamic atoms; fail closed on unknown ids; empty native safe-negative allowlist. Performance: pure in-memory; no DB. Phase 5D: `bash scripts/dev_local.sh catalogue-dry-run --fresh` forbidden. PR: own fresh branch from main + draft PR. STOP: if domain semantics must be redesigned; if live v2 modules are modified; if Redis/Cachex/GenServer introduced; if safe-negative allowlist non-empty. |

### 5C-02 — Historical v2 compatibility adapter

| Field | Content |
| --- | --- |
| Task | Implement compat.v2_to_source_risk_v3.v1 pure adapter for historical_v2_compatibility_review only, with source_emitter rules and Gate D hardening tests. Do not route live operational v2 through this adapter. |
| Objective | Provide certainty-monotonic historical projection without rewriting v2 snapshots or changing live v2 Apply. |
| Output | Create `lib/event_sales/catalog/tickera_catalog/source_risk_v3/compatibility/v2_adapter.ex`. Create `test/event_sales/catalog/tickera_catalog/source_risk_v3/compatibility/v2_adapter_test.exs`. Dependency: 5C-01 merged. |
| Note | Minimal tools: git, rg, mix format, mix test test/event_sales/catalog/tickera_catalog/source_risk_v3/compatibility/v2_adapter_test.exs. Indexes: none. Caching: none. TTL: n/a. Redis: none. Invalidation: none. PubSub: none. Security: bounded provenance; never invent erased codes; origin=compatibility_derived; automation-ineligible. Performance: pure bounded compute. Phase 5D: catalogue-dry-run --fresh forbidden. PR: own fresh branch + draft PR. STOP: if adapter becomes live operational path; if certainty strengthened; if payment_plan_product aliases payment_plan; if v2 snapshots rewritten. |

### 5C-03 — Dual-mode ingestion and DiscoveryResult carrier

| Field | Content |
| --- | --- |
| Task | Add exact schema dispatch that preserves legacy_v2_operational unchanged and adds native_v3_review parsing, DiscoveryIntegrity, and FINAL extended DiscoveryResult carrier fields filled by Normalizer/FindingPolicy ownership. Unknown/mixed versions fail closed. No adjacent carrier structs. |
| Objective | Make Phoenix dual-mode: live v2 stays v2; native v3 is parsed and carried solely via DiscoveryResult without hidden side channels. |
| Output | Update `lib/event_sales/catalog/tickera_catalog/wordpress_feed_response.ex`, `lib/event_sales/catalog/tickera_catalog/wordpress_feed_discovery_source.ex`, `lib/event_sales/catalog/tickera_catalog/discovery_result.ex`. Create `lib/event_sales/catalog/tickera_catalog/source_risk_v3/discovery_integrity.ex`. Update/create tests: `test/event_sales/catalog/tickera_catalog/wordpress_feed_response_test.exs`, `test/event_sales/catalog/tickera_catalog/wordpress_feed_discovery_source_test.exs`, `test/event_sales/catalog/tickera_catalog/discovery_result_test.exs`, `test/event_sales/catalog/tickera_catalog/source_risk_v3/discovery_integrity_test.exs`. Dependency: 5C-01 and 5C-02 merged. |
| Note | Minimal tools: git, rg, mix format, mix test test/event_sales/catalog/tickera_catalog/wordpress_feed_response_test.exs test/event_sales/catalog/tickera_catalog/wordpress_feed_discovery_source_test.exs test/event_sales/catalog/tickera_catalog/discovery_result_test.exs test/event_sales/catalog/tickera_catalog/source_risk_v3/discovery_integrity_test.exs. Indexes: none. Caching: none. TTL: n/a. Redis: none. Invalidation: none. PubSub: none. Security: exact envelope keys; derive-only source_system_id verify (`wordpress_tickera:`+sha256(normalize_url(base_url))); reject unknown/mixed/mismatch; transport validation only. Performance: page-bounded aggregation; no unbounded catalogue load. Phase 5D: catalogue-dry-run --fresh forbidden. PR: own fresh branch + draft PR. STOP: if live v2 is routed through V2Adapter; if DiscoveryResult v2 fields change semantics; if an adjacent carrier struct is introduced; if parser assigns severity/authority; if WP producer is cut over in this slice; if source-key overrides are added. |

### 5C-04 — Planner plan.v3 review-only, durable findings, Apply denial

| Field | Content |
| --- | --- |
| Task | Wire planner/snapshot canonicalizer to emit tickera_catalog_plan.v3 for native_v3_review; persist findings into both plan.v3 and existing TickeraCatalogSyncFinding rows via DiscoverTickeraCatalogWorker; keep tickera_catalog_plan.v2 operational path unchanged; skip AutoApply evaluation enqueue for v3; deny Human Apply, Applier, and Apply worker for v3. |
| Objective | Produce reviewable native-v3 dry-runs with durable findings, no Apply writes, and no AutoApply evaluation jobs. |
| Output | Update `lib/event_sales/catalog/tickera_catalog/planner.ex`, `lib/event_sales/catalog/tickera_catalog/snapshot_canonicalizer.ex`, `lib/event_sales/catalog/tickera_catalog/applier.ex`, `lib/event_sales/ingestion/tickera_catalog_sync.ex`, `lib/event_sales/ingestion/workers/discover_tickera_catalog_worker.ex`, `lib/event_sales/ingestion/workers/apply_tickera_catalog_worker.ex`, `lib/event_sales_web/live/admin/catalog_sync_live.ex`. Reuse without schema migration: `lib/event_sales/ingestion/resources/tickera_catalog_sync_finding.ex`. Update tests: `test/event_sales/catalog/tickera_catalog/snapshot_canonicalizer_test.exs`, `test/event_sales/catalog/tickera_catalog/planner_applier_test.exs`, `test/event_sales/catalog/tickera_catalog/auto_apply_policy_test.exs`, `test/event_sales/ingestion/tickera_catalog_auto_apply_test.exs`, `test/event_sales/ingestion/workers/discover_tickera_catalog_worker_test.exs`, `test/event_sales/ingestion/workers/apply_tickera_catalog_worker_test.exs`, `test/event_sales/ingestion/tickera_catalog_sync_test.exs`, `test/event_sales/ingestion/resources/tickera_catalog_sync_finding_test.exs`. Dependency: 5C-03 merged. |
| Note | Minimal tools: git, rg, mix format, mix test test/event_sales/catalog/tickera_catalog/snapshot_canonicalizer_test.exs test/event_sales/catalog/tickera_catalog/planner_applier_test.exs test/event_sales/catalog/tickera_catalog/auto_apply_policy_test.exs test/event_sales/ingestion/tickera_catalog_auto_apply_test.exs test/event_sales/ingestion/workers/discover_tickera_catalog_worker_test.exs test/event_sales/ingestion/workers/apply_tickera_catalog_worker_test.exs test/event_sales/ingestion/tickera_catalog_sync_test.exs test/event_sales/ingestion/resources/tickera_catalog_sync_finding_test.exs. Indexes: none new. Caching: existing Cache.put_preview may store v3 preview bytes; not authority. TTL: n/a. Redis: none for source-risk. Invalidation: none new. PubSub: existing catalog_sync_preview_ready notify only. Security: explicit unsupported_snapshot_version before writes; no catalogue mutation on v3 Apply paths; finding codes ≤120 chars; metadata bounded; severity maps to info/warning/blocking. Performance: deterministic ordering before hash; no N+1 introduced. Required proofs: v2 ready → auto-eval enqueue unchanged; v3 ready → no EvaluateTickeraCatalogAutoApplyWorker; v3 findings present in plan.v3 and TickeraCatalogSyncFinding rows; queue_apply(v3) rejected; Applier(v3) returns unsupported_snapshot_version; Apply worker(v3) zero writes and does not mark applied; no DB migration. Phase 5D: catalogue-dry-run --fresh forbidden. PR: own fresh branch + draft PR. STOP: if v3 serializes as plan.v2; if v3 AutoApply evaluation is enqueued; if v3 Apply can write; if a second finding table/migration is introduced without separate review; if AutoApplyPolicy semantics weaken; if live v2 Apply changes. |

### 5C-05 — Native WordPress 2026-08-07.v3 producer

| Field | Content |
| --- | --- |
| Task | Upgrade WP feed to emit native typed evidence with complete envelope, producer_version=2026-08-07.1, derive-only source_system_id hash, SnapshotGeneration opaque token+generation_at, generation-tied source_snapshot_at, mid-page generation check, discovery_snapshot_id excluding page/per_page, and native bounds per_page<=100 and evidence.length<=500. |
| Objective | Provide authoritative native producer evidence only after Phoenix dual-mode + plan.v3 review-only support exists. |
| Output | Update `integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php`, `integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-feed-contract.md`, `integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-feed-test.php`, `integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-change-trigger-test.php`. Dependency: 5C-04 merged. |
| Note | Minimal tools: git, rg, php integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-feed-test.php, php integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-change-trigger-test.php. Indexes: none. Caching: keep CACHE_VERSION_OPTION for transients only; SnapshotGeneration is separate contract identity. TTL: existing MIN/DEFAULT/MAX cache TTL bounds unchanged conceptually for transients. Redis: none. Invalidation: every catalogue-relevant invalidate replaces SnapshotGeneration with new opaque token+generation_at; also bumps transient cache version. PubSub: none. Security: no secrets in source key; no SOURCE_KEY override; bounded strings; typed evidence primary; legacy risk strings non-authoritative if retained. Performance: page build with before/after generation read; fail/retry on mid-page change; native per_page<=100; evidence<=500/page (do not inherit legacy MAX_PER_PAGE=500 for v3). Required contract tests: per_page 100 accepted / 101 rejected; evidence 500 accepted / 501 rejected. Legacy 2026-07-22.v2 behaviour unchanged until cutover. Phase 5D: catalogue-dry-run --fresh forbidden. PR: own fresh branch + draft PR. STOP: if deployed before Phoenix 5C-04; if source_snapshot_at uses request time; if arithmetic cache version is used as discovery_snapshot_id; if page/per_page enter discovery identity; if native per_page>100 or evidence>500; if producer_version invents a value other than 2026-08-07.1; if source-key override is added. |

### 5C-06 — Regression/security/performance closure

| Field | Content |
| --- | --- |
| Task | Close cross-mode regressions proving live v2 unchanged, historical adapter review-only, native v3 review-only, DiscoveryResult-only carrier, durable TickeraCatalogSyncFinding persistence, Apply/AutoApply denial, native page bounds, deterministic hashes, security bounds, and generation/filter identity tests. |
| Objective | Prove Phase 5C is fail-closed and ready to hand off to Phase 5D without consuming the reserved fresh dry-run. |
| Output | Extend/add exactly these test files: `test/event_sales/catalog/tickera_catalog/source_risk_v3/contract_registry_test.exs`, `test/event_sales/catalog/tickera_catalog/source_risk_v3/canonical_fact_test.exs`, `test/event_sales/catalog/tickera_catalog/source_risk_v3/normalizer_test.exs`, `test/event_sales/catalog/tickera_catalog/source_risk_v3/finding_policy_test.exs`, `test/event_sales/catalog/tickera_catalog/source_risk_v3/discovery_integrity_test.exs`, `test/event_sales/catalog/tickera_catalog/source_risk_v3/compatibility/v2_adapter_test.exs`, `test/event_sales/catalog/tickera_catalog/wordpress_feed_response_test.exs`, `test/event_sales/catalog/tickera_catalog/wordpress_feed_discovery_source_test.exs`, `test/event_sales/catalog/tickera_catalog/discovery_result_test.exs`, `test/event_sales/catalog/tickera_catalog/snapshot_canonicalizer_test.exs`, `test/event_sales/catalog/tickera_catalog/planner_applier_test.exs`, `test/event_sales/ingestion/tickera_catalog_auto_apply_test.exs`, `test/event_sales/ingestion/tickera_catalog_sync_test.exs`, `test/event_sales/ingestion/workers/discover_tickera_catalog_worker_test.exs`, `test/event_sales/ingestion/workers/apply_tickera_catalog_worker_test.exs`, `test/event_sales/ingestion/resources/tickera_catalog_sync_finding_test.exs`, `integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-feed-test.php`, `integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-change-trigger-test.php`, `integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-feed-contract.md`. Dependency: 5C-01 through 5C-05 merged. |
| Note | Minimal tools: git, rg, mix format, mix test test/event_sales/catalog/tickera_catalog/source_risk_v3/contract_registry_test.exs test/event_sales/catalog/tickera_catalog/source_risk_v3/canonical_fact_test.exs test/event_sales/catalog/tickera_catalog/source_risk_v3/normalizer_test.exs test/event_sales/catalog/tickera_catalog/source_risk_v3/finding_policy_test.exs test/event_sales/catalog/tickera_catalog/source_risk_v3/discovery_integrity_test.exs test/event_sales/catalog/tickera_catalog/source_risk_v3/compatibility/v2_adapter_test.exs test/event_sales/catalog/tickera_catalog/wordpress_feed_response_test.exs test/event_sales/catalog/tickera_catalog/wordpress_feed_discovery_source_test.exs test/event_sales/catalog/tickera_catalog/discovery_result_test.exs test/event_sales/catalog/tickera_catalog/snapshot_canonicalizer_test.exs test/event_sales/catalog/tickera_catalog/planner_applier_test.exs test/event_sales/ingestion/tickera_catalog_auto_apply_test.exs test/event_sales/ingestion/tickera_catalog_sync_test.exs test/event_sales/ingestion/workers/discover_tickera_catalog_worker_test.exs test/event_sales/ingestion/workers/apply_tickera_catalog_worker_test.exs test/event_sales/ingestion/resources/tickera_catalog_sync_finding_test.exs, php integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-feed-test.php, php integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-change-trigger-test.php. Indexes: none new. Caching: none new. TTL: n/a. Redis: none. Invalidation: none new. PubSub: none new. Security: envelope/provenance/Apply denial/source_system_id mismatch regressions must pass. Performance: no unbounded fixtures; assert native per_page<=100 and evidence<=500 bounds. Phase 5D: catalogue-dry-run --fresh forbidden. PR: own fresh branch + draft PR then STOP Phase 5C. STOP: if any test requires production WordPress mutation; if Apply guards weaken; if live v2 operational assertions regress; if Phase 5D fresh run is invoked; if this TOON must consult another TOON for file names. |

---

## 31. Deployment Ordering

```text
5C-01 → 5C-02 → 5C-03 → 5C-04 → 5C-05 → 5C-06
```

Hard rule:

```text
Phoenix dual-mode + plan.v3 review-only + Apply denial MUST land before WP emits 2026-08-07.v3.
```

If WP emits v3 too early: Phoenix fail closed on unknown/unsupported schema (until 5C-03/04 present).

Rollback: keep WP on `2026-07-22.v2`; live operational path unchanged.

---

## 32. Risk Review

| Risk | Mitigation |
|---|---|
| Live v2 cutover via adapter | three-mode lock; 5C-03/04 tests |
| False-safe evidence | empty safe-negative allowlist |
| Apply safety regression | skip auto-eval; explicit denials at Sync/Applier/worker |
| Snapshot instability | opaque SnapshotGeneration + mid-page check |
| Version skew | Phoenix before WP |
| Compatibility as native | origin + automation-ineligible |
| DiscoveryResult side channels | sole extended DiscoveryResult; no adjacent carrier |
| Source UUID coupling | derive-only hash bind; no Phase 5C override |
| Durable findings drift | plan.v3 + TickeraCatalogSyncFinding both required |
| Phase 5D consumed early | forbidden --fresh |

---

## 33. Success Criteria

An implementation agent must answer without guessing:

```text
Which mode am I in? → legacy_v2_operational | historical_v2_compatibility_review | native_v3_review
Does live v2 use the adapter? → NO
Which snapshot do I write? → plan.v2 or plan.v3 per mode
Is DB migration needed? → NO
Can v3 Apply? → NO
Is v3 AutoApply evaluation enqueued? → NO
What is producer_version? → 2026-08-07.1
How is source_system_id produced/verified? → §11 algorithm
How is discovery_snapshot_id built? → §13
What does DiscoveryResult carry? → §12 sole carrier fields
Who writes facts/findings onto it? → Normalizer / FindingPolicy only
Where do durable findings land? → plan.v3 AND TickeraCatalogSyncFinding
Is source-key override in Phase 5C? → NO
Native per_page / evidence bounds? → 100 / 500
Which PR next? → next unmet 5C-0N
When STOP? → after 5C-06; no Phase 5D in 5C
```

### Explicit design decisions

| Decision | Lock |
|---|---|
| Live v2 path | operational unchanged; not via adapter |
| Historical adapter | review-only |
| Plan snapshot native | `tickera_catalog_plan.v3` |
| DB migration | NO |
| Human Apply v3 | denied |
| AutoApply evaluate v3 | not enqueued |
| AutoApplyPolicy | unchanged v2-only |
| DiscoveryResult | sole extended carrier; FINAL |
| Adjacent carrier structs | forbidden |
| Durable findings | plan snapshot + TickeraCatalogSyncFinding |
| SnapshotGeneration | opaque token + generation_at |
| source_snapshot_at | generation_at |
| Filters in identity | exclude page/per_page |
| producer_version first value | `2026-08-07.1` |
| source_system_id | derive-only hash; no override in Phase 5C |
| Native per_page max | 100 |
| Native evidence/page max | 500 |
| Redis for source-risk | none |
| Phase 5D --fresh in 5C | forbidden |

No remaining `BLOCKING DESIGN DECISION` for these cutover questions.

---

## 34. Invariants

```text
do not redesign locked Phase 5B semantics
preserve legacy SourceRisk + Normalizer for live v2
live v2 operational != historical compatibility review
live v2 must not be routed through V2Adapter as replacement path
native v3 output uses tickera_catalog_plan.v3 only
never serialize new semantics under tickera_catalog_plan.v2
no historical v2 rewrite
compatibility_derived != native automation proof
native safe-negative allowlist empty
v3 AutoApply evaluation not enqueued in Phase 5C
v3 AutoApply denied
v3 Human Apply denied
direct v3 Apply worker performs zero writes
no variation auto-Apply
Applier sole catalogue writer
Phoenix before WP v3 deploy
no Phase 5D --fresh during Phase 5C
no Redis/Cachex/GenServer for source-risk vocabulary
exact version/mode dispatch only
source_snapshot_at is generation-tied
page/per_page excluded from discovery identity
DiscoveryResult is the sole v3 carrier
no adjacent result struct / side-channel carrier
Normalizer owns canonical_source_risk_facts
FindingPolicy owns canonical_source_risk_findings
v3 findings persist in plan.v3 and TickeraCatalogSyncFinding
source_system_id is derive-only hash in Phase 5C (no override)
native per_page <= 100
native evidence per page <= 500
```

---

## 35. Gate / Acceptance for This Design PR

Reviewers confirm:

- three modes are unambiguous and live v2 stays operational
- native envelope includes producer_version + derive-only source_system_id
- DiscoveryResult is the sole FINAL v3 carrier with locked field ownership
- durable findings use plan.v3 + TickeraCatalogSyncFinding (no new table/migration)
- SnapshotGeneration is exact (opaque token, not arithmetic identity)
- native per_page≤100 and evidence≤500 are locked
- v3 AutoApply evaluation skipped; Apply denied at all boundaries
- all six TOONs are fully expanded with tools/tests/PR/STOP and mandatory Note fields
- 5C-06 enumerates exact files without consulting other TOONs
- no implementation code included

---

## Document control

| Item | Value |
|---|---|
| Next after merge | Implementation agents execute 5C-01…5C-06 as separate PRs |
| Forbidden until then | implementation code; Phase 5D dry-run; Apply unlock; live v2 cutover via adapter |

End of Phase 5C implementation boundary.
