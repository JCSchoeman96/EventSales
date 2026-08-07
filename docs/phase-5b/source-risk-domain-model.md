# Phase 5B — Source-Risk Domain Model

| Field | Value |
|---|---|
| Plan / document ID | `phase-5b-source-risk-domain-model` |
| Document version | `v2` |
| Status | Draft for independent domain-model re-review (Gate B REQUEST CHANGES applied) |
| Scope | Domain concepts, resources, invariants, ownership — **no** closed registry vocabulary lock, **no** Phase 5C implementation |
| Authority | This file is the active Phase 5B domain-model contract until superseded in place |
| Supersedes for domain concepts | Informal Phase 5B handoff notes; does not supersede Phase 5A taxonomy |
| Historical context | `docs/phase-5a/source-risk-blocker-taxonomy.md`, `docs/phase-5a/source-risk-blocker-ledger.csv` |
| Last updated | 2026-08-07 |
| Change summary | Gate B targeted hardening: fact identity without code, compatibility state/completeness translation, semantic duplicate equality, single normalizer fact boundary, EOF repair |

### Revision log

- `v1` — initial domain model after Gate A approval with boundary tightening (raw vs compatibility layers, completeness, severity ownership, compatibility-derived origin)
- `v2` — Gate B REQUEST CHANGES: CanonicalEvidenceFact identity excludes answer/code; compatibility may translate legacy epistemic representation without strengthening certainty; semantic (not byte) duplicate equality; parser validates transport only — normalizer alone constructs CanonicalEvidenceFact; remove malformed EOF bytes

---

## 1. Status and Scope

Phase 5A is complete. Phase 5B is design and documentation only. Phase 5C implementation remains locked.

This document defines the **domain model** for source-risk evidence. It does not:

- lock the closed canonical code registry or feed schema stamp;
- specify Phase 5C file-level implementation slices;
- invent WordPress authority for unresolved product dimensions;
- mutate or reinterpret persisted `2026-07-22.v2` runs;
- weaken Human Apply, AutoApplyPolicy, or Applier ownership;
- authorize Apply, mapping mutations, dry-runs, or runtime inspection.

Certified historical run `3efd208f-b148-4568-8591-13d968399081` remains an immutable diagnostic record. This model must not reinterpret it.

---

## 2. Ultimate Goal

WordPress evidence, the feed contract, Phoenix parsing, canonical normalization, source-risk facts, findings, and planning must agree on exactly what evidence exists and what it means.

Unsafe ambiguity must never silently classify as safe.

Work backwards from that outcome: define evidence, completeness, authority, scope, and disposition before codes, adapters, or planners.

---

## 3. Backward-Planned Architecture

```text
1. Domain concepts and ownership (this document)
2. Versioned closed contract + typed envelope + registry
   (future: docs/phase-5b/source-risk-contract.md)
3. Explicit v2 compatibility adapter rules
   (future: docs/phase-5b/v2-compatibility-adapter.md)
4. Ordered Phase 5C implementation boundary (design only)
   (future: docs/phase-5b/phase-5c-implementation-boundary.md)
5. Index README last, after authoritative docs exist
```

Runtime pipeline (conceptual; not an implementation order):

```text
RawProducerEvidence
  → Phoenix parser (transport/shape/version validation only)
  → CompatibilityTranslation when required (bypassed for native)
  → Normalizer + registry/authority/scope validation
  → CanonicalEvidenceFact
  → SourceRiskFinding / StructuralWarning (owned emitters)
  → PlannerDecision / PlannerAction
  → AutoApplyPolicy gate (future cutover may require native new-contract proof;
     current policy remains v2-tied and must not be weakened)
  → Human Apply or (separately eligible) Auto Apply
  → Applier (sole catalogue writer)
```

---

## 4. Terminology

| Term | Definition |
|---|---|
| Producer raw code | Exact string the producer emitted (`trash_event`, `subscription_product`, …) |
| Canonical code | Closed-registry label known to the canonical contract |
| Declared alias | Versioned raw→canonical mapping recorded as a CompatibilityTranslation; not authority |
| Evidence dimension | Semantic axis under observation (lifecycle, subscription, payment_plan, …) |
| Evidence value | Bounded typed observation when the state carries a value |
| Evidence state | What was proven about the dimension (epistemic status) |
| Evidence completeness | How complete the observation is relative to the authority’s required coverage |
| Evidence authority | Named producer + field allowed to assert a dimension |
| Producer scope | Scope the producer claimed on the transport row |
| Semantic scope | Scope the canonical contract assigns to a code/dimension |
| Target identity | Concrete ID(s) the fact or finding attaches to |
| Risk / finding disposition | What the evidence means for catalogue safety |
| Finding severity | Outcome of finding policy (blocking, warning, info, …) — not a code-intrinsic constant alone |
| Provenance | Allowlisted bounded fields that retain origin without full payloads |
| Fact origin | `native` or `compatibility_derived` |
| Confidence | Audit/analysis confidence only; never promotes unknown to safe |

