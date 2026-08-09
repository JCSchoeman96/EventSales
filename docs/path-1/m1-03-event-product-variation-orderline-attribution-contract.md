Document:
Path 1 M1-03 Event → Product → Variation → OrderLine Attribution Contract

Baseline:
4712f7736390ffec38c22c4e82fc46e9c054981b

origin/main:
4712f7736390ffec38c22c4e82fc46e9c054981b

Contract date:
2026-08-09

Verdict:
PASS

Authority:
CERTIFY + EXTEND CONTRACT DOCUMENTATION (no production code)

---

# Path 1 M1-03 — Event → Product → Variation → OrderLine Attribution Contract

| Field | Value |
| --- | --- |
| Document | Event → Product → Variation → OrderLine attribution contract |
| Plan ID | `m1-03-event-product-variation-orderline-attribution-contract` |
| Plan version | `v2` |
| Status | LOCKED for Path 1 attribution / mapping semantics — M1-03 COMPLETE (PASS) |
| Scope | Event-first attribution, ProductMapping fallback, mapping states/reasons, historical immutability, explicit correction boundary |
| Identity input | `docs/path-1/m1-02-source-scoped-external-identity-contract.md` (immutable) |
| Repository truth | `docs/path-1/m1-01-current-repo-truth.md` |
| Execution roadmap | `docs/path-1/path-1-phase-breakdown.md` |
| Strategy | CERTIFY existing attribution architecture; document gaps; no implementation |

### Revision log

- `v1` — initial locked attribution contract at baseline `4712f7736390ffec38c22c4e82fc46e9c054981b`
- `v2` — closeout: keep PASS; classify G1 as BLOCKING BEFORE M2; defer implementation to M1-09 PRE-M2 gap inventory / optional M1-C corrective gate; do not interrupt M1-04..M1-09

### Conflict rule

```text
This contract wins for Path 1 OrderItem attribution / mapping semantics.

M1-02 wins for identity tuples and source-scoped lookup vocabulary.
This document consumes M1-02; it does not revise it.

M1-04 owns order lifecycle, recognised sale, and revenue semantics.
M1-03 owns only attribution / mapping_status / attribution_status_reason behaviour.
```

---

## 1. Contract Metadata / Baseline

```text
branch: main
HEAD: 4712f7736390ffec38c22c4e82fc46e9c054981b
origin/main: 4712f7736390ffec38c22c4e82fc46e9c054981b
worktree at start: CLEAN
P1-00 / M1-01 / M1-01A / M1-02: COMPLETE
Path 2 / Phase 5E: PAUSED
```

Preflight evidence: `HEAD == origin/main`, clean worktree, on `main`, baseline matches authorized SHA.

No contradiction found between M1-02 locked identity tuples and current attribution call sites for Event / ProductMapping / Order / OrderItem source scoping. TicketType event-first variation lookup does not currently validate parent product against `TicketType.external_product_id` (locked under A9 / gap G1).

---

## 2. Executive Verdict

```text
M1-03 = PASS
```

Reasons:

```text
One durable OrderItem proves Event/TicketType membership through a deterministic
event-first path (source_tickera_event_id) or ProductMapping fallback.
ProductMapping never overrides a resolved source Tickera event.
Conflicts fail closed with explicit attribution_status_reason values, or map with
review reasons without changing Event authority.
Mapped historical rows are not automatically reassigned by normal ingestion.
Explicit correction is a narrow audited admin path, not a general remap API.
On-hold orders defer automatic mapping only (not a revenue decision).
Source-scoped lookups prevent Source A numeric IDs resolving Source B Events/Mappings.
```

Production code changes: **NONE**.

---

## 3. M1-02 Identity Inputs

Consumed unchanged (not redefined here):

| Concept | Identity tuple | Attribution use |
| --- | --- | --- |
| Event | `(source_system_id, external_event_kind, external_event_id)` | Event-first lookup; Tickera uses `:tickera_event` |
| Logical Woo product | `(source_system_id, woo_product_id)` | ProductMapping product-level fallback |
| Logical Woo variation | `(source_system_id, woo_product_id, woo_variation_id)` | ProductMapping exact variation (parent required) |
| Order | `(source_system_id, woo_order_id)` | Source scope for line attribution |
| OrderItem | physical `(order_id, woo_line_item_id)` | Inherits source via Order |

`OrderItem.source_tickera_event_id` is an **attribution input**, not the Event identity tuple.

Evidence: M1-02 §5–§6; `order_attribution_resolver.ex:49-58`; `mapping_resolver.ex:39-60`; `order.ex` / `order_item.ex` identities as locked in M1-02.

---

## 4. Attribution Terminology

| Term | Meaning in this contract |
| --- | --- |
| **SOURCE EVIDENCE** | Values taken from the Woo line / order payload (or preserved line facts) |
| **CATALOGUE EVIDENCE** | Durable Catalog rows used during resolution (`Event`, `TicketType`, `ProductMapping`) |
| **DERIVED ATTRIBUTION** | Durable `OrderItem.event_id` / `ticket_type_id` / `mapping_status` written by attribution |
| **REVIEW STATE** | `attribution_status_reason` and/or non-mapped `mapping_status` requiring attention |
| **HISTORICAL SNAPSHOT** | Persisted line facts that must not be silently rewritten after valid mapping |
| **NOT AUTHORITY** | Names, labels, SKUs, titles, similarity, or “nearest” matches — forbidden |

