# Phase 5A source-risk blocker taxonomy

## 1. Executive verdict

The certified dry-run remains correctly ineligible for Apply, but its 100 blocking findings do not represent 100 independently proven risky source states. This analysis classifies 72 rows as **C — unknown by design**, 0 as **D — contract mismatch**, and 28 as **E — scope or duplication defect**. No blocker is classified A or B.

The safe Phase 5B direction is a closed, versioned evidence contract with code ownership, explicit evidence states, target scope, declared legacy aliases, and fail-closed handling that does not silently convert unknown codes. Phase 5C should implement only that contract boundary and focused migration tests. It must not unlock Apply merely by reducing counts.

The row-level reconciliation is in `docs/phase-5a/source-risk-blocker-ledger.csv`.

## 2. Frozen source state

| Item | Frozen value |
|---|---|
| Certified run | `3efd208f-b148-4568-8591-13d968399081` |
| Run state | `dry_run_ready` |
| Snapshot | `tickera_catalog_plan.v2` |
| Feed schema proven by the v2 planner branch | `2026-07-22.v2` |
| Reviewed plugin source commit | `5922c90f3afba9bb11f37c42e54e014b118cb75f` |
| EventSales analysis base HEAD | `625e109a75d04be13c177cc7a9f6de711bffd494` |
| Exact variation identities | 14 |
| Phase 4 persisted create actions | 14 |
| Manual mappings | 0 |
| Apply jobs / applying runs | 0 / 0 globally |
| Catalogue records / mappings | 0 / 0 globally |
| Orders / order items | 0 / 0 globally |

The reviewed plugin files are unchanged from the reviewed plugin commit at the analysis base. Static source resolves the relevant semantics, so no WordPress runtime read was needed. Names, descriptions, slugs, categories, labels, and marketing text were not used as proof.

Direct source anchors used for the trace:

- WordPress schema and producers: `integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php:15`, `integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php:746`, `integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php:851`, and `integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php:915`.
- Phoenix fetch/parser boundary: `lib/event_sales/catalog/tickera_catalog/wordpress_feed_client.ex:20`, `lib/event_sales/catalog/tickera_catalog/wordpress_feed_client.ex:38`, `lib/event_sales/catalog/tickera_catalog/wordpress_feed_response.ex:36`, `lib/event_sales/catalog/tickera_catalog/wordpress_feed_response.ex:147`, and `lib/event_sales/catalog/tickera_catalog/wordpress_feed_response.ex:174`.
- Code map: `lib/event_sales/catalog/tickera_catalog/source_risk.ex:6`, `lib/event_sales/catalog/tickera_catalog/source_risk.ex:57`, and `lib/event_sales/catalog/tickera_catalog/source_risk.ex:58`.
- Scope, semantic normalization, emitter, structural warning, and dedupe: `lib/event_sales/catalog/tickera_catalog/normalizer.ex:17`, `lib/event_sales/catalog/tickera_catalog/normalizer.ex:40`, `lib/event_sales/catalog/tickera_catalog/normalizer.ex:91`, `lib/event_sales/catalog/tickera_catalog/normalizer.ex:181`, `lib/event_sales/catalog/tickera_catalog/normalizer.ex:230`, and `lib/event_sales/catalog/tickera_catalog/normalizer.ex:296`.
- Closed snapshot boundary: `lib/event_sales/catalog/tickera_catalog/snapshot_canonicalizer.ex:31`, `lib/event_sales/catalog/tickera_catalog/snapshot_canonicalizer.ex:214`, and `lib/event_sales/catalog/tickera_catalog/snapshot_canonicalizer.ex:438`.
- Durable finding persistence: `lib/event_sales/ingestion/workers/discover_tickera_catalog_worker.ex:216`, `lib/event_sales/ingestion/workers/discover_tickera_catalog_worker.ex:229`, `lib/event_sales/ingestion/resources/tickera_catalog_sync_finding.ex:10`, and `lib/event_sales/ingestion/resources/tickera_catalog_sync_finding.ex:13`.

### Runtime evidence and method boundary

The dynamic run state, snapshot schema, `100/7/107` totals, 14 persisted create actions, absence of a newer same-source run, and all zero mutation counts came from the separately authorized one-row PostgreSQL aggregate diagnostic executed inside `BEGIN TRANSACTION READ ONLY` and ended with `ROLLBACK`. They are certified diagnostic evidence; they are not derivable from static source or from the ledger.

The subsequent ledger export was a separate `READ ONLY` transaction filtered only by the exact run ID and blocking severity. The ledger independently proves exactly 100 blocking rows, 100 unique finding IDs, the exact run ID and severity, deterministic ordering, and the retained identifier fields. It does not independently prove run state, schema, warning count, planner action count, newer-run state, or mutation counts.

## 3. Diagnostic correction COPY0

The first export joined findings to the run and placed all freeze assertions in one combined `WHERE`. That structure suppresses every finding when any expression is false or unknown and makes `COPY 0` indistinguishable from an absent run, a failed prerequisite, or a query defect.