---

## 5. Resource Map

Add a resource only when it introduces a separate invariant. The domain defines at least the following.

### 5.1 RawProducerEvidence

Represents **exactly** what the producer supplied. It is never an adapter output and never silently normalized in place.

May include:

- raw producer code;
- raw evidence state and/or value as supplied;
- producer-declared scope;
- producer field or JSON path;
- producer contract version;
- producer implementation version;
- bounded target identity from the transport row;
- bounded run/discovery identity when already known.

Invariants:

- raw fields remain raw;
- normalization does not rewrite RawProducerEvidence;
- absence of a field is itself observable as missing at parse time, not silently filled.

### 5.2 CompatibilityTranslationRecord

Represents an explicit, versioned translation **event**, not an evidence authority.

Compatibility translation is **not** limited to raw-code aliasing. It may also translate legacy epistemic representation into the new model’s EvidenceState / EvidenceCompleteness vocabulary when a declared compatibility rule exists.

Records at minimum (conceptual; exact fields deferred to the contract document):

- raw code (when applicable);
- canonical code (when code translation succeeds);
- raw classification / legacy state (when applicable), for example v2 `explicit_safe`, `explicit_risky`, `missing`, `unknown`, `unsupported`;
- translated EvidenceState (when state translation is performed);
- translated EvidenceCompleteness (when completeness can be stated without inventing certainty);
- alias / compatibility-table identifier and/or translation rule id;
- translation reason / rule id;
- source (producer) contract version;
- compatibility adapter version;
- translation result (`translated` \| `undeclared_raw` \| `rejected` \| `error`);
- link to the RawProducerEvidence identity.

The adapter never becomes authority for a dimension. Successful translation does not change fact origin to `native`.

**Certainty monotonicity (mandatory):** compatibility translation may preserve or reduce certainty relative to what the historical source proves. It must never create stronger evidence than the historical source and historical contract prove. In particular, v2 `explicit_safe` must **not** automatically become `EvidenceState = absent` and `EvidenceCompleteness = exhaustive` unless exhaustive negative proof is explicitly supported by the historical source contract and AuthorityDefinition. When historical completeness cannot be proven, compatibility-derived completeness remains `unknown` (or another explicitly weaker compatibility-appropriate value) — never invented as exhaustive.

### 5.3 CanonicalEvidenceFact

Validated semantic evidence after:

- closed-registry lookup;
- declared alias translation when applicable;
- authority validation;
- scope validation;
- state and completeness validation.

Must retain bounded raw provenance (raw code, producer path, versions, translation id when used). Must carry `origin: native | compatibility_derived`.

### 5.4 SourceRiskFinding

Owned projection from one or more CanonicalEvidenceFacts (or an owned contract-error path) into a durable finding.

Finding code, severity, and meaning are owned by the finding emitter and finding policy — not by raw string equality with another emitter.

### 5.5 StructuralWarning

Normalizer- or planner-owned structural notice with its **own** code namespace and identity.

Must not reuse source-risk evidence codes with incompatible meaning or severity.

### 5.6 PlannerDecision

Planner-owned evaluation outcome for an identity or mapping question (for example: create eligible, conflict, ambiguous, missing destination).

Not a source-risk evidence fact.

### 5.7 PlannerAction

Durable planned mutation proposal (event create, ticket create, mapping create, …).

Not equal to a finding. Not equal to Apply execution.

### 5.8 ContractRegistry

Immutable, preferably compile-time, closed registry of:

- canonical codes / dimensions;
- allowed semantic scopes;
- allowed evidence states;
- whether authoritative negative proof is permitted;
- required authorities;
- declared aliases by compatibility version;
- finding-policy hooks or disposition rules references.

Unknown runtime strings do not automatically become registry members.

### 5.9 AuthorityDefinition

Immutable definition of who may assert a dimension:

- authority id;
- producer system;
- authoritative field or query;
- supported scopes;
- supported states;
- whether exhaustive negative proof is contract-permitted;
- completeness requirements for exhaustive coverage.

### 5.10 ScopeDefinition