Resolver result vocabulary (resolver-internal, before Ash persist):

```text
OrderAttributionResolver: status :mapped | :pending
MappingResolver: {:mapped, ProductMapping} | :pending_mapping_resolution
```

Persisted OrderItem `mapping_status` vocabulary (Ash state machine):

```text
:pending_mapping_resolution | :mapped | :unmapped | :non_ticket | :ignored
```

Evidence: `order_attribution_resolver.ex:15-21`; `mapping_resolver.ex:15`; `order_item.ex:13-19,282-302`.

---

## 5. Attribution Input Matrix

| Field | Classification | Authority notes |
| --- | --- | --- |
| `OrderItem.source_tickera_event_id` | SOURCE EVIDENCE | Primary event-first input when integer; from Woo meta `tickera_event_id` |
| `OrderItem.woo_product_id` | SOURCE EVIDENCE / HISTORICAL SNAPSHOT | Required line product identity; used inside event bucket and ProductMapping lookup |
| `OrderItem.woo_variation_id` | SOURCE EVIDENCE / HISTORICAL SNAPSHOT | Optional; when present selects variation TicketType / exact variation mapping |
| `OrderItem.event_id` | DERIVED ATTRIBUTION | Durable Event FK after successful mapping / correction / mapped import |
| `OrderItem.ticket_type_id` | DERIVED ATTRIBUTION | Durable TicketType FK; must belong to same Event (`ValidateTicketTypeEvent`) |
| `OrderItem.mapping_status` | REVIEW STATE / DERIVED ATTRIBUTION | Ash state machine attribute |
| `OrderItem.attribution_status_reason` | REVIEW STATE | Constrained atom reasons; may coexist with `:mapped` |
| `OrderItem.item_kind` | DERIVED ATTRIBUTION | Set to `:ticket` on successful mapping actions; `:non_ticket` via `mark_non_ticket` |
| `OrderItem.name` | NOT AUTHORITY | Display/history only; never used for matching |
| `ProductMapping.source_system_id` | CATALOGUE EVIDENCE | Required source scope for all ProductMapping lookups |
| `ProductMapping.woo_product_id` | CATALOGUE EVIDENCE | Product identity component |
| `ProductMapping.woo_variation_id` | CATALOGUE EVIDENCE | Nil = product-level; non-nil = exact variation (parent required) |
| `ProductMapping.event_id` | CATALOGUE EVIDENCE | Fallback authority; event-first validation/review context |
| `ProductMapping.ticket_type_id` | CATALOGUE EVIDENCE | Fallback authority; event-first validation/review context |
| `ProductMapping.active` | CATALOGUE EVIDENCE | Inactive rows ignored by resolvers |
| `TicketType.external_ticket_type_kind` | CATALOGUE EVIDENCE | Event-first lookup key (`:woo_product` / `:woo_variation`) |
| `TicketType.external_ticket_type_id` | CATALOGUE EVIDENCE | Event-first lookup key (product id or variation id) |
| `TicketType.external_product_id` | CATALOGUE EVIDENCE | Stored parent mirror; **not** currently required by event-first TicketType filter |
| `TicketType.external_variation_id` | CATALOGUE EVIDENCE | Stored variation mirror; event-first filter uses `external_ticket_type_*` |
| `TicketType.active` | CATALOGUE EVIDENCE | Event-first requires `active == true` |
| `Event.external_event_*` + `source_system_id` | CATALOGUE EVIDENCE | Event-first Event resolution |
| Event/product/ticket **names**, SKUs, labels | NOT AUTHORITY | Forbidden fuzzy/similarity authority |

Evidence: `woocommerce_order_parser.ex:87-102,148-181`; `order_item.ex:192-257`; `product_mapping.ex:93-137`; `ticket_type.ex:81-96`; `order_attribution_resolver.ex:49-114`.

---

## 6. Authority / Precedence Contract

```text
1. Parser validity of tickera_event_id meta
   → may set :invalid_source_tickera_event_id and clear source id

2. If attribution_status_reason == :invalid_source_tickera_event_id
   → automatic mapping MUST NOT use ProductMapping fallback
   → remain pending with that reason

3. Else if source_tickera_event_id is a positive integer
   → OrderAttributionResolver (event-first) is sole Event authority
   → ProductMapping is validation / review context only

4. Else (no source event id)
   → MappingResolver ProductMapping fallback
   → exact active variation mapping preferred over active product-level
```

Forbidden authority (never used by current resolvers):

```text
event title, product name, ticket label, SKU similarity,
human-looking similarity, previous mapping merely because it exists,
nearest match, fuzzy match, cross-source numeric ID alone
```