An authorized one-row aggregate preflight subsequently proved every independent prerequisite: run existence, state, schema, `100/7/107`, 14 exact positive identities, 14 create actions, no non-create action, no newer same-source run, and all certified zero mutation counts. The **freeze diagnostic classification H — original prerequisite-gated export query defect** therefore approved a separate export filtered only by exact run ID and blocking severity. Diagnostic H belongs only to the A–I freeze-diagnostic vocabulary; it is distinct from the row-level A–E taxonomy used in this ledger. The corrected read returned exactly 100 rows. The combined prerequisite query was not rerun.

## 4. Exact totals

| Measure | Count |
|---|---:|
| Blocking findings in ledger | 100 |
| Structural warnings outside ledger | 7 |
| Total persisted findings | 107 |
| Unique blocking finding IDs | 100 |
| Blocking rows with exact run ID | 100 |
| Persisted planned-create actions | 14 |

The equation is `100 blocking + 7 warning = 107 total`. The seven warnings are product-group structural `variation_mapping_required` findings; the 14 same-code blockers are variation-scoped source-risk findings.

Ledger order records the export's stable key exactly: `finding_code`, `woo_product_id`, `woo_variation_id`, `tickera_event_id`, then `finding_id`; every nullable numeric key uses `NULLS FIRST`, and finding ID is the final deterministic tie-breaker. This states the recorded order only and does not imply semantic precedence between codes.

## 5. Blocker code counts

| Finding code | Product scope | Variation scope | Total |
|---|---:|---:|---:|
| `add_on` | 14 | 0 | 14 |
| `bundle` | 14 | 0 | 14 |
| `membership` | 14 | 0 | 14 |
| `missing_source_risk_data` | 2 | 0 | 2 |
| `payment_plan` | 14 | 0 | 14 |
| `unknown_product_semantics` | 14 | 14 | 28 |
| `variation_mapping_required` | 0 | 14 | 14 |
| **Total** | **72** | **28** | **100** |

All findings have at least one target identifier. There are no event-only or run-only blockers.

## 6. A–E

| Classification | Meaning | Count |
|---|---|---:|
| A | Genuine risk: authoritative proof that risky state exists | 0 |
| B | Deterministically safe: authoritative proof that risk is absent | 0 |
| C | Unknown by design: source state or retained provenance cannot currently prove a more specific classification | 72 |
| D | Contract mismatch: the exact retained row deterministically proves a vocabulary or evidence mismatch | 0 |
| E | Scope or duplication defect | 28 |
| **Total** |  | **100** |

Unknown stays unknown and remains blocking. No C row is promoted to B from absence, names, labels, or heuristic interpretation.

## 7. Pipeline

```text
WordPress posts/postmeta and Woo product API
  -> catalog_rows() SQL aggregation
  -> normalize_catalog_row()
  -> product_semantics / status classifications / risk_codes
  -> signed JSON catalog_rows[] in schema 2026-07-22.v2
  -> WordPressFeedClient page fetch and in-memory aggregation
  -> WordPressFeedResponse.parse_page/1 shape/type validation
  -> DiscoveryResult
  -> Normalizer.source_risks/3
  -> SourceRisk.from_code/3 or product_semantic_fact/4
  -> Normalizer.source_risk_findings/1 at blocking severity
  -> Enum.uniq_by({code,event_id,product_id,variation_id})
  -> Planner v2 source_risks/findings snapshot
  -> per-finding persistence by DiscoverTickeraCatalogWorker
```

The parser validates that `risk_codes` is a list of strings, but it does not validate the closed vocabulary, alias, authority, or code-to-target scope. Those decisions occur later and currently fail closed in ways that lose source meaning.

## 8. WordPress evidence matrix

| Dimension | Producer and evidence | Current state semantics | Assessment |
|---|---|---|---|
| Event status | `event_rows()` reads `wp_posts.post_status`; `event_risk_codes/1` | `publish` yields no risk; private/draft/trash yield status risk; unknown yields missing data | Authoritative for post lifecycle when the row exists |
| Product status | `catalog_rows()` reads `p.post_status`; `review_reasons/3` | private or non-publish produces a risk | Authoritative for product lifecycle |
| Variation status | SQL reads `variation.post_status` | Serialized classification exists but `review_reasons/3` does not emit private/draft variation codes | Evidence exists but risk vocabulary is incomplete |
| Subscription | `product_type()` plus allowlisted subscription meta in `is_subscription_product/4` | Positive match sets `subscription_classification=subscription`; review codes are `subscription_product` and `payment_plan_product` | Positive evidence is meaningful; emitted aliases do not match Phoenix |
| Payment plan | Same subscription predicate plus hard-coded `product_semantics.payment_plan=unknown` | Subscription detection is conflated with payment plan; explicit payment-plan authority is absent | Unknown by design outside the alias mismatch |
| Membership | Hard-coded `product_semantics.membership=unknown` | No reviewed evidence source | Unknown by design |
| Bundle | Hard-coded `product_semantics.bundle=unknown` | No reviewed evidence source | Unknown by design |
| Add-on | Hard-coded `product_semantics.add_on=unknown` | No reviewed evidence source | Unknown by design |
| Ticket template | `_ticket_template` allowlisted postmeta | Non-empty is present; nil is missing | Bounded metadata evidence |
| Variation mapping | `woo_variation_id` presence in `review_reasons/3` | Every variation emits `variation_mapping_required` | Identity presence is not authoritative mapping-risk evidence |

