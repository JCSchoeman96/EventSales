# Phase 5C — Source-Risk Implementation Boundary

| Field | Value |
|---|---|
| Plan / document ID | `phase-5c-source-risk-implementation-boundary` |
| Document version | `v1` |
| Status | Draft for independent Phase 5C boundary review |
| Scope | Implementation boundary, module ownership, tests, PR slices, and cutover rules for merged Phase 5B contracts — **design only** |
| Authority | Subordinate to locked Phase 5B domain model, native contract, and v2 compatibility adapter |
| Locked domain model | `docs/phase-5b/source-risk-domain-model.md` — SHA256 `16563ee02f58a12d2fde1e6995da3cb4d1be89dfd9ecbb8e07eb76ba5d8a6375` |
| Locked native contract | `docs/phase-5b/source-risk-contract.md` — SHA256 `87dec4238e5c7ea04fe8d2a9735980a35f2bf542324a851686d60fead1d0785c` |
| Locked v2 adapter | `docs/phase-5b/v2-compatibility-adapter.md` — SHA256 `8236b6c1ddcd908a9a602f9b25bbe248323f3e117b20f63410e5cf348aaf30f5` |
| Base main | `b384ed48f0cd644005e7762c496f341a0d7269de` |
| Last updated | 2026-08-07 |
| Change summary | Initial Phase 5C implementation boundary after Gate D merge |

### Revision log