Evidence: `order_item_mapper.ex:112-146`; `order_attribution_resolver.ex:1-7,116-140`; `mapping_resolver.ex:17-34`.

---

## 7. Event-First Resolution Contract

Entry: `OrderItemMapper` with integer `source_tickera_event_id` and eligible order status.

### 7.1 Steps

```text
source_system_id ← Order.source_system_id
source_tickera_event_id ← OrderItem.source_tickera_event_id
woo_product_id / woo_variation_id ← OrderItem

1) Event = read_one where
     source_system_id == Order.source_system_id
     AND external_event_kind == :tickera_event
     AND external_event_id == source_tickera_event_id
   limit 1

2) TicketType inside that Event:
     if woo_variation_id is nil:
       active TicketType where kind=:woo_product and id==woo_product_id
     else:
       active TicketType where kind=:woo_variation and id==woo_variation_id
       (OrderItem.woo_product_id is not part of this filter today)

3) ProductMapping (exact, active, source-scoped):
     product-only if variation nil; else exact (product, variation)
     may be nil

4) Compose result:
     Event+TicketType found → status :mapped with optional review reason
     else pending with reason
```

Evidence: `order_attribution_resolver.ex:29-160`; `order_item_mapper.ex:122-168`.

### 7.2 Outcome matrix (event-first)

| Scenario | Result status (resolver) | Persisted mapping_status | Reason |
| --- | --- | --- | --- |
| Valid source event + matching TicketType + ProductMapping agrees | `:mapped` | `:mapped` | `nil` |
| Valid source event + matching TicketType + ProductMapping absent | `:mapped` | `:mapped` | `:missing_product_mapping` |
| Valid source event + matching TicketType + ProductMapping points elsewhere | `:mapped` | `:mapped` | `:order_event_mapping_conflict` |
| Valid source event + product-only item + product TicketType | `:mapped` | `:mapped` | per ProductMapping agree/miss/conflict |
| Valid source event + missing TicketType | `:pending` | stays pending; reason set | `:source_ticket_type_not_found` |
| Unknown Event under this source | `:pending` | stays pending; reason set | `:source_event_not_found` |
| Invalid/conflicting meta (parser) | n/a (mapper short-circuit) | stays pending | `:invalid_source_tickera_event_id` |
| Source event belonging to another SourceSystem | treated as not found under Order's source | pending | `:source_event_not_found` |

**Critical:** when ProductMapping disagrees with the source event, attribution **still maps** to the source-event TicketType and records `:order_event_mapping_conflict`. ProductMapping does **not** win.

Evidence: `order_attribution_resolver.ex:116-140`; `order_attribution_resolver_test.exs:79-119`; `order_item_mapper_test.exs:60-108`.

### 7.3 Parser invalidation (before resolver)

```text
missing tickera_event_id meta          → source_tickera_event_id=nil, reason=nil
single valid positive integer          → source_tickera_event_id=id, reason=nil
conflicting multiple values            → source_tickera_event_id=nil, reason=:invalid_source_tickera_event_id
non-positive / unparsable values       → source_tickera_event_id=nil, reason=:invalid_source_tickera_event_id
```

Evidence: `woocommerce_order_parser.ex:164-181`.

---

## 8. ProductMapping Fallback Contract

Entry: no integer `source_tickera_event_id`, and reason is **not** `:invalid_source_tickera_event_id`.

### 8.1 Rules

```text
source scope: Order.source_system_id only (never cross-source)

1) If woo_variation_id present:
     try active ProductMapping (source, product, variation) exact
2) If none (or variation nil):
     try active ProductMapping (source, product, variation IS NULL)
3) If found → apply_mapping → :mapped with mapping.event_id / ticket_type_id
4) If none → remain :pending_mapping_resolution (no reason required)
```

Inactive mappings are ignored. Multiple actives for the same key are prevented by partial unique indexes; resolvers `limit(1)`.

Evidence: `mapping_resolver.ex:26-61`; `product_mapping.ex:24-34`; `order_item_mapper.ex:138-189`; `mapping_resolver_test.exs:17-82`.

### 8.2 Variation-over-product precedence

```text
Exact active variation mapping wins over product-level mapping.
If exact variation mapping is absent, product-level mapping MAY still map
a variation-bearing OrderItem (certified current behaviour).
```

This is **not** sibling-variation inference: a mapping for variation B is never selected for variation A. Parent product remains part of the exact variation lookup key.

Evidence: `mapping_resolver_test.exs:32-62`.

### 8.3 MissingCatalogResolver interaction

Retries local mapping for pending rows matching `(source, product, variation)`. Does not create mappings or call Woo REST. Eligible still-pending rows may be transitioned to `:unmapped`. On-hold rows remain pending unchanged.

Evidence: `missing_catalog_resolver.ex:1-98`; `missing_catalog_resolver_test.exs:23-70`.

---

## 9. Variation / Parent Integrity

### 9.1 ProductMapping paths (M1-02-aligned)

```text
Exact variation lookup ALWAYS includes woo_product_id + woo_variation_id
under source_system_id.

Therefore:
  Source A Variation 456 ≠ Source B Variation 456
  Mapping (source, parent 999, var 456) is NOT selected for OrderItem (123, 456)
```