The plugin attaches product-level fields and `risk_codes` to each SQL row. When the row also contains a variation ID, that does not turn parent product evidence into variation evidence.

## 9. Phoenix matrix

| Stage | Current behavior | Risk |
|---|---|---|
| Page parser | Requires v2 fields and allowed enum shapes; accepts any strings in `risk_codes` | Unknown and alias codes pass parsing |
| Discovery adapter | Copies events and rows into `DiscoveryResult` | Preserves payload but adds no authority/scope metadata |
| Target selection | Chooses variation whenever `woo_variation_id` parses positive; otherwise product | Product evidence on variation rows is retargeted incorrectly |
| Code map | `SourceRisk.from_code/3` maps known strings; every unknown string becomes `missing_source_risk_data` | Original code and alias provenance are lost |
| Semantic dimensions | `product_semantic_fact/4` maps present/absent/nil/other to risky/safe/missing/unknown | Correctly preserves unknown for product rows only |
| Safe completion | `ensure_dimension/2` inserts safe facts for dimensions not present | Alias loss can synthesize a contradictory safe subscription fact |
| Finding emitter | Every non-safe source risk becomes blocking | Severity is not code/authority specific |
| Dedupe | `Enum.uniq_by` on code and identifier tuple | Collapses distinct source aliases after fallback and hides amplification |
| Snapshot | Closed canonicalizer accepts only normalized codes and classifications | Invalid producer vocabulary is already erased before validation |

## 10. Parent/variation scope

The WordPress SQL row contains both parent product and optional variation identity. `normalize_catalog_row()` calculates `product_type`, subscription classification, ticket-template presence, and the four `product_semantics` values from the parent product. It then serializes those parent facts on every variation row.

Phoenix selects source-risk target type solely with:

```text
woo_variation_id present -> variation target
otherwise                -> product target
```

Consequently, 14 `unknown_product_semantics` blockers are variation-scoped even though the evidence concerns the parent product. They are E. The 14 product-scoped umbrella findings and the 56 product dimension findings remain product-scoped. Parent evidence must not be copied to variations, and variation evidence must not be promoted to parents.

`variation_mapping_required` is variation-scoped in the source-risk path. A separate Phoenix path persists the same canonical code as a product-group warning summarizing that a product has variations. The proven defect is code-level semantic overloading across incompatible target and severity meanings. It is not proof that any warning row duplicates a particular blocker row. Phase 5B should assign authority-specific codes or explicit relationship metadata.

## 11. Duplication

Persisted source risks contain four `missing_source_risk_data` facts across two distinct product targets, while finding dedupe leaves two blockers. This proves duplicate normalized missing facts per target. It does **not** prove the original WordPress strings: `SourceRisk.from_code/3` erased every undeclared raw code before snapshot persistence.

Static producer paths that could reach that fallback include `subscription_product`, `payment_plan_product`, `missing_tickera_event`, and event-scoped `trash_event`; other undeclared input would behave the same. The reviewed producer emits the two subscription-related values together when its subscription predicate is true, which is a strong system-level mismatch candidate, but the exact two persisted product blocker rows do not retain enough provenance to attribute that path deterministically. They are therefore C with medium confidence, not D.

There is also intentional-looking but costly semantic amplification: each product with all semantics unknown yields four dimension findings plus the `unknown_product_semantics` umbrella. This taxonomy keeps the 14 correctly product-scoped umbrella rows as C because the v2 contract explicitly requires that umbrella; Phase 5B must decide explicitly whether it remains canonical. It must not disappear silently.

The 14 blocking `variation_mapping_required` source risks and seven product-group warnings use the same canonical code even though one path means an exact variation source risk and the other means a parent-product structural summary. Each of the 14 blocker rows participates in that persisted code-level diagnostic overloading, so it remains E at medium confidence. This is duplication of diagnostic vocabulary/meaning, not duplicate record identity and not a claimed one-to-one match between 14 blockers and seven warnings.

The separately certified aggregate also contains 14 planned-create actions. That proves planner state exists for the run as an aggregate; it does not prove row-set equality between actions, blockers, and warnings because this ledger does not carry action identifiers.

## 12. Contract mismatches

No ledger row is D because the normalized `missing_source_risk_data` rows no longer retain the exact raw producer value needed to prove which contract mismatch caused each row. D is not retained merely to preserve a classification count.

