# Phase 5B — Native Source-Risk Contract

| Field | Value |
|---|---|
| Plan / document ID | `phase-5b-source-risk-contract` |
| Document version | `v1` |
| Status | Draft for independent Gate C review |
| Scope | Native producer/page envelope, closed dimension/authority/disposition registries, finding policy — **no** v2 adapter detail, **no** Phase 5C implementation |
| Authority | Active Phase 5B **contract** document; subordinate to locked domain model on resource/invariant conflicts |
| Locked domain model | `docs/phase-5b/source-risk-domain-model.md` v2 — SHA256 `16563ee02f58a12d2fde1e6995da3cb4d1be89dfd9ecbb8e07eb76ba5d8a6375` |
| Historical context | `docs/phase-5a/source-risk-blocker-taxonomy.md`, `docs/phase-5a/source-risk-blocker-ledger.csv` |
| Last updated | 2026-08-07 |
| Change summary | Initial native `2026-08-07.v3` / `source_risk.v3` contract |

### Revision log

- `v1` — initial native source-risk contract after Gate B domain-model lock

### Conflict rule

```text
domain model (locked) wins on resource definitions and fail-closed invariants
this contract wins on closed vocabularies, version stamps, envelopes, and policy tables
```

---

## 1. Status and Authority

Phase 5A complete. Phase 5B domain model locked at v2. Phase 5C remains locked.

This document defines the **native** source-risk contract only. It does not:

- implement Elixir/PHP/tests;
- rewrite persisted `2026-07-22.v2` semantics;
- fully specify the v2 compatibility adapter (reserved §30);
- weaken Human Apply, AutoApplyPolicy, or Applier ownership;
- authorize Apply, mapping mutations, dry-runs, or runtime inspection.

Certified historical run `3efd208f-b148-4568-8591-13d968399081` remains immutable.

---

## 2. Contract Goals and Non-Goals

### Goals

```text
producer observation
→ validated raw evidence
→ optional compatibility translation
→ canonical typed evidence fact
→ deterministic disposition / finding policy
```

Primary model (mandatory):

```text
dimension
+ semantic scope
+ target identity
+ authority slot/group
+ evidence state
+ evidence value
+ completeness
```

Risk/finding codes are **downstream labels**, never primary fact identity.

### Non-goals

- Flat risk-string identity model.
- Inventing WordPress authority for unresolved dimensions.
- Runtime-mutable registries, Redis/Cachex/GenServer vocabulary services, generic rule engines.
- Changing current AutoApplyPolicy behaviour in Phase 5B.
- Automatic variation Apply.
- Second catalogue writer.

---

## 3. Version Model

Versions are not interchangeable.

| Version kind | Proposed identifier | Governs |
|---|---|---|
| Producer contract | `2026-08-07.v3` | Feed/page envelope, evidence items, pagination/snapshot fields |
| Canonical source-risk contract | `source_risk.v3` | Dimension/authority/disposition/finding policy registries |
| Compatibility adapter version | *deferred* (`compat.v2_to_v3` proposed name only) | Legacy translation tables — adapter document |
| Snapshot / plan schema version | *deferred* | Persisted plan shape — later docs / Phase 5C |

**Why these stamps:** producer versions in-repo already use `YYYY-MM-DD.vN` (`2026-07-22.v2`). Canonical uses a stable semantic id `source_risk.v3` so feed date stamps can advance without renaming the semantic registry.

### Producer → canonical binding

| Producer contract | Canonical contract | Normalization mode |
|---|---|---|
| `2026-08-07.v3` | `source_risk.v3` | `native` |
| `2026-07-22.v2` | `source_risk.v3` via adapter | `compatibility_derived` (never native) |
| `2026-07-08.v1` / `2026-07-05.v1` | human-review only via adapter | `compatibility_derived` / incomplete |

`native` means a **declared binding row**, not “two version strings look current.”

Changing semantics requires a new version. Do not mutate `2026-07-22.v2` in place.

---

## 4. Native Producer/Page Envelope

Every native page MUST include:

| Field | Type | Required | Notes |
|---|---|---|---|
| `schema_version` | string | yes | Exactly `2026-08-07.v3` |
| `canonical_contract_version` | string | yes | Exactly `source_risk.v3` |
| `producer_version` | string | yes | Plugin implementation stamp (semver or dated build id); contract-significant |
| `source` | string | yes | `wordpress_tickera` |
| `source_system_id` | string/uuid | yes when known to producer; else stable producer-local source key | Must agree across pages |
| `discovery_snapshot_id` | string | yes | Stable id for one discovery snapshot; all pages must match |
| `source_snapshot_at` | RFC3339 Z | yes | Snapshot clock for the discovery |
| `generated_at` | RFC3339 Z | yes | Page generation time |
| `page` | pos int | yes if offset mode | Mutually exclusive with cursor mode below |
| `per_page` | pos int | yes if offset mode | Max **100** for native v3 (stricter than legacy 500) |
| `has_more` | boolean | yes | Pagination completion signal |
| `cursor` | string \| null | yes if cursor mode | Opaque deterministic cursor |
| `next_cursor` | string \| null | yes if cursor mode | Null iff `has_more=false` |
| `filters` | object | yes | Bounded filter echo |
| `events` | array | yes | May be empty |
| `catalog_rows` | array | yes | May be empty |
| `evidence` | array | yes | Native typed evidence items (preferred collection) |