Evidence: `mapping_resolver.ex:39-48`; `order_attribution_resolver.ex:104-114`; M1-02 §6 forbidden weakened identity `(source, variation)` alone.

### 9.2 Event-first TicketType variation path (certified current)

```text
Lookup key:
  (event_id, external_ticket_type_kind=:woo_variation, external_ticket_type_id=variation_id)
  active == true

OrderItem.woo_product_id is intentionally unused in this filter
(ticket_type/3 binds _woo_product_id).

TicketType.external_product_id / external_variation_id are storage mirrors;
they are not the event-first filter keys.
```

Evidence: `order_attribution_resolver.ex:76-89`; `ticket_type.ex:81-96`; unique index `catalog_ticket_types_unique_external_ticket_idx` on `(event_id, kind, id)` (`20260703090000_vs_26a_tickera_catalog_sync.exs:30-36`).

### 9.3 Locked behaviours

| Case | Behaviour |
| --- | --- |
| Variation under expected parent + exact ProductMapping | Maps via matching keys |
| Same variation ID under another source | No cross-source match |
| Variation ID with unexpected parent vs ProductMapping | Exact ProductMapping miss; may fall back to product-level or pending |
| Variation mapping missing, parent product mapping exists (no source event) | Product-level fallback may map |
| Product-only OrderItem (`variation_id` nil) | Product TicketType / product-level ProductMapping only |
| Variable line with variation ID + source event | Event-first TicketType by variation id inside event |

**No silent ProductMapping re-parent.** Parent mismatch against `TicketType.external_product_id` on the event-first path is a dual-field consistency concern (A10 / gap G1), not ProductMapping identity collapse.

---

## 10. TicketType vs ProductMapping Contract

| Concern | TicketType | ProductMapping |
| --- | --- | --- |
| What it is | Event-scoped catalogue ticket category + external Woo mirror fields | Source-scoped Woo product/variation → Event/TicketType relationship |
| Event-first authority for Event/TicketType assignment | **Yes** (after Event resolved) | **No** — validation/review only |
| Fallback authority (no source event) | Indirect via `ProductMapping.ticket_type_id` | **Yes** |
| Lookup keys (event-first) | `(event_id, external_ticket_type_kind, external_ticket_type_id)` + active | `(source, product[, variation])` + active for review |
| Lookup keys (fallback) | Not queried directly | Same ProductMapping keys |
| May validate the other | Source Event+TicketType vs ProductMapping event/ticket | Write-time `ValidateTicketTypeEvent` ensures mapping.ticket_type.event_id == mapping.event_id |
| Disagreement handling | Source event TicketType wins; reason `:order_event_mapping_conflict` | Does not override; not silently “picked instead” |
| Silent repair of the other | **Forbidden / not implemented** | **Forbidden / not implemented** |
| What OrderItem stores after attribution | Durable `event_id` + `ticket_type_id` | No ProductMapping FK on OrderItem |

Principle:

```text
disagreement ≠ pick whichever succeeds
```

On event-first disagreement: map to source-event TicketType **and** record conflict reason (deterministic, fail-visible).

Evidence: `order_attribution_resolver.ex:1-7,116-140`; Catalog + Sales `ValidateTicketTypeEvent` changes; `order_item.ex:129-151`.

---

## 11. Mapping Status State Contract

Statuses: `:pending_mapping_resolution` | `:mapped` | `:unmapped` | `:non_ticket` | `:ignored`

### 11.1 Entry / meaning

| Status | Entry conditions | Meaning |
| --- | --- | --- |
| `:pending_mapping_resolution` | Default create; `:remap` from mapped | Unresolved attribution; eligible for automatic mapping when order eligible |
| `:mapped` | `apply_mapping`, `apply_event_first_mapping`, `sync_from_mapped_import` | Durable Event/TicketType attribution present |
| `:unmapped` | `mark_unmapped` from pending (e.g. MissingCatalogResolver after failed retry) | Explicitly unresolved after recovery attempt; still eligible for `map_item` / apply_* transitions |
| `:non_ticket` | `mark_non_ticket` from pending | Classified non-ticket; automatic mapper leaves unchanged |
| `:ignored` | `mark_ignored` from pending | Intentionally ignored; automatic mapper leaves unchanged |

Evidence: `order_item.ex:13-19,172-189,282-302`; `order_item_mapper.ex:41-44`.

### 11.2 Transition triggers

| Transition | Automatic? | Trigger |
| --- | --- | --- |
| pending → mapped | Yes (eligible orders) | OrderUpserter → `map_pending_items_for_order`; `map_item`; MissingCatalogResolver success |
| unmapped → mapped | Via `map_item` / apply_* (not via upsert pending-only query) | Direct mapper call or apply actions |
| pending → unmapped | Semi-automatic | MissingCatalogResolver when eligible mapping still fails |
| pending → non_ticket / ignored | Manual / explicit Ash action | Not performed by OrderItemMapper |
| mapped → pending | Explicit `:remap` action | Available on resource; **no normal ingestion caller** found |
| mapped → different Event/TicketType | **No** for normal ingestion | Only explicit `correct_event_attribution` / mapped-import path |
| mapped → unmapped | **No** automatic path | State machine has no such transition |

