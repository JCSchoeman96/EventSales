# Phase 5B — Native Source-Risk Contract

| Field | Value |
|---|---|
| Plan / document ID | `phase-5b-source-risk-contract` |
| Document version | `v3` |
| Status | Draft for final Gate C re-review (PR #152 consistency pass) |
| Scope | Native producer/page envelope, closed dimension/authority/disposition registries, finding policy — **no** v2 adapter detail, **no** Phase 5C implementation |
| Authority | Active Phase 5B **contract** document; subordinate to locked domain model on resource/invariant conflicts |
| Locked domain model | `docs/phase-5b/source-risk-domain-model.md` v2 — SHA256 `16563ee02f58a12d2fde1e6995da3cb4d1be89dfd9ecbb8e07eb76ba5d8a6375` |
| Historical context | `docs/phase-5a/source-risk-blocker-taxonomy.md`, `docs/phase-5a/source-risk-blocker-ledger.csv` |
| Last updated | 2026-08-07 |
| Change summary | Final Gate C consistency: closed EvidenceState only, capability≠missing, event_link absent/invalid split, product_type observation vs support, producer provenance ownership |

### Revision log

- `v1` — initial native source-risk contract after Gate B domain-model lock
- `v2` — Gate C PR #152 corrections from comment `5216546173`
- `v3` — Gate C PR #152 consistency pass from comment `5216673666`

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
- Inventing WordPress authority for unresolved semantic present/absent claims.
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
| `filters` | object | yes | Exact-key allowlist only (§4.1) |
| `events` | array | yes | May be empty |
| `catalog_rows` | array | yes | May be empty |
| `evidence` | array | yes | Native typed evidence items (preferred collection) |

**Native recommendation:** emit typed `evidence[]` as the authoritative evidence collection. Do not rely on open `risk_codes[]` strings for native automation proof. Legacy `risk_codes` / `product_semantics` shapes are compatibility-only (§26, §30).

Auth headers/signatures remain transport security and are **never** persisted as evidence provenance.

### 4.1 Closed `filters` object

Exact allowed keys (all optional values; object itself required):

| Key | Type |
|---|---|
| `updated_since` | RFC3339 Z string \| null |
| `product_id` | pos int \| null |
| `variation_id` | pos int \| null |
| `event_id` | pos int \| null |
| `include_private` | boolean |

Unknown filter keys → parser reject / `contract.contract_violation`.

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

A positive fact may still receive a **dimension-local** `safe_positive_proof` when its authority-specific positive-proof preconditions hold, even before discovery-wide exhaustive completeness is proven. That does **not** make the run automation eligible (§13.1).

If the producer cannot guarantee a stable snapshot across pagination, the discovery **cannot** establish native automation completeness.

Phase 5C may use bounded aggregation, streaming, or run-scoped indexed persistence. Redis is not required and not recommended for this path.

---

## 6. Native Evidence Envelope

Each `evidence[]` item is one producer observation.

### Required fields

| Field | Type | Constraint |
|---|---|---|
| `dimension` | string | Closed native dimension id (§10) |
| `producer_scope` | string | Closed producer scope token (§9) |
| `target` | object | Target identity shape for that scope (§9) |
| `state` | string | Producer-emittable EvidenceState (§7) |
| `producer_source_key` | string | Closed producer evidence/source key (§11) |
| `completeness` | string | Only `exhaustive` \| `partial` \| `unknown` (§8); **not** authoritative alone |
| `provenance` | object | Producer-owned exact-key allowlist only (§23.1); reject trusted local fields if present |

### Optional / conditional fields

| Field | When |
|---|---|
| `value` | Required when state=`present` and dimension defines values; for `event_link` present, value is the resolved `tickera_event_id` |
| `related_targets` | Optional secondary ids; for `event_link`, may echo `{ tickera_event_id }` but must not redefine primary identity |

### Producer must not self-declare authority

`producer_source_key` identifies the producer field/query. Canonical AuthorityDefinition decides whether that key is authoritative for the dimension/state. Producer claims of “authority=true” are ignored/rejected.

### Bounds

| Bound | Value |
|---|---|
| Max evidence items per page | 500 |
| Max evidence items per catalog row association (if nested) | 32 |
| Max `dimension` / `producer_source_key` length | 64 |
| Max string `value` length | 64 |
| Max provenance object keys | equal to allowlist size (exact keys only) |
| Charset for ids/keys | `a-z0-9_` for closed ids; raw unknown codes see §23 |

Missing required fields → parser `missing` / `invalid` path → fail closed.

---

## 7. EvidenceState Registry

Locked native states:

| State | Meaning | Producer-emittable? | Parser-local? |
|---|---|---|---|
| `present` | Authoritative query positively observed the semantic item/relationship | yes | no |
| `absent` | Authoritative observation proves the semantic item/relationship does **not** exist | yes | no |
| `unknown` | Producer executed but cannot decide | yes | no |
| `missing` | Required evidence observation/field itself was not supplied | yes (producer-visible gaps) | yes (missing key) |
| `unsupported` | Integration cannot evaluate the dimension | yes | no |
| `invalid` | Value violates contract shape/enum / malformed unresolvable relationship | yes | yes |
| `producer_error` | Producer evaluation failed | yes | no |
| `parser_error` | Phoenix parse/validation failed | **no** | **yes only** |

Mandatory distinction:

```text
absent =
  authoritative observation proves the semantic item/relationship does not exist

missing =
  required evidence observation itself was not supplied

missing != absent
```

Producer envelopes **must not** emit `parser_error`. Transport cannot impersonate parser errors.

Forbidden collapses: do not merge unknown/missing/unsupported/invalid/producer_error/parser_error into one state.

Generic prose such as “errors fail closed” is allowed when it clearly means producer_error/parser_error paths — never as a ninth EvidenceState token named `error`.

---

## 8. EvidenceCompleteness Registry

The **only** EvidenceCompleteness values are:

| Completeness | Meaning |
|---|---|
| `exhaustive` | Authority’s required coverage for the claimed proof was achieved **and** discovery completion rules hold when required for that claim class |
| `partial` | Observation exists but coverage incomplete |
| `unknown` | Completeness cannot be determined |

There are **no** other completeness tokens. Phrases such as:

```text
read complete
type read complete
relationship resolve complete
present-observation completeness
```

are **authority-specific positive-proof preconditions**, not EvidenceCompleteness values. Policy tables must reference either a closed completeness value or an explicit “authority precondition satisfied” boolean — never invent a fourth completeness enum.

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

If discovery is incomplete, exhaustive claims are rejected → treat as `partial` or `unknown` and non-safe for any claim that requires exhaustive completeness.

---

## 9. Scope Registry

| Scope id | Target identity shape | Notes |
|---|---|---|
| `event` | `{ tickera_event_id: pos_int }` | Event post |
| `parent_product` | `{ woo_product_id: pos_int }` | Parent product |
| `variation` | `{ woo_variation_id: pos_int, woo_product_id: pos_int }` | Variation; parent id required for linkage |
| `ticket_template` | `{ ticket_template_id: pos_int }` | **Reserved** for future evidence about a template entity itself — not used for native v3 product↔template presence |
| `event_product_relationship` | `{ woo_product_id: pos_int }` | Relationship question “does this product have a resolved Tickera event?” — linked event id is **value**, not identity |
| `product_variation_relationship` | `{ woo_product_id: pos_int, woo_variation_id: pos_int }` | Relationship |

Transport row containing both product and variation ids **does not** set semantic scope. Scope comes from the dimension registry.

Producer scope tokens on the wire map 1:1 to these ids for native v3.

---

## 10. Evidence Dimension Registry

Closed native dimensions:

| Dimension id | Allowed scopes | Allowed states | Allowed values | Authority slot | Exhaustive negative permitted? | Native producer support now? | Default fail-closed |
|---|---|---|---|---|---|---|---|
| `lifecycle` | `event`, `parent_product`, `variation` | present, unknown, missing, invalid, producer_error | `publish`, `private`, `draft`, `trash`, `deleted` | `slot.lifecycle.wp_post_status` | no (lifecycle uses positive value proof; “absent” N/A) | event/product: yes; variation: **required by contract**, currently incomplete in WP emission | unknown/missing/invalid/producer_error block; non-publish values risk |
| `ticket_template` | `parent_product` **only** (native v3 presence evidence) | present, absent, missing, unknown, unsupported, invalid, producer_error | optional template id string when present | `slot.ticket_template.meta` | yes for authoritative absent under exhaustive meta read | yes (`_ticket_template`) | absent → explicit_risk; missing → contract blocking_missing; unknown/producer_error block |
| `event_link` | `event_product_relationship` | present, absent, missing, unknown, invalid, producer_error | resolved `tickera_event_id` when present | `slot.event_link.meta` | yes for authoritative absent under exhaustive relationship query | yes (null reference path today) | absent → explicit_risk; missing → contract blocking_missing; invalid → blocking_invalid; unknown/producer_error block |
| `subscription` | `parent_product` | present, absent, unknown, unsupported, missing, invalid, producer_error | optional bounded type/meta digest when present | `slot.subscription.detection` | **no** under current reviewed evidence (positive-only) | positive detection yes; exhaustive negative **no** | present → risk; absent not safe; unknown/unsupported/missing/invalid/producer_error block |
| `payment_plan` | `parent_product` | unsupported, unknown, producer_error | none | `slot.payment_plan.capability` | no | capability reporting only | unsupported/unknown/producer_error block; present/absent unauthorized; missing capability envelope → contract.blocking_missing (not this authority) |
| `membership` | `parent_product` | unsupported, unknown, producer_error | none | `slot.membership.capability` | no | capability reporting only | same |
| `bundle` | `parent_product` | unsupported, unknown, producer_error | none | `slot.bundle.capability` | no | capability reporting only | same |
| `add_on` | `parent_product` | unsupported, unknown, producer_error | none | `slot.add_on.capability` | no | capability reporting only | same |
| `product_type` | `parent_product` | present, unsupported, unknown, missing, invalid, producer_error | closed observed type tokens starting with `simple` (§12); support is policy, not EvidenceState | `slot.product_type.wc` | no | type read available | unevaluable → unsupported; observed non-simple known types → present+explicit_risk; undeclared tokens fail closed |

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

For native automation completeness, a complete discovery must include evaluated facts for every required dimension/scope/target in the completeness set defined by finding policy / future AutoApply cutover (§27). Unresolved product dimensions must still appear as explicit non-safe envelopes (`unsupported` preferred when capability absent) under capability slots.

---

## 11. Authority Registry

| Authority id | Producer system | Producer source key | Scopes | States may assert | Positive proof | Negative / absence proof | Exhaustive requirements |
|---|---|---|---|---|---|---|---|
| `auth.wp_post_status` | `wordpress_tickera` | `wp_posts.post_status` | event, parent_product, variation | present, unknown, missing, invalid, producer_error | yes (status value) | N/A for lifecycle values | Row must exist; status in closed set; unknown status → `unknown` |
| `auth.ticket_template_meta` | `wordpress_tickera` | `postmeta:_ticket_template` | parent_product | present, absent, missing, unknown, invalid, producer_error | yes | yes (`absent` when meta proves no template under exhaustive product meta read) | Allowlisted meta read for that product completed |
| `auth.event_name_meta` | `wordpress_tickera` | `postmeta:_event_name` + `tc_events` resolve | event_product_relationship | present, absent, missing, unknown, invalid, producer_error | yes (resolved event) | yes (`absent` only when exhaustive query proves **no relationship reference exists**) | Deterministic absent vs invalid per §19; never “present” without successful resolve |
| `auth.subscription_detection` | `wordpress_tickera` | `wc_product_type` + allowlisted subscription meta | parent_product | present, unknown, unsupported, missing, invalid, producer_error | yes (type/meta positive match) | **not** under this authority | Exhaustive negative **not** claimed |
| `auth.wc_product_type` | `wordpress_tickera` | `wc_get_product.type` / SQL product type | parent_product | present, unsupported, unknown, missing, invalid, producer_error | yes (observed type value) | N/A | Type read completed; `unsupported` only when type cannot be evaluated; support policy is separate (§12, §15) |
| `auth.wp_semantic_capability` | `wordpress_tickera` | `product_semantics_capability` (declared producer capability report) | parent_product | unsupported, unknown, producer_error | no | no | May report inability to evaluate only; **never** asserts present/absent/missing |

### Capability vs semantic absence

```text
authority to assert unsupported ("I cannot evaluate this semantic")
≠
authority to assert absent ("this semantic is not present")
```

`auth.wp_semantic_capability` may assert **only** `unsupported`, `unknown`, or `producer_error` for `payment_plan`, `membership`, `bundle`, and `add_on`.

It may **never** assert `present`, `absent`, or `missing` for those dimensions.

```text
unsupported / unknown / producer_error
→ capability CanonicalEvidenceFact under auth.wp_semantic_capability

missing required capability observation/envelope
→ contract.blocking_missing
→ NO successful semantic capability authority assertion
→ NOT CanonicalEvidenceFact(authority=auth.wp_semantic_capability, state=missing)
```

### Authority groups / slots

MVP: one authority slot per dimension (no multi-authority precedence).

| Dimension | Authority slot | Authority id |
|---|---|---|
| `lifecycle` | `slot.lifecycle.wp_post_status` | `auth.wp_post_status` |
| `ticket_template` | `slot.ticket_template.meta` | `auth.ticket_template_meta` |
| `event_link` | `slot.event_link.meta` | `auth.event_name_meta` |
| `subscription` | `slot.subscription.detection` | `auth.subscription_detection` |
| `product_type` | `slot.product_type.wc` | `auth.wc_product_type` |
| `payment_plan` | `slot.payment_plan.capability` | `auth.wp_semantic_capability` |
| `membership` | `slot.membership.capability` | `auth.wp_semantic_capability` |
| `bundle` | `slot.bundle.capability` | `auth.wp_semantic_capability` |
| `add_on` | `slot.add_on.capability` | `auth.wp_semantic_capability` |

Do **not** use `slot.<dim>.none` for canonical facts.

Conflicting claims within one slot → `blocking_conflict`. No silent winner.

---

## 12. Evidence Value Registries

### Lifecycle values

| Value | Meaning |
|---|---|
| `publish` | Published |
| `private` | Private |
| `draft` | Draft (non-publish non-trash non-private statuses map only via closed producer classification; otherwise unknown/invalid) |
| `trash` | In trash |
| `deleted` | Authoritative tombstone (native full feed typically does not emit; reserved) |

Mapping rule for producer status classification: closed set `{publish, private, draft, trash}`; any other observed status → state `unknown` or `invalid`, never invent a value.

### Product type observation vs support (native v3 MVP)

EvidenceState `unsupported` means **only**: the integration cannot evaluate `product_type`.

A successfully observed product type always uses:

```text
dimension=product_type
state=present
value=<canonical observed product type>
```

Support is finding policy, not EvidenceState.

| Observed value | EvidenceState | Disposition / finding |
|---|---|---|
| `simple` | `present` | dimension-local `safe_positive_proof` when authority precondition holds |
| other **closed, registry-declared** observed types (none locked beyond `simple` in native v3 MVP) | `present` | `explicit_risk` → `source_risk.unsupported_product_type` when declared as known-but-not-supported |
| undeclared / unknown runtime type token | not silently canonicalized | fail closed with bounded raw provenance (`blocking_invalid` / `blocking_contract_error`) |
| type truly unevaluable | `unsupported` | `blocking_unsupported` |

Only `simple` is currently locked as a concrete canonical product-type value grounded from repository/static source. Do not invent additional Woo type tokens from general knowledge.

### Ticket template values

Bounded optional template id string when `state=present`. Empty string → `invalid`.

### Event link values

When `state=present`, `value` MUST be the successfully resolved positive `tickera_event_id`. Empty/null value with `present` → `invalid`.

---

## 13. Safe-Proof Policy

No state/value is implicitly safe. Safe disposition requires an explicit matching rule.

### 13.1 Dimension-local safety invariant (mandatory)

```text
safe_positive_proof and safe_negative_proof apply only to
one canonical evidence fact / dimension.

They NEVER imply:
  target safe
  row safe
  plan safe
  run safe
  Apply eligible
```

Examples:

```text
product_type=simple
does not prove subscription/payment_plan/membership/bundle/add_on safe

event_link=present
does not prove product safe

lifecycle=publish
does not prove other dimensions safe
```

Whole-run automation eligibility requires all required native facts **and** all existing policy gates (§27).

### 13.2 Safe-positive proof (allowlist)

Authority-specific positive-proof preconditions (not completeness values) must be satisfied in addition to the listed completeness column.

| Dimension | Scope | State | Value | Completeness | Authority precondition | Authority | Disposition |
|---|---|---|---|---|---|---|---|
| `lifecycle` | event / parent_product / variation | present | `publish` | `partial` or `exhaustive` or `unknown`* | post-status row read succeeded for target | `auth.wp_post_status` | `safe_positive_proof` (dimension-local) |
| `ticket_template` | parent_product | present | any valid id | `partial` or `exhaustive` or `unknown`* | allowlisted meta read returned valid template id | `auth.ticket_template_meta` | `safe_positive_proof` (dimension-local) |
| `product_type` | parent_product | present | `simple` | `partial` or `exhaustive` or `unknown`* | product type read succeeded | `auth.wc_product_type` | `safe_positive_proof` (dimension-local) |
| `event_link` | event_product_relationship | present | resolved tickera_event_id | `partial` or `exhaustive` or `unknown`* | `_event_name` read **and** Tickera event resolve succeeded | `auth.event_name_meta` | `safe_positive_proof` (dimension-local) |

\*Dimension-local positive proof does not require discovery-wide exhaustive completeness. Automation still does (§5, §27).

`_event_name` presence alone is **never** enough for `event_link` present/safe-positive. Successful relationship resolution is required.

### 13.3 Safe-negative allowlist (native v3 MVP)

```text
safe-negative allowlist:
EMPTY
```

No native v3 MVP rule yields `safe_negative_proof`.

The general safe-negative formula remains for future contract versions:

```text
state=absent
AND valid authority for negative proof
AND compatible scope
AND completeness=exhaustive
AND registry permits negative proof for that dimension
AND no producer/parser/compatibility error
AND (for automation) origin=native + discovery complete
```

### 13.4 Explicitly non-safe absence cases

| Dimension | State | Completeness | Result |
|---|---|---|---|
| `ticket_template` | `absent` | `exhaustive` | `explicit_risk` → finding `source_risk.missing_ticket_template` |
| `ticket_template` | `missing` | * | `blocking_missing` |
| `event_link` | `absent` | `exhaustive` | `explicit_risk` → finding `source_risk.missing_tickera_event` |
| `event_link` | `missing` | * | `blocking_missing` |
| `event_link` | `invalid` | * | `blocking_invalid` (malformed/unresolvable relationship) |
| `subscription` | `absent` | * | **not accepted as safe** — exhaustive negative authority unproven; remains non-safe / blocking unresolved unless a future authority is proven |
| `payment_plan` / `membership` / `bundle` / `add_on` | `absent` or `present` | * | unauthorized semantic claim → `blocking_authority_mismatch` / `blocking_contract_error` |

### 13.5 Risk-positive proof

Non-publish lifecycle values; subscription `present`; `product_type` `present` with known-but-not-supported declared values; ticket_template `absent`; event_link `absent`; etc. → `explicit_risk` when authority supports the observation.

Do not use EvidenceState `unsupported` to mean “observed but not supported.”

### 13.6 Unresolved

Anything not matched by an explicit safe or explicit_risk rule → fail-closed blocking disposition. Never default to safe.

---

## 14. Risk Disposition Registry

Closed dispositions:

| Disposition | Meaning |
|---|---|
| `safe_positive_proof` | Explicit allowlisted **dimension-local** safe positive |
| `safe_negative_proof` | Explicit allowlisted exhaustive safe absence (none in native v3 MVP) |
| `explicit_risk` | Authoritative risky observation |
| `blocking_unknown` | Unknown / unresolved |
| `blocking_missing` | Required evidence observation not supplied |
| `blocking_unsupported` | Unsupported evaluation |
| `blocking_invalid` | Invalid value/shape / unresolvable relationship |
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

Finding identity uses **owner + local_code** with deterministic qualified name `owner.local_code`.

### Policy classes (summary)

| Class | Dimension / condition | State/value | Completeness | Scope | Authority | Disposition | Qualified finding id | Severity |
|---|---|---|---|---|---|---|---|---|
| Lifecycle publish | `lifecycle` | present/`publish` | any closed | matching | `auth.wp_post_status` | `safe_positive_proof` | none | — |
| Lifecycle private | `lifecycle` | present/`private` | any closed | matching | same | `explicit_risk` | `source_risk.lifecycle_private` | blocking |
| Lifecycle draft | `lifecycle` | present/`draft` | any closed | matching | same | `explicit_risk` | `source_risk.lifecycle_draft` | blocking |
| Lifecycle trash | `lifecycle` | present/`trash` | any closed | matching | same | `explicit_risk` | `source_risk.lifecycle_trashed` | blocking |
| Lifecycle deleted | `lifecycle` | present/`deleted` | any closed | matching | same | `explicit_risk` | `source_risk.lifecycle_deleted` | blocking |
| Lifecycle unresolved | `lifecycle` | unknown/missing/invalid/producer_error | * | matching | * | matching blocking_* | `source_risk.lifecycle_unresolved` or contract ids | blocking |
| Ticket template present | `ticket_template` | present | any closed | parent_product | `auth.ticket_template_meta` | `safe_positive_proof` | none | — |
| Ticket template absent | `ticket_template` | absent | exhaustive | parent_product | same | `explicit_risk` | `source_risk.missing_ticket_template` | blocking |
| Ticket template evidence missing | `ticket_template` | missing | * | parent_product | * | `blocking_missing` | `contract.blocking_missing` | blocking |
| Event link present | `event_link` | present + resolved id | any closed | event_product_relationship | `auth.event_name_meta` | `safe_positive_proof` | none | — |
| Event link absent | `event_link` | absent | exhaustive | event_product_relationship | same | `explicit_risk` | `source_risk.missing_tickera_event` | blocking |
| Event link evidence missing | `event_link` | missing | * | event_product_relationship | * | `blocking_missing` | `contract.blocking_missing` | blocking |
| Event link invalid | `event_link` | invalid | * | event_product_relationship | * | `blocking_invalid` | `contract.blocking_invalid` | blocking |
| Subscription present | `subscription` | present | * | parent_product | `auth.subscription_detection` | `explicit_risk` | `source_risk.subscription` | blocking |
| Subscription non-safe non-present | `subscription` | unknown/unsupported/missing/invalid/producer_error/absent | * | parent_product | * | blocking_* | `source_risk.subscription_unresolved` | blocking |
| Capability dims (semantic) | payment_plan/membership/bundle/add_on | unsupported/unknown/producer_error | * | parent_product | `auth.wp_semantic_capability` | blocking_* | `source_risk.payment_plan` / `.membership` / `.bundle` / `.add_on` | blocking |
| Capability evidence missing | payment_plan/membership/bundle/add_on | missing required observation | * | parent_product | none (contract path) | `blocking_missing` | `contract.blocking_missing` | blocking |
| Product type simple | `product_type` | present/`simple` | any closed | parent_product | `auth.wc_product_type` | `safe_positive_proof` | none | — |
| Product type observed unsupported | `product_type` | present/`<registry-declared non-simple>` | * | parent_product | same | `explicit_risk` | `source_risk.unsupported_product_type` | blocking |
| Product type unevaluable | `product_type` | unsupported | * | parent_product | same | `blocking_unsupported` | `contract.blocking_unsupported` | blocking |
| Product type undeclared token | `product_type` | invalid / contract error | * | parent_product | * | `blocking_invalid` / `blocking_contract_error` | `contract.contract_violation` | blocking |
| Scope mismatch | any | * | * | wrong | * | `blocking_scope_mismatch` | `contract.scope_mismatch` | blocking |
| Authority mismatch | any | * | * | * | wrong | `blocking_authority_mismatch` | `contract.authority_mismatch` | blocking |
| Conflict | same identity | differing claims | * | * | * | `blocking_conflict` | `contract.evidence_conflict` | blocking |
| Undeclared vocabulary | * | * | * | * | * | `blocking_contract_error` | `contract.unknown_source_risk_code` / `contract.contract_violation` | blocking |
| Parser error | * | parser_error | * | * | * | `blocking_error` | `contract.parser_error` | blocking |

Severity is **policy-owned**, not intrinsic to a code string.

Unknown/missing/unsupported/invalid/producer_error/parser_error/conflict remain blocking unless an independently reviewed policy explicitly says otherwise (none currently).

`parser_error` is contract/parser-owned only. It is never a producer semantic evidence state.

---

## 16. Finding and Diagnostic Namespaces

Locked representation:

```text
qualified_finding_id = owner + "." + local_code
```

| Owner | Purpose | Locked examples |
|---|---|---|
| `source_risk` | Catalogue-safety from canonical facts | `source_risk.subscription`, `source_risk.missing_ticket_template`, `source_risk.missing_tickera_event`, `source_risk.lifecycle_trashed` |
| `contract` | Parser/normalizer contract errors | `contract.parser_error`, `contract.scope_mismatch`, `contract.evidence_conflict`, `contract.unknown_source_risk_code` |
| `structural` | Structural notices | `structural.product_has_variations` |
| `planner.status` | Mapping/identity status | `planner.status.variation_mapping_unresolved` |
| `planner.action` | Planned actions | existing planner action types |

Cross-owner code reuse is forbidden. Local codes alone are not identities.

### `variation_mapping_required`

```text
NOT a native WordPress source-risk evidence code
NOT a native evidence dimension
```

Future ownership:

- structural product-group notice → `structural.*`;
- exact variation mapping policy → `planner.status.*`.

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
| `event` | publish/private/draft/trash/deleted | publish (dimension-local) | private/draft/trash/deleted | unknown status → unknown; deleted reserved | status classification exists; trash currently emitted as `trash_event` in v2 |
| `parent_product` | same | publish (dimension-local) | non-publish set | same | product status exists; trash often collapsed into draft_product in v2 — native must emit `trash` distinctly |
| `variation` | same | publish (dimension-local) | non-publish set | same | status often serialized but risk codes not emitted today — native **requires** variation lifecycle evidence |

Do not assume variation lifecycle completeness from event/product status.

Phase 5C must emit variation lifecycle evidence under native producer changes; this contract requires it for native automation completeness when variations are in scope.

---

## 18. Product Semantic Contract

| Dimension | Native treatment |
|---|---|
| `subscription` | Positive detection authority only; present → blocking risk; absent not safe |
| `payment_plan` | Capability authority only; emit `unsupported`/`unknown`/`producer_error`; never `absent`/`present`/`missing` via that authority; missing envelope → `contract.blocking_missing` |
| `membership` | same |
| `bundle` | same |
| `add_on` | same |
| `product_type` | Observed types use `state=present` + value; `simple` may be dimension-local safe-positive; known-but-not-supported declared values → explicit_risk; EvidenceState `unsupported` only when unevaluable |

Excluded as proof: names, slugs, categories, marketing text, arbitrary meta, heuristics.

---

## 19. Relationship Evidence Contract

### `event_link` / `source_risk.missing_tickera_event`

| Item | Rule |
|---|---|
| Dimension | `event_link` |
| Scope | `event_product_relationship` |
| **Primary target identity** | `{ woo_product_id }` only |
| Linked event id | Fact **value** (and optional `related_targets.tickera_event_id`) — **not** part of primary identity |
| Present | state=`present` + successfully resolved Tickera event id → dimension-local `safe_positive_proof` |
| Absent | exhaustive authoritative query proves **no** `_event_name` / event relationship reference exists → `explicit_risk` → `source_risk.missing_tickera_event` |
| Invalid | a relationship reference **exists** but is malformed or cannot resolve to a valid Tickera event → `blocking_invalid` |
| Missing | required event-link evidence omitted → `blocking_missing` |

Deterministic absent vs invalid (no overlap):

```text
absent =
  exhaustive authoritative relationship query proves
  no _event_name / event relationship reference exists

invalid =
  a relationship reference exists but is malformed or cannot
  resolve to a valid Tickera event
```

Examples of `invalid`:

```text
non-positive target id
malformed reference
referenced post missing
referenced post wrong post type
reference cannot resolve to valid tc_events target
```

```text
no relationship reference
→ absent
→ source_risk.missing_tickera_event

relationship reference exists but invalid/unresolvable
→ invalid
→ blocking_invalid
```

Conflict example (mandatory):

```text
same product + event_link + slot.event_link.meta
claim A: present value=10
claim B: present value=20
→ same canonical fact identity
→ conflicting claims
→ blocking_conflict
```

`_event_name` meta existence without successful `tc_events` resolve is **not** present/safe-positive. If the reference exists but cannot resolve, use `invalid`, not `absent`.

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

For `event_link`, target identity is `{woo_product_id}` only. Competing resolved event ids are conflicting **values**.

### Normalized semantic claim (duplicate/conflict)

Contract-significant fields:

| Field | In claim? |
|---|---|
| `state` | yes |
| `value` | yes (normalized; null if N/A) |
| `completeness` | yes (`exhaustive` \| `partial` \| `unknown` only) |
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
| `private_event` / `draft_event` / `trashed_event` / `deleted_event` | typed `lifecycle` value + `source_risk.lifecycle_*` | identity is dimension/value |
| `private_product` / `draft_product` / `trashed_product` / `deleted_product` | typed `lifecycle` | native must distinguish trash vs draft |
| `private_variation` / `draft_variation` | typed `lifecycle` @ variation | required native emission |
| `trash_event` | compatibility alias → lifecycle `trash` @ event | provenance retained |
| `subscription_product` | compatibility alias → `subscription` present | provenance retained |
| `payment_plan_product` | **not** approved alias | undeclared → contract error / unknown raw unless later proven |
| `subscription` | typed dimension + `source_risk.subscription` | — |
| `payment_plan` / `membership` / `bundle` / `add_on` | typed dims via capability authority | blocking unsupported/unknown |
| `missing_ticket_template` | ticket_template **absent** + `source_risk.missing_ticket_template` | not EvidenceState `missing` |
| `unsupported_product_type` | typed `product_type` | — |
| `unknown_product_semantics` | derived summary only | not primary |
| `missing_tickera_event` | event_link **absent** + `source_risk.missing_tickera_event` | relationship scope; identity `{woo_product_id}` |
| `missing_source_risk_data` | `contract.*` finding family | do not erase raw; replace silent fallback |
| `unknown_source_risk_code` | `contract.unknown_source_risk_code` | retain bounded raw |
| `variation_mapping_required` | `structural.*` and/or `planner.status.*` | **not** WP evidence |
| `ambiguous_variation_name` / `ambiguous_variation_ticket_type_name` | planner/normalizer | `planner.status.*` |
| `duplicate_ticket_name` / `duplicate_ticket_type_name` | planner/normalizer | `planner.status.*` |
| `existing_mapping_conflict` / `product_moved_between_events` / `ambiguous_identity` | planner status | `planner.status.*` |
| `duplicate_meta_collapsed` | structural/info | `structural.*` |
| `private_event_skipped` / `draft_event_skipped` | structural/info | not source evidence |
| `published_event_without_ticket_products` | structural warning | `structural.*` |
| `existing_mapping_adopted` / `vwg_pretoria_preserved` | planner/audit | planner/audit |
| Planner create/reuse/adopt actions | `planner.action` | never findings |

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
| `2026-07-22.v2` | `trash_event` | `lifecycle` / event / value=`trash` | retain raw |
| `2026-07-22.v2` | `subscription_product` | `subscription` / present | retain raw |

### Explicitly rejected / unproven aliases

| Raw | Status | Reason |
|---|---|---|
| `payment_plan_product` → `payment_plan` | **rejected until proven** | Static co-emission with subscription does not prove payment-plan equivalence |
| Any undeclared string | rejected | `contract.unknown_source_risk_code` / undeclared_raw |

Full epistemic classification mapping tables for v2 `explicit_safe` etc. are reserved for the compatibility adapter document (§30), under certainty-monotonicity.

---

## 23. Provenance and Security Bounds

Provenance is split by ownership. Do not conflate layers.

```text
producer-supplied provenance
≠
canonical/normalizer-derived provenance
≠
compatibility-adapter provenance
```

### 23.1 Producer-supplied provenance (exact-key allowlist)

Native producer `evidence[].provenance` may include **only**:

| Key | Type |
|---|---|
| `discovery_snapshot_id` | string |
| `producer_version` | string |
| `producer_source_key` | string |
| `raw_producer_code` | string (bounded) |
| `woo_product_id` | pos int |
| `woo_variation_id` | pos int |
| `tickera_event_id` | pos int |

Unknown producer provenance keys → `contract.contract_violation`.

Native producer provenance **must not** supply (reject if present):

```text
origin
authority_slot
translation_rule_id
alias_id
canonical_contract_version
run_id
schema_version
```

Preferred closed-v3 policy: **reject** those fields if producer-supplied. Do not trust or accept them.

### 23.2 Canonical / normalizer-derived provenance

Derived locally by trusted Phoenix boundaries after validation:

| Field | Derived by |
|---|---|
| `origin` | declared producer→canonical binding (`native`) or adapter path (`compatibility_derived`) |
| `authority_slot` | ContractRegistry / normalizer |
| `canonical_contract_version` | declared binding |
| `schema_version` | validated page envelope (already page-level; may be referenced, not producer-asserted on evidence) |
| `run_id` | EventSales discovery/run identity |

### 23.3 Compatibility-adapter provenance

Adapter-only fields:

| Field | Notes |
|---|---|
| `translation_rule_id` | compatibility adapter only |
| `alias_id` | compatibility adapter only |
| `raw_producer_code` | may be retained from legacy |

### 23.4 Prohibited content

credentials, signatures, authorization headers, cookies, full upstream payloads, unbounded metadata, customer/order payloads, PII.

### 23.5 Bounds

| Item | Bound |
|---|---|
| Closed id charset | `[a-z][a-z0-9_]*` max 64 |
| Raw producer code max | 64 bytes UTF-8 |
| Producer source key / path max | 128 bytes UTF-8 |
| Evidence string value max | 64 bytes UTF-8 |
| Max evidence items / page | 500 |
| Max producer provenance keys | exactly the producer allowlist cardinality (no extras) |
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
findings: (qualified_finding_id, scope, target_canonical_json, source_fact_id)
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

Dimension-local safe facts never alone satisfy this cutover.

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
native v3 MVP safe-negative allowlist is EMPTY
safe-positive proof must be explicitly allowlisted
safe_positive_proof / safe_negative_proof are dimension-local only
safe fact != target/row/plan/run/Apply safety
undeclared value/state/dimension/code != safe
unknown raw producer code != canonical membership
compatibility translation never strengthens certainty
compatibility_derived != native automation proof
semantic scope comes from contract, not transport IDs
same semantic identity + conflicting claim = blocking conflict
event_link identity target is {woo_product_id} only
finding code != fact identity
qualified finding id = owner.local_code
severity is finding-policy owned
relationship evidence != entity evidence
EvidenceCompleteness is only exhaustive|partial|unknown
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
payment_plan/membership/bundle/add_on never present/absent without proven semantic authority
capability authority may assert unsupported/unknown/producer_error only for those dims
capability authority never asserts present/absent/missing
product_type unsupported means unevaluable, not observed-but-unsupported
producer provenance cannot self-assert origin/authority_slot/translation_rule_id/alias_id
event_link absent means no relationship reference; invalid means reference exists but fails resolve
no EvidenceState token named error
filters and provenance reject unknown keys
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
- preserves `missing != absent` for ticket_template and event_link;
- keeps event_link identity on `{woo_product_id}` with event id as value;
- keeps event_link absent vs invalid non-overlapping;
- states dimension-local safety explicitly;
- keeps EvidenceCompleteness closed to three values;
- keeps native v3 MVP safe-negative allowlist empty;
- provides capability authority/slots for unresolved dims without asserting missing;
- separates product_type observation (`present`) from support policy;
- uses only `parent_product` for ticket-template presence;
- locks qualified finding namespaces;
- closes filters and splits producer vs derived provenance;
- preserves Gate B identity/conflict/monotonic-certainty rules;
- states AutoApply future cutover without weakening current policy;
- introduces no Redis/GenServer/Cachex vocabulary path;
- writes no implementation code.

---

## Document control

| Item | Value |
|---|---|
| Next allowed docs | Independent Gate C re-review on PR #152; then `v2-compatibility-adapter.md` when authorized |
| Forbidden until authorized | Phase 5C implementation boundary, README, merge, code |
| STOP if | Any §29 invariant would be weakened |

End of source-risk contract.