**Native recommendation:** emit typed `evidence[]` as the authoritative evidence collection. Do not rely on open `risk_codes[]` strings for native automation proof. Legacy `risk_codes` / `product_semantics` shapes are compatibility-only (§26, §30).

Auth headers/signatures remain transport security and are **never** persisted as evidence provenance.

---

## 5. Pagination and Snapshot Integrity

### Cross-page agreement (mandatory)

All pages of one discovery MUST agree on:

- `schema_version`
- `canonical_contract_version`
- `producer_version` (contract-significant)
- `source`
- `source_system_id`
- `discovery_snapshot_id`
- `source_snapshot_at`

Reject (fail closed) the whole discovery on:

| Defect | Disposition |
|---|---|
| Mixed producer/canonical versions | `blocking_error` / discovery reject |
| Mixed snapshot identities | discovery reject |
| Cursor/page gaps or out-of-order pages | discovery reject |
| Duplicate pages (same page/cursor) | discovery reject |
| Incompatible pagination metadata | discovery reject |
| `has_more=true` but no next page obtainable | incomplete discovery |
| Partial discovery presented as complete | incomplete discovery |

### Exhaustive completeness invariant

```text
No evidence fact may receive completeness = exhaustive
until the discovery/page sequence proves successful completion
under the native contract for that discovery_snapshot_id.
```

A partially retrieved feed is never exhaustive.

If the producer cannot guarantee a stable snapshot across pagination, the discovery **cannot** establish native automation completeness.

Phase 5C may use bounded aggregation, streaming, or run-scoped indexed persistence. Redis is not required and not recommended for this path.

---

## 6. Native Evidence Envelope

Each `evidence[]` item is one producer observation.

### Required fields

| Field | Type | Constraint |
|---|---|---|
| `dimension` | string | Closed native dimension id (§10) |
| `producer_scope` | string | Closed producer scope token (§9 producer side) |
| `target` | object | Target identity shape for that scope (§9) |
| `state` | string | Producer-emittable EvidenceState (§7) |
| `producer_source_key` | string | Closed producer evidence/source key (§11) |
| `completeness` | string | Producer-claimed completeness (§8); **not** authoritative alone |
| `provenance` | object | Bounded allowlisted fields (§23) |

### Optional / conditional fields

| Field | When |
|---|---|
| `value` | Required when state=`present` and dimension defines values; forbidden or null when not applicable |
| `related_targets` | Relationship dimensions may include secondary ids |

### Producer must not self-declare authority

`producer_source_key` identifies the producer field/query. Canonical AuthorityDefinition decides whether that key is authoritative for the dimension/state. Producer claims of “authority=true” are ignored/rejected.

### Bounds

| Bound | Value |
|---|---|
| Max evidence items per page | 500 |
| Max evidence items per catalog row association (if nested) | 32 |
| Max `dimension` / `producer_source_key` length | 64 |
| Max string `value` length | 64 |
| Max provenance object keys | 16 |
| Charset for ids/keys | `a-z0-9_` for closed ids; raw unknown codes see §23 |

Missing required fields → parser `missing` / `invalid` path → fail closed.

---

## 7. EvidenceState Registry

Locked native states:

| State | Meaning | Producer-emittable? | Parser-local? |
|---|---|---|---|
| `present` | Authoritative query positively observed the condition/value | yes | no |
| `absent` | Authoritative query returned a negative observation | yes | no |
| `unknown` | Producer executed but cannot decide | yes | no |
| `missing` | Required observation/field not supplied | yes (for producer-visible gaps) | yes (missing key) |
| `unsupported` | Integration cannot evaluate the dimension | yes | no |
| `invalid` | Value violates contract shape/enum | yes (producer detects) | yes (parser detects) |
| `producer_error` | Producer evaluation failed | yes | no |
| `parser_error` | Phoenix parse/validation failed | **no** | **yes only** |

Producer envelopes **must not** emit `parser_error`. Transport cannot impersonate parser errors.

Forbidden collapses: do not merge unknown/missing/unsupported/invalid/error into one state.

---

## 8. EvidenceCompleteness Registry

Locked names:

| Completeness | Meaning |
|---|---|
| `exhaustive` | Authority’s required coverage for the claimed proof was achieved **and** discovery completion rules hold when required |
| `partial` | Observation exists but coverage incomplete |
| `unknown` | Completeness cannot be determined |

### Who may assert / who validates