Static source nevertheless proves a system-level contract hazard: WordPress can emit `subscription_product`, `payment_plan_product`, `missing_tickera_event`, and `trash_event`, none of which is in the Phoenix `SourceRisk` vocabulary. Phoenix instead declares `trashed_event`, so even the source-supported trash lifecycle state currently takes the unknown-code fallback. Every undeclared value becomes `missing_source_risk_data`. If an alias is lost, `ensure_dimension/2` can then insert a safe canonical dimension because it no longer sees the original meaning. That behavior can create missing evidence beside a contradictory safe fact, but the two exact ledger rows cannot identify which product alias or field caused them.

The parser's open string-list acceptance conflicts with the snapshot canonicalizer's closed vocabulary. Unknown producer codes should fail at the versioned translation boundary with retained bounded provenance; they should never be silently renamed to a generic code.

## 13. Genuine

No ledger row is A. Static source shows that positive subscription detection is one possible path to undeclared codes, but the two C targets do not retain the raw code needed to prove that path. The taxonomy does not infer a genuine subscription risk from normalized missing evidence.

Phase 5B should preserve the positive subscription evidence as a canonical `subscription` fact. A future certified run may then contain genuine A findings with unambiguous authority and scope.

## 14. Deterministic safe

No blocker is B. The snapshot contains safe facts outside this ledger—published lifecycle status, present ticket template, simple Woo product type, and absent subscription according to the current normalizer—but blocking findings by definition are the non-safe facts emitted from the same source-risk collection.

An absence can be B only when both the source API and versioned contract define an exhaustive supported query whose explicit result means absent. A missing key, nil, unsupported integration, lookup error, or unknown producer code is never safe.

## 15. Unknown

The 72 C rows comprise:

- 14 each for `payment_plan`, `membership`, `bundle`, and `add_on` (56 total), derived from four explicit `unknown` values on product rows.
- 14 correctly product-scoped `unknown_product_semantics` umbrella findings required by the current v2 contract.
- 2 `missing_source_risk_data` findings whose normalized state is known to be missing but whose exact undeclared WordPress code and authoritative field were erased before persistence.

These findings accurately state that the current producer cannot prove present or absent. They should remain blocking until an authoritative evidence source is designed and versioned. Product names, descriptions, slugs, categories, arbitrary meta, display labels, and marketing text are explicitly excluded as proof.

## 16. Closed versioned vocabulary

Phase 5B should define this relevant vocabulary as part of a new feed version rather than mutate `2026-07-22.v2` in place.