Immutable definition of a semantic scope kind and its allowed target identity shape.

Transport row shape does not define semantic scope.

---

## 6. Ownership Boundaries

| Boundary | Owns | Must not |
|---|---|---|
| WordPress producer | RawProducerEvidence emission | Emit planner codes as source-risk evidence; invent authority |
| Transport / feed | Signed pages, producer contract version, pagination integrity | Reclassify evidence |
| Phoenix parser | Shape/type/version validation; reject mixed versions | Invent canonical codes; erase raw provenance |
| Compatibility adapter | Declared alias translation records; compatibility-derived projections | Act as authority; mint native facts; satisfy auto-Apply completeness |
| Normalizer | Scope checks; fact construction from validated inputs | Copy parent evidence to variation; silent safe completion after provenance loss |
| Source-risk registry | Closed vocabulary and authority bindings | Accept undeclared runtime codes as canonical |
| Finding emitter (source-risk) | SourceRiskFinding codes and policy application | Share codes with structural/planner emitters |
| Structural warning emitter | StructuralWarning codes and identities | Reuse source-risk codes with different meaning |
| Snapshot persistence | Immutable run-scoped snapshots and findings | Rewrite historical v2 meaning |
| Planner | PlannerDecision / PlannerAction | Claim WordPress source-risk authority |
| AutoApplyPolicy | Fail-closed eligibility | Accept compatibility-derived facts as native proof |
| Applier | Sole catalogue writes | Be bypassed by findings or planners |
| Human Apply | Explicit operator apply path | Be replaced by silent automation |

Separations that must remain visible:

```text
evidence ≠ finding
finding ≠ structural warning
finding ≠ planner action
planner action ≠ Apply execution
compatibility translation ≠ authority
compatibility_derived ≠ native
```

---

## 7. Evidence Pipeline

There is exactly one conceptual fact-construction boundary: the **Normalizer** (with ContractRegistry, AuthorityDefinition, and ScopeDefinition). The parser never mints CanonicalEvidenceFact merely because the producer speaks the native contract version.

```text
WordPress / reviewed producer
  emits RawProducerEvidence (raw codes, states, scopes, paths, versions)
        │
        ▼
Phoenix parser
  shape / type / page / version validation
  preserves raw envelopes; rejects mixed versions
  does NOT construct CanonicalEvidenceFact
        │
        ▼
Validated raw evidence
        │
        ├── native producer contract
        │     CompatibilityTranslation bypassed
        │
        └── legacy / non-native producer contract
              → CompatibilityTranslationRecord
              → compatibility-derived normalized input
                    (origin remains compatibility_derived;
                     certainty not strengthened)
        │
        ▼
Normalizer
  registry lookup
  authority validation
  semantic-scope validation
  state / completeness validation
        │
        ▼
CanonicalEvidenceFact
  origin = native | compatibility_derived
        │
        ▼
SourceRiskFinding / StructuralWarning (owned emitters)
        │
        ▼
PlannerDecision / PlannerAction
        │
        ▼
AutoApplyPolicy / Human Apply → Applier
```

Rules:

1. Do not represent raw evidence and adapter output as one resource.
2. CompatibilityTranslation is a recorded event between validated raw evidence and the normalizer’s input when the producer contract is not the native canonical contract; it is bypassed for native evidence.
3. Parser validates transport/shape/version only (§6). Normalizer alone constructs canonical semantic facts for both native and compatibility-derived paths.
4. CanonicalEvidenceFact never erases raw provenance.
5. Findings and planner artifacts are downstream projections with independent identities.

---

## 8. Evidence State Machine

Evidence state answers: **What was proven?**

It does **not** answer: **Is catalogue apply safe?**

### 8.1 EvidenceState (conceptual closed set)

| State | Meaning |
|---|---|
| `present` | The authoritative query positively observed the asserted condition or value |
| `absent` | The authoritative query returned a negative observation for the dimension |
| `unknown` | The producer executed but cannot decide |
| `missing` | Required field, key, or observation was not supplied |
| `unsupported` | The integration/API cannot evaluate the dimension under this contract |
| `invalid` | Supplied value violates contract shape/type/enum |
| `producer_error` | Producer evaluation attempted and failed |
| `parser_error` | Phoenix parse or validation failed for the envelope |

Names may be refined in the contract document if a better closed vocabulary is justified; these distinctions must remain.

### 8.2 Forbidden equivalences