| Actor | May claim | Validated by |
|---|---|---|
| Producer | claimed completeness token | Normalizer + AuthorityDefinition + discovery completion |
| Compatibility adapter | non-strengthening translated completeness | Adapter rules; never invents exhaustive |
| Parser | never invents exhaustive | — |

```text
Producer writing completeness=exhaustive is never sufficient alone.
Canonical validation must prove exhaustive conditions.
```

If discovery is incomplete, exhaustive claims are rejected → treat as `partial` or `unknown` and non-safe.

---

## 9. Scope Registry

| Scope id | Target identity shape | Notes |
|---|---|---|
| `event` | `{ tickera_event_id: pos_int }` | Event post |
| `parent_product` | `{ woo_product_id: pos_int }` | Parent product |
| `variation` | `{ woo_variation_id: pos_int, woo_product_id: pos_int }` | Variation; parent id required for linkage |
| `ticket_template` | `{ woo_product_id: pos_int }` (+ optional template id in value) | Linkage evidence owned by product |
| `event_product_relationship` | `{ woo_product_id: pos_int, tickera_event_id: pos_int \| null }` | Relationship, not entity collapse |
| `product_variation_relationship` | `{ woo_product_id: pos_int, woo_variation_id: pos_int }` | Relationship |

Transport row containing both product and variation ids **does not** set semantic scope. Scope comes from the dimension registry.

Producer scope tokens on the wire map 1:1 to these ids for native v3.

---

## 10. Evidence Dimension Registry

Closed native dimensions:

| Dimension id | Allowed scopes | Allowed states | Allowed values | Authority group | Exhaustive negative permitted? | Native producer support now? | Default fail-closed |
|---|---|---|---|---|---|---|---|
| `lifecycle` | `event`, `parent_product`, `variation` | present, unknown, missing, invalid, producer_error | `publish`, `private`, `draft`, `trash`, `deleted` | `auth.wp_post_status` | no (lifecycle uses positive value proof; “absent” N/A) | event/product: yes; variation: **required by contract**, currently incomplete in WP emission | unknown/missing/invalid/error block; non-publish values risk |
| `ticket_template` | `ticket_template` / `parent_product` | present, missing, unknown, unsupported, invalid, producer_error | optional template id string when present | `auth.ticket_template_meta` | yes for missing-vs-present when meta query exhaustive for product | yes (`_ticket_template`) | missing/unknown/error block |
| `event_link` | `event_product_relationship` | present, missing, unknown, invalid, producer_error | optional event id when present | `auth.event_name_meta` | yes when relationship query exhaustive | yes (null event status path today) | missing/unknown/error block |
| `subscription` | `parent_product` | present, absent, unknown, unsupported, missing, invalid, producer_error | optional bounded type/meta digest when present | `auth.subscription_detection` | **no** under current reviewed evidence (positive-only) | positive detection yes; exhaustive negative **no** | present → risk; absent without exhaustive authority → not allowed as safe; unknown/unsupported/missing/error block |
| `payment_plan` | `parent_product` | unsupported, unknown, missing, producer_error | none | *none proven* | no | no | unsupported/unknown/missing/error block |
| `membership` | `parent_product` | unsupported, unknown, missing, producer_error | none | *none proven* | no | no | unsupported/unknown/missing/error block |
| `bundle` | `parent_product` | unsupported, unknown, missing, producer_error | none | *none proven* | no | no | unsupported/unknown/missing/error block |
| `add_on` | `parent_product` | unsupported, unknown, missing, producer_error | none | *none proven* | no | no | unsupported/unknown/missing/error block |
| `product_type` | `parent_product` | present, unsupported, unknown, missing, invalid, producer_error | closed allowlist token, starting with `simple`; others unsupported | `auth.wc_product_type` | no | partial (type available) | non-allowlisted / unknown / missing / error block |

### Deterministic recommendation (lifecycle)

Lifecycle is **dimension + value**, not primary fact-per-code:

```text
dimension: lifecycle
scope: event | parent_product | variation
state: present
value: publish | private | draft | trash | deleted
```

Legacy codes such as `private_product` remain **finding labels / compatibility aliases**, not fact identities.

### Required native emission set

For native automation completeness, a complete discovery must include evaluated facts for every required dimension/scope/target in the completeness set defined by finding policy / future AutoApply cutover (§27). Unresolved product dimensions must still appear as explicit non-safe envelopes (`unsupported` preferred when capability absent).

---

## 11. Authority Registry