| Canonical code | Description | Authority | Allowed evidence states | Scope | Default severity | Unknown behavior | WP producer | Phoenix representation | Declared legacy aliases |
|---|---|---|---|---|---|---|---|---|---|
| `private_event` | Event post is private | wp_posts.post_status for tc_events | present absent unknown error | event | blocking when present | unknown/error block | event_risk_codes/1 and review_reasons/3 | event lifecycle SourceRisk | none |
| `draft_event` | Event post is draft | wp_posts.post_status for tc_events | present absent unknown error | event | blocking when present | unknown/error block | event_risk_codes/1 and review_reasons/3 | event lifecycle SourceRisk | none |
| `trashed_event` | Event post is in WordPress trash | wp_posts.post_status for tc_events | present absent unknown error | event | blocking when present | unknown/error block | event_risk_codes/1 from status_classification/1 | event lifecycle SourceRisk with wp_post_status=trash | v2 trash_event |
| `deleted_event` | Authoritative event tombstone | signed targeted tombstone or reconciliation result | present absent unknown error | event | blocking when present | unknown/error block | not currently emitted by full feed | event lifecycle SourceRisk | none |
| `private_product` | Product post is private | wp_posts.post_status for product | present absent unknown error | product | blocking when present | unknown/error block | review_reasons/3 | product lifecycle SourceRisk | none |
| `draft_product` | Product post is draft | wp_posts.post_status for product | present absent unknown error | product | blocking when present | unknown/error block | review_reasons/3 | product lifecycle SourceRisk | none |
| `trashed_product` | Product post is in WordPress trash | wp_posts.post_status for product | present absent unknown error | product | blocking when present | unknown/error block | new producer must use product_status_classification | product lifecycle SourceRisk | v2 draft_product only when status classification is trash |
| `deleted_product` | Authoritative product tombstone | signed targeted tombstone or reconciliation result | present absent unknown error | product | blocking when present | unknown/error block | not currently emitted by full feed | product lifecycle SourceRisk | none |
| `private_variation` | Variation post is private | wp_posts.post_status for product_variation | present absent unknown error | variation | blocking when present | unknown/error block | variation_status_classification currently serialized but no code emitted | variation lifecycle SourceRisk | none |
| `draft_variation` | Variation post is draft or trash under declared mapping | wp_posts.post_status for product_variation | present absent unknown error | variation | blocking when present | unknown/error block | new variation evidence producer | variation lifecycle SourceRisk | none |
| `variation_mapping_required` | Proposed future code for unresolved exact variation mapping policy | Proposed Phoenix planner identity and mapping query | planned_create mapped conflict ambiguous missing | variation/planner | proposed warning for complete create and blocking for unresolved state | unknown/missing block | prohibited in new WordPress risk_codes | proposed planner finding; current code is not carried by planner actions | v2 producer and structural codes retained as provenance |
| `ambiguous_variation_name` | Variation identity cannot produce a distinct ticket-type identity | Phoenix normalized variation identity fields | present absent unknown error | variation | blocking when present | unknown/error block | not a WordPress semantic code | planner/normalizer SourceRisk | none |
| `subscription` | Product has subscription purchase semantics | reviewed Woo subscription API/type/meta adapter | present absent unknown unsupported error missing | product | blocking unless explicit supported absence | unknown/unsupported/error/missing block | subscription evidence adapter | product semantic SourceRisk | subscription_product |
| `payment_plan` | Product has payment-plan semantics | reviewed payment-plan integration API | present absent unknown unsupported error missing | product | blocking unless explicit supported absence | unknown/unsupported/error/missing block | payment-plan evidence adapter | product semantic SourceRisk | payment_plan_product only after equivalence review |
| `membership` | Product grants membership semantics | reviewed membership integration API | present absent unknown unsupported error missing | product | blocking unless explicit supported absence | unknown/unsupported/error/missing block | membership evidence adapter | product semantic SourceRisk | none |
| `bundle` | Product is a bundle/container | reviewed bundle integration API | present absent unknown unsupported error missing | product | blocking unless explicit supported absence | unknown/unsupported/error/missing block | bundle evidence adapter | product semantic SourceRisk | none |
| `add_on` | Product adds another entitlement | reviewed add-on integration API | present absent unknown unsupported error missing | product | blocking unless explicit supported absence | unknown/unsupported/error/missing block | add-on evidence adapter | product semantic SourceRisk | none |
| `unsupported_product_type` | Woo product type is outside reviewed support | Woo product API get_type result against versioned allowlist | present absent unsupported unknown error missing | product | blocking when unsupported or unknown | unknown/error/missing block | product_type/1 and evidence adapter | product support SourceRisk | none |
| `missing_ticket_template` | Required Tickera template link is missing | _ticket_template allowlisted postmeta under declared contract | present missing unknown error | product | blocking when missing | unknown/error block | review_reasons/3 | ticket-template SourceRisk | none |
| `unknown_product_semantics` | One or more product dimensions are unknown | typed product semantics envelope | unknown | product | blocking | always block until dimensions resolve | normalize_catalog_row/1 legacy envelope | product aggregate SourceRisk | none |
| `duplicate_ticket_name` | Multiple identities collide on one ticket name | Phoenix normalized identity set | present absent unknown error | product or variation identity group | blocking when present | unknown/error block | not emitted by WordPress semantic feed | planner/normalizer SourceRisk | none |
| `existing_mapping_conflict` | Existing mapping conflicts with proposed exact destination | Phoenix durable mapping query | present absent unknown error | product or variation exact identity | blocking when present | unknown/error block | not emitted by WordPress | planner SourceRisk | none |
| `product_moved_between_events` | Product destination differs across event identity | Phoenix durable mapping and event query | present absent unknown error | product or variation exact identity | blocking when present | unknown/error block | not emitted by WordPress | planner SourceRisk | none |
| `ambiguous_identity` | Source identity cannot resolve exactly | Phoenix planner identity query | present absent unknown error missing | declared event/product/variation target | blocking when present or unresolved | unknown/error/missing block | not emitted by WordPress | planner SourceRisk | none |
| `missing_source_risk_data` | Required evidence field or translated fact is absent | versioned parser/translation boundary | missing | declared target scope | blocking | preserve missing field identity | envelope completeness check | typed missing-evidence SourceRisk | none |
| `missing_tickera_event` | Ticket product has no resolvable Tickera event relationship | _event_name postmeta plus referenced tc_events row | missing unknown error | product/event-link relationship | blocking | unknown/error block | review_reasons/3 when resolved event status is null | typed missing-event-link SourceRisk | none |
| `unknown_source_risk_code` | Producer sent undeclared code | versioned translation boundary | error | source row scope plus known owner | blocking | preserve bounded raw code and block | none | contract-error SourceRisk/finding | no catch-all alias |

The registry contains all 25 codes currently declared by `SourceRisk`, plus canonical `missing_tickera_event` and `unknown_source_risk_code`. Statically known non-canonical WordPress emissions are declared only as aliases or compatibility inputs: `trash_event`, `subscription_product`, and conditionally `payment_plan_product`. No other producer string has catch-all canonical meaning.

Evidence-state rules must be explicit:

| Source value | Contract meaning | Safe? |
|---|---|---|
| `false` / `absent` | Safe only when the producer declares the dimension supported and the authoritative query is exhaustive | Yes in that narrow contract |
| `nil` | No observation or nullable transport value | No; map to missing unless the field explicitly allows null as a value |
| missing key | Contract-incomplete payload | No; blocking contract error |
| `unknown` | Producer executed but cannot decide | No; blocking unknown |
| `unsupported` | Integration/API cannot evaluate the dimension | No; blocking unsupported |
| `error` | Evaluation attempted and failed | No; blocking source error |

## 17. Explicit WordPress-to-Phoenix translation table