```text
present  ≠  risky          (disposition is separate)
absent   ≠  safe           (completeness and authority required)
missing  ≠  absent
unsupported ≠ absent
unknown  ≠  absent
nil / missing key ≠ absent
parser_error ≠ safe
producer_error ≠ safe
```

### 8.3 RiskDisposition / FindingDisposition

Disposition answers: **What does this evidence mean for catalogue safety?**

Conceptual dispositions include:

- `safe_negative_proof` — only via the safe-absence proof in §9;
- `explicit_risk` — authoritative positive proof of a risky condition;
- `blocking_unknown` — unknown / unresolved;
- `blocking_missing` — missing required evidence;
- `blocking_unsupported`;
- `blocking_invalid`;
- `blocking_error` — producer or parser error;
- `blocking_scope_mismatch`;
- `blocking_authority_mismatch`;
- `blocking_conflict` — conflicting facts or authorities;
- `not_applicable` — fact recorded for proof completeness without a finding.

Disposition is computed by owned policy from semantic context; it is not identical to EvidenceState.

---

## 9. Completeness and Safe-Absence Proof

### 9.1 EvidenceCompleteness

Modelled separately from EvidenceState.

Recommended closed values:

| Completeness | Meaning |
|---|---|
| `exhaustive` | Authority’s required coverage for negative (or full) proof was achieved under the contract |
| `partial` | Some observation exists but coverage is incomplete |
| `unknown` | Completeness cannot be determined |

### 9.2 Safe-absence proof (mandatory)

`absent` alone is **never** safe.

Safe absence requires **all** of:

```text
EvidenceState == absent
AND authority is valid for the dimension (AuthorityDefinition match)
AND semantic scope is compatible (ScopeDefinition + registry)
AND EvidenceCompleteness == exhaustive
AND the ContractRegistry explicitly permits authoritative negative proof for that dimension/code
AND no producer_error, parser_error, or compatibility translation error exists on the path
AND fact origin rules for automation are satisfied when used as automation proof
   (native facts only for new-contract auto-Apply completeness; see §14)
```

Anything else remains non-safe.

In particular:

```text
absent + partial              ≠ safe
absent + unknown completeness ≠ safe
absent + wrong authority      ≠ safe
absent + wrong scope          ≠ safe
missing                       ≠ absent
unsupported                   ≠ absent
unknown                       ≠ absent
compatibility_derived alone   ≠ native automation safe-proof
```

---

## 10. Scope Model

### 10.1 Scope kinds

Define separately; do not collapse relationship evidence into entity evidence:

| Scope | Attaches to |
|---|---|
| `event` | Tickera / event post identity |
| `parent_product` | Woo parent product identity |
| `variation` | Woo variation identity |
| `ticket_template` | Ticket template linkage evidence |
| `event_product_relationship` | Relationship between event and product |
| `product_variation_relationship` | Relationship between parent product and variation |

### 10.2 Transport vs semantic scope

A catalog transport row may contain both `woo_product_id` and `woo_variation_id`. That **does not** determine semantic scope.

Semantic scope comes from the canonical contract (code/dimension → allowed ScopeDefinition).

Target identity must match the semantic scope. Scope-incompatible codes fail closed.

### 10.3 Parent / variation rule

Parent product semantics must not become variation-scoped merely because the transport row contains a variation ID.

Variation lifecycle or attributes must not be promoted to parent product scope without explicit contract authority.

Relationship scopes (`event_product_relationship`, `product_variation_relationship`) carry relationship evidence such as missing Tickera event links — they are not silently rewritten as pure `event` or `parent_product` facts.

---

## 11. Authority Model

### 11.1 AuthorityDefinition

Each evidence dimension that may produce CanonicalEvidenceFacts must bind to zero or more reviewed authorities. Zero authorities implies the dimension cannot leave `unknown` / unsupported paths except via explicit contract rules.

Authority is proven by reviewed producer/source definition — **never** by:

- names, descriptions, slugs, categories, labels, marketing text;
- compatibility adapter translation;
- heuristic inference;
- absence of a risk code string.

### 11.2 Product semantic dimensions (Phase 5A locked stance)

For:

- `payment_plan`
- `membership`
- `bundle`
- `add_on`

No authoritative evidence source has yet been proven.

Current design state:

```text
unknown
blocking
```

Do not invent authority in Phase 5B. Do not claim a compatibility adapter can establish authority. Future authority requires an explicitly reviewed producer/source definition recorded in AuthorityDefinition and the contract registry.

### 11.3 Lifecycle and reviewed authorities (illustrative binding, not registry lock)