| Authority id | Producer system | Producer source key | Scopes | States may assert | Positive proof | Negative proof | Exhaustive requirements |
|---|---|---|---|---|---|---|---|
| `auth.wp_post_status` | `wordpress_tickera` | `wp_posts.post_status` | event, parent_product, variation | present, unknown, missing, invalid, producer_error | yes (status value) | N/A for lifecycle values | Row must exist; status in closed set; unknown status → `unknown` |
| `auth.ticket_template_meta` | `wordpress_tickera` | `postmeta:_ticket_template` | ticket_template / parent_product | present, missing, unknown, invalid, producer_error | yes | yes (`missing` when meta absent under exhaustive product meta read) | Allowlisted meta read for that product completed |
| `auth.event_name_meta` | `wordpress_tickera` | `postmeta:_event_name` + `tc_events` resolve | event_product_relationship | present, missing, unknown, invalid, producer_error | yes | yes (unresolved link → missing) | Meta+resolve query completed |
| `auth.subscription_detection` | `wordpress_tickera` | `wc_product_type` + allowlisted subscription meta | parent_product | present, unknown, unsupported, missing, invalid, producer_error | yes (type/meta positive match) | **not** under this authority | Exhaustive negative **not** claimed |
| `auth.wc_product_type` | `wordpress_tickera` | `wc_get_product.type` / SQL product type | parent_product | present, unsupported, unknown, missing, invalid, producer_error | yes | N/A | Type read completed; allowlist check |

### Capability vs semantic absence

```text
authority to assert unsupported ("I cannot evaluate")
≠
authority to assert absent ("dimension is not present")
```

Unresolved dimensions (`payment_plan`, `membership`, `bundle`, `add_on`) have **no** AuthorityDefinition row that may assert `absent` or `present`.

### Authority groups / slots

MVP: one authority per dimension (no multi-authority precedence).

| Dimension | Authority slot |
|---|---|
| `lifecycle` | `slot.lifecycle.wp_post_status` |
| `ticket_template` | `slot.ticket_template.meta` |
| `event_link` | `slot.event_link.meta` |
| `subscription` | `slot.subscription.detection` |
| `product_type` | `slot.product_type.wc` |
| `payment_plan` / `membership` / `bundle` / `add_on` | `slot.<dim>.none` (no authority; facts remain non-safe) |

Conflicting claims within one slot → `blocking_conflict`. No silent winner.

---

## 12. Evidence Value Registries

### Lifecycle values

| Value | Meaning |
|---|---|
| `publish` | Published |
| `private` | Private |
| `draft` | Draft (and other non-publish non-trash non-private mapped only if contract maps them; default non-publish → treat carefully) |
| `trash` | In trash |
| `deleted` | Authoritative tombstone (native full feed typically does not emit; reserved) |

Mapping rule for producer status classification: closed set `{publish, private, draft, trash}`; any other observed status → state `unknown` or `invalid`, never invent a value.

### Product type allowlist (native v3 MVP)

| Value | Disposition class |
|---|---|
| `simple` | candidate for safe-positive when other policies pass |
| any other known type string | `unsupported` / explicit_risk path via product_type dimension |
| missing/unknown type | blocking |

### Ticket template / event link values

Bounded optional id strings when `state=present`. Empty string → `invalid`.

---

## 13. Safe-Proof Policy

No state/value is implicitly safe. Safe disposition requires an explicit matching rule.

### Safe-positive proof (allowlist)

| Dimension | Scope | State | Value | Completeness | Authority | Disposition |
|---|---|---|---|---|---|---|
| `lifecycle` | event / parent_product / variation | present | `publish` | exhaustive *or* present-observation completeness per authority (row-local read complete) | matching `auth.wp_post_status` | `safe_positive_proof` |
| `ticket_template` | parent_product | present | any valid id | exhaustive product meta read | `auth.ticket_template_meta` | `safe_positive_proof` |
| `product_type` | parent_product | present | `simple` | type read complete | `auth.wc_product_type` | `safe_positive_proof` |
| `event_link` | event_product_relationship | present | valid event id | relationship resolve complete | `auth.event_name_meta` | `safe_positive_proof` |

### Safe-negative proof (allowlist)

| Dimension | Scope | State | Completeness | Authority | Disposition |
|---|---|---|---|---|---|
| `ticket_template` | parent_product | missing | exhaustive | `auth.ticket_template_meta` | **not safe** — missing template is risk (`explicit_risk` / blocking finding) |
| `subscription` | parent_product | absent | — | — | **not permitted as safe** under current authority (no exhaustive negative) |

```text
Safe-negative proof requires:
state=absent
AND valid authority for negative proof
AND compatible scope
AND completeness=exhaustive
AND registry permits negative proof
AND no producer/parser/compatibility error
AND (for automation) origin=native + discovery complete
```

Under native v3 MVP, **no subscription/payment_plan/membership/bundle/add_on safe-negative rules exist**.

Ticket-template `missing` is explicit risk, not safe-negative.

### Risk-positive proof

Non-publish lifecycle values; subscription `present`; unsupported product types; missing ticket template; missing event link; etc. → `explicit_risk` when authority supports the observation.

### Unresolved

Anything not matched by an explicit safe or explicit_risk rule → fail-closed blocking disposition (`blocking_unknown` / `blocking_unsupported` / …). Never default to safe.

---

## 14. Risk Disposition Registry

Closed dispositions:

| Disposition | Meaning |
|---|---|
| `safe_positive_proof` | Explicit allowlisted safe positive |
| `safe_negative_proof` | Explicit allowlisted exhaustive safe absence |
| `explicit_risk` | Authoritative risky observation |
| `blocking_unknown` | Unknown / unresolved |
| `blocking_missing` | Missing required evidence |
| `blocking_unsupported` | Unsupported evaluation |
| `blocking_invalid` | Invalid value/shape |
| `blocking_error` | Producer or parser error |
| `blocking_scope_mismatch` | Scope incompatible |
| `blocking_authority_mismatch` | Authority incompatible |
| `blocking_conflict` | Conflicting claims/authorities |
| `blocking_contract_error` | No matching policy / undeclared vocabulary |
| `not_applicable` | Recorded for audit without safety meaning — **not safe** |

Fallback:

```text
no matching disposition rule → blocking_contract_error
```

Never default to safe. Do not overload `not_applicable` as safe.

---

## 15. Finding Policy

Evidence fact ≠ finding. Mapping:

```text
canonical fact → disposition → optional finding
```

### Policy classes (summary)

| Class | Dimension / condition | State/value | Completeness | Scope | Authority | Disposition | Finding owner | Finding code | Severity |
|---|---|---|---|---|---|---|---|---|---|
| Lifecycle publish | `lifecycle` | present/`publish` | read complete | matching | `auth.wp_post_status` | `safe_positive_proof` | — | none | — |
| Lifecycle private | `lifecycle` | present/`private` | read complete | matching | same | `explicit_risk` | source_risk | `lifecycle_private` | blocking |
| Lifecycle draft | `lifecycle` | present/`draft` | read complete | matching | same | `explicit_risk` | source_risk | `lifecycle_draft` | blocking |
| Lifecycle trash | `lifecycle` | present/`trash` | read complete | matching | same | `explicit_risk` | source_risk | `lifecycle_trashed` | blocking |
| Lifecycle deleted | `lifecycle` | present/`deleted` | read complete | matching | same | `explicit_risk` | source_risk | `lifecycle_deleted` | blocking |
| Lifecycle unknown | `lifecycle` | unknown/missing/invalid/error | * | matching | * | matching blocking_* | source_risk / contract | `lifecycle_unresolved` / contract codes | blocking |
| Ticket template missing | `ticket_template` | missing | exhaustive | parent_product | `auth.ticket_template_meta` | `explicit_risk` | source_risk | `missing_ticket_template` | blocking |
| Ticket template present | `ticket_template` | present | read complete | parent_product | same | `safe_positive_proof` | — | none | — |
| Event link missing | `event_link` | missing | exhaustive | event_product_relationship | `auth.event_name_meta` | `explicit_risk` | source_risk | `missing_tickera_event` | blocking |
| Subscription present | `subscription` | present | * | parent_product | `auth.subscription_detection` | `explicit_risk` | source_risk | `subscription` | blocking |
| Subscription non-present non-safe | `subscription` | unknown/unsupported/missing/error | * | parent_product | * | blocking_* | source_risk | `subscription_unresolved` | blocking |
| Unresolved product dims | payment_plan/membership/bundle/add_on | unsupported/unknown/missing/error | * | parent_product | none | blocking_* | source_risk | same as dimension id | blocking |
| Product type simple | `product_type` | present/`simple` | read complete | parent_product | `auth.wc_product_type` | `safe_positive_proof` | — | none | — |
| Product type other | `product_type` | unsupported / non-allowlist | * | parent_product | same | `explicit_risk` / `blocking_unsupported` | source_risk | `unsupported_product_type` | blocking |
| Scope mismatch | any | * | * | wrong | * | `blocking_scope_mismatch` | contract | `scope_mismatch` | blocking |
| Authority mismatch | any | * | * | * | wrong | `blocking_authority_mismatch` | contract | `authority_mismatch` | blocking |
| Conflict | same identity | differing claims | * | * | * | `blocking_conflict` | contract | `evidence_conflict` | blocking |
| Undeclared dimension/state/value | * | * | * | * | * | `blocking_contract_error` | contract | `unknown_source_risk_code` / `contract_violation` | blocking |
| Parser error | * | parser_error | * | * | * | `blocking_error` | contract | `parser_error` | blocking |

Severity is **policy-owned**, not intrinsic to a code string.

Unknown/missing/unsupported/invalid/error/conflict remain blocking unless an independently reviewed policy explicitly says otherwise (none currently).

---

## 16. Finding and Diagnostic Namespaces

| Namespace | Owner | Purpose | Example codes |
|---|---|---|---|
| `source_risk.*` | Source-risk finding emitter | Catalogue-safety from canonical facts | `subscription`, `missing_ticket_template`, `lifecycle_trashed` |
| `contract.*` | Parser/normalizer contract | Envelope/registry/conflict errors | `parser_error`, `scope_mismatch`, `unknown_source_risk_code` |
| `structural.*` | Structural emitter | Structural notices | `structural.product_has_variations` (replacement family) |
| `planner.status.*` | Planner | Mapping/identity status | `planner.status.variation_mapping_unresolved` (conceptual) |
| `planner.action.*` | Planner | Planned actions | create/reuse/adopt action types (existing planner) |

