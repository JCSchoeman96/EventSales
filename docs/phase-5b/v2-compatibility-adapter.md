# Phase 5B — v2 Source-Risk Compatibility Adapter

| Field | Value |
|---|---|
| Plan / document ID | `phase-5b-v2-compatibility-adapter` |
| Document version | `v2` |
| Status | Draft for independent Gate D re-review (PR #153) |
| Scope | Compatibility translation from historical `2026-07-22.v2` representations into locked `source_risk.v3` **projections** — no implementation, no historical mutation |
| Authority | Active Phase 5B Gate D contract; subordinate to locked domain model and native contract on conflicts |
| Locked domain model | `docs/phase-5b/source-risk-domain-model.md` — SHA256 `16563ee02f58a12d2fde1e6995da3cb4d1be89dfd9ecbb8e07eb76ba5d8a6375` |
| Locked native contract | `docs/phase-5b/source-risk-contract.md` — SHA256 `87dec4238e5c7ea04fe8d2a9735980a35f2bf542324a851686d60fead1d0785c` |
| Historical context | `docs/phase-5a/source-risk-blocker-taxonomy.md`, `docs/phase-5a/source-risk-blocker-ledger.csv` |
| Last updated | 2026-08-07 |
| Change summary | Harden translation: no null-status→absent, no draft_product-only→draft, closed product_type registry, split missing_source_risk_data, precedence≠conflict |

### Revision log

- `v1` — initial compatibility adapter after PR #152 merge (`83fae70…`)
- `v2` — Gate D REQUEST CHANGES on PR #153: weaken overstated translations; separate precedence from conflict
### Conflict rule

```text
domain model + source_risk.v3 native contract win on semantics/invariants
this adapter wins only on historical translation rules and projection behaviour
```

---

## 1. Status and Authority

Phase 5B Gates B/C are merged. Phase 5C remains locked.

This document designs the **compatibility boundary only**. It does not:

- implement Elixir/PHP/tests/migrations;
- mutate certified run `3efd208f-b148-4568-8591-13d968399081`;
- rewrite persisted `tickera_catalog_plan.v2` snapshots/hashes/finding counts;
- weaken Human Apply, AutoApplyPolicy, or Applier ownership;
- invent WordPress authority or erased producer codes.

---

## 2. Goals and Non-Goals

### Goal

```text
historical v2 representation
  → validated legacy input
  → version-scoped CompatibilityTranslation
  → compatibility-derived normalized representation
  → locked source_risk.v3 canonical validation
  → human-review / read-model facts + findings
```

### Non-goals

- Making v2 automation-equivalent to native v3.
- Strengthening historical certainty.
- Inventing raw codes, scopes, authorities, or completeness.
- Persisting required MVP compatibility snapshots (prefer computed read model).
- Redis/Cachex/GenServer vocabulary services.
- Dynamic rule engines.

---

## 3. Adapter Version

Exact immutable identifier:

```text
compat.v2_to_source_risk_v3.v1
```

**Why:** unambiguous; includes source and target contracts; separately versioned from producer schema `2026-07-22.v2` and canonical `source_risk.v3`; `.v1` allows later adapter revisions without renaming those contracts.

Separately:

| Kind | Identifier |
|---|---|
| Producer contract (historical) | `2026-07-22.v2` |
| Canonical contract | `source_risk.v3` |
| Compatibility adapter | `compat.v2_to_source_risk_v3.v1` |
| Snapshot schema (historical) | `tickera_catalog_plan.v2` (immutable) |

---

## 4. Historical Inputs

Distinguish input classes; do not mix them opportunistically for the “safest” outcome.

| Class | Examples | Fidelity |
|---|---|---|
| A. Raw historical producer/feed fields | `risk_codes[]`, `product_semantics`, `product_status_classification`, `event_status_classification`, `variation_status_classification`, `ticket_template_id`, `woo_product_id`, `woo_variation_id` | Highest when retained |
| B. v2 normalized risk facts | `SourceRisk` structs / snapshot `source_risks[]` with `evidence_classification` | Medium; may already have erased raw codes |
| C. Persisted v2 snapshot data | `tickera_catalog_plan.v2` bytes/hash | Immutable historical |
| D. v2 findings | persisted findings with codes/severity | Downstream summaries |
| E. Planner/structural artifacts | planned-create actions; structural `variation_mapping_required` warnings | Independent namespaces |

### Source precedence (deterministic)

```text
1. Exact retained authoritative producer/source field (Class A)
2. Exact version-scoped legacy semantic code with proven meaning (Class A/B raw code retained)
3. Exact persisted v2 risk fact (Class B) under a weaker translation rule
4. Compatibility diagnostic from retained raw fallback literal (Class B/D)
5. Unrecoverable / blocking unknown
```

Never reconstruct missing producer evidence from a downstream summary when original semantics were erased.

### Representation precedence vs evidence conflict

These are different rules. Do not conflate them.

**Known derived / lossy representations** (one underlying observation, different fidelity):

```text
example:
  product_status_classification=trash
  + risk_code=draft_product
```

v2 is known to emit `draft_product` from a broader non-publish branch that includes trash.

```text
higher-fidelity authoritative representation wins translation
lower-fidelity known derivative:
  - retained in compatibility provenance
  - marked superseded / derived / lossy
  - does NOT independently create blocking_conflict
```

**Genuinely independent contradictory claims** (separate evidence for the same canonical identity):

```text
example:
  independent source A → lifecycle=private
  independent source B → lifecycle=draft
  same canonical identity
→ blocking_conflict
```

Never choose whichever independent claim is safer.

Never manufacture a conflict from a documented lossy derivative of the same observation.

---

## 5. Translation Pipeline

```text
Validated historical input (single mode: historical_v2_review)
  → CompatibilityTranslationRecord(s)
  → compatibility-derived normalized claim candidates
  → Normalizer/registry validation under source_risk.v3
  → CanonicalEvidenceFact(origin=compatibility_derived)
     and/or compatibility diagnostic / derived summary / structural|planner projection
  → human-review read model
```

Every adapted CanonicalEvidenceFact MUST carry:

```text
origin = compatibility_derived
```

Never:

```text
compatibility_derived → native
```

---

## 6. Certainty-Monotonicity Rule

Primary Gate D invariant:

```text
compatibility translation may:
  preserve certainty
  reduce certainty

compatibility translation may NEVER:
  increase certainty
  invent authority
  invent completeness
  invent raw codes
  invent semantic scope
  invent missing historical evidence
```

In particular:

```text
v2 explicit_safe  != automatic state=absent + completeness=exhaustive
v2 explicit_risky != automatic present semantic fact
```

without a code/source-specific rule proving what was observed.

Default adapted completeness:

```text
unknown
```

unless historical contract evidence proves something stronger (rare for v2).

`certainty_change` allowed values:

```text
preserved
weakened
```

Never `strengthened`.

---

## 7. Legacy Epistemic Classification Matrix

v2 classifications (`SourceRisk.evidence_classification`):

| Legacy classification | Proves | Does NOT prove | Default v3 state if no stronger code-specific evidence | Default completeness | Finding handling | May code-specific rules refine? |
|---|---|---|---|---|---|---|
| `explicit_safe` | A synthetic or producer-derived “safe fill” existed for a v2 risk key | Exhaustive absence; native safe-negative proof; discovery completeness | Do **not** auto-map; require code-specific rule. Else compatibility diagnostic / unresolved | `unknown` | Retain historical non-blocking context; never mint native automation proof | yes |
| `explicit_risky` | A non-safe v2 fact existed for a code | Exact observed value/state without code-specific proof | Prefer code-specific present/risk mapping when proven; else unresolved diagnostic | `unknown` | Preserve blocking historical finding visibility | yes |
| `missing` | Required v2 evidence field/classification path treated observation as missing | Semantic absence of a business relationship | Prefer EvidenceState `missing` / contract diagnostic — **not** automatic `absent` | `unknown` | `contract.blocking_missing` or weaker unresolved | yes when code proves absence |
| `unknown` | Producer/normalizer could not decide | Absence or presence | EvidenceState `unknown` / capability unknown | `unknown` | blocking unknown | yes |
| `unsupported` | v2 marked unsupported classification | That EventSales “does not support an observed value” vs “cannot evaluate” | Capability/unevaluable path only when proven; else diagnostic | `unknown` | blocking unsupported / diagnostic | yes |

Classification-only mapping is forbidden.

---

## 8. Translation Source Precedence

See §4 for the class ladder and the precedence-vs-conflict distinction.

Additional deterministic rules:

- Prefer Class A classification fields (`*_status_classification`) over known lossy `risk_codes` derivatives (e.g. `product_status_classification=trash` + `draft_product`). Apply §4 lossy-derivative handling — **not** `blocking_conflict`.
- Prefer retained raw `risk_codes` entry over post-`from_code/3` Phoenix-fallback `missing_source_risk_data` fact when the original code is still recoverable from Class A.
- Prefer parent product id for parent semantics even when variation id is present on the transport row (§16).
- When two representations are **not** documented as lossy derivatives of each other and normalize to different claims on the same canonical identity → `blocking_conflict` (§17).

---

## 9. Code-Specific Translation Registry

Adapter version scope: `compat.v2_to_source_risk_v3.v1` / source `2026-07-22.v2`.

| Rule id | Legacy code | Legacy owner | Observed scope (v2) | Legacy classification behaviour | Handling class | v3 dimension | v3 state | v3 value | v3 scope | Target reconstruction | Completeness | Finding handling | Certainty note |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| `t.trash_event` | `trash_event` | WP `event_risk_codes` | event | erased by Phoenix `from_code` → often `missing_source_risk_data` | declared alias → typed fact | `lifecycle` | `present` | `trash` | `event` | `{tickera_event_id}` from event | `unknown` | `source_risk.lifecycle_trashed` (compat) | preserved semantic; completeness unknown |
| `t.private_event` | `private_event` | WP + Phoenix known | event | `explicit_risky` | typed fact | `lifecycle` | `present` | `private` | `event` | event id | `unknown` | `source_risk.lifecycle_private` | preserved |
| `t.draft_event` | `draft_event` | WP + Phoenix known | event | `explicit_risky` | typed fact | `lifecycle` | `present` | `draft` | `event` | event id | `unknown` | `source_risk.lifecycle_draft` | preserved; note draft may include non-trash non-private statuses only when classification says draft |
| `t.trashed_event` | `trashed_event` | Phoenix vocab (often not WP-emitted) | event | `explicit_risky` if present | typed fact | `lifecycle` | `present` | `trash` | `event` | event id | `unknown` | `source_risk.lifecycle_trashed` | preserved |
| `t.deleted_event` | `deleted_event` | Phoenix vocab; not full-feed WP | event | if present | typed fact / diagnostic | `lifecycle` | `present` | `deleted` | `event` | event id | `unknown` | lifecycle deleted | rare; no invention |
| `t.private_product` | `private_product` | WP `review_reasons` | product (may be on variation row) | `explicit_risky` | typed fact | `lifecycle` | `present` | `private` | `parent_product` | `{woo_product_id}` regroup | `unknown` | `source_risk.lifecycle_private` | preserved |
| `t.draft_product` | `draft_product` | WP `review_reasons` | product | `explicit_risky` | compatibility diagnostic / unresolved lifecycle unless classification proves exact value | `lifecycle` | only when classification proves exact value; else — | only when classification proves; else — | `parent_product` | product id | `unknown` | retain historical finding | **never** map draft_product-only → present/draft; trash collapsed into this code |
| `t.trashed_product` | `trashed_product` | Phoenix vocab | product | if present | typed fact | `lifecycle` | `present` | `trash` | `parent_product` | product id | `unknown` | lifecycle trashed | rare in WP emission |
| `t.deleted_product` | `deleted_product` | Phoenix vocab | product | if present | typed fact | `lifecycle` | `present` | `deleted` | `parent_product` | product id | `unknown` | lifecycle deleted | rare |
| `t.private_variation` | `private_variation` | mostly Phoenix ensure_dimension | variation | often synthetic `explicit_safe` fill | typed / diagnostic | `lifecycle` | depends | see §10 | `variation` | variation id | `unknown` | as proven | synthetic safe fills do not invent publish observation from absence of code alone without retained classification |
| `t.draft_variation` | `draft_variation` | Phoenix vocab | variation | if present | typed fact | `lifecycle` | `present` | `draft` | `variation` | variation id | `unknown` | lifecycle draft | WP often serializes status but may not emit risk code |
| `t.subscription_product` | `subscription_product` | WP when `is_subscription_product` true | product | erased by `from_code` | declared alias → typed fact | `subscription` | `present` | optional digest | `parent_product` | product id | `unknown` | `source_risk.subscription` | positive only; never safe absent |
| `t.payment_plan_product` | `payment_plan_product` | WP co-emitted with subscription | product | erased by `from_code` | **rejected alias** / undeclared_raw diagnostic | — | — | — | — | retain product id in provenance | `unknown` | `contract.unknown_source_risk_code` or compat diagnostic | **NOT** `payment_plan` |
| `t.missing_ticket_template` | `missing_ticket_template` | WP when template id null | product | Phoenix `explicit_risky` | typed fact | `ticket_template` | `absent` | null | `parent_product` | product id | `unknown` (not invented exhaustive) | `source_risk.missing_ticket_template` | “missing” in code name ≠ EvidenceState missing |
| `t.missing_tickera_event` | `missing_tickera_event` | WP when `event_status` null | product relation | erased by `from_code` | compatibility diagnostic / unresolved event_link unless Class A proves reference absence or invalidity | `event_link` | only absent/invalid when Class A proves; null-status alone → — | — | `event_product_relationship` | `{woo_product_id}` | `unknown` | preserve `source_risk.missing_tickera_event` visibility | **never** mint absent from event_status=null alone |
| `t.unknown_product_semantics` | `unknown_product_semantics` | WP always appended | product | Phoenix `unknown` | derived summary only | — | — | — | — | product id for aggregate | — | derived UI/audit only | do not mint co-equal blocker |
| `t.payment_plan` | `payment_plan` | Phoenix semantic dim / WP semantics unknown | product | `unknown` from `product_semantics` | capability fact | `payment_plan` | `unknown` | — | `parent_product` | product id | `unknown` | `source_risk.payment_plan` | via capability slot semantics for review |
| `t.membership` | `membership` | same | product | `unknown` | capability fact | `membership` | `unknown` | — | `parent_product` | product id | `unknown` | `source_risk.membership` | same |
| `t.bundle` | `bundle` | same | product | `unknown` | capability fact | `bundle` | `unknown` | — | `parent_product` | product id | `unknown` | `source_risk.bundle` | same |
| `t.add_on` | `add_on` | same | product | `unknown` | capability fact | `add_on` | `unknown` | — | `parent_product` | product id | `unknown` | `source_risk.add_on` | same |
| `t.subscription` | `subscription` | Phoenix after alias / ensure | product | risky or safe fill | typed / capability | `subscription` | present if risky from code; safe fill ≠ exhaustive absent | — | `parent_product` | product id | `unknown` | as applicable | never promote safe fill to exhaustive absent |
| `t.unsupported_product_type` | `unsupported_product_type` | Phoenix | product | often `unsupported` class | closed-registry observation vs diagnostic | `product_type` | `present` **only** if retained token is locked-declared (`simple`); else — | `simple` only when declared; else — | `parent_product` | product id | `unknown` | preserve historical `source_risk.unsupported_product_type` | undeclared tokens stay raw provenance; fail closed — never mint present with undeclared token as canonical value |
| `t.variation_mapping_required` | `variation_mapping_required` | WP risk_codes **and** Normalizer structural warning | variation blocker / product warning | overloaded | structural_projection and/or planner_projection | — | — | — | — | separate identities per emitter | — | `structural.*` / `planner.status.*` | never source-risk canonical evidence |
| `t.missing_source_risk_data.wp_event_unknown` | `missing_source_risk_data` | WP `event_risk_codes` (explicit emission for unknown event status) | event | `missing` | lifecycle unresolved/unknown projection | `lifecycle` | `unknown` | — | `event` | event id when known | `unknown` | blocking compatibility / lifecycle unknown | explicit WP literal — **not** erased producer code |
| `t.missing_source_risk_data.phoenix_fallback` | `missing_source_risk_data` | Phoenix `SourceRisk.from_code/3` fallback | varies | `missing` | unrecoverable / contract diagnostic | — | — | — | — | retained targets only | `unknown` | `contract.*` diagnostic | original raw code erased; **never invent**; do not map to lifecycle |
| `t.unknown_source_risk_code` | n/a (v3) | contract | — | — | contract diagnostic | — | — | — | — | — | — | `contract.unknown_source_risk_code` | for undeclared raw |
| Planner codes (`ambiguous_*`, `existing_mapping_*`, etc.) | various | planner/normalizer | varies | — | planner_projection | — | — | — | — | planner identities | — | `planner.status.*` | not source evidence |

Unique rule ids above are closed for `compat.v2_to_source_risk_v3.v1`.

Rule uniqueness key:

```text
compatibility_version + source_contract_version + raw_code + source_owner
```

`missing_source_risk_data` therefore has two rules because WP explicit emission and Phoenix fallback share the literal but not the owner/provenance. If provenance cannot determine which owner produced the historical literal → use the weaker `t.missing_source_risk_data.phoenix_fallback` path; do not guess.

---

## 10. Lifecycle Translation

### Event

Static proof: `event_risk_codes/1` emits `private_event`, `draft_event`, or `trash_event` (`status . '_event'`), or explicit `missing_source_risk_data` for unknown status.

| Classification retained | Mapping |
|---|---|
| `trash` / raw `trash_event` | lifecycle present/trash @ event |
| `private` / `private_event` | lifecycle present/private |
| `draft` / `draft_event` | lifecycle present/draft |
| explicit WP `missing_source_risk_data` for unknown event status (`t.missing_source_risk_data.wp_event_unknown`) | lifecycle unresolved/`unknown` @ event — raw code was explicitly emitted, not erased |
| Phoenix-fallback `missing_source_risk_data` with unproven owner | unrecoverable diagnostic — do not invent lifecycle value |

### Parent product

Static proof: `review_reasons/3` emits `private_product` for private; **any other non-publish status including trash** emits `draft_product`.

Therefore:

| Retained evidence | Mapping |
|---|---|
| `product_status_classification=trash` | lifecycle present/trash @ parent_product; if `draft_product` also present, treat it as known lossy derivative (§4) — not conflict |
| `product_status_classification=draft` | lifecycle present/draft @ parent_product |
| `private_product` / classification=`private` | lifecycle present/private |
| `draft_product` only AND `product_status_classification` unavailable/unknown | **compatibility diagnostic** or lifecycle unresolved/`unknown` projection; completeness=`unknown`; origin=`compatibility_derived`; historical finding retained; **do not invent draft or trash**; a `certainty_change=weakened` flag does **not** authorize `present/draft` |

### Variation

Status classification may be serialized (`variation_status_classification`) while risk codes often omit variation lifecycle. Prefer retained classification fields. Synthetic `explicit_safe` `private_variation` fills from `ensure_dimension` do **not** prove publish; treat as compatibility diagnostic unless retained classification supports a present value.

---

## 11. Ticket-Template Translation

Static proof: WP emits `missing_ticket_template` when `ticket_template_id` is null; Phoenix maps known code to explicit_risky.

```text
legacy code missing_ticket_template
→ dimension ticket_template
→ scope parent_product
→ state absent
→ target {woo_product_id}
→ completeness unknown
→ finding source_risk.missing_ticket_template (compat)
```

Do **not** use EvidenceState `missing` for this code name.

If only a synthetic `explicit_safe` missing_ticket_template fill exists without retained template observation → do not invent present template; weaken to diagnostic.

---

## 12. Event-Link Translation

Static proof: WP emits `missing_tickera_event` whenever `event_status === null`. Targeted SQL uses LEFT JOINs for both `_event_name` and the referenced Tickera event, so null status can mean:

```text
no relationship reference
```

or

```text
relationship reference exists but target is missing / malformed / wrong type / unresolvable
```

v2 null event status alone does **not** distinguish those cases. The adapter must never choose `absent` merely because that is the historical finding's name or emission path.

Lock:

```text
retained Class A evidence proves relationship reference itself absent
→ event_link state=absent

retained Class A evidence proves reference exists but cannot resolve
→ event_link state=invalid

only event_status=null / missing_tickera_event survives
without the relationship-reference distinction
→ compatibility diagnostic
   or weakened event_link unresolved/unknown projection
→ preserve historical source_risk.missing_tickera_event visibility
→ DO NOT mint absent
→ DO NOT guess invalid
```

If only post-fallback Phoenix `missing_source_risk_data` remains and raw `missing_tickera_event` was erased:

```text
unrecoverable / contract diagnostic
do not invent absent vs invalid split
```

Primary canonical target remains `{woo_product_id}`; resolved Tickera event id is value, never primary identity.

---

## 13. Product Semantic Translation

WP hard-codes `product_semantics.{payment_plan,membership,bundle,add_on}=unknown` and appends `unknown_product_semantics`.

For each dimension:

```text
state=unknown
authority_slot=slot.<dim>.capability
origin=compatibility_derived
completeness=unknown
```

Do not mint present/absent. Do not invent capability `unsupported` unless historical source explicitly said unsupported (v2 typically used unknown).

`unknown_product_semantics` → derived summary only; do not add a co-equal blocker in the compatibility projection when per-dimension unknown facts already exist.

---

## 14. Product-Type Translation

v2 often uses code `unsupported_product_type` with classification `unsupported`, which overloads “not supported” vs “unevaluable”.

Locked `source_risk.v3` MVP currently declares only:

```text
simple
```

as a concrete canonical `product_type` value. The adapter must **not** expand that registry.

Rules:

| Retained evidence | Mapping |
|---|---|
| Actual product type token retained and equals locked-declared `simple` | `product_type` present/`simple` (compat); historical unsupported finding only if also present historically |
| Actual type token retained and **explicitly declared** in the locked canonical registry (future adapter/registry versions may add more) | use its reviewed canonical mapping |
| Actual type token retained but **not** declared in the locked canonical registry | do **not** mint a canonical `product_type` present fact with an undeclared token as value; retain bounded raw token as compatibility provenance; compatibility diagnostic / contract-invalid or unresolved projection; preserve historical `source_risk.unsupported_product_type` visibility |
| Type token not retained; only `unsupported_product_type` fact | compatibility diagnostic; **do not invent type value**; do not claim EvidenceState unsupported unless unevaluable proven |

Do not infer additional WooCommerce type tokens from general knowledge.

---

## 15. Structural / Planner Diagnostic Translation

### Dual emitters of `variation_mapping_required`

| Emitter | Static proof | Compatibility projection |
|---|---|---|
| WP `review_reasons` when `variation_id != null` | identity presence hint as risk_codes | structural/planner diagnostic only — **not** source-risk fact |
| Normalizer `variation_findings/1` | product-group warning | `structural.product_has_variations` (compat namespace) |

Do not collapse the two into one identity. Do not create CanonicalEvidenceFact source-risk for either.

Planner codes remain `planner.status.*` / `planner.action.*` projections.

---

## 16. Parent-to-Variation Regrouping

Critical defect: Normalizer selects `target_type=:variation` whenever `woo_variation_id` parses positive, then attaches row `risk_codes` (often parent semantics) to the variation id. Product semantic dimensions are only filled on the product branch.

Adapter **read-model regrouping** (not new authority):

```text
IF legacy semantic is proven parent-product scoped
AND woo_product_id is trustworthy positive int
THEN
  canonical target = {woo_product_id}
  semantic_scope = parent_product
  record translation_result = translated_weakened or translated
  provenance notes = compatibility_regrouping
ELSE
  fail closed / diagnostic
```

Do **not**:

- copy parent evidence onto every variation;
- treat variation id presence as semantic scope;
- invent parent id.

Variation-scoped lifecycle from retained variation classification remains variation-scoped.

---

## 17. Canonical Identity, Duplicate and Conflict Rules

Use locked identity:

```text
run/discovery
+ dimension
+ semantic scope
+ canonical target
+ authority slot
```

Compatibility metadata is **not** part of identity.

```text
same identity + same normalized claim → duplicate collapse; retain all bounded compat provenance refs
same identity + different normalized claim from genuinely independent evidence → blocking_conflict
```

Known lossy / derived representations of one observation (§4, §8):

```text
higher-fidelity claim wins translation
lossy derivative retained as superseded provenance
→ NOT blocking_conflict
```

Two differently named v2 aliases that imply incompatible **independent** claims must conflict, not silently merge.

Never choose whichever independent claim is safer.

Normalized claim fields follow `source_risk.v3` (§20 of contract): state, value, completeness, scope, authority_slot, origin=`compatibility_derived`.

---

## 18. CompatibilityTranslationRecord

Conceptual fields (Phase 5C may implement structs later):

| Field | Notes |
|---|---|
| `compatibility_version` | `compat.v2_to_source_risk_v3.v1` |
| `source_contract_version` | `2026-07-22.v2` |
| `source_record_identity` | run/finding/fact/row key |
| `source_owner` | WP function / Phoenix module |
| `raw_code` | when present |
| `raw_classification` | when present |
| `raw_scope` / `raw_target` | as retained |
| `translation_rule_id` | from §9 |
| `translation_result` | §19 |
| `canonical_dimension/state/value/scope/target` | when produced |
| `translated_completeness` | default `unknown` |
| `certainty_change` | `preserved` \| `weakened` |
| `reason` | bounded string |
| `bounded_provenance_refs` | allowlisted |

---

## 19. Translation Result Vocabulary

Closed set:

| Result | Meaning |
|---|---|
| `translated` | Successful code-specific mapping; certainty preserved |
| `translated_weakened` | Mapped with reduced certainty / regrouping / collapsed value |
| `compatibility_diagnostic` | Retained for review; no safe typed claim |
| `derived_summary` | e.g. unknown_product_semantics aggregate |
| `structural_projection` | structural namespace only |
| `planner_projection` | planner namespace only |
| `undeclared_raw` | Raw retained; no alias |
| `unrecoverable` | Erased meaning cannot be reconstructed |
| `rejected` | Explicitly rejected (e.g. payment_plan_product as alias) |

---

## 20. Completeness Rules

```text
adapted completeness = unknown
```

by default.

Do **not** infer `exhaustive` from:

- `explicit_safe`
- `explicit_risky`
- `has_more=false`
- single page
- successful dry-run

v2 lacks native v3 stable snapshot guarantees for automation completeness. Because all adapted facts are automation-ineligible, this underclaiming is required and sufficient.

---

## 21. Mixed-Version Rejection

Modes:

| Mode | Contents |
|---|---|
| `historical_v2_review` | Only v2 inputs → compatibility-derived projections |
| `native_v3` | Only native `2026-08-07.v3` → `source_risk.v3` |

Never aggregate compatibility-derived facts with native v3 facts as one homogeneous discovery.

Mixed incompatible versions/pages → fail closed.

---

## 22. Human-Review Read Model

Operators should see:

```text
Historical v2 fact / finding (literal)
Raw legacy code + classification
Compatibility interpretation (rule id + result)
Canonical v3 concept if safely translatable
Badge: origin=compatibility_derived
Certainty: preserved|weakened
Unresolved reason when incomplete
```

Clear separation:

```text
historical literal != native v3 evidence
```

Do not present adapted facts as freshly observed WordPress evidence.

---

## 23. Snapshot / Persistence Policy

Preferred MVP:

```text
v2 persisted snapshot remains untouched
compatibility projection = computed read model
```

Do not overwrite `tickera_catalog_plan.v2` or certified hashes/counts.

If a future separately authorized Phase 5C task persists compatibility results:

```text
new schema/version
separate identity
origin=compatibility_derived
retain source historical snapshot hash
```

Exact future schema stamp deferred to Phase 5C boundary.

---

## 24. Automation Ineligibility

```text
ALL compatibility-derived facts are automation-ineligible.
```

No exceptions — including semantically “equivalent” adapted facts.

Human review / diagnostics / migration tooling may use them.

Auto Apply must not treat them as native proof.

Current AutoApplyPolicy (`conservative_auto_apply.v1` / `tickera_catalog_plan.v2`) remains unchanged by Gate D.

---

## 25. Security and Provenance

Allowed compatibility provenance (bounded):

- source contract version, compatibility version
- historical run id, historical snapshot hash
- raw legacy code/classification
- historical target ids
- translation rule id, certainty result

Never: credentials, signatures, auth headers, cookies, full WP payloads, order/customer PII, unbounded metadata.

Oversized unknown raw strings → fail closed (digest/length diagnostic allowed later). Align bounds with `source_risk.v3` contract.

Producer/history must not be trusted to supply `origin`, `authority_slot`, `translation_rule_id`, or `alias_id` as if native; adapter derives those locally.

---

## 26. Ordering and Hashing

If compatibility projections are hashed/displayed:

1. Translate.
2. Semantic duplicate collapse.
3. Leave conflicts visible.
4. Sort by canonical key (dimension, scope, target_canonical_json, authority_slot, origin, state, value, completeness).

Do not depend on map/DB/producer incidental order.

Historical v2 snapshot hashes remain unchanged.

---

## 27. Performance and Scaling Review

| Component | Layer | Redis? | Notes |
|---|---|---|---|
| Compatibility rule registry | immutable compile-time | no | table + pure functions later |
| Translation table | immutable compile-time | no | — |
| Historical v2 input | cold read-only | no | bounded pages |
| Compatibility projection | bounded run-scoped read model | no | optional later cold persist |

Later Phase 5C: page-by-page translate; batch reads; avoid N+1; no unbounded run loads; incremental counters. Not a flash-sale hot path.

---

## 28. Source-Authority Evidence Matrix

| Claim | Static evidence | Legacy owner | Proven semantics | Adapter decision | Confidence | Unresolved? |
|---|---|---|---|---|---|---|
| `trash_event` → lifecycle trash @ event | WP `event_risk_codes` uses `status.'_event'`; trash∈status set | WP | Positive trash observation | Alias translate | high | no |
| Phoenix erases unknown raw codes | `SourceRisk.from_code/3` fallback → `:missing_source_risk_data` | Phoenix | Original raw lost | Prefer Class A raw before fallback; else `t.missing_source_risk_data.phoenix_fallback` | high | Exact erased codes for certified rows remain unknown |
| Explicit WP `missing_source_risk_data` | WP `event_risk_codes` for unknown event status | WP | Event lifecycle could not be classified | `t.missing_source_risk_data.wp_event_unknown` → lifecycle unknown @ event | high | no |
| `subscription_product` positive | WP emits when `is_subscription_product` true | WP | Positive subscription detection | Alias → subscription present | high | no |
| `payment_plan_product` ≠ payment_plan | Co-emitted under same subscription predicate | WP | Not independent payment-plan proof | Reject alias; diagnostic | high | no |
| `missing_ticket_template` → absent | WP when template id null | WP | Authoritative absence of template link | state=absent | high | Completeness remains unknown |
| `missing_tickera_event` + `event_status=null` | WP emits for null status; SQL LEFT JOINs `_event_name` and Tickera event | WP | Ambiguous: no relationship vs unresolved reference | Diagnostic / unresolved event_link; **never** mint absent from null-status alone | high | Absent/invalid only when Class A proves reference distinction |
| Product trash → `draft_product` | WP non-publish branch | WP | Trash collapsed into draft_product code | Classification trash wins; `draft_product` is lossy derivative (not conflict) | high | no |
| `draft_product` only | WP review_reasons without classification | WP | Exact lifecycle value unrecoverable | Diagnostic / lifecycle unknown — **not** present/draft | high | no |
| Parent semantics on variation rows | Normalizer target_type from variation_id | Phoenix | Scope defect | Regroup to parent_product when product id present | high | no |
| Dual `variation_mapping_required` | WP review_reasons + Normalizer.variation_findings | both | Overloaded code | Structural/planner projections only | high | Exact replacement names deferred |
| `unknown_product_semantics` | WP always appends; semantics all unknown | WP | Aggregate unknown | Derived summary only | high | no |
| product_semantics dims unknown | WP hard-coded unknown | WP | Unknown by design | Capability unknown facts | high | no |
| Variation lifecycle incomplete | classification serialized; codes often omitted | WP/Phoenix | Incomplete emission | Prefer classification; no invention | medium | Full variation lifecycle historical coverage incomplete |
| `unsupported_product_type` + non-simple token | Phoenix classification unsupported; v3 registry only `simple` | Phoenix / contract | Token may be retained but undeclared | Retain raw provenance; diagnostic; no canonical present value for undeclared tokens | high | Future registry expansion out of Gate D scope |
| Classification trash + `draft_product` | documented WP collapse | WP | One observation, two fidelities | Precedence wins; not blocking_conflict | high | no |

---

## 29. Invariants

```text
v2 persisted meaning immutable
compatibility translation never strengthens certainty
all adapted canonical facts: origin=compatibility_derived
compatibility_derived != native automation proof
legacy classification alone does not determine v3 state
v2 explicit_safe != automatic absent+exhaustive
v2 explicit_risky != automatic present
missing legacy evidence != semantic absence
no invented raw producer code
Phoenix-fallback missing_source_risk_data cannot recover erased producer code
explicit WP missing_source_risk_data != Phoenix fallback (separate rules)
event_status=null / missing_tickera_event alone != event_link absent
draft_product-only != lifecycle present/draft
undeclared product type token != canonical product_type value
payment_plan_product != payment_plan alias
variation_mapping_required != source-risk canonical evidence
unknown_product_semantics = derived only
product semantic parent scope != variation scope
transport variation_id does not determine semantic scope
regrouping is read-model projection, not new authority
known lossy derivative != blocking_conflict
same canonical identity + genuinely independent conflicting claim = blocking_conflict
raw/provenance retained within bounds
historical v2 snapshot/hash not rewritten
mixed incompatible versions fail closed
no AutoApplyPolicy weakening
no variation auto-Apply
Applier remains sole catalogue writer
```

---

## 30. Unresolved Items

1. Exact future structural/planner replacement code strings for overloaded `variation_mapping_required` (namespaces locked; names may refine in Phase 5C boundary).
2. Whether a separately versioned persisted compatibility snapshot is required beyond computed read model (prefer no for MVP).
3. Certified-run rows whose raw codes were erased: remain unrecoverable; no investigation via runtime/DB in Gate D.
4. Full historical variation lifecycle coverage when only classification exists without codes.
5. Exact UI layout for human-review badges (design intent only here).
6. Class A proofs that distinguish event_link absent vs invalid (beyond null status) remain source-owner investigation for future native producers; v2 adapter stays weakened.

---

## 31. Gate D Acceptance Criteria

Gate D succeeds when this document:

- locks adapter version `compat.v2_to_source_risk_v3.v1`;
- defines certainty-monotonic translation with default completeness `unknown`;
- sets source precedence and forbids inventing erased codes;
- maps approved aliases (`trash_event`, `subscription_product`) and rejects `payment_plan_product`→`payment_plan`;
- routes `variation_mapping_required` out of source-risk evidence;
- treats `unknown_product_semantics` as derived only;
- maps ticket-template without mechanical EvidenceState `missing`; maps event-link only when Class A proves absent vs invalid;
- forbids draft_product-only → present/draft and undeclared product-type tokens as canonical values;
- splits WP vs Phoenix `missing_source_risk_data` rules;
- separates representation precedence from genuine evidence conflict;
- defines parent-product regrouping as projection only;
- marks all adapted facts `compatibility_derived` and automation-ineligible;
- leaves v2 snapshots immutable;
- grounds claims in static source (§28);
- writes no implementation code.

### Challenge answers

1. Universal `explicit_safe → safe`? **No.**
2. Compatibility toward native automation completeness? **No.**
3. Misleading code names as semantics? **No.**
4. Copy parent evidence to variations? **No.**
5. Persist compatibility MVP? **Prefer computed read model.**
6. Redis? **No.**
7. Immutable table + pure functions later? **Yes.**

---

## Document control

| Item | Value |
|---|---|
| Next | Independent Gate D PR review → merge → then Phase 5C implementation-boundary design on a new PR |
| Forbidden | Phase 5C implementation; editing locked domain/contract docs; historical mutation |

End of v2 compatibility adapter.