Examples of dimensions that already have reviewed static authority candidates (locked as “authority exists” only where Phase 5A proved it; exact field bindings belong in the contract document):

- event / product post lifecycle via `wp_posts.post_status` when the row exists;
- ticket template presence via allowlisted `_ticket_template` meta under declared contract;
- subscription **positive** detection candidates via reviewed Woo subscription type/meta adapters (positive evidence must retain provenance; undeclared aliases must not erase it).

Variation lifecycle emission completeness remains an open contract decision (§22).

### 11.4 Conflicting authorities

If two authorities disagree for the same fact identity, disposition is `blocking_conflict` (or equivalent). Do not pick a winner silently.

---

## 12. Finding and Diagnostic Ownership

### 12.1 Separation

| Artifact | Owner | Purpose |
|---|---|---|
| RawProducerEvidence | Producer | Exact supplied observation |
| CanonicalEvidenceFact | Normalizer + registry | Validated semantic fact |
| SourceRiskFinding | Source-risk finding emitter | Catalogue-safety finding from facts / contract errors |
| StructuralWarning | Structural emitter | Structural/process notice |
| PlannerDecision | Planner | Identity/mapping evaluation |
| PlannerAction | Planner | Proposed catalogue mutation |
| Apply decision / job | AutoApplyPolicy + Apply workers | Execution gate and write orchestration |
| Catalogue write | Applier only | Durable catalogue mutation |

### 12.2 Finding severity ownership

Severity is **not** a property of canonical code alone.

Finding policy evaluates severity (and disposition) from at least:

- canonical meaning / code;
- evidence state;
- evidence completeness;
- semantic scope;
- finding emitter / owner.

This prevents two independent emitters from reusing one code with incompatible severity or meaning — the Phase 5A `variation_mapping_required` overloading defect.

Code equality never implies finding identity.

### 12.3 `variation_mapping_required`

Domain lock:

```text
variation_mapping_required is not a future WordPress source-risk evidence code
```

Variation identity presence is not authoritative mapping-risk evidence.

Mapping status belongs to planner / operator mapping logic.

Structural warning ownership must use a separate, unambiguous code family.

Final replacement names are deferred to the contract document unless a name is required to state an invariant (none required here beyond the prohibition).

### 12.4 `unknown_product_semantics`

Model as a **derived summary**, not a primary evidence dimension.

Preferred recommendation:

```text
Do not persist it as an additional co-equal blocking finding
when the underlying per-dimension findings already exist.
```

It may exist as:

- derived summary;
- UI aggregate;
- diagnostic count;
- audit / read model.

It must not multiply blocker identities unnecessarily.

Historical v2 `unknown_product_semantics` findings remain unchanged and auditable.

---

## 13. Identity and Deduplication

Do not deduplicate merely because two records share a diagnostic code string.

### 13.1 RawProducerEvidence — candidate identity

- run / discovery identity;
- producer;
- producer contract version;
- dimension and/or raw code;
- producer-declared scope;
- target identity (as supplied);
- producer field / path.

### 13.2 CanonicalEvidenceFact — candidate identity

The identity represents the **semantic question being answered**, not the answer or registry code.

Candidate identity components:

- run / discovery identity;
- canonical evidence dimension;
- semantic scope;
- target identity;
- authority identity or authority slot / group.

State, value, canonical code (when used as a derived registry label), and disposition are **claims attached to that identity**. They must not create separate identities merely because they disagree.

Canonical risk/finding codes such as `private_product` or `draft_product` may be retained as fields or provenance/registry labels. They are **not** primary identity components.

**Conflict invariant:**

```text
Two authoritative canonical facts for the same semantic fact identity
with incompatible state/value claims MUST collide and fail closed.
```

Illustrative example:

```text
same run
same parent_product target
same lifecycle dimension
same authority slot
claim A: private
claim B: draft
→ conflict (fail closed)
```

Including `private_product` vs `draft_product` in the identity to hide that conflict is forbidden.

Origin may be retained for audit. A second fact must not hide a conflicting claim for the same semantic identity without conflict handling — including across `native` and `compatibility_derived` observations of the same identity.

### 13.3 SourceRiskFinding — candidate identity

- run identity;
- finding owner / emitter;
- finding code;
- semantic scope;
- target identity;
- source fact identity where applicable.

### 13.4 StructuralWarning

Own identity and own code namespace. Must not collide with SourceRiskFinding identity rules by shared code alone.

### 13.5 PlannerDecision / PlannerAction

Planner-owned identities (for example exact variation destination keys, action refs). Independent from finding identities even when human operators discuss them together.