Cross-owner code reuse is forbidden.

### `variation_mapping_required`

```text
NOT a native WordPress source-risk evidence code
NOT a native evidence dimension
```

Future ownership:

- structural product-group notice → `structural.*` family;
- exact variation mapping policy → `planner.status.*` family.

Exact final strings may be refined in Phase 5C boundary doc; namespaces are locked here.

### `unknown_product_semantics`

```text
NOT a primary evidence dimension
NOT persisted as a co-equal blocker when per-dimension facts already exist
```

Chosen representation (smallest useful):

```text
derived audit / UI aggregate (read-model diagnostic)
```

Historical v2 findings remain unchanged and auditable.

---

## 17. Lifecycle Contract

| Scope | Allowed values | Safe value | Risky values | Deleted/missing | Native WP support |
|---|---|---|---|---|---|
| `event` | publish/private/draft/trash/deleted | publish | private/draft/trash/deleted | unknown status → unknown; deleted reserved | `event_risk_codes` / status classification exists; trash currently emitted as `trash_event` string in v2 |
| `parent_product` | same | publish | non-publish set | same | product status classification exists; trash often collapsed into draft_product in v2 — native must emit `trash` distinctly |
| `variation` | same | publish | non-publish set | same | status classification often serialized but **risk codes not emitted** today — native **requires** variation lifecycle evidence |

Do not assume variation lifecycle completeness from event/product status.

Phase 5C must emit variation lifecycle evidence under native producer changes; this contract requires it for native automation completeness when variations are in scope.

---

## 18. Product Semantic Contract

| Dimension | Native treatment |
|---|---|
| `subscription` | Positive detection authority only; present → blocking risk; no safe absent |
| `payment_plan` | No authority; emit `unsupported` (preferred) or `unknown`; never `absent`; blocking |
| `membership` | same |
| `bundle` | same |
| `add_on` | same |
| `product_type` | Allowlist; `simple` may be safe-positive; others unsupported/risk |

Excluded as proof: names, slugs, categories, marketing text, arbitrary meta, heuristics.

---

## 19. Relationship Evidence Contract

### `event_link` / `missing_tickera_event`

| Item | Rule |
|---|---|
| Dimension | `event_link` |
| Scope | `event_product_relationship` |
| Target shape | `{ woo_product_id, tickera_event_id \| null }` |
| Missing link | state=`missing` → finding `missing_tickera_event` |
| Present link | state=`present` + event id → candidate safe-positive |

Must not collapse into generic product or event lifecycle absence.

### `product_variation_relationship`

Used for structural/planner linkage; not a substitute for parent_product semantic dimensions. Parent semantics remain parent-scoped even when a variation id appears on a transport row.

---

## 20. Canonical Fact Identity and Conflict Rules

Locked from Gate B:

```text
CanonicalEvidenceFact identity =
  run/discovery identity
  + canonical evidence dimension
  + semantic scope
  + target identity
  + authority slot/group
```

State/value/finding code are **claims**, not identity components.

### Normalized semantic claim (duplicate/conflict)

Contract-significant fields:

| Field | In claim? |
|---|---|
| `state` | yes |
| `value` | yes (normalized; null if N/A) |
| `completeness` | yes |
| `semantic_scope` | yes (must match identity scope) |
| `authority_slot` | yes |
| `origin` | yes (`native` \| `compatibility_derived`) |
| finding/risk code label | no (derived) |
| provenance blobs | no (retained separately) |

Rules:

```text
same identity + same normalized claim → deterministic duplicate collapse
same identity + different normalized claim → blocking_conflict
```

Not defined by JSON/byte serialization equality.

Example:

```text
same parent_product + lifecycle + slot.lifecycle.wp_post_status
private vs draft → conflict
```

---

## 21. Legacy Concept Ownership Matrix

Reconciles Phase 5A / current `SourceRisk` + structural codes into future categories.