| WordPress emitted value | Current Phoenix interpretation | Problem | Canonical replacement | Scope | Severity | Compatibility action |
|---|---|---|---|---|---|---|
| `private_event` / `draft_event` | Known explicit-risk `SourceRisk` | Lifecycle values share the open string list with undeclared codes | Preserve canonical lifecycle code plus typed `wp_post_status` evidence | event | blocking | Preserve in v2 adapter and new contract |
| `trash_event` | Undeclared code becomes `missing_source_risk_data`; Phoenix declares `trashed_event` instead | Producer and consumer use different lifecycle vocabulary for the same authoritative `wp_posts.post_status=trash` state | `trashed_event` because it is the existing closed Phoenix lifecycle code and unambiguously names the persisted trash state | event | blocking | Declare `trash_event` as a v2-only backward-compatible alias to `trashed_event` with retained alias provenance |
| `private_product` / `draft_product` | Known explicit-risk `SourceRisk` | No parser-level code/scope enforcement | Preserve canonical lifecycle code plus typed `wp_post_status` evidence | product | blocking | Preserve and validate scope |
| `missing_ticket_template` | Known explicit-risk `SourceRisk` | String code carries no supported/error distinction | Canonical code plus typed ticket-template evidence state | product | blocking | Preserve value and add typed state in new version |
| `subscription_product` | Undeclared code becomes `missing_source_risk_data` | Raw alias and positive subscription meaning are erased | `subscription` with retained legacy alias provenance | product | blocking when present or not explicitly absent | Translate only in declared v2 adapter |
| `payment_plan_product` | Undeclared code becomes `missing_source_risk_data` | Static name does not prove semantic equivalence to canonical payment plan | Typed `payment_plan` evidence if authority proves equivalence; otherwise `unknown_source_risk_code` | product | blocking | Do not alias until semantics are reviewed |
| `missing_tickera_event` | Undeclared code becomes `missing_source_risk_data` | Missing event-link condition is conflated with all other undeclared codes | `missing_tickera_event` with typed relationship evidence defined in the closed vocabulary | product / event-link relationship | blocking | Declare separately in v2 adapter with provenance; preserve as canonical in the new version |
| `unknown_product_semantics` | Known unknown `SourceRisk` | Correct on product rows but retargeted to variation when a variation ID is present | Product-only aggregate unknown with explicit parent product ID | product | blocking | Preserve product rows; repair variation-row scope with audit provenance |
| `product_semantics.<dimension>=unknown` | Product rows become dimension-specific unknown facts; variation rows do not | Parent evidence is repeated on variation rows and target selection is identity-driven | Typed per-dimension product evidence object | product | blocking | Regroup v2 rows by explicit parent product ID |
| `variation_mapping_required` | Known explicit-risk variation `SourceRisk` | WordPress identity hint becomes blocking while an independent structural path uses the same overloaded code for product warnings | Proposed future planner-owned mapping-policy code with a distinct structural summary code | variation / planner | proposed warning for complete planned create and blocking only when unresolved | Retain historical source blocker provenance; prohibit in new WP risk list; do not treat current actions as carrying this code |
| Any other undeclared string | `missing_source_risk_data` | Silent generic fallback destroys exact code and authority | `unknown_source_risk_code` retaining bounded raw code and feed version | declared row scope | blocking | Fail closed; never generic-alias silently |

The table preserves source-supported lifecycle and template values as well as explicit unknown semantic states. It distinguishes possible static producer paths from the retained provenance of the two C rows; it does not claim that either exact row came from a particular undeclared string.

Backward compatibility should keep v1 and v2 parseable for human review but not automation eligible after the new contract is enabled. A v2 compatibility adapter may translate only declared aliases and must attach legacy provenance. New auto-Apply proof should require the new version. Mixed versions across pages remain rejected.

## 18. Phase 5B contract

### Change 1 — Evidence envelope and state machine

- **Problem:** booleans, nil, missing, unknown, unsupported, and errors cannot be distinguished consistently.
- **Authoritative evidence:** one reviewed adapter per semantic dimension; lifecycle remains `wp_posts.post_status`.
- **WordPress/schema:** emit `{code, scope, evidence_state, evidence_source, evidence_value}` with exact types and bounded values.
- **Parser:** validate code, state, scope, required fields, and version before normalization.
- **Normalizer/finding:** preserve the state without inference; only explicit supported absence becomes safe.
- **Scope/dedupe:** key by `{scope_type, scope_id, code, evidence_source}` and reject conflicting duplicates.
- **Migration/backcompat:** v2 remains human-reviewable; the declared adapter records alias provenance.
- **Tests:** table-driven tests for false/absent, nil, missing, unknown, unsupported, error, conflicting duplicates, and mixed versions.

### Change 2 — Closed code ownership and aliases