### 13.6 Non-equivalence of Phase 5A row sets

Do not treat as equivalent:

- source-risk blockers;
- structural warnings;
- planned-create actions.

Phase 5A proved code overloading and aggregate co-occurrence; it did not prove row-set equality.

---

## 14. Compatibility Model

### 14.1 Fact origin

Every CanonicalEvidenceFact carries:

```text
origin: native | compatibility_derived
```

| Origin | Meaning | May satisfy new-contract auto-Apply completeness? |
|---|---|---|
| `native` | Produced from a producer observation under the native canonical contract | Yes, when all other proof rules hold |
| `compatibility_derived` | Produced via CompatibilityTranslation / v2 adapter projection | **No** |

### 14.2 Adapter invariants

The v2 compatibility adapter:

- may translate declared aliases (example: `trash_event` → `trashed_event`) and record CompatibilityTranslationRecord;
- may translate legacy epistemic classifications (`explicit_safe`, `explicit_risky`, `missing`, `unknown`, `unsupported`) into EvidenceState / EvidenceCompleteness / disposition-relevant representation under declared rules;
- may produce compatibility-derived human-review representations;
- may support historical rendering and migration diagnostics;
- must **never** upgrade historical v2 evidence into native new-contract authority;
- must **never** independently satisfy new-contract auto-Apply completeness;
- must not treat parent-product regrouping as creation of new authoritative evidence — regrouping is a compatibility / read-model projection only;
- must leave persisted v2 meaning immutable;
- must obey certainty monotonicity (§5.2): preserve or reduce certainty; never strengthen it.

**Legacy `explicit_safe` rule (mandatory):**

```text
v2 explicit_safe MUST NOT automatically become:
  EvidenceState = absent
  AND EvidenceCompleteness = exhaustive
```

unless exhaustive negative proof is explicitly supported by the historical source contract and AuthorityDefinition. When historical completeness cannot be proven, adapted completeness remains `unknown` (or another weaker compatibility-appropriate value). Compatibility may translate representation; it may not invent exhaustive proof.

Forbidden:

```text
v2 adapted evidence → native automation proof
compatibility translation → stronger certainty than historical source proves
```

without a new native producer observation under the new contract (for the first) / without historical exhaustive proof (for the second).

### 14.3 Mixed versions

Mixed incompatible producer contract versions across pages of one discovery fail closed for the whole discovery.

---

## 15. Versioning Model

These versions are **not** interchangeable:

| Version | Governs |
|---|---|
| Producer contract version | Feed/schema vocabulary and shapes the producer emits |
| Canonical contract version | Closed registry, envelope, scope, authority, disposition rules |
| Compatibility adapter version | Declared alias tables and translation behaviour |
| Snapshot / plan schema version | Persisted plan snapshot shape |

Do **not** choose the exact new producer/canonical version date stamp in this document. That is a later contract decision.

Changing semantics requires a new version. Do not mutate `2026-07-22.v2` meaning in place.

---

## 16. Permissions and Policies

| Policy | Rule |
|---|---|
| Human Apply | Remains explicit; not replaced by findings |
| AutoApplyPolicy | Fail-closed; requires native new-contract completeness when cut over; never accepts compatibility-derived facts as native proof; never auto-Applies variations |
| Applier | Sole catalogue writer |
| Catalogue auto-Apply config | Remains disabled unless a separately authorized task enables and tests it |
| Mapping resolver | Local lookup only; not a source-risk authority |
| Phase 5B / 5C docs | Must not weaken the above |

---

## 17. Invariants

```text
unknown ≠ safe
missing ≠ absent
unsupported ≠ safe
nil ≠ safe
parser_error ≠ safe
producer_error ≠ safe
unrecognised canonical code ≠ safe
undeclared raw code ≠ automatic canonical membership
absent alone ≠ safe
absent + partial ≠ safe
absent + unknown completeness ≠ safe
absent + wrong authority ≠ safe
absent + wrong scope ≠ safe
compatibility_derived ≠ native automation proof
compatibility translation must not strengthen historical certainty
v2 explicit_safe ≠ automatic absent+exhaustive
evidence ≠ finding
finding ≠ structural warning
finding ≠ planner action
planner action ≠ Apply execution
code equality ≠ record identity
canonical code ≠ CanonicalEvidenceFact identity component
same semantic fact identity + incompatible claims → conflict
parent_product evidence ≠ variation scope merely from transport variation_id
scope mismatch → fail closed
authority mismatch → fail closed
conflicting facts → fail closed
mixed contract versions → fail closed
parser ≠ canonical fact constructor
v2 persisted semantics immutable
raw provenance retained (bounded)
no second catalogue writer
no AutoApplyPolicy weakening
no automatic variation Apply
```