`OrderItemMapper.map_item/1` no-ops for statuses other than `:pending_mapping_resolution` and `:unmapped`.

`map_pending_items_for_order/1` queries **only** `:pending_mapping_resolution`.

Evidence: `order_item_mapper.ex:41-44,86-90`; `order_item.ex:282-302`; `order_item_mapper_test.exs:133-158,189-209`.

---

## 12. Attribution Reason Matrix

Constrained atoms (`order_item.ex:21-28`):

| Reason | Trigger | Authoritative evidence | Typical mapping_status | Retry may clear? | Operator review? | Auto overwrite mapped attribution? |
| --- | --- | --- | --- | --- | --- | --- |
| `:invalid_source_tickera_event_id` | Parser: conflicting/unparsable `tickera_event_id` meta | SOURCE meta | pending | Only if later payload provides single valid id **and** row not yet mapped; mapped rows protected specially | Yes | No (mapper blocks fallback) |
| `:source_event_not_found` | Event-first: no Event under Order's source | SOURCE id + CATALOGUE Event miss | pending (reason set) | Yes, if Event later created under same source | Yes | No until pending→mapped |
| `:source_ticket_type_not_found` | Event found; no matching active TicketType | SOURCE Woo ids + CATALOGUE TicketType miss | pending | Yes, if TicketType later created under that Event | Yes | No until pending→mapped |
| `:missing_product_mapping` | Event+TicketType mapped; no active ProductMapping for Woo ids | Event-first success + ProductMapping miss | **mapped** | Reason may clear on remapping only if row remapped; normal mapped path does not re-run | Review/context | No |
| `:order_event_mapping_conflict` | Event+TicketType mapped; ProductMapping exists but different event/ticket | Source Event TicketType vs ProductMapping | **mapped** | Same as above | Yes | No — source event already won |
| `:source_event_identity_conflict` | Mapped row receives conflicting incoming `source_tickera_event_id` on sync | HISTORICAL mapped Event vs incoming SOURCE | stays **mapped**; frozen source id | No automatic remap | Yes | **No** — protect_mapped_source_identity |

Evidence: `woocommerce_order_parser.ex:164-181`; `order_attribution_resolver.ex:38-42,116-140`; `order_upserter.ex:195-228`; `order_item_mapper.ex:112-120`.

Do **not** collapse distinct reasons into a generic unmapped bucket.

---

## 13. Historical Attribution Immutability

Hard Path 1 invariant:

```text
catalogue evolution must not silently rewrite historical sales attribution.
```

### 13.1 Mechanisms

1. **Mapper gate:** non-pending/non-unmapped items returned unchanged (`order_item_mapper.ex:41-44`).
2. **`protect_mapped_source_identity`:** on `:sync_from_order` / `:sync_from_mapped_import` for `:mapped` rows (`order_upserter.ex:195-228`).
3. **`:sync_from_order` accept list:** does not accept `event_id` / `ticket_type_id` / `mapping_status` (`order_item.ex:90-104`).
4. **MappingChangedWorker:** no-op for sales remapping (`mapping_changed_worker.ex:4-12`).

### 13.2 Case lock

| Change | Effect on mapped OrderItem |
| --- | --- |
| Incoming `source_tickera_event_id` conflicts with stored / mapped Event external id | Keep historical attribution; set `:source_event_identity_conflict`; freeze source id as coded |
| Incoming source event id cleared | Do not clear stored source event id / reason on mapped rows |
| Incoming invalid reason | May record `:invalid_source_tickera_event_id` without clearing protected source id path as coded |
| ProductMapping changed / deactivated | Does **not** rewrite mapped OrderItem event/ticket |
| TicketType metadata / name changed | Does not change OrderItem FKs |
| Woo product/variation renamed | Line `name` may update via sync; Event/TicketType FKs unchanged |
| Same order replayed / newer Woo update | Money/qty/status may update; mapped attribution preserved; mapper skips mapped |
| Historical source event conflicts with mapped Event | Conflict reason; no reassignment |

Evidence: `order_upserter_test.exs:162-248`; `order_item_mapper_test.exs:133-158`.

---

## 14. Explicit Correction Boundary

### 14.1 NORMAL AUTOMATIC INGESTION

```text
Parser → OrderUpserter → create/sync line attrs → map_pending_items_for_order
```

May create pending→mapped. Must not reassign mapped Event/TicketType.

### 14.2 EXPLICIT REVIEWED CORRECTION

Module: `EventSales.Sales.OrderAttributionCorrection`

```text
Scope: confirmed Woo order 113834 / product 109132 / variation 109167 / qty 5
       from external event 108658 → 109120
Not a general historical remap API.
```