- **Problem:** open `risk_codes` plus silent fallback loses every undeclared raw value; static candidates include `subscription_product`, `payment_plan_product`, `missing_tickera_event`, and event-scoped `trash_event`, but the two exact product ledger rows cannot be attributed after fallback.
- **Authoritative evidence:** the reviewed producer function and versioned translation table.
- **WordPress/schema:** emit canonical codes in the new version; remove undeclared aliases.
- **Parser:** reject unknown codes as a typed contract error while retaining a bounded original code value.
- **Normalizer/finding:** remove generic unknown-to-missing conversion and contradictory safe completion.
- **Scope/dedupe:** aliases normalize once with provenance before dedupe; no two aliases collapse invisibly.
- **Migration/backcompat:** explicit v2 alias map only; no silent rename and no historical blocker deletion.
- **Tests:** every canonical code, every declared alias, one unknown code, alias collision, and contradictory safe/risky facts.

### Change 3 — Parent and variation evidence separation

- **Problem:** product semantics on variation rows become variation risks.
- **Authoritative evidence:** parent product ID owns product type/meta; variation ID owns variation lifecycle and attributes.
- **WordPress/schema:** use separate `product_evidence` and `variation_evidence` objects with explicit IDs.
- **Parser:** enforce code-to-scope compatibility and positive identity.
- **Normalizer/finding:** build product facts once per product and variation facts once per variation.
- **Scope/dedupe:** do not copy parent evidence to variations or promote variation evidence to parents.
- **Migration/backcompat:** v2 rows may be regrouped by parent ID only under the declared adapter.
- **Tests:** multiple variations under one parent, mixed parent/variation status, missing parent identity, and repeated pages.

### Change 4 — Proposed planner-owned variation mapping policy

- **Problem:** two independent emitters persist one overloaded code with incompatible semantics: exact-variation blocking source risk and parent-product warning structural summary.
- **Authoritative evidence:** current `review_reasons/3` and `Normalizer.variation_findings/1` emitters. The 14 planned-create actions are separately certified aggregate context and are neither code-linked nor row-set-equal to these findings.
- **WordPress/schema:** prohibit `variation_mapping_required` from source-risk codes in the new version.
- **Parser:** recognize legacy v2 occurrence only as migration provenance.
- **Normalizer/finding:** proposed policy derives a future planner-owned mapping status from action completeness under an authority-specific code; current planner actions do not carry `variation_mapping_required`.
- **Scope/dedupe:** product-group notices and any proposed variation policy use distinct codes/keys; no blocker-warning-action row equality is assumed.
- **Migration/backcompat:** retain the 14 historical findings in this ledger; future replacement is explicit and auditable.
- **Tests:** seven products/two variations, planned create, exact mapped, conflict, ambiguous, and missing destination.

## 19. Phase 5C boundary

| Proposed change | Problem | Authoritative evidence | WordPress change | Feed-contract change | Phoenix parser | Normalizer | Finding | Scope | Dedupe | Schema-version impact | Migration | Backward compatibility | Tests |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Typed evidence envelope | Current values cannot distinguish explicit absence from nil/missing/unsupported/error | Reviewed adapter per semantic dimension; post status for lifecycle | Emit bounded typed state/source/value per canonical dimension | Define exact required fields and allowed states | Reject missing/type/state violations before discovery | Preserve state without heuristic inference | Map each non-safe state to a distinct contract finding | Code-declared target only | Reject conflicting same-key facts | New version required | Do not rewrite certified run; certify a new run later | v2 remains human-review-only through adapter | Producer and parser tables for absent nil missing unknown unsupported error and conflicts |
| Closed vocabulary and aliases | Undeclared strings silently become generic missing data and erase provenance | Complete Section 16 registry plus reviewed producer functions | Emit canonical codes; retain no arbitrary aliases in new version | Publish every Section 16 code ownership alias severity and unknown behavior including v2 `trash_event` to `trashed_event` | Validate the complete registry and retain bounded raw code for contract errors | Remove generic unknown-to-missing conversion and contradictory safe completion | Emit `unknown_source_risk_code` with safe provenance | Validate every registry code/scope pair | Translate one declared alias once before dedupe | New version required; v2 alias table immutable | Historical findings unchanged; optional immutable analysis links only | Declared v2 aliases including `trash_event` accepted with provenance; all others fail closed | Every registry code declared aliases unknown code trash alias alias collision contradictory facts |
| Parent/variation separation | Parent evidence on variation rows is retargeted to variation | Parent product owns product API/meta; variation owns variation lifecycle/attributes | Emit separate product and variation evidence objects keyed by explicit IDs | Require code-compatible scope and parent linkage | Reject incompatible code/scope or missing positive identity | Build each product fact once and each variation fact once | Emit scope-contract error without copying evidence | Parent never copied down; variation never promoted | Canonical key includes target type/id/code/source | New version required | No rewrite; v2 adapter may regroup only with explicit parent ID | v2 regrouping is review-only and records legacy origin | Multiple variations one parent mixed lifecycle missing parent repeated pages conflicting scope |
| Proposed planner-owned variation mapping policy | Same code is persisted by two emitters as exact-variation blocking source risk and parent-product warning structural summary | Current WP and Normalizer emitters; 14 planned-create actions are separate certified aggregate context without code or row linkage | Remove code from new WordPress `risk_codes` | Propose Phoenix-owned mapping-policy code and a distinct structural-summary code | Preserve legacy occurrences only as provenance | Do not create source risk from new feeds; derive proposed policy independently from action completeness | Proposed planner finding severity follows create/mapped/conflict/ambiguous state | Proposed exact-variation policy plus separate product-group summary | One proposed policy result per exact variation; summaries have distinct code; no historical row equality assumed | New version prohibits producer code | Keep 14 historical blockers and seven warnings unchanged | v2 source and structural occurrences stay auditable and are not silently deleted | Seven products/two variations planned create exact mapped conflict ambiguous missing destination and proof current actions carry no legacy code |