- `v1` — initial implementation boundary after PR #153 merge

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
read-only compatibility interpretation of v2,
and a new dry-run snapshot,
without weakening Apply safety or rewriting v2 history.
```

### Phase 5D success dependency (reserved)

```text
exactly one fresh native-v3 end-to-end dry-run
→ deterministic reviewable plan
→ no false-safe evidence
→ no oversold/automatic variation behaviour
→ independent Phase 5E review
```

### Backward dependency map (required before Phase 5D)

| Dependency | Why required before Phase 5D |
|---|---|
| Immutable `source_risk.v3` ContractRegistry + structs | Typed canonical model without guessing |
| Finding-policy + conflict pipeline | Correct blocking/safe dispositions |
| Dual-version Phoenix ingestion | Fail closed on unknown/mixed versions |
| `compat.v2_to_source_risk_v3.v1` adapter | Historical review without rewriting v2 |
| Stable WP discovery snapshot identity | Reject mid-discovery source change |
| Bounded page aggregation | Deterministic multi-page finalization |
| Planner consumes canonical facts | No raw risk-string authority |
| `tickera_catalog_plan.v3` snapshot + hash | Separate from immutable v2 |
| Explicit v3 Apply denial | Preserve Apply safety during Phase 5C |
| Native WP `2026-08-07.v3` producer | Typed evidence primary |
| Contract/regression tests | Prove fail-closed cutover |

---

## 3. Locked Conceptual Resources → Concrete Ownership

Do **not** redesign domain semantics. Map locked concepts to modules:

| Concept | Responsible module | File path | Input | Output | Owns validation? | Owns policy? | Persistence? | Layer |
|---|---|---|---|---|---|---|---|---|
| ContractRegistry | `SourceRiskV3.ContractRegistry` | `lib/event_sales/catalog/tickera_catalog/source_risk_v3/contract_registry.ex` | compile-time tables from locked contract | lookup/reject | yes (closed ids) | no | none | hot code |
| RawProducerEvidence | `SourceRiskV3.Evidence` (+ parser) | `…/source_risk_v3/evidence.ex` | wire page/evidence maps | validated evidence structs | transport only | no | optional bounded run refs only | warm/run |
| CanonicalEvidenceFact | `SourceRiskV3.CanonicalFact` | `…/source_risk_v3/canonical_fact.ex` | validated evidence / adapter output | fact structs + identity | identity/equality | no | via plan snapshot | cold |
| CompatibilityTranslation | `SourceRiskV3.Compatibility.V2Adapter` | `…/source_risk_v3/compatibility/v2_adapter.ex` | historical v2 inputs | translation records + candidates | Gate D rules | no | preferably none (computed) | cold compute |
| SourceRiskFinding | `SourceRiskV3.FindingPolicy` → existing `Finding` shape | `…/source_risk_v3/finding_policy.ex` + `lib/event_sales/catalog/tickera_catalog/finding.ex` | facts/errors | dispositioned findings | disposition codes | yes | plan snapshot | cold |
| PlannerDecision / PlannerAction | `Planner` | `lib/event_sales/catalog/tickera_catalog/planner.ex` | canonical facts/findings + rows | decisions/actions + plan | planner structural | planner status | plan snapshot | cold |
| EvidenceState / Completeness / Scope / Dimension / Authority | ContractRegistry enums | same registry module | atoms/strings | closed sets | yes | no | none | hot code |
| Discovery integrity | `SourceRiskV3.DiscoveryIntegrity` | `…/source_risk_v3/discovery_integrity.ex` | page envelopes | accept/reject mixed discovery | integrity | no | run aggregation state | warm/run |
| Native normalizer | `SourceRiskV3.Normalizer` | `…/source_risk_v3/normalizer.ex` | validated evidence | canonical candidates | semantic construction | no | none alone | cold compute |
| Legacy v2 SourceRisk | `SourceRisk` | `lib/event_sales/catalog/tickera_catalog/source_risk.ex` | historical | v2 facts | legacy only | legacy | historical snapshots | preserve |

---

## 4. Proposed Module Namespace and Folder Structure

### Namespace lock

```text
EventSales.Catalog.TickeraCatalog.SourceRiskV3
```

Reason: mirrors existing `TickeraCatalog.*` ownership; avoids colliding with historical `SourceRisk` v2 module; keeps catalogue domain cohesive.

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

### Module challenge / merge decisions

| Proposed module | Keep separate? | Reason |
|---|---|---|
| `contract_registry.ex` | yes | immutable compile-time closed tables |
| `evidence.ex` | yes | transport structs vs semantic facts |
| `canonical_fact.ex` | yes | identity/equality/claim helpers |
| `normalizer.ex` | yes | constructs facts; must not own severity |
| `finding_policy.ex` | yes | disposition/severity ownership |
| `discovery_integrity.ex` | yes | page/snapshot/version fail-closed |
| `compatibility/v2_adapter.ex` | yes | Gate D isolation; never native |

Avoid: generic rule engines, behaviour-heavy DI, runtime vocabulary GenServers, one-module-per-enum, metaprogrammed registries.

Prefer: immutable maps/constants, small structs, pure functions, explicit pattern matching, version dispatch, closed registries.

### Legacy preservation

```text
EventSales.Catalog.TickeraCatalog.SourceRisk
```

remains historical v2 behaviour.

Do **not** rename it, reinterpret it as `source_risk.v3`, or silently migrate its persisted meaning.

---

## 5. Version Dispatch

Exact entry routing (no guessing):

```text
producer/page schema_version
→ exact parser
→ exact normalization mode
```

| Producer schema | Parser | Normalization | Origin |
|---|---|---|---|
| `2026-08-07.v3` | native v3 parser (extend `WordPressFeedResponse` / discovery source) | `SourceRiskV3.Normalizer` | `native` |
| `2026-07-22.v2` | existing legacy parser | `SourceRiskV3.Compatibility.V2Adapter` → then `source_risk.v3` validation | `compatibility_derived` |
| unknown | reject | — | — |
| mixed versions in one discovery | reject | — | — |

Forbidden:

```text
"latest"
string-prefix guessing
fallback-to-newest
best-effort mixed schema interpretation
```

Primary dispatch owner:

```text
lib/event_sales/catalog/tickera_catalog/wordpress_feed_discovery_source.ex
+ lib/event_sales/catalog/tickera_catalog/wordpress_feed_response.ex
+ SourceRiskV3.DiscoveryIntegrity
```

---

## 6. Raw Producer Evidence Boundary

Parser (`WordPressFeedResponse` / v3 evidence decode in `SourceRiskV3.Evidence`) may validate only:

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

Parser must **not** decide:

```text
semantic authority
safe/risky disposition
scope correction
finding severity
automation eligibility
```

`SourceRiskV3.Normalizer` owns construction of canonical facts.

---

## 7. ContractRegistry Implementation Boundary

One immutable compile-time registry in:

```text
lib/event_sales/catalog/tickera_catalog/source_risk_v3/contract_registry.ex
```

Contains locked contract tables for:

```text
dimensions
scopes
states
completeness
authorities
authority slots
allowed values (incl. product_type = simple only for MVP)
dispositions
finding ownership namespaces
producer→canonical bindings
native safe-negative allowlist = EMPTY
```

```text
No DB
No Redis
No Cachex
No GenServer
No runtime admin mutation
```

Registry changes require code review + contract/version change when semantic.

---

## 8. Canonical Fact Identity and Conflict Pipeline

Identity (locked):

```text
run/discovery
+ dimension
+ semantic_scope
+ canonical target
+ authority slot/group
```

Never include in identity:

```text
state
value
legacy code
finding code
translation_rule_id
source_emitter
```

Ownership:

| Concern | Owner |
|---|---|
| Fact identity generation | `SourceRiskV3.CanonicalFact` |
| Semantic equality | `SourceRiskV3.CanonicalFact` |
| Duplicate collapse | `SourceRiskV3.Normalizer` (or small helper in CanonicalFact used by Normalizer) |
| Conflict detection | same |
| Provenance merge | same (bounded refs only) |
| Known lossy derivative handling | `Compatibility.V2Adapter` + Normalizer conflict stage |

Pipeline:

```text
validated observation
→ canonical candidate
→ identity
→ semantic claim
→ duplicate/conflict resolution
→ disposition
→ finding
```

Rules:

```text
same identity + same claim → collapse + retain bounded provenance
same identity + genuinely conflicting claim → blocking_conflict
known lossy derivative (Gate D) → precedence; not manufactured conflict
```

Deterministic ordering before hash:

```text
dimension
scope
canonical target
authority slot
origin
state
value
completeness
```

---

## 9. Finding-Policy Boundary

Owner:

```text
lib/event_sales/catalog/tickera_catalog/source_risk_v3/finding_policy.ex
```

Maps facts/errors to dispositions:

```text
safe_positive_proof
safe_negative_proof
blocking_unknown
blocking_missing
blocking_unsupported
blocking_invalid
blocking_error
blocking_conflict
blocking_contract_error
explicit_risk
not_applicable
```

Locks:

```text
native v3 safe-negative allowlist = EMPTY
safe proof is dimension-local only
never imply row/target/plan/run/Apply safety from one safe fact
severity not encoded in raw codes/state enums
```

Finding wire shape continues through existing:

```text
lib/event_sales/catalog/tickera_catalog/finding.ex
```

---

## 10. Compatibility Adapter Implementation Boundary

Owner:

```text
lib/event_sales/catalog/tickera_catalog/source_risk_v3/compatibility/v2_adapter.ex
```

Implement Gate D as:

```text
immutable translation registry
+ small pure translation functions
```

Locks:

```text
compat.v2_to_source_risk_v3.v1
origin=compatibility_derived always
automation-ineligible always
source_emitter-specific rules
draft_event emitter split
missing_source_risk_data owner split
draft_product ambiguity
event_link null-status ambiguity
payment_plan_product rejection
product_type closed registry
parent/variation regrouping
representation precedence vs genuine conflict
MVP = computed read model (no required persistence)
```

No dynamic rules engine. No Redis.

---

## 11. Native WordPress v3 Producer Boundary

Path:

```text
integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php
integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-feed-contract.md
integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-feed-test.php
```

Must emit:

```text
schema_version = 2026-08-07.v3
canonical_contract_version = source_risk.v3
typed evidence[]
stable discovery_snapshot_id / generation identity
source_snapshot_at tied to generation (not request clock alone)
```

Native typed evidence is primary.

Legacy flat `risk_codes` / `review_reasons` strings must **not** remain an authority source for native v3 Phoenix normalization.

If retained temporarily for human diagnostics only:

```text
non-authoritative compatibility/debug output
Phoenix native normalization ignores them for canonical proof
```

Do not create two competing source-risk truths.

---

## 12. WordPress Discovery Snapshot Integrity

### Current static proof

- Cache key includes `CACHE_VERSION_OPTION` + schema + params (`cache_key/1`).
- `invalidate_cache/0` increments option on product/event/meta/status changes.
- Response currently sets `source_snapshot_at` and `generated_at` from **request-time** `utc_now()` in `build_response/1`.
- Cache version is **not** currently emitted in the response envelope.

### Decision (required for native v3)

Preferred minimal strategy:

```text
stable source-generation = CACHE_VERSION_OPTION (or equivalent generation counter)
+ normalized discovery filter identity
→ deterministic discovery_snapshot_id
source_snapshot_at tied to that generation (or first materialization of that generation)
```

Required invariant:

```text
if relevant source data changes between pages
→ generation/snapshot identity changes
→ Phoenix DiscoveryIntegrity rejects the mixed discovery
```

### Implementation requirement (5C-05)

WP v3 response envelope must include explicit:

```text
discovery_snapshot_id
generation / cache_version
source_snapshot_at (generation-tied)
```

Phoenix must reject:

```text
page N with different discovery_snapshot_id than page 1
duplicate page numbers
gaps
mixed schema_version
```

### Honesty rule

If implementation cannot prove generation-tied timestamps and invalidation coverage for all relevant mutations:

```text
do NOT claim exhaustive native completeness
completeness remains partial/unknown
automation remains impossible
```

Never fake snapshot stability merely to pass the contract.

Current invalidation hooks cover product/variation/event save/status/meta/trash/restore/delete for catalogue-relevant keys — sufficient baseline for generation bump; still insufficient without emitting generation into the page envelope and tying `source_snapshot_at` to it.

---

## 13. Page Processing / Memory Boundary

Native bounds (from locked contract):

```text
≤ 100 catalog rows/page
≤ 500 evidence items/page
```

Preferred processing:

```text
validate page
→ canonicalize bounded evidence
→ incrementally aggregate run state
→ deterministic finalization
```

Do not load an unbounded catalogue into one process solely to normalize evidence.

Cross-page conflict detection may use existing run-scoped aggregation in discovery worker memory + finalized `plan_snapshot` map.

```text
Redis: none for this path
Cachex: none
GenServer: none new
```

Existing `TickeraCatalog.Cache` / Postgres-only adapter remain preview helpers; do not make them source-risk authority.

---

## 14. Plan Snapshot Version Lock

```text
native source_risk.v3 dry-run output
→ tickera_catalog_plan.v3
```

Historical:

```text
tickera_catalog_plan.v2
```

remains immutable and readable.

Minimal v3 snapshot shape must include:

```text
snapshot_schema_version = tickera_catalog_plan.v3
producer_contract_version
canonical_contract_version = source_risk.v3
discovery_snapshot_id
origin
canonical source-risk facts
findings
planner decisions/actions (existing action namespaces as applicable)
deterministic dry_run_hash
```

Owners:

```text
lib/event_sales/catalog/tickera_catalog/planner.ex
lib/event_sales/catalog/tickera_catalog/snapshot_canonicalizer.ex
```

`SnapshotCanonicalizer` today is closed for `tickera_catalog_plan.v2` — Phase 5C must add an explicit v3 canonicalization path without altering v2 bytes/hashes.

---

## 15. Persistence / DB Decision

Inspected storage:

```text
lib/event_sales/ingestion/resources/tickera_catalog_sync_run.ex
attribute :plan_snapshot, :map
attribute :dry_run_hash, :string
```

### Does `tickera_catalog_plan.v3` require a DB migration?

```text
NO
```

Existing JSON/map snapshot storage already versioned by `snapshot_schema_version` inside the document. Schema version change alone does not require a migration.

No historical v2 row may be rewritten.

CompatibilityTranslationRecord: preferably **not** persisted for MVP.

---

## 16. Index Review

| Query path | Existing index | New index? |
|---|---|---|
| Sync run by id / status / source | existing run identities/status filters | no |
| Auto-apply decision by run/hash/policy | `tickera_auto_apply_decision_identity_idx` etc. | no |
| Catalogue source-risk discovery | no large order/sales table scans | no |
| Admin run list | existing | no |

No new index without a demonstrated critical query path in an implementation PR.

Source-risk discovery must not trigger catalogue-wide peak table scans of orders/transactions.

---

## 17. Apply Boundary (critical)

Phase 5C builds:

```text
native-v3 discovery → normalization → planning → dry-run → human review
```

Phase 5C does **not** unlock native-v3 Apply.

### AutoApply

```text
current AutoApplyPolicy remains unchanged
@policy_version = conservative_auto_apply.v1
@snapshot_version = tickera_catalog_plan.v2
```

Path:

```text
lib/event_sales/catalog/tickera_catalog/auto_apply_policy.ex
lib/event_sales/ingestion/tickera_catalog_auto_apply.ex
```

Already fail-closed on unsupported snapshot version (`:unsupported_snapshot_version`). Keep that behaviour. Add regression tests that `tickera_catalog_plan.v3` is ineligible. Do not weaken policy.

Variations remain ineligible for automatic Apply.

### Human Apply — Phase 5C decision

```text
A — Phase 5C v3 plans are dry-run/review-only; all Apply rejected
```

Recommended and **locked** for Phase 5C.

Explicit denial owners (implementation later):

```text
lib/event_sales/ingestion/tickera_catalog_sync.ex (queue_apply / validate_apply_ready)
lib/event_sales/catalog/tickera_catalog/applier.ex (fail closed on tickera_catalog_plan.v3)
lib/event_sales_web/live/admin/catalog_sync_live.ex (UI must not present Apply as available for v3; backend denial is authoritative)
```

Prefer explicit schema/version rejection over accidental field-shape incompatibility.

`Applier` remains the sole catalogue writer. Do not create a second writer.

After Phase 5D + Phase 5E, a separately reviewed boundary may unlock Human Apply for v3. That unlock is **out of Phase 5C scope**.

---

## 18. Planner Boundary

Path:

```text
lib/event_sales/catalog/tickera_catalog/planner.ex
lib/event_sales/catalog/tickera_catalog/normalizer.ex (legacy v2 path preserved)
```

Planner consumes canonical source-risk facts/findings, not raw WordPress risk strings.

Planner must not contain:

```text
legacy alias translation
producer-specific code meaning
authority inference
scope correction
```

Those belong in `SourceRiskV3` / adapter earlier.

Planner retains:

```text
decision/action derivation
structural status
finding aggregation
dry-run output
```

`variation_mapping_required` remains outside canonical source-risk evidence (structural/planner namespaces).

---

## 19. Structural vs Source-Risk Ownership

| Namespace | Owner |
|---|---|
| `source_risk.*` | `SourceRiskV3.FindingPolicy` |
| `contract.*` | `SourceRiskV3.FindingPolicy` / DiscoveryIntegrity |
| `structural.*` | Planner / Normalizer structural path |
| `planner.status.*` | Planner |
| `planner.action.*` | Planner |

Prevent duplicate blockers for one condition across owners.

`unknown_product_semantics` remains derived-only; not a co-equal canonical fact.

---

## 20. Security Boundary

Lock:

```text
exact-key parser envelopes
bounded strings
bounded provenance
no dynamic atoms from producer strings
no arbitrary nested maps
no raw auth headers / signatures / cookies / credentials
no full WordPress payload persistence
no PII
unknown/oversized evidence → fail closed
no truncate-then-alias of unknown raw values
digest retention only as digest + original byte length when needed
```

Signature verification remains in:

```text
lib/event_sales/catalog/tickera_catalog/wordpress_feed_signature.ex
```

---

## 21. Concurrency / Failure-Mode Matrix

| Failure mode | Detect | Fail-closed | Retry/idempotency | Finding/status | Persistence |
|---|---|---|---|---|---|
| Source changes between pages | discovery_snapshot_id / generation mismatch | reject discovery | re-queue new run | contract/integrity | no partial ready plan |
| Page duplicate | page number set | reject | retry fresh | integrity | none ready |
| Page gap | sequence check | reject | retry fresh | integrity | none ready |
| Mixed schema versions | version set size > 1 | reject | retry | integrity | none |
| Mixed snapshots | snapshot id mismatch | reject | retry | integrity | none |
| Producer restart mid-run | generation change / incomplete pages | reject incomplete | retry | integrity | none |
| Plugin version mismatch | unknown schema | reject | no silent fallback | contract | none |
| Duplicate canonical facts | identity+claim | collapse | n/a | provenance merge | snapshot |
| Conflicting canonical facts | identity+diff claim | blocking_conflict | n/a | blocking finding | snapshot |
| Unknown producer code | registry miss | blocking_contract / unknown | n/a | finding | snapshot |
| Oversized provenance | bounds | reject item/page | no truncate-alias | contract | none/partial reject |
| Missing required evidence | envelope/registry | blocking_missing/unknown | n/a | finding | snapshot |
| Adapter source_emitter unknown | Gate D unknown path | weaker diagnostic | n/a | finding | review projection |
| Parent/variation scope ambiguity | regrouping rules | fail closed if parent id missing | n/a | diagnostic | projection |
| Snapshot finalization crash | worker failure | run failed / retry_scheduled existing patterns | Oban retry existing | last_error bounded | no false ready |
| Retry/reprocessing | run status machine | existing idempotent claim rules | existing | unchanged | no double apply |
| Partial run | has_more / page count | not ready | continue or fail | discovering | no ready |
| Planner incomplete discovery | integrity gate before planner | reject | retry | integrity | none |
| AutoApply with v3 plan | policy version check | ineligible | no enqueue | unsupported_snapshot_version | decision audit only |
| Human Apply with v3 plan | Sync/Applier guard | reject | no apply | error | no write |

---

## 22. Performance & Scaling Review

| Component | Layer | Redis | Notes |
|---|---|---|---|
| ContractRegistry | immutable compile-time / hot code | none | — |
| Canonical facts | cold, run-scoped in plan snapshot | none | — |
| Compatibility translation | pure bounded compute | none | — |
| Discovery page aggregation | bounded process/run state | none | no cross-node requirement proven |
| Historical snapshots | Postgres cold durable (`plan_snapshot`) | none required | existing Cache preview optional only |
| WP plugin/assets | normal deploy | n/a | — |

Do **not** introduce Cachex/Redis/GenServer/PubSub/Oban merely for source-risk.

Existing Oban discovery/apply workers remain orchestration; they are not source-risk vocabulary services.

This is an administrative integration path, isolated from hot checkout/seat-write paths.

Assessments:

```text
100k concurrent-user impact? negligible if not on checkout path
DB query amplification? avoid; use existing run persistence
N+1? forbid in page aggregation
unbounded memory? forbid; page-bounded
streaming? page-by-page yes
```

---

## 23. Test Architecture

### Contract registry tests

`test/event_sales/catalog/tickera_catalog/source_risk_v3/contract_registry_test.exs`

Closed dimensions/scopes/states/completeness/authorities/slots/safe allowlists; unknown ids fail closed.

### Parser tests

Extend `test/event_sales/catalog/tickera_catalog/wordpress_feed_response_test.exs` + new v3 cases.

Exact v3 envelope; missing/unknown fields; bounds; parser_error ownership; mixed versions/snapshots; page gaps/duplicates; pagination completion; producer parser_error forgery rejection.

### Normalizer tests

`test/event_sales/catalog/tickera_catalog/source_risk_v3/normalizer_test.exs`

Authority/scope/target; event_link value-not-identity; ticket_template absent vs missing; product_type simple; unresolved capabilities; dimension-local safety.

### Conflict tests

Same module or `canonical_fact_test.exs`: collapse, conflict, provenance merge, ordering.

### v2 adapter tests

`test/event_sales/catalog/tickera_catalog/source_risk_v3/compatibility/v2_adapter_test.exs`

Every Gate D hardening rule (trash_event, subscription_product, payment_plan_product rejection, missing_ticket_template, missing_tickera_event ambiguity, draft_product, draft_event emitter split, missing_source_risk_data owner split, unknown_product_semantics, product_type registry, regrouping, lossy precedence vs conflict).

### Planner/snapshot tests

Extend `snapshot_canonicalizer_test.exs`, `planner_applier_test.exs`.

`tickera_catalog_plan.v3` hash stability; compatibility automation-ineligible; blocking dispositions; no source-risk/structural duplicate blocker.

### Apply safety regression

Extend `auto_apply_policy_test.exs`, `tickera_catalog_auto_apply_test.exs`, `planner_applier_test.exs`, Sync apply tests.

Existing v2 policy unchanged; v3 AutoApply denied; v3 variation AutoApply denied; v3 Human Apply denied in Phase 5C; Applier sole writer.

### WordPress contract tests

`integrations/wordpress/eventsales-tickera-catalog-feed/tests/*` + contract md.

Stamps, envelope, stable snapshot identity, typed evidence, provenance allowlist, lifecycles, ticket_template, event_link, subscription positive-only, unresolved capabilities, product_type, page bounds.

### Forbidden during Phase 5C implementation

```text
bash scripts/dev_local.sh catalogue-dry-run --fresh
```

Phase 5D owns exactly one fresh E2E dry-run.

---

## 24. Implementation Sequence (5C-01 … 5C-06)

| Slice | Outcome | Cutover? |
|---|---|---|
| **5C-01** Canonical v3 core | registry, structs, identity/equality, finding policy, pure normalizer primitives | no production cutover |
| **5C-02** v2 compatibility adapter | `compat.v2_to_source_risk_v3.v1` pure translation + emitter rules | no cutover |
| **5C-03** Dual-version ingestion / native parser | version dispatch; v2→adapter; v3→native; page integrity; bounded canonicalize | fail closed unknown/mixed |
| **5C-04** Planner + `tickera_catalog_plan.v3` review-only | planner consumes canonical facts; v3 hash; v2 unchanged; **v3 Apply denied** | review-only |
| **5C-05** Native WP `2026-08-07.v3` producer | typed evidence; stable discovery identity; closed provenance | after Phoenix dual-version |
| **5C-06** Regression/security/performance closure | contract tests; Apply denial; hashes; bounds | STOP |

Then:

```text
Phase 5D → exactly one fresh native-v3 E2E dry-run
```

Each slice: fresh main → fresh branch → one responsibility → tests → draft PR → independent review → merge → next from fresh main.

No stacked implementation PRs unless a concrete dependency requires them.

---

## 25. Folder/File Ownership Map

| Concern | Existing path(s) | Proposed path(s) | Action later | Reason |
|---|---|---|---|---|
| legacy v2 SourceRisk | `lib/event_sales/catalog/tickera_catalog/source_risk.ex` | — | preserve | historical semantics |
| legacy v2 Normalizer | `…/normalizer.ex` | keep for v2 path | preserve/update call sites carefully | do not turn into v3 |
| contract registry | — | `…/source_risk_v3/contract_registry.ex` | add | immutable v3 registry |
| evidence structs | — | `…/source_risk_v3/evidence.ex` | add | transport validation helpers |
| canonical fact | — | `…/source_risk_v3/canonical_fact.ex` | add | typed identity/equality |
| v3 normalizer | — | `…/source_risk_v3/normalizer.ex` | add | semantic construction |
| finding policy | — | `…/source_risk_v3/finding_policy.ex` | add | dispositions |
| discovery integrity | — | `…/source_risk_v3/discovery_integrity.ex` | add | page/snapshot fail-closed |
| v2 adapter | — | `…/source_risk_v3/compatibility/v2_adapter.ex` | add | Gate D only |
| Finding shape | `…/finding.ex` | same | reuse | shared finding struct |
| feed response/parser | `…/wordpress_feed_response.ex` | same | update | version dispatch / v3 envelope |
| discovery source | `…/wordpress_feed_discovery_source.ex` | same | update | multi-page aggregation hooks |
| feed client/signature | `…/wordpress_feed_client.ex`, `…/wordpress_feed_signature.ex` | same | preserve | transport/auth |
| planner | `…/planner.ex` | same | update | consume canonical facts; emit plan.v3 |
| snapshot canonicalizer | `…/snapshot_canonicalizer.ex` | same | update | add v3 path; keep v2 closed |
| Plan struct | `…/plan.ex` | same | update if needed | carry snapshot/hash |
| AutoApplyPolicy | `…/auto_apply_policy.ex` | same | guard only / no semantic weakening | fail closed v3 |
| AutoApply orchestration | `lib/event_sales/ingestion/tickera_catalog_auto_apply.ex` | same | regression only | keep v2 behaviour |
| Sync orchestration | `lib/event_sales/ingestion/tickera_catalog_sync.ex` | same | explicit v3 Apply denial | apply gate |
| Discover worker | `lib/event_sales/ingestion/workers/discover_tickera_catalog_worker.ex` | same | wire dual-version path | persist plan.v3 |
| Apply worker | `…/workers/apply_tickera_catalog_worker.ex` | same | fail closed for v3 | no v3 apply |
| Applier | `…/applier.ex` | same | explicit v3 denial | sole writer |
| Sync run resource | `lib/event_sales/ingestion/resources/tickera_catalog_sync_run.ex` | same | no migration | JSON snapshot |
| Admin review UI | `lib/event_sales_web/live/admin/catalog_sync_live.ex` | same | review-only for v3 | no Apply UX for v3 |
| WP producer | `integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php` | same | upgrade to native v3 | typed evidence |
| WP contract tests | `integrations/wordpress/…/tests/*` | same + extend | add/modify | producer contract |
| Phoenix tests | `test/event_sales/catalog/tickera_catalog/*`, `test/event_sales/ingestion/*` | add `source_risk_v3/**` | add/modify | regression |
| Fixtures | `test/support/tickera_catalog_fixtures.ex` | same + extend | add v3 fixtures | determinism |

---

## 26. Persistence Matrix

| Resource | Persist? | Store | Version | Mutable? | Migration? | Retention |
|---|---|---|---|---|---|---|
| v2 historical SourceRisk in plan | yes existing | `tickera_catalog_sync_runs.plan_snapshot` | `tickera_catalog_plan.v2` | no rewrite | no | historical |
| native RawProducerEvidence | preferably no full raw; bounded refs only if needed | run-scoped / snapshot provenance | v3 | run-scoped | no | bounded |
| CanonicalEvidenceFact | yes (in plan) | plan_snapshot JSON map | `source_risk.v3` inside `tickera_catalog_plan.v3` | immutable after ready | no | audit |
| CompatibilityTranslationRecord | preferably no MVP | computed | `compat.v2_to_source_risk_v3.v1` | n/a | no | computed |
| source-risk findings | yes | plan_snapshot findings | v3 | finalized | no | audit |
| plan snapshot | yes | existing `plan_snapshot` | `tickera_catalog_plan.v3` | immutable when ready | **no DB migration** | historical |
| dry_run_hash | yes | `dry_run_hash` column | hash of v3 bytes | immutable when ready | no | audit |

---

## 27. State-Machine / Flow Diagrams

### Native v3

```text
request (signed feed)
→ pages (≤100 rows, ≤500 evidence)
→ DiscoveryIntegrity (version + discovery_snapshot_id + pagination)
→ RawProducerEvidence (transport validate)
→ SourceRiskV3.Normalizer
→ CanonicalEvidenceFact(s) origin=native
→ FindingPolicy
→ Planner
→ tickera_catalog_plan.v3 + hash
→ dry_run_ready review only
→ Apply denied
```

### Historical v2

```text
historical v2 input / legacy feed
→ legacy validation (existing WordPressFeedResponse v2)
→ SourceRiskV3.Compatibility.V2Adapter (compat.v2_to_source_risk_v3.v1)
→ source_risk.v3 validation of candidates
→ origin=compatibility_derived projections
→ human review read model
→ never native automation proof
```

### Apply

```text
tickera_catalog_plan.v2
→ existing AutoApplyPolicy / Applier behaviour unchanged

tickera_catalog_plan.v3
→ reject AutoApply (unsupported_snapshot_version / explicit)
→ reject Human Apply during Phase 5C
→ Applier remains sole writer; no write occurs
```

---

## 28. Phase 5C Scaffolding TOON

| Field | Content |
| --- | --- |
| Task | Design/implement the complete source-risk.v3 execution path from versioned producer evidence to review-only plan v3 while preserving v2 history. |
| Objective | Enable the future Phase 5D native-v3 dry-run without weakening Apply safety. |
| Output | Exact implementation slice map, files, dependencies, tests, rollout/cutover rules. |
| Note | Indexes: prefer existing only. Cache/TTL: WP cache_version + transient TTL unchanged conceptually; Redis structure: none for source-risk. Invalidation: WP CACHE_VERSION_OPTION bump. PubSub: none new (existing catalog sync PubSub may notify UI only). Version rules: exact stamps only. Security: fail closed on unknown/oversized. No Phase 5D fresh run. v3 Apply denied. |

Do not execute this TOON as implementation in this design task.

---

## 29. Granular TOON Micro-Prompts

### 5C-01 — Canonical v3 core

| Field | Content |
| --- | --- |
| Task | Implement `SourceRiskV3` contract registry, evidence/canonical fact structs, identity/equality, finding-policy primitives, and pure normalizer helpers with unit tests — no production discovery cutover. |
| Objective | Establish immutable compile-time `source_risk.v3` core so later slices cannot invent dimensions/states/scopes. |
| Output | Files: `lib/event_sales/catalog/tickera_catalog/source_risk_v3/{contract_registry,evidence,canonical_fact,normalizer,finding_policy}.ex`; tests under `test/event_sales/catalog/tickera_catalog/source_risk_v3/`. Dependency: none (first slice). |
| Note | Redis/Cachex/GenServer/PubSub: none. Indexes: none. No WP changes. No planner cutover. No Apply changes. Forbidden: `catalogue-dry-run --fresh`. PR: own draft PR from fresh main. STOP if domain semantics must be redesigned or safe-negative allowlist is non-empty. |

### 5C-02 — v2 compatibility adapter

| Field | Content |
| --- | --- |
| Task | Implement `compat.v2_to_source_risk_v3.v1` pure adapter with `source_emitter` rules and Gate D hardening matrix tests. |
| Objective | Provide certainty-monotonic historical projection without rewriting v2 snapshots. |
| Output | File: `…/source_risk_v3/compatibility/v2_adapter.ex` + tests `…/compatibility/v2_adapter_test.exs`. Dependency: 5C-01 merged. |
| Note | All outputs `origin=compatibility_derived` and automation-ineligible. Cover draft_event emitter split, missing_source_risk_data owner split, draft_product ambiguity, event_link null-status, payment_plan_product rejection, product_type closed registry, regrouping, lossy vs conflict. Persistence: none. Redis: none. Forbidden: Phase 5D dry-run; mutating v2 fixtures’ historical meaning. Own PR. STOP if adapter would strengthen certainty or invent erased codes. |

### 5C-03 — Dual-version ingestion / native parser

| Field | Content |
| --- | --- |
| Task | Add exact version dispatch and native v3 page/evidence parsing plus `DiscoveryIntegrity` for snapshot/page fail-closed aggregation. |
| Objective | Make Phoenix accept only exact `2026-07-22.v2` (via adapter) or `2026-08-07.v3` (native); reject unknown/mixed. |
| Output | Update `wordpress_feed_response.ex`, `wordpress_feed_discovery_source.ex`; add `…/source_risk_v3/discovery_integrity.ex`; extend response/discovery tests. Dependency: 5C-01+5C-02. |
| Note | No “latest”. Parser transport-only. Redis: none. PubSub: none new. Forbidden: WP producer cutover before this lands; Phase 5D dry-run. Own PR. STOP if mixed versions would be accepted or parser assigns severity/authority. |

### 5C-04 — Planner + tickera_catalog_plan.v3 review-only

| Field | Content |
| --- | --- |
| Task | Wire planner/snapshot canonicalizer to emit `tickera_catalog_plan.v3`, persist via existing `plan_snapshot`, and explicitly deny AutoApply + Human Apply for v3. |
| Objective | Produce reviewable native-v3 dry-runs without Apply writes. |
| Output | Update `planner.ex`, `snapshot_canonicalizer.ex`, `applier.ex`, `tickera_catalog_sync.ex`, optionally `catalog_sync_live.ex` UX gating; tests for v3 hash + Apply denial + v2 unchanged. Dependency: 5C-03. |
| Note | DB migration: no. Keep `tickera_catalog_plan.v2` path byte-stable. AutoApplyPolicy unchanged semantically. Applier sole writer. Forbidden: enabling v3 Apply; Phase 5D dry-run. Own PR. STOP if v3 would serialize as v2 or Apply becomes possible. |

### 5C-05 — Native WordPress 2026-08-07.v3 producer

| Field | Content |
| --- | --- |
| Task | Upgrade WP feed to emit native typed evidence with `schema_version=2026-08-07.v3`, `canonical_contract_version=source_risk.v3`, and stable `discovery_snapshot_id`/generation-tied `source_snapshot_at`. |
| Objective | Provide authoritative native producer evidence after Phoenix can parse it. |
| Output | Update `eventsales-tickera-catalog-feed.php`, `tests/catalog-feed-contract.md`, `tests/catalog-feed-test.php` (+ related PHP tests). Dependency: 5C-04 merged (Phoenix dual-version + plan.v3 ready). |
| Note | Deploy order: Phoenix first. Typed evidence primary; legacy risk strings non-authoritative if retained. Cache invalidation must bump generation and change snapshot id. Redis: none. Forbidden: Phase 5D dry-run in this slice; claiming exhaustive completeness without generation invariant. Own PR. STOP if snapshot identity is request-time UUID/clock only. |

### 5C-06 — Regression/security/performance closure

| Field | Content |
| --- | --- |
| Task | Close contract, cross-version, deterministic hash, Apply-denial, security-bounds, and performance sanity regressions across Phoenix+WP fixtures. |
| Objective | Prove Phase 5C review-only pipeline is fail-closed and ready to hand off to Phase 5D. |
| Output | Additional/extended tests under `test/event_sales/catalog/tickera_catalog/source_risk_v3/**`, ingestion apply/auto-apply regressions, WP contract tests; short note in PR of checks run. Dependency: 5C-01..5C-05. |
| Note | Forbidden: `catalogue-dry-run --fresh` (reserved for Phase 5D). No Redis/Cachex introduction. No Apply unlock. Own PR then STOP Phase 5C. STOP if any test requires production/WordPress mutation or weakens Apply guards. |

---

## 30. Deployment Ordering

Preferred later deploy sequence:

```text
5C-01 canonical core
→ 5C-02 adapter
→ 5C-03 dual-version Phoenix support
→ 5C-04 planner v3 review-only + Apply denial
→ 5C-05 WP v3 producer
→ 5C-06 closure
```

Hard rule:

```text
Phoenix dual-version support MUST land before the WP producer starts emitting v3.
```

If WP emits v3 while Phoenix only understands v2:

```text
fail closed (unknown/unsupported schema)
```

Never deploy WP v3 first.

Rollback: leave WP on v2; v3 Phoenix paths remain inert without v3 pages; historical v2 untouched.

---

## 31. Risk Review

| Risk | Mitigation |
|---|---|
| False-safe evidence | empty safe-negative allowlist; dimension-local safety; tests |
| Apply safety regression | explicit v3 denial; AutoApplyPolicy unchanged; regressions |
| Version skew WP/Phoenix | deploy Phoenix first; exact stamps; fail closed |
| Snapshot instability | generation-tied discovery_snapshot_id; reject mixed |
| Partial rollout | review-only v3; no Apply |
| Fixture drift | shared fixtures + contract tests |
| Compatibility treated as native | origin badge + automation-ineligible |
| Duplicate blockers | namespace ownership map |
| Memory blowups | page bounds + incremental aggregation |
| Security envelope escape | exact keys, bounds, no dynamic atoms |
| Multi-tenant/source isolation | existing source_system scoping unchanged |
| Test consuming Phase 5D run | forbidden `--fresh` in 5C |

---

## 32. Success Criteria (agent must answer without guessing)

```text
Which files do I touch? → §25 ownership map + slice TOON
Which modules own each rule? → §3 / §8–§10
Which contract version do I parse? → exact schema_version stamps
Where does v2 compatibility happen? → SourceRiskV3.Compatibility.V2Adapter
Where does native normalization happen? → SourceRiskV3.Normalizer
How are facts identified? → §8
Where are conflicts resolved? → Normalizer/CanonicalFact pipeline
Where are findings produced? → FindingPolicy
What snapshot version do I write? → tickera_catalog_plan.v3
Is a DB migration needed? → NO
Can v3 Apply? → NO during Phase 5C
Can compatibility evidence satisfy automation? → NO
How does WP keep page snapshot identity stable? → §12 generation + filters
Which tests prove each boundary? → §23
Which PR comes next? → next unmet 5C-0N from fresh main
When do I STOP? → after 5C-06 merge; no Phase 5D in 5C
```

### Explicit design decisions (not deferred)

| Decision | Lock |
|---|---|
| Plan snapshot for native v3 | `tickera_catalog_plan.v3` |
| DB migration | **NO** |
| Human Apply v3 in Phase 5C | **denied (option A)** |
| AutoApply v3 | **denied / unsupported_snapshot_version** |
| Compatibility persistence MVP | **computed only** |
| Module namespace | `EventSales.Catalog.TickeraCatalog.SourceRiskV3` |
| Redis for source-risk | **none** |
| Phase 5D fresh dry-run in 5C | **forbidden** |

No remaining `BLOCKING DESIGN DECISION` for ownership of the above. Snapshot generation emission into WP envelope is a **required implementation property of 5C-05**, not an open semantic redesign.

---

## 33. Invariants

```text
do not redesign locked Phase 5B semantics
preserve legacy SourceRisk v2 module
native v3 output uses tickera_catalog_plan.v3 only
never serialize new semantics under tickera_catalog_plan.v2
no historical v2 rewrite
compatibility_derived != native automation proof
native safe-negative allowlist empty
v3 AutoApply denied in Phase 5C
v3 Human Apply denied in Phase 5C
no variation auto-Apply
Applier sole catalogue writer
Phoenix before WP v3 deploy
no Phase 5D --fresh during Phase 5C
no Redis/Cachex/GenServer for source-risk vocabulary
exact version dispatch only
```

---

## 34. Gate / Acceptance for This Design PR

This boundary PR succeeds when reviewers confirm:

- module/file ownership is concrete and matches static repo paths
- `tickera_catalog_plan.v3` is locked
- dual-version ingestion and Gate D adapter boundaries are clear
- v3 remains review-only (Apply denied)
- 5C-01..5C-06 TOON slices are unique and PR-isolated
- Phase 5D fresh dry-run remains reserved
- no implementation code is included

---

## Document control

| Item | Value |
|---|---|
| Next after merge | Implementation agents execute 5C-01…5C-06 as separate PRs |
| Forbidden until then | implementation code; Phase 5D dry-run; Apply unlock |

End of Phase 5C implementation boundary.