| Legacy / current concept | Future category | Notes |
|---|---|---|
| `private_event` / `draft_event` / `trashed_event` / `deleted_event` | typed `lifecycle` value + source_risk finding label | identity is dimension/value |
| `private_product` / `draft_product` / `trashed_product` / `deleted_product` | typed `lifecycle` | native must distinguish trash vs draft |
| `private_variation` / `draft_variation` | typed `lifecycle` @ variation | required native emission |
| `trash_event` | compatibility alias → lifecycle `trash` @ event | provenance retained |
| `subscription_product` | compatibility alias → `subscription` present | provenance retained |
| `payment_plan_product` | **not** approved alias | undeclared → contract error / unknown raw unless later proven |
| `subscription` | typed dimension + finding label | — |
| `payment_plan` / `membership` / `bundle` / `add_on` | typed dimensions; unresolved unsupported/unknown | blocking |
| `missing_ticket_template` | typed `ticket_template` missing + finding | — |
| `unsupported_product_type` | typed `product_type` | — |
| `unknown_product_semantics` | derived summary only | not primary |
| `missing_tickera_event` | typed `event_link` missing + finding | relationship scope |
| `missing_source_risk_data` | contract/parser finding family | do not erase raw; replace silent fallback |
| `unknown_source_risk_code` | contract finding | retain bounded raw |
| `variation_mapping_required` | structural.* and/or planner.status.* | **not** WP evidence |
| `ambiguous_variation_name` / `ambiguous_variation_ticket_type_name` | planner/normalizer | planner namespace |
| `duplicate_ticket_name` / `duplicate_ticket_type_name` | planner/normalizer | planner namespace |
| `existing_mapping_conflict` / `product_moved_between_events` / `ambiguous_identity` | planner status | planner namespace |
| `duplicate_meta_collapsed` | structural/info | structural namespace |
| `private_event_skipped` / `draft_event_skipped` | structural/info (planner skip notices) | not source evidence |
| `published_event_without_ticket_products` | structural warning | structural |
| `existing_mapping_adopted` / `vwg_pretoria_preserved` | planner/audit | planner/audit |
| Planner create/reuse/adopt actions | planner.action | never findings |

---

## 22. Alias Contract

Alias requirements:

```text
source-version scoped
explicit
one-way
deterministic
proven semantically equivalent
provenance-preserving
never increases certainty
```

No fuzzy, spelling-similarity, or heuristic aliases.

### Approved aliases (v2 → native semantic)

| Source version | Raw | Maps to | Provenance |
|---|---|---|---|
| `2026-07-22.v2` | `trash_event` | `lifecycle` / event / value=`trash` (finding label may be `lifecycle_trashed` / legacy `trashed_event`) | retain raw |
| `2026-07-22.v2` | `subscription_product` | `subscription` / present | retain raw |

### Explicitly rejected / unproven aliases

| Raw | Status | Reason |
|---|---|---|
| `payment_plan_product` → `payment_plan` | **rejected until proven** | Static co-emission with subscription does not prove payment-plan equivalence |
| Any undeclared string | rejected | `unknown_source_risk_code` / undeclared_raw |

Full epistemic classification mapping tables for v2 `explicit_safe` etc. are reserved for the compatibility adapter document (§30), under certainty-monotonicity.

---

## 23. Provenance and Security Bounds

### Allowlisted provenance fields

- `discovery_snapshot_id` / run id
- `schema_version`, `canonical_contract_version`, `producer_version`
- `producer_source_key`
- `raw_producer_code` (bounded)
- `translation_rule_id` / alias id (when adapted)
- `origin`
- `authority_slot`
- target ids

### Prohibited

credentials, signatures, authorization headers, cookies, full upstream payloads, unbounded metadata, customer/order payloads, PII.

### Bounds

| Item | Bound |
|---|---|
| Closed id charset | `[a-z][a-z0-9_]*` max 64 |
| Raw producer code max | 64 bytes UTF-8 |
| Producer source key / path max | 128 bytes UTF-8 |
| Evidence string value max | 64 bytes UTF-8 |
| Max evidence items / page | 500 |
| Max provenance keys | 16 |
| Max page size (`per_page`) | 100 |

If an unknown raw value exceeds bounds: **fail closed**. Do not truncate into an ambiguous canonical value.

Diagnostic storage may retain `sha256` + `byte_length` of rejected oversized input without storing full content.

---

## 24. Ordering, Deduplication and Hashing

When arrays participate in snapshots/hashes:

1. Validate envelopes.
2. Build canonical facts.
3. Apply semantic duplicate collapse (§20).
4. Leave conflicts visible (do not collapse).
5. Sort by canonical key:

```text
facts: (dimension, scope, target_canonical_json, authority_slot, origin, state, value, completeness)
findings: (owner, code, scope, target_canonical_json, source_fact_id)
raw evidence (if hashed): (dimension, producer_scope, target_canonical_json, producer_source_key, state, value)
```

`target_canonical_json` uses sorted object keys and integer ids.

Ordering must not depend on map iteration, DB retrieval order, or incidental producer order.

---

## 25. Parser / Normalizer Contract Boundary

```text
RawProducerEvidence
  → Parser: shape/type/page/version only (may emit parser_error locally)
  → Validated raw evidence
  → CompatibilityTranslation if required (bypassed for native binding)
  → Normalizer: registry + authority + scope + state/completeness validation
  → CanonicalEvidenceFact
  → owned finding emitters
```

Exactly one fact-construction boundary: Normalizer.

Parser does not mint CanonicalEvidenceFact for native pages.

---

## 26. Compatibility Boundary

Summary only (full adapter doc later):

- `origin=compatibility_derived` for all adapted facts.
- Certainty monotonic: preserve or reduce; never strengthen.
- `v2 explicit_safe` ≠ automatic `absent`+`exhaustive`.
- Compatibility-derived facts never satisfy native automation proof.
- v2 persisted semantics immutable.
- Parent regrouping is read-model projection only.