Note on AutoApplyPolicy: requiring native new-contract completeness is a **future cutover rule**. Current AutoApplyPolicy remains tied to existing snapshot/risk proof behaviour (including `tickera_catalog_plan.v2` and variation rejection). Phase 5B must not weaken that policy and must not imply it already consumes the future contract.

---

## 18. Failure Modes

Every unsafe or unresolved case fails closed (non-safe disposition; block automation proof).

### 18.1 Duplicate vs conflict (canonical semantic equality)

Do **not** define duplicate equality by JSON/map/string byte serialization.

```text
same CanonicalEvidenceFact identity (§13.2)
+ same normalized semantic claim
→ duplicate / deterministic collapse

same CanonicalEvidenceFact identity
+ different normalized semantic claim
→ blocking conflict
```

The normalized semantic claim conceptually covers contract-significant fields such as:

- EvidenceState;
- evidence value (when applicable);
- EvidenceCompleteness;
- semantic scope;
- authority (or authority slot / group);
- fact origin (`native` \| `compatibility_derived`).

Canonical code may appear as a derived registry label on the claim when useful; it must not redefine identity (§13.2).

When equivalent canonical claims collapse, all bounded provenance records remain retained or referenceable. RawProducerEvidence may still retain multiple raw observations when their provenance differs.

### 18.2 Failure-mode table

| Failure mode | Required behaviour |
|---|---|
| Unknown raw producer code | Retain bounded raw code; CompatibilityTranslation `undeclared_raw` or reject; Canonical path emits contract-error fact/finding; never silent `missing_source_risk_data`-style erasure of the raw value |
| Undeclared alias | Do not translate; treat as unknown raw |
| Wrong authority | Reject or blocking_authority_mismatch |
| Wrong semantic scope | Reject or blocking_scope_mismatch; no retarget by transport IDs |
| Partial evidence presented as exhaustive | Invalid; cannot enter safe-absence proof |
| Missing required evidence | `missing` / blocking_missing |
| Unsupported producer capability | `unsupported` / blocking_unsupported |
| Producer error | `producer_error` / blocking_error |
| Parser error | `parser_error` / blocking_error |
| Mixed contract versions | Reject discovery aggregation |
| Duplicate facts (same identity) | Same canonical fact identity + same normalized semantic claim → deterministic collapse (not byte-serialization equality); retain/reference bounded provenance |
| Conflicting facts | Same canonical fact identity + different normalized semantic claim → blocking_conflict |
| Conflicting authoritative producers | blocking_conflict |
| Overloaded diagnostic code | Forbidden in new contract; emitters own distinct codes |
| Compatibility-derived mistaken for native | Origin field mandatory; AutoApplyPolicy rejects compatibility-derived as native proof |
| Compatibility strengthens certainty | Forbidden; adapted completeness must not invent exhaustive proof |
| v2 explicit_safe auto-mapped to absent+exhaustive | Forbidden unless historical contract + authority explicitly prove exhaustive negative proof |
| Safe inference without exhaustive proof | Forbidden |
| Parser mints CanonicalEvidenceFact | Forbidden; normalizer is the sole fact-construction boundary |

---

## 19. Security and Provenance

Provenance is bounded and allowlisted.

### 19.1 Allowed provenance classes (conceptual)

- run / discovery id;
- producer contract version;
- producer implementation version;
- compatibility adapter version;
- canonical contract version;
- raw producer code (bounded length);
- producer field / JSON path (bounded);
- authority id;
- semantic scope + target ids;
- translation result / alias id;
- fact origin.

### 19.2 Explicitly prohibited

- secrets;
- credentials;
- signed request material;
- authorization headers;
- raw full upstream payloads;
- unbounded plugin metadata;
- unbounded strings or arrays;
- customer PII, order payloads, or marketing content as “evidence”.

Raw producer code may be retained. The future implementation contract must define a bounded maximum representation (length and charset). Exact bounds are deferred to the contract / Phase 5C boundary documents.

---

## 20. Performance and Scaling Review