Phase 5C implements only this matrix at the feed/parser/normalizer/finding boundary plus focused tests. It does not change existing durable business resources, Apply policy, or this certified run. A future local certification requires separate authorization.

## 20. Performance and scaling

This Phase 5A analysis used one bounded exact-run export of 100 blocker rows, small aggregate reads, and in-memory grouping. It changes no Cachex/ETS cache, Redis, GenServer, PubSub, Oban, analytics aggregate, or materialized view.

At 100,000 source-risk rows, the current feed path needs explicit scale work in the same vertical slice before certification:

- WordPress uses offset pagination, repeated joins/grouping across postmeta, and `wc_get_product()`/taxonomy fallback per catalog row for `product_type`; this can become metadata N+1 work and increasingly expensive offsets.
- Product evidence is repeated on every variation row, inflating payload size and source-risk count.
- Phoenix's default `100 x 50` page cap reaches only 5,000 rows. Page collection uses `acc ++ [response]`, and aggregation retains every event and catalog row in memory.
- Normalization constructs multiple facts/findings per row; the umbrella plus four dimensions can amplify one row to five blockers, before variation-mapping code overloading adds further diagnostics.
- Finding persistence performs one `Ash.create` per finding inside a transaction, so large plans create unbounded insert round trips and notification accumulation.
- Source lookups and planner identity queries must be batched; no per-risk database lookup should be introduced.

Recommended contract-level limits are cursor/keyset pagination, bounded page/payload bytes, parent evidence emitted once, batch metadata prefetch, streaming or bounded aggregation where correctness permits, deterministic batch insert, and explicit maximum facts per target. Full-page aggregation remains required before findings whose truth depends on cross-page completeness.

## 21. Security and privacy

The ledger contains only finding IDs, exact run ID, severity/code, source identifiers, static function/path names, classifications, and paraphrased reasons. It contains no raw finding messages, feed payload, names, descriptions, signed URLs, headers, signatures, credentials, environment values, or customer/order data.

Future contract errors should retain only bounded allowlisted code/state/source fields. Never persist arbitrary payload fragments as error metadata. Signature verification, HTTPS in production, local-only development targets, and existing secret handling remain unchanged. This analysis performed no WordPress or database mutation.

## 22. Open questions

1. Which installed WooCommerce extensions are authoritative for payment-plan, membership, bundle, and add-on semantics?
2. Does `payment_plan_product` mean every subscription is a payment plan, or was it only a review hint? It must not alias to `payment_plan` until answered.
3. Should `unknown_product_semantics` remain an aggregate blocker alongside four dimension blockers, or become a non-counting summary? Historical rows must remain auditable either way.
4. Which exact variation lifecycle risks should WordPress emit (`private_variation`, `draft_variation`, `trashed_variation`) and with what targeted-query behavior?
5. What bounded metadata may retain an undeclared original risk code without creating a data-exfiltration path?
6. What feed-version cutover policy makes v2 human-review-only while avoiding mixed-version pagination?

## 23. Non-goals

- Enabling auto-Apply or changing Apply policy.
- Creating manual mappings or resolving the 14 planned-create identities.
- Defining new event or ticket-type business policy.
- Running a fresh dry-run or rewriting the certified run.
- Adding Redis, GenServer, PubSub, Oban queues, analytics, caches, or materialized views.
- Adding new source systems or unreviewed semantic heuristics.
- WordPress mutation, payment/email/CRM/marketing activation, deployment, Railway, VPS, or tunnels.
- Using names, descriptions, slugs, categories, labels, or marketing text as semantic evidence.

## 24. Success criteria

Phase 5A documentation succeeds when:

- the ledger has exactly 100 deterministic rows and 100 unique finding IDs for the exact run;
- code counts sum to 100 and A+B+C+D+E equals 100;
- every row traces producer evidence, JSON path, parser, normalizer, emitter, scope, and required changes;
- unknown remains unknown and no absent/missing/unsupported/error state is called safe;
- the seven structural warnings remain outside the blocker ledger while `100 + 7 = 107` reconciles;
- aliases, unknown codes, parent/variation scope, `variation_mapping_required` code overloading, dedupe, versioning, and backward compatibility are explicit;
- only the two Phase 5A documentation files change;
- no application code, tests, configuration, integration source, schema, runtime, domain state, WordPress state, or database state changes.