| Rule | Lock |
| --- | --- |
| Who may invoke | Global admin actor (`Policies.global_admin?`) |
| Evidence required | Exact confirmation string; exact order/item tuple; current event match; target Event; active target ProductMapping consistent with target Event/TicketType |
| Fields changed | `event_id`, `ticket_type_id`, `source_tickera_event_id`, `attribution_status_reason` via `:correct_event_attribution` |
| Audited? | Yes — `AuditLogger.order_attribution_corrected` (safe ids only) |
| Original source identity | `source_tickera_event_id` updated to target external id as part of correction; prior values in audit metadata |
| Source mismatch | Fail closed (`:current_event_mismatch`, `:order_not_found`, etc.) |
| Cross Event | Allowed only for this confirmed same-`source_system_id` tuple |
| Cross SourceSystem | Not allowed (order/event/mapping loads are source-scoped) |

Ash action `:correct_event_attribution` exists on OrderItem; the **supported** programme correction path is the dedicated module above, not an open remap API.

Evidence: `order_attribution_correction.ex:1-260`; `order_item.ex:158-170`; `order_attribution_correction_test.exs:29-130`.

---

## 15. On-Hold Deferral

Attribution-processing rule only (not revenue):

| Question | Lock |
| --- | --- |
| Mapping attempted for `:on_hold`? | **No** automatic apply (`AutomaticMappingPolicy` → `:deferred`) |
| State while deferred | Remains `:pending_mapping_resolution` (and any prior attribution reason) |
| Re-evaluation trigger | Later upsert when order status is no longer `:on_hold` and `map_pending_items_for_order` runs |

Other supported statuses (`:pending`, `:processing`, `:completed`, `:cancelled`, `:refunded`, `:failed`) are `:eligible` for automatic mapping.

Evidence: `automatic_mapping_policy.ex:4-26`; `order_item_mapper.ex:29-52`; `order_upserter_test.exs:82-108`; `missing_catalog_resolver_test.exs:43-57`.

---

## 16. Retry / Reprocessing Matrix

| Scenario | Allowed automatic effect |
| --- | --- |
| Same webhook / order upsert replay | Idempotent order/item upsert; pending may become mapped; mapped attribution unchanged |
| Catch-up same Order | Same as upsert path |
| Catalogue mapping becomes available later | Pending (and recovery paths) may become mapped; mapped rows unchanged |
| on_hold → completed (or other eligible) | Deferred pending becomes eligible and may map |
| Event-first evidence arrives after unresolved row | If still pending/unmapped and source id present, event-first may map |
| Conflicting event evidence after mapped | Conflict reason; **no** remapped Event/TicketType |
| pending → mapped | Allowed when resolution succeeds |
| mapped → different mapped attribution | **Forbidden** without explicit correction / mapped-import |

Evidence: `order_upserter.ex:95-100,195-228`; §13–§15.

---

## 17. Cross-Contamination Matrix

| Scenario | Authoritative evidence | Expected result | Status | Reason | Auto mutation? | Operator correction? |
| --- | --- | --- | --- | --- | --- | --- |
| Source A Event 10 vs Source B Event 10 | Event lookup includes `source_system_id` | B cannot resolve A's Event | pending if missing locally | `:source_event_not_found` | pending only | Yes (catalogue/data) |
| Source A Product 123 vs Source B Product 123 | ProductMapping source-scoped | Isolated | pending or mapped within source | n/a / mapping | within source only | Yes |
| Source A Var 456 vs Source B Var 456 | Same | Isolated | same | same | same | Yes |
| source_event=Event A, ProductMapping=Event B | Source event TicketType | Map to A | `:mapped` | `:order_event_mapping_conflict` | maps once | Review; explicit correction only if authorised case |
| variation 456 expected parent 123, mapping parent 999 | Exact ProductMapping miss for (123,456) | No wrong-parent mapping selected; product-level fallback may apply if present | pending or mapped via product-level | n/a | per fallback | Review |
| source event valid, TicketType missing | Event ok, TicketType miss | Fail closed | pending | `:source_ticket_type_not_found` | reason update | Create TicketType then retry |
| source event absent, exact variation mapping exists | ProductMapping | Map via fallback | `:mapped` | nil | yes if eligible | n/a |
| source event absent, variation mapping missing, product mapping exists | Product-level ProductMapping | Map via product-level | `:mapped` | nil | yes if eligible | Review if wrong grain |
| mapped historical row receives conflicting event id | protect_mapped | Keep attribution | `:mapped` | `:source_event_identity_conflict` | reason only | Explicit correction |
| mapped row's ProductMapping later changes | Mapper skip + no-op worker | Unchanged | `:mapped` | prior reason retained | no | Explicit correction |

Every ambiguous cross-event/cross-source case fails closed or maps with explicit conflict reason — never silent cross-source attribution.

---

## 18. Deterministic Attribution Flow