---

## 27. AutoApplyPolicy Future Cutover Boundary

**Current behaviour (unchanged in Phase 5B):**

- Policy version `conservative_auto_apply.v1`
- Snapshot `tickera_catalog_plan.v2`
- Requires expected v2 risk keys all `explicit_safe`
- Independently rejects variation presence
- Catalogue auto-Apply remains disabled unless separately authorized

**Future eligibility requirement (contract intent only):**

```text
native producer binding 2026-08-07.v3 → source_risk.v3
complete discovery (exhaustive collection proven)
all required dimensions evaluated for in-scope targets
only origin=native facts count toward automation proof
no blocking findings / conflicts / contract errors
no compatibility_derived reliance
variation auto-Apply remains prohibited
Human Apply and Applier ownership unchanged
```

Phase 5B does **not** claim existing AutoApplyPolicy already enforces the new envelope. Phase 5C may implement a separately approved policy-version change later.

---

## 28. Performance and Scaling Review

| Component | Data layer | 100k-concurrency | Extra DB? | Streamable? | Redis? | Invalidation |
|---|---|---|---|---|---|---|
| Dimension/authority/disposition registries | immutable compile-time | none (read-only) | no | n/a | **no** | deploy/version |
| Native bindings | immutable compile-time | none | no | n/a | **no** | deploy/version |
| Page evidence ingest | bounded warm/transient | page-bound | no | yes (pages) | no | per discovery |
| Run canonical facts | cold/run-scoped durable or temp | run-bound | batch writes later | after page validate | no | run-scoped |
| Findings | cold run-scoped durable | run-bound | batch writes later | keyset pages | no | run-scoped |

Not the flash-sale seat hot path. Avoid N+1 Ash.create; prefer batch persistence in Phase 5C. Emit parent evidence once per product, not once per variation row.

---

## 29. Contract Invariants

```text
unknown != safe
missing != absent
unsupported != safe
invalid != safe
producer_error != safe
parser_error != safe
absent alone != safe
safe-negative proof requires validated exhaustive authoritative evidence
safe-positive proof must be explicitly allowlisted
undeclared value/state/dimension/code != safe
unknown raw producer code != canonical membership
compatibility translation never strengthens certainty
compatibility_derived != native automation proof
semantic scope comes from contract, not transport IDs
same semantic identity + conflicting claim = blocking conflict
finding code != fact identity
severity is finding-policy owned
relationship evidence != entity evidence
mixed versions/snapshots/pages fail closed
partial discovery != exhaustive
v2 persisted semantics immutable
variation_mapping_required is not a future WP evidence code
unknown_product_semantics is derived, not primary evidence
no AutoApplyPolicy weakening
no automatic variation Apply
Applier remains sole catalogue writer
flat risk string is not primary fact identity
lifecycle is dimension+value based
payment_plan/membership/bundle/add_on never absent/safe without proven authority
subscription positive detection != exhaustive negative authority
```

---

## 30. Open Items Reserved for v2 Adapter

Deferred to `docs/phase-5b/v2-compatibility-adapter.md`:

1. Exact `compat.*` adapter version stamp.
2. Full v2 epistemic map: `explicit_safe|explicit_risky|missing|unknown|unsupported` → state/completeness without strengthening.
3. v2 parent-evidence regrouping projection algorithm and audit fields.
4. Handling of erased `missing_source_risk_data` rows (no invented raw codes).
5. Page-level legacy field adapters for `risk_codes` / `product_semantics`.
6. Human-review rendering rules for adapted runs.
7. Snapshot/plan schema version strategy for mixed historical review.

---

## 31. Acceptance Criteria for Gate C

Gate C succeeds when this document:

- locks producer `2026-08-07.v3` and canonical `source_risk.v3` with declared native binding;
- defines page/snapshot integrity and exhaustive-collection rules;
- defines typed evidence envelopes with closed state/completeness/scopes/dimensions/authorities;
- keeps unresolved product dimensions non-safe without invented authority;
- separates subscription positive vs negative authority;
- allowlists safe-positive and safe-negative policies explicitly;
- keeps finding codes/namespaces separate from fact identity;
- removes `variation_mapping_required` from future WP evidence;
- treats `unknown_product_semantics` as derived;
- reconciles Phase 5A legacy concepts;
- approves only proven aliases;
- preserves Gate B identity/conflict/monotonic-certainty rules;
- states AutoApply future cutover without weakening current policy;
- introduces no Redis/GenServer/Cachex vocabulary path;
- writes no implementation code.

---

## Document control

| Item | Value |
|---|---|
| Next allowed docs | Independent Gate C review; then `v2-compatibility-adapter.md` |
| Forbidden until authorized | Phase 5C implementation boundary, README, commits/PRs, code |
| STOP if | Any §29 invariant would be weakened |

End of source-risk contract.