| Representation | Data layer | Notes |
|---|---|---|
| ContractRegistry | Immutable / compile-time | Prefer no runtime mutability |
| AuthorityDefinition | Immutable / compile-time | Versioned with contract |
| ScopeDefinition | Immutable / compile-time | Versioned with contract |
| Compatibility aliases | Immutable / compile-time | Keyed by compatibility adapter version |
| Run RawProducerEvidence / CanonicalEvidenceFacts | Cold or bounded run-scoped durable data | Page-bounded ingest |
| Findings / warnings | Cold durable run-scoped data | Independent identities |
| Planner decisions / actions | Cold durable run-scoped data | Existing planner ownership |

Do **not** recommend Redis, Cachex, or GenServer for static vocabulary.

For later Phase 5C persistence (record only; no design expansion here):

- avoid N+1 writes;
- use bounded pages;
- stream where possible;
- batch durable writes where appropriate;
- index critical identity / query paths;
- bound provenance and collections;
- emit parent-product evidence once (not once per variation transport row) under the native contract.

Full-page / full-run aggregation remains required before findings whose truth depends on cross-page completeness.

---

## 21. Decisions Locked by Phase 5A

These remain binding inputs to Phase 5B:

1. Certified run `3efd208f-b148-4568-8591-13d968399081` is immutable historical evidence; do not reinterpret under new semantics.
2. Ledger: 100 blocking rows; 72 `C_unknown_by_design`; 28 `E_scope_or_duplication`; observed product/variation scope 72/28.
3. Finding-code totals: add_on 14, bundle 14, membership 14, missing_source_risk_data 2, payment_plan 14, unknown_product_semantics 28, variation_mapping_required 14.
4. Unknown remains unknown and blocking; missing/unsupported/error are never safe.
5. Two `missing_source_risk_data` rows cannot recover erased producer codes — do not invent them.
6. Flat open `risk_codes` plus silent fallback destroyed provenance — closed registry and retained raw codes are required.
7. Parent product semantics on variation rows retargeted by `woo_variation_id` is a scope defect — transport identity ≠ semantic scope.
8. `variation_mapping_required` is overloaded across independent emitters — future WP source-risk vocabulary must not carry it.
9. `payment_plan`, `membership`, `bundle`, `add_on` lack proven authority — remain unknown/blocking.
10. `unknown_product_semantics` umbrella amplification is costly — treat as derived summary going forward; keep historical rows.
11. Declared alias example: `trash_event` → `trashed_event` with retained alias provenance.
12. `missing_tickera_event` must be a first-class relationship concern, not collapsed into generic missing-data erasure.
13. `payment_plan_product` must not alias to `payment_plan` until semantic equivalence is proven.
14. AutoApplyPolicy, Human Apply, and Applier ownership must not weaken; no automatic variation Apply.
15. Primary model moves from flat risk strings to typed evidence facts.

---

## 22. Open Decisions for the Contract Document

Deferred to `docs/phase-5b/source-risk-contract.md` (and related Phase 5B docs), not decided here:

1. Exact new producer / canonical contract version stamp string.
2. Exact closed EvidenceState / EvidenceCompleteness atom names if refined.
3. Full closed canonical registry rows (codes, aliases, severities via policy tables).
4. Exact AuthorityDefinition bindings per dimension, including whether subscription positive detection maps only to `subscription`.
5. Whether and when `payment_plan_product` may become a declared alias.
6. Exact variation lifecycle codes the native producer must emit.
7. Exact StructuralWarning and planner mapping-status code names replacing overloaded `variation_mapping_required`.
8. Exact derived-summary representation for `unknown_product_semantics` (UI-only vs audit record).
9. Bounded max length / charset for retained raw producer codes and paths.
10. Snapshot / plan schema version bump strategy relative to the new feed contract.
11. Cutover policy detailing when new runs must be native-contract-only for human vs automation paths — including how AutoApplyPolicy versioning relates to the future contract without implying current policy already consumes it.
12. Precise finding-policy tables (inputs → disposition → severity) per emitter.
13. Declared compatibility tables mapping v2 epistemic classifications (`explicit_safe`, `explicit_risky`, `missing`, `unknown`, `unsupported`) to EvidenceState / EvidenceCompleteness without strengthening certainty.
14. Exact definition of “authority slot / group” for CanonicalEvidenceFact identity when multiple authorities can observe one dimension.
15. Exact normalized semantic-claim field set used for duplicate/conflict comparison (beyond the conceptual list in §18.1).

---

## Document control

| Item | Value |
|---|---|
| Next allowed documentation task | Independent review of this domain model; only then `source-risk-contract.md` |
| Forbidden until review | Other Phase 5B docs, Phase 5C implementation, commits/PRs unless separately authorized |
| STOP if | Any invariant in §17 would be weakened by a later document |

End of domain model.