```text
OrderItem (after durable upsert)
  │
  ├─ mapping_status ∉ {pending_mapping_resolution, unmapped}?
  │     └─ YES → leave unchanged
  │
  ├─ AutomaticMappingPolicy(order.status) == :deferred (:on_hold)?
  │     └─ YES → leave pending
  │
  ├─ attribution_status_reason == :invalid_source_tickera_event_id?
  │     └─ YES → set/keep reason; do NOT MappingResolver fallback
  │
  ├─ source_tickera_event_id is integer?
  │     │
  │     ├─ YES → OrderAttributionResolver
  │     │         ├─ resolve Event under Order.source_system_id
  │     │         ├─ resolve TicketType inside Event (product or variation key)
  │     │         ├─ load ProductMapping as validation/review context
  │     │         ├─ MAP (optional :missing_product_mapping | :order_event_mapping_conflict)
  │     │         └─ or PENDING (:source_event_not_found | :source_ticket_type_not_found)
  │     │
  │     └─ NO → MappingResolver
  │               ├─ exact active variation ProductMapping (if variation present)
  │               ├─ else active product-level ProductMapping
  │               ├─ MAP via apply_mapping
  │               └─ or remain pending_mapping_resolution
```

Evidence: `order_item_mapper.ex:41-189`; `order_attribution_resolver.ex`; `mapping_resolver.ex`.

---

## 19. Performance & Index Review

Attribution truth remains **Postgres**. No Redis/ETS attribution authority.

| Path | Source-scoped? | Bounded? | Indexes used / present | Queries per item (typical) | N+1 / load risk |
| --- | --- | --- | --- | --- | --- |
| Event-first Event lookup | Yes | `limit(1)` | `catalog_events_unique_external_tickera_event_idx` | 1 | Low |
| Event-first TicketType | Via event_id | `limit(1)` | `catalog_ticket_types_unique_external_ticket_idx`; `catalog_ticket_types_event_active_idx` | 1 | Low |
| Event-first ProductMapping | Yes | `limit(1)` | active product/variation unique indexes | 1 | Low |
| MappingResolver | Yes | `limit(1)` × up to 2 | same mapping indexes | 1–2 | Low |
| Mapper pending list per order | By order_id | order-scoped | `sales_order_items_order_id_idx` | 1 list + per-item resolve | Per-line sequential resolve (acceptable; not whole-catalogue load) |
| protect_mapped mapped_external_event_id | — | loads `:event` | PK | +1 load when mapped + conflicting path | Localised |
| MissingCatalogResolver | Yes + product/variation filters | product-scoped pending set | `sales_order_items_woo_product_variation_idx`, mapping_status indexes | 1 list + per item | Bounded by matching pending set |

Flash-sale note: per-line 1–3 indexed reads is reasonable. No whole-mapping-table scan in resolvers.

Evidence: `order_item.ex:58-77`; `product_mapping.ex:24-34`; migrations cited in §9.2; resolver `limit(1)` filters.

---

## 20. Required Future Implementation Gaps

Only evidence-backed gaps. **Do not implement during M1-04..M1-08.** Collect into the M1-09 certification pack as a mandatory **PRE-M2 CONTRACT IMPLEMENTATION GATE**; open a small **M1-C** corrective implementation slice only if required gaps remain after M1-09.

| ID | Gap | Class |
| --- | --- | --- |
| G1 | Event-first TicketType variation resolution must fail closed when `TicketType.external_product_id` is present **and** differs from `OrderItem.woo_product_id`. This follows M1-02 variation identity `(source, parent woo_product_id, woo_variation_id)` — matching variation while accepting the wrong parent weakens locked parent integrity. **Not cosmetic.** Current production code omits this check (`order_attribution_resolver.ex:76-89`). | REQUIRED_BEFORE_M2 (**BLOCKING BEFORE M2**) |
| G2 | Product-level ProductMapping fallback for variation-bearing lines (when exact variation mapping absent) can attribute a variation purchase at product grain. Keep optional unless later evidence shows wrong attribution. | OPTIONAL_HARDENING |
| G3 | OrderItem `:remap` Ash action exists without a normal-ingestion caller. Treat as optional attack-surface review; **do not implement merely because it exists**; do not generalise into a remapping API. | OPTIONAL_HARDENING |
| G4 | Programme-supported correction remains the hardcoded Order 113834 module. **Do not generalise** until a proper correction/audit design exists; a narrow mechanism is safer than a premature general remap API. | REQUIRED_LATER |

No speculative indexes. No Redis attribution structures required by this contract.

**Closeout note:** M1-03 contract = PASS. Current production implementation has known gap G1 against that contract. That split is acceptable because M1 is contract-first and forbids implementation here.

---

## 21. Explicit Non-Goals

M1-03 does **not**:

```text
change source identity or implement M1-02 normalization gaps
add Event Ash identities / harden identity-field accepts
implement multi-source webhook routing
create Product / ProductVariation / Event*Link resources
change OrderUpserter ownership
redesign Woo statuses / define recognised revenue / order count
design refunds / Refund resources / financial metrics
resolve timestamp / freshness / backfill / financial reconciliation
design ANALYTICS_READY / change dashboard/cache architecture
perform Phase 5E / Apply / AutoApply / mutate WordPress
```

---

## 22. Decisions A1–A18

| ID | Decision |
| --- | --- |
| **A1** | Precedence: invalid source-event reason blocks fallback; else integer `source_tickera_event_id` → event-first; else ProductMapping fallback. Names/SKU/similarity never authority. |
| **A2** | `source_tickera_event_id` must be a single positive integer from `tickera_event_id` meta; conflict/unparsable → nil id + `:invalid_source_tickera_event_id`. |
| **A3** | Event resolution always includes `Order.source_system_id` + `:tickera_event` + external id; never cross-source. |
| **A4** | Inside Event: product-only lines match active `:woo_product` TicketType by product id; variation lines match active `:woo_variation` TicketType by variation id. |
| **A5** | On event-first path, ProductMapping is validation/review context only — never Event override. |
| **A6** | Source Event vs ProductMapping disagreement → still map to source Event/TicketType with `:order_event_mapping_conflict`. |
| **A7** | Absent source event id (and not invalid reason) → `MappingResolver` under Order's source. |
| **A8** | Exact active variation ProductMapping preferred; if absent, active product-level may map (certified). Sibling variation mappings never selected. |
| **A9** | ProductMapping exact variation always requires parent product id (no silent re-parent). Event-first TicketType variation filter does not currently enforce parent mirror equality (gap G1). |
| **A10** | TicketType is event-first relationship authority; ProductMapping is fallback relationship authority and event-first review evidence. Disagreement is explicit conflict reason, never silent repair. |
| **A11** | Status machine as §11; automatic pending→mapped allowed; mapped not auto-unmapped; mapped not auto-reassigned. |
| **A12** | Reasons as §12; distinct failures keep distinct atoms. |
| **A13** | Mapped historical rows: Event/TicketType immutable under normal ingestion; conflict freezes source identity with `:source_event_identity_conflict`. |
| **A14** | Normal reprocessing may pending→mapped only; Event/TicketType changes require explicit reviewed correction (or authorised mapped-import), not ordinary sync. |
| **A15** | `:on_hold` defers automatic mapping; remains pending until later eligible status upsert. |
| **A16** | Unresolved pending may retry; MissingCatalogResolver may mark `:unmapped` after failed eligible retry; mapped conflict evidence does not remapped. |
| **A17** | Cross-source equal numeric IDs never alias; cross-event ProductMapping conflict is fail-visible (`:order_event_mapping_conflict`) without override. |
| **A18** | Current attribution queries are source-scoped, `limit(1)`, indexed; adequate for flash-sale line rates without Redis authority. Gaps are G1–G4 only. |

---

## 23. M1-04 Handoff Inputs

M1-04 may assume:

```text
ATTRIBUTION
  event-first when source_tickera_event_id present
  ProductMapping fallback otherwise
  mapped means durable event_id + ticket_type_id (+ item_kind ticket on apply paths)

MAPPING STATES
  pending_mapping_resolution | mapped | unmapped | non_ticket | ignored
  on_hold defers mapping only

IMMUTABILITY
  normal ingestion does not reassign mapped Event/TicketType

OUT OF SCOPE FOR M1-04 FROM THIS DOC
  do not redefine attribution precedence
  do not invent parallel mapping systems
```

M1-04 owns: order status lifecycle, recognised sale/revenue rules, visibility — using existing MetricRules/StatusRules as its certification baseline.

---

## 24. Open Questions

| Question | Blocks M1-04? |
| --- | --- |
| When to implement G1 parent-mirror fail-closed on event-first TicketType path | DOES NOT BLOCK M1-04 |
| Whether product-level fallback for variation lines should later become fail-closed (G2) | DOES NOT BLOCK M1-04 |
| Broader audited correction API beyond order 113834 | DOES NOT BLOCK M1-04 |
| Scheduling of M1-02 identity implementation gaps | DOES NOT BLOCK M1-04 |

No open question leaves A1–A18 ambiguous for attribution semantics.

---

## 25. M1-03 Verdict

```text
M1-03 VERDICT:
PASS

BASELINE:
4712f7736390ffec38c22c4e82fc46e9c054981b

DOCUMENT:
docs/path-1/m1-03-event-product-variation-orderline-attribution-contract.md

PRODUCTION CODE CHANGES:
NONE

MIGRATION AUTHORIZED:
NO

ATTRIBUTION IMPLEMENTATION GAPS:
1) REQUIRED_BEFORE_M2 / BLOCKING BEFORE M2 — G1 TicketType variation-parent fail-closed (unresolved; defer to M1-09 PRE-M2 gate / optional M1-C)
2) OPTIONAL_HARDENING — G2 product-level fallback for variation-bearing lines
3) OPTIONAL_HARDENING — G3 unused OrderItem :remap (do not generalise)
4) REQUIRED_LATER — G4 hardcoded order 113834 correction (do not generalise without design)

M1-04 AUTHORIZATION:
NOT GRANTED BY THIS TASK

NEXT RECOMMENDED ACTION:
Close out M1-03 on main, then start M1-04 with a FRESH agent using m1-01, m1-02, m1-03, roadmap, and product decisions — without redesigning attribution.
```
