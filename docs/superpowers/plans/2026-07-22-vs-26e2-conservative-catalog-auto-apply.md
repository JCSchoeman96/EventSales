# VS-26E.2 Conservative Catalog Auto-Apply Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Automatically queue exactly one existing hash-locked catalog Apply for an explicitly targeted, additive, published simple-product dry-run only when complete persisted risk proof, an empty finding set, supported versions, and zero historical impact are proven.

**Architecture:** Extend the existing discovery snapshot with a versioned, deterministic source-risk and identity-proof contract. A pure policy evaluates only durable run/snapshot/finding/configuration inputs; an ingestion orchestrator persists one Ash/Postgres decision per run/hash/policy version and transactionally links a once-only Oban Apply job. The existing `TickeraCatalog.Applier` remains the sole automated Event, TicketType, and ProductMapping writer, while Human Apply continues through its unchanged public path.

**Tech Stack:** Elixir, Phoenix LiveView, Ash 3.x, AshPostgres/PostgreSQL, Oban, Ecto transactions, Phoenix PubSub, existing Cachex/ETS read models, WordPress/PHP feed adapter.

---

## Authority and exact baseline

- Planning authority: approved VS-26E.2 pack v0.9.1, SHA-256 `4b1b5cc428049690da929c30f755abf85b945f23d974ce78a50059e81e23ef30`.
- Pack planning baseline: `38df57526370211482d1734d2fb32740ef43d081`.
- Merged repository truth for this plan: `d489931c5e18da57fa4055538b7b2ac7a87e704d`.
- VS-26E.1 accepted serving commit: `149816a69728b6d09be53275aa6255f4f2e1b0d6`; evidence came from isolated Railway staging, not an actual production WordPress lifecycle mutation.
- Initial snapshot schema version: `tickera_catalog_plan.v2`.
- Initial policy version: `conservative_auto_apply.v1`.
- Initial finding allowlist: empty.
- Initial eligible origin: `targeted_catalog_change` only.
- Initial history threshold: every line and quantity count is zero.
- Initial explicit run origins: `human_admin | targeted_catalog_change | legacy_unknown`; only `targeted_catalog_change` is eligible in v1.
- This plan does not authorize implementation. JC-128 approval, JC-129 `APPROVE`, and JC-130 authorization are still required.

## Current architecture confirmation

| Area | Current truth at `d489931c` | Required VS-26E.2 change |
|---|---|---|
| Run lifecycle | `queued → discovering → retry_scheduled/dry_run_ready → applying → applied`, plus `failed/cancelled` | Add explicit immutable run origin; do not add an auto-specific run status. |
| Snapshot/hash | Planner currently JSON-normalizes a map, SHA-256 hashes it, then embeds `dry_run_hash` in the legacy snapshot | For v2, add schema version, source-risk proof, and reuse identity/membership fields before hashing, and store the digest outside the exact eleven-key snapshot. |
| Findings | Durable Ash finding rows and copies inside snapshot; severities info/warning/blocking | Persist exact risk findings, but initial policy requires zero findings. |
| Apply | Existing Applier validates ready/hash/snapshot/blocking findings, atomically claims, writes catalog in a transaction | Keep as sole writer; add an optional auto-decision claim guard without changing manual invocation semantics. |
| Human Apply | Admin LiveView calls `TickeraCatalogSync.queue_apply/3` | Preserve behavior and arguments; no automation mode check on the human path. |
| Discovery | Oban worker, 3 attempts, one active run per source partial unique index | Insert evaluator job transactionally with dry-run readiness and add bounded recovery. |
| Apply job | Oban uniqueness by run ID for 300 seconds | Keep as defense in depth; decision row lock + transactional job linkage becomes correctness boundary. |
| Historical impact | Pair-scoped DB aggregation, batches of 25, maximum 5,000 pairs | Policy validates every required total exists and equals zero; no raw lines loaded. |
| Target trigger | Generation-aware pending target and source-wide dispatcher | Copy target reason into run scope and set origin `targeted_catalog_change`. |
| Notifications | Run-scoped PubSub after durable commit; preview Cache is optional | Broadcast decision changes only after commit; UI never polls. |

## Domain and resource map

```text
Catalog
├── SourceSystem
│   └── catalog_auto_apply_mode: inherit | disabled | observe | enabled
├── Event
├── TicketType
└── ProductMapping

Catalog.TickeraCatalog
├── WordPressFeedResponse ── validates feed schema/risk fields
├── DiscoveryResult ──────── carries feed schema + target observation
├── SourceRisk ───────────── pure normalized per-source-identity proof
├── Normalizer ───────────── emits rows + findings + source risks
├── Planner ──────────────── emits v2 snapshot/hash + reuse proof
├── AutoApplyPolicy ──────── pure evaluation only
└── Applier ──────────────── only catalog writer (unchanged authority)

Ingestion
├── TickeraCatalogSyncRun ───────── explicit origin + durable snapshot
├── TickeraCatalogSyncFinding ───── durable findings
├── TickeraCatalogAutoApplyDecision ─ durable policy/audit/enqueue state
├── TickeraCatalogAutoApply ─────── orchestration and transactional enqueue
├── AutoApplyConfig ─────────────── deterministic global/source composition
├── EvaluateTickeraCatalogAutoApplyWorker
├── RecoverTickeraCatalogAutoApplyWorker
├── DiscoverTickeraCatalogWorker ── readiness + evaluator insertion
└── ApplyTickeraCatalogWorker ───── manual or decision-linked invocation

Phoenix LiveView
└── CatalogSyncLive ── bounded decision explanation via existing PubSub
```

## Locked contracts

### Source-risk codes

Persist only these bounded codes in v1:

```elixir
~w(
  private_event draft_event trashed_event deleted_event
  private_product draft_product trashed_product deleted_product
  private_variation draft_variation variation_mapping_required
  ambiguous_variation_name subscription_product payment_plan_product
  membership_product bundle_product addon_product unsupported_product_type
  missing_ticket_template unknown_product_semantics duplicate_ticket_name
  existing_mapping_conflict product_moved_between_events ambiguous_identity
  missing_source_risk_data
)a
```

The WordPress adapter must derive semantic codes from status, product type, subscription metadata, and reviewed source reason fields only. It must never infer membership, bundle, or add-on semantics from titles or display labels. A missing required field produces `missing_source_risk_data`; an unknown non-empty type produces `unknown_product_semantics` and `unsupported_product_type`.

### Persisted source proof

DiscoveryResult and Normalizer carry a per-identity internal proof while planning, but the persisted v2 snapshot projects it into the closed `source_risks` fact list and `identity_membership_proof` objects enumerated below. The persisted representation has no parallel `proof_complete` boolean and no raw status/type fields: policy verifies that the exact required safe fact set exists and that no risky/missing/unknown/unsupported fact exists. This avoids trusting a derived flag and gives every fact one bounded evidence source/value.

For a targeted deletion whose feed row no longer exists, copy the durable signed trigger reason and target identity into the run scope. `WordPressFeedDiscoverySource` combines that scope with the parsed empty targeted response to emit the exact tombstone fact. `deleted` maps to the exact deleted event/product risk; an unexplained empty response maps to `missing_source_risk_data` and remains ineligible.

### Reuse proof

Version-2 reuse changes must persist the identifiers already verified by Planner queries:

```elixir
event reuse: %{
  "action" => "reuse",
  "event_id" => uuid,
  "source_system_id" => uuid,
  "external_event_kind" => "tickera_event",
  "external_event_id" => integer
}

ticket reuse: %{
  "action" => "reuse",
  "ticket_type_id" => uuid,
  "event_id" => uuid,
  "external_ticket_type_kind" => "woo_product",
  "external_ticket_type_id" => integer,
  "external_product_id" => integer,
  "external_variation_id" => nil
}
```

The policy validates equality and event membership from these persisted values. `reuse` performs no mutation in Applier. Missing proof fields fail closed.

### Closed canonical snapshot contract

Create `EventSales.Catalog.TickeraCatalog.SnapshotCanonicalizer` at `lib/event_sales/catalog/tickera_catalog/snapshot_canonicalizer.ex`. This module owns only the closed `tickera_catalog_plan.v2` byte representation and SHA-256 calculation. Planner supplies the logical snapshot; the canonicalizer returns `{:ok, canonical_bytes, lowercase_hex_hash}` or a bounded fail-closed error. It is not a general canonical-JSON library.

The v2 schema is closed recursively. Unknown top-level or nested keys and missing required keys are rejected. The complete field/type/nullability contract is enumerated below; implementation must not add fields outside it. Map keys are normalized to strings, validated against the allowed keys, and emitted lexicographically by UTF-8 byte order. The encoder writes compact UTF-8 JSON with no insignificant whitespace and never relies on Elixir map iteration order.

Scalar normalization is exact:

- integers remain JSON integers;
- floats are rejected;
- decimals become non-exponent decimal strings, with trailing fractional zeroes removed and negative zero normalized to `"0"`;
- datetimes become UTC RFC3339 strings with exactly six fractional digits and a `Z` suffix;
- booleans and explicit nullable fields remain JSON booleans and `null`;
- atoms are accepted only at the Planner boundary when mapped through a closed enum to fixed lowercase strings; arbitrary atoms/strings fail closed.

#### Complete persisted `tickera_catalog_plan.v2` schema

Planner keeps the current internal names `event_changes`, `ticket_type_changes`, `product_mapping_changes`, `touched_event_ids` and `touched_product_keys` while planning. `SnapshotCanonicalizer` is the explicit rename boundary: persisted v2 uses `event_actions`, `ticket_type_actions`, `product_mapping_actions` and `touched_identifiers`. V2 Applier reads only the v2 names after version dispatch; the legacy Human Apply branch continues reading the existing unversioned names. No alias is accepted within a v2 object.

Top-level object: exactly these eleven required keys, none nullable:

| Key | Exact type/enum |
|---|---|
| `snapshot_schema_version` | fixed string `tickera_catalog_plan.v2` |
| `source_system_id` | lowercase canonical UUID string |
| `origin` | `human_admin | targeted_catalog_change | legacy_unknown` |
| `event_actions` | list of closed Event-action variants below |
| `ticket_type_actions` | list of closed TicketType-action variants below |
| `product_mapping_actions` | list of closed ProductMapping-action variants below |
| `findings` | list of closed Finding objects below |
| `source_risks` | list of closed SourceRisk objects below |
| `historical_impact` | closed HistoricalImpact object below |
| `identity_membership_proof` | closed proof object below |
| `touched_identifiers` | closed touched-identifier object below |

All action-object keys listed for a variant are required. “Nullable” means the key must exist with JSON `null`; null never equals zero or empty string.

**Event action `create`**

```text
action: fixed "create"
ref: non-empty bounded string (max 160)
source_system_id: UUID
name: non-empty bounded string (max 255)
slug: non-empty bounded string (max 255)
status: fixed "active"
external_event_id: positive integer
external_event_kind: fixed "tickera_event"
source_status: "publish" | "private" | "draft" | "trash" | "deleted" | "unknown"
source_updated_at: canonical datetime, nullable
starts_at: canonical datetime, nullable
ends_at: canonical datetime, nullable
venue_name: bounded string max 255, nullable
booking_fee_type: "fixed" | "percentage" | null
booking_fee_value: canonical decimal string, nullable
```

**Event action `reuse`** — exact no-mutation proof is carried in the action and duplicated in the proof index for cross-checking:

```text
action: fixed "reuse"
ref: non-empty bounded string max 160
event_id: UUID
source_system_id: UUID
external_event_kind: fixed "tickera_event"
external_event_id: positive integer
```

**Event action `update_metadata`**

```text
action: fixed "update_metadata"
ref: bounded string max 160, nullable (key required)
event_id: UUID
source_status: "publish" | "private" | "draft" | "trash" | "deleted" | "unknown"
source_updated_at: canonical datetime, nullable
starts_at: canonical datetime, nullable
ends_at: canonical datetime, nullable
venue_name: bounded string max 255, nullable
booking_fee_type: "fixed" | "percentage" | null
booking_fee_value: canonical decimal string, nullable
```

**Event action `adopt_existing`** has the same metadata fields as `update_metadata`, plus required `external_event_id` positive integer and fixed `external_event_kind="tickera_event"`; it has no `ref` key because current Apply does not resolve one for adoption. Both `update_metadata` and `adopt_existing` canonicalize but are policy-ineligible in v1.

**TicketType action `create`**

```text
action: fixed "create"
ref: non-empty bounded string max 160
event_ref: non-empty bounded string max 160
name: non-empty bounded string max 255
active: fixed true
external_ticket_type_id: positive integer
external_ticket_type_kind: "woo_product" | "woo_variation"
external_product_id: positive integer
external_variation_id: positive integer, nullable
source_status: "publish" | "private" | "draft" | "trash" | "deleted" | "unknown"
source_updated_at: canonical datetime, nullable
```

**TicketType action `reuse`**

```text
action: fixed "reuse"
ref: non-empty bounded string max 160
ticket_type_id: UUID
event_id: UUID
external_ticket_type_kind: "woo_product" | "woo_variation"
external_ticket_type_id: positive integer
external_product_id: positive integer
external_variation_id: positive integer, nullable
```

**TicketType action `adopt_existing`**

```text
action: fixed "adopt_existing"
ticket_type_id: UUID
event_id: UUID
external_ticket_type_id: positive integer
external_ticket_type_kind: "woo_product" | "woo_variation"
external_product_id: positive integer
external_variation_id: positive integer, nullable
source_status: "publish" | "private" | "draft" | "trash" | "deleted" | "unknown"
source_updated_at: canonical datetime, nullable
```

Adoption canonicalizes but is policy-ineligible in v1.

**ProductMapping action `create`**

```text
action: fixed "create"
event_ref: non-empty bounded string max 160
ticket_type_ref: non-empty bounded string max 160
source_system_id: UUID
woo_product_id: positive integer
woo_variation_id: positive integer, nullable
original_label: bounded string max 255
current_label: bounded string max 255
active: fixed true
```

ProductMapping `move`, `update`, `deactivate`, `delete` and every unknown action are rejected by the closed v2 schema with bounded `unsupported_product_mapping_action`; they do not have a permissive unknown variant and can never reach automatic Apply.

**Finding object** — exactly five required keys:

```text
severity: "info" | "warning" | "blocking"
code: reviewed bounded finding-code string max 80
target_type: "event" | "product" | "variation" | "run"
target_id: positive integer, nullable only when target_type="run"
context: {} or closed object {"event_lifecycle": "past"|"current"|"future"|"unknown"}
```

Raw finding message and arbitrary metadata are excluded from the v2 hash projection. Human review continues to use durable `TickeraCatalogSyncFinding` rows for bounded display. Unknown context keys/values are rejected.

The closed finding-code enum is the current Planner vocabulary `duplicate_meta_collapsed | variation_mapping_required | ambiguous_variation_ticket_type_name | duplicate_ticket_type_name | private_event_skipped | draft_event_skipped | published_event_without_ticket_products | existing_mapping_conflict | existing_mapping_adopted | vwg_pretoria_preserved`, plus the exact bounded source-risk codes listed earlier when Normalizer persists a corresponding finding. Any other code is rejected as `unknown_finding_code`; v1 eligibility still requires an empty finding list.

**Source-risk fact** — exactly six required keys:

```text
target_type: "event" | "product" | "variation"
target_id: positive integer
code: one exact v1 source-risk code
evidence_classification: "explicit_safe" | "explicit_risky" | "missing" | "unknown" | "unsupported"
evidence_source: "wp_post_status" | "wc_product_type" | "ticket_template_meta" |
  "subscription_meta" | "signed_target_reason" | "planner_identity_query"
evidence_value: one source-specific enum below, nullable only for missing evidence
```

Closed evidence values are: for `wp_post_status`, `publish|private|draft|trash|deleted|unknown`; for `wc_product_type`, `simple|variable|grouped|external|simple-subscription|variable-subscription|subscription|unknown|unsupported`; for `ticket_template_meta`, `present|missing`; for `subscription_meta`, `present|absent|unknown`; for `signed_target_reason`, `saved|metadata_changed|status_changed|trashed|restored|deleted`; for `planner_identity_query`, `exact|mismatch|missing|ambiguous|moved`. Any other value maps to the corresponding `unknown`/`unsupported` fact before canonicalization; the raw value is not retained.

No title, description, raw metadata or raw WordPress value is allowed. One source identity may produce multiple facts; safe eligibility requires the exact complete fact set defined by SourceRisk validation.

**Historical-impact object** — exactly five required keys:

```text
totals: closed object containing ten non-negative integers:
  affected_pending_lines, affected_quantity,
  eligible_lines, eligible_quantity,
  deferred_lines, deferred_quantity,
  conflicting_lines, conflicting_quantity,
  already_mapped_lines, already_mapped_quantity
warning_count: non-negative integer
unresolved_destination_count: non-negative integer derived from non-resolved destinations
unknown_classification_count: non-negative integer aggregated across all classified rows
destinations: list of closed destination objects
```

Historical destination object, all keys required:

```text
woo_product_id: positive integer
woo_variation_id: positive integer, nullable
proposed_event_external_id: positive integer, nullable only for unresolved destination
proposed_ticket_type_external_id: positive integer, nullable only for unresolved destination
resolution: "proposed" | "existing_active_mapping" | "missing_destination" | "conflict"
pending_line_count: non-negative integer
quantity: non-negative integer
eligible_line_count: non-negative integer
deferred_line_count: non-negative integer
conflicting_line_count: non-negative integer
conflicting_quantity: non-negative integer
already_mapped_line_count: non-negative integer
already_mapped_quantity: non-negative integer
unknown_classification_count: non-negative integer
```

The current forecast’s unbounded/dynamic `by_order_status`, `by_mapping_status`, `by_source_event_identity`, `eligibility`, warning metadata and distribution maps are not copied into v2. Planner deterministically projects them to the totals, `warning_count`, top-level unresolved/unknown counts and destinations above. Any omitted/dynamic source category produces unknown classification and policy ineligibility.

**Identity/membership proof object** — exactly three required list keys:

```text
events[]:
  source_system_id UUID, external_event_kind "tickera_event",
  external_event_id positive integer, event_id UUID nullable for create,
  action "create"|"reuse"|"update_metadata"|"adopt_existing",
  no_mutation boolean
ticket_types[]:
  external_ticket_type_kind "woo_product"|"woo_variation",
  external_ticket_type_id positive integer,
  external_product_id positive integer,
  external_variation_id positive integer nullable,
  ticket_type_id UUID nullable for create,
  event_id UUID nullable only when the event is created and linked by event_ref,
  event_ref bounded string max 160 nullable only when event_id is non-null,
  action "create"|"reuse"|"adopt_existing",
  no_mutation boolean
product_mappings[]:
  source_system_id UUID, woo_product_id positive integer,
  woo_variation_id positive integer nullable,
  event_ref bounded string max 160, ticket_type_ref bounded string max 160,
  action fixed "create", no_existing_conflict boolean, no_movement boolean
```

Policy cross-checks proof entries against actions and rejects missing, duplicate or contradictory proof. `no_mutation=true` is valid only for reuse and is recomputed from action shape; it is never trusted alone.

**Touched-identifiers object** — exactly four required lists:

```text
event_ids: unique lowercase UUID strings, sorted bytewise
ticket_type_ids: unique lowercase UUID strings, sorted bytewise
mapping_ids: unique lowercase UUID strings, sorted bytewise; empty for creates before Apply
product_keys: unique objects {woo_product_id: positive integer,
  woo_variation_id: positive integer nullable}
```

`product_keys` preserves the product/variation pair required by existing post-Apply missing-resolution work. It sorts by `{woo_product_id, woo_variation_id || 0}`. Empty lists are present as `[]`; null is never an empty list.

Every semantically unordered list is normalized before encoding:

```text
event_actions:
  {external_event_id || 0, action, event_id || "", ref || ""}
ticket_type_actions:
  {external_product_id, external_variation_id || 0, action, ticket_type_id || "", ref || ""}
product_mapping_actions:
  {woo_product_id, woo_variation_id || 0, action, ticket_type_ref, event_ref}
findings:
  {severity, code, target_type, target_id || 0}
source_risks:
  {target_type, target_id, code, evidence_source, evidence_value || ""}
historical destinations:
  {woo_product_id, woo_variation_id || 0, proposed_ticket_type_external_id || 0}
identity proof lists:
  by each object type's corresponding action sort key above
touched identifiers:
  UUID lists bytewise; product_keys by {woo_product_id, woo_variation_id || 0}
```

No v2 list remains implicitly ordered. A list whose sequence becomes semantically meaningful must be added to a later closed schema version and explicitly declared order-preserving before that version is supported.

The exact hashed bytes include every closed top-level v2 value: `snapshot_schema_version`, `source_system_id`, `origin`, all action records, persisted findings, source-risk facts, historical-impact proof, identity/membership proof, and touched identifiers required by Apply. They exclude evaluation time, current modes, source allowlist, configuration revision/fingerprint, policy result, Oban IDs and telemetry.

The canonicalization and storage boundary is exact:

1. Validate the complete closed eleven-key v2 object.
2. Normalize every scalar and collection.
3. Produce deterministic canonical UTF-8 JSON bytes.
4. Calculate SHA-256 over those exact bytes.
5. Store the lowercase 64-character hexadecimal digest outside the snapshot.

The canonical v2 snapshot is stored unchanged in `plan_snapshot` as the exact eleven-key object. Its digest is stored in `TickeraCatalogSyncRun.dry_run_hash`, copied into `TickeraCatalogAutoApplyDecision.dry_run_hash`, and carried in automatic Apply job arguments and existing exact-hash linkage. The digest is never inserted into the object from which it is derived, and no second persisted envelope exists. Recomputing SHA-256 from the persisted snapshot must equal the run hash; the decision hash must equal the run hash; and an automatic job hash must equal both. Any mismatch fails closed. A `dry_run_hash` key inside a v2 snapshot is an unknown key and is rejected.

Compatibility is fail-closed without rewriting history:

- current unversioned snapshots remain available to Human Apply under the existing rules but are always auto-ineligible;
- feed schemas `2026-07-08.v1` and `2026-07-05.v1` remain Human-review-only and cannot produce an auto-eligible v2 snapshot;
- `tickera_catalog_plan.v1` and every unsupported version are auto-ineligible;
- existing snapshots and hashes are never migrated or rewritten;
- a new dry-run is required to produce v2.

Canonicalizer tests cover map insertion order, every unordered nested collection, decimal and datetime normalization, floats, unknown/missing keys, nullable fields, unsupported/unversioned snapshots, identical logical input producing identical bytes/hash, and every meaningful data change producing a different hash.

### Pure policy interface

```elixir
AutoApplyPolicy.evaluate(%{
  run_id: uuid,
  dry_run_hash: hash,
  origin: origin,
  snapshot: durable_snapshot,
  findings: durable_findings,
  policy_version: "conservative_auto_apply.v1"
}) :: {:ok, %{result: :eligible | :ineligible, reason_codes: [atom], summaries: map}}
       | {:error, %{result: :error, reason_codes: [atom], summaries: map}}
```

The policy must not receive a Repo, actor, clock, configuration callback, HTTP client, cache, PubSub, or Oban dependency. Evaluated time and effective modes are appended by orchestration after pure evaluation.

### Initial action/finding/history rules

- Event: `create` and proven no-mutation `reuse` are candidates; `update_metadata` is manual in initial v1, `adopt_existing` is manual, and unknown is ineligible. A later policy may reconsider `update_metadata` only after separate review.
- TicketType: `create` and proven same-event `reuse` are candidates; `adopt_existing` is manual and unknown is ineligible.
- ProductMapping: only `create` is a candidate. The current Planner emits no other ProductMapping action; `move`, `update`, `deactivate`, `delete`, and unknown are unsupported and therefore manual or rejected.
- A variation identity anywhere makes the whole run ineligible.
- Any persisted finding of any severity makes the whole run ineligible; missing finding metadata also fails closed.
- Every v2 historical field must exist with its closed type. Initial auto eligibility requires `affected_pending_lines = 0`, `affected_quantity = 0`, `eligible_lines = 0`, `deferred_lines = 0`, `conflicting_lines = 0`, `already_mapped_lines = 0`, `warning_count = 0`, `unresolved_destination_count = 0`, and `unknown_classification_count = 0`. Missing, negative, non-integer or non-zero values fail closed. V2 has no warnings list; legacy Human-only snapshots may retain their existing warning collection representation. Any affected historical order line makes the run manual in initial v1.
- Any unsupported/missing snapshot version, policy version, origin, risk, action, finding, or history field is ineligible with a bounded reason; policy exceptions persist an ineligible `policy_error` reason when audit storage remains available. Neither outcome enqueues Apply.

### Mode precedence

Use one audited hybrid configuration model. `CATALOG_AUTO_APPLY_HARD_ENABLED` is the environment-owned emergency kill, defaults false and cannot be overridden. A durable singleton `TickeraCatalogAutoApplyConfig` owns global mode, enabled policy versions, supported snapshot versions and monotonic revision. `SourceSystem` owns source mode and durable allowlisted boolean. Malformed environment configuration always resolves disabled, emits an explicit operator-visible health error and never crashes into or defaults to enabled.

```text
hard kill false                            → disabled
global disabled                            → disabled
source disabled or source not allowlisted  → disabled
global observe                             → observe (source enabled cannot override)
source observe                             → observe
global enabled + source enabled/inherit + allowlisted → enabled
anything missing/unknown/malformed         → disabled with bounded health error
```

Every decision persists evaluated modes, allowlist result, revision and configuration fingerprint. A changed revision/fingerprint supersedes the old decision and requires explicit reevaluation; an observation decision never becomes enqueued merely because configuration changes. Disabling is immediate defense in depth and is rechecked before enqueue claim and automatic Apply claim. Human Apply ignores this automation configuration.

The fingerprint uses this closed projection only:

```json
{
  "hard_kill_enabled": false,
  "global_mode": "disabled",
  "source_mode": "inherit",
  "source_allowlisted": false,
  "enabled_policy_versions": ["conservative_auto_apply.v1"],
  "supported_snapshot_versions": ["tickera_catalog_plan.v2"],
  "configuration_revision": 1
}
```

Reject unknown/missing keys, floats and arbitrary values; use fixed lowercase enums/booleans and a non-negative integer revision. Sort/deduplicate both version lists by UTF-8 bytes. Recursively sort string keys, encode compact deterministic UTF-8 JSON and SHA-256 the exact bytes. Operator identity, timestamps, row/source IDs, database metadata and explanations are excluded because they do not change eligibility. Tests cover map/list insertion order, changed eligibility fields, excluded-field changes and missing/unknown keys.

The durable singleton is database-enforced, not a lookup convention. `TickeraCatalogAutoApplyConfig` contains UUID `id`, fixed `singleton_key="global"`, global mode, enabled policy versions, supported snapshot versions, non-negative bigint revision starting at 1, and bounded audit actor/timestamps. The database has `UNIQUE(singleton_key)` plus `CHECK singleton_key='global'`. Only a private orchestration bootstrap action may create it; bootstrap performs insert-on-conflict followed by get, concurrent bootstrap converges on one row, public create/delete are unavailable, and deletion is prohibited while the feature exists.

Eligibility-affecting configuration updates lock the singleton row and require the caller's expected current revision. The caller never supplies a new revision. A real normalized value change increments revision exactly once in the same transaction; a no-op leaves revision unchanged because effective configuration did not change. Concurrent/stale updates serialize on the row lock and stale expected revision returns bounded `configuration_revision_conflict`. Fingerprint is computed from the resulting committed projection and decisions persist that revision/fingerprint. Tests cover singleton bootstrap/concurrency, invalid key/second row, unavailable public actions, concurrent and stale updates, exactly-once increment, no-op behavior, fingerprint/revision agreement and full rollback on failure.

### Evidence-based source-semantic derivation

The v2 contract distinguishes repository-confirmed inputs from additions and deliberately unknown semantics.

**Confirmed current repository fields**

| Meaning | Exact current source | Safe/risky interpretation |
|---|---|---|
| Event/product/variation status | `wp_posts.post_status` selected by the feed SQL | `publish` is candidate-safe; `private`, `draft`, `trash` map to bounded risks; missing/other is missing/unknown risk. |
| Product type | WooCommerce `product_type` taxonomy through `get_the_terms/2` | Reviewed simple type is candidate-safe; subscription types are risky; missing/other is unknown/unsupported. |
| Ticket template | `_ticket_template` product meta selected by feed SQL | Present reviewed ID is candidate-safe; missing is `missing_ticket_template`. |
| Subscription evidence | product type plus `_subscription_period`, `_subscription_length`, `_subscription_price`, `_subscription_sign_up_fee`, `_wc_subscription_period`, `_wc_subscription_length` | Any reviewed evidence yields `subscription_product`; missing classification data is unknown. |
| Variation identity | `product_variation` parent relationship and variation ID | Any variation is ineligible. |
| Target trash/delete intent | durable signed catalog-change reason and target identity copied into run scope | Exact trash/delete reason becomes tombstone risk; unexplained empty response is missing risk. |
| Mapping conflict/membership | Planner queries against persisted Event, TicketType and ProductMapping | Exact identity/membership proof is required; conflict/movement/ambiguity is risky. |

**Fields v2 adds from those confirmed sources**

The feed emits explicit normalized event/product/variation status classifications, product type, ticket-template presence, subscription classification, target observation/deletion state and reviewed risk codes. Each is derived only from the exact current source named above and parsed into the closed response schema before DiscoveryResult.

**No confirmed deterministic source**

Payment plan beyond confirmed subscription evidence, membership, bundle and add-on remain `unknown` until separately reviewed repository evidence identifies a deterministic API or metadata source. V2 persists `unknown_product_semantics`, making the run ineligible. It must not invent metadata keys or infer from titles, slugs, descriptions, category display names or arbitrary metadata-key discovery. Any future deterministic source requires plan/policy review before widening this table.

## Durable decision schema, ownership and state machines

Use a dedicated `TickeraCatalogAutoApplyDecision`; extending the run is rejected because observation, versioned evaluation, enqueue recovery and Apply audit have a lifecycle independent from run status. The decision belongs to both the Catalog Sync run and SourceSystem and stores `source_system_id` directly for bounded source-scoped recovery/admin queries.

Source consistency is a transactional domain invariant, not a row check. The private orchestration create action accepts only `catalog_sync_run_id`, locks/reloads that run inside its transaction, rejects a missing source, copies `run.source_system_id`, and never accepts independent client-supplied source ownership. Neither relationship is updateable. Tests prove forged/mismatched source input cannot create a decision and concurrent creation cannot produce disagreement.

Create `ingestion_tickera_catalog_auto_apply_decisions` with:

```text
id uuid primary key
catalog_sync_run_id uuid not null references ingestion_tickera_catalog_sync_runs(id) on delete restrict
source_system_id uuid not null references catalog_source_systems(id) on delete restrict
dry_run_hash text not null
snapshot_schema_version text not null, max 80
policy_version text not null, max 80
decision_result text not null: observe | eligible | ineligible
reason_codes text[] not null
action_summary jsonb not null
finding_summary jsonb not null
historical_summary jsonb not null
origin text not null
evaluated_global_mode text not null
evaluated_source_mode text not null
effective_mode text not null
source_allowlisted boolean not null
configuration_revision bigint not null
configuration_fingerprint text not null
evaluated_at timestamptz not null
enqueue_state text not null:
  not_applicable | pending | claimed | enqueued | retryable_failure | terminal_failure | superseded
apply_audit_state text not null:
  not_started | claim_rejected | claimed | completed | failed
apply_enqueue_key uuid not null
apply_job_id bigint null
enqueue_attempts integer not null default 0
enqueue_claimed_at timestamptz null
next_attempt_at timestamptz null
last_enqueue_error_code text null, max 80
internal_error_reference uuid null
apply_claimed_at/apply_completed_at timestamptz null
inserted_at/updated_at timestamptz not null
```

### Closed bounded summaries

Use closed validated JSON objects because summaries are aggregate audit projections, not independent domain entities. Application validation rejects extra/missing keys and non-integer/negative values; database checks bound `octet_length(summary::text)`.

```text
action_summary: maximum 1,024 bytes, exactly six integer keys
  event_create_count
  event_reuse_count
  ticket_type_create_count
  ticket_type_reuse_count
  product_mapping_create_count
  total_action_count

finding_summary: maximum 1,024 bytes, exactly five integer keys
  total_count
  info_count
  warning_count
  blocking_count
  unknown_count

historical_summary: maximum 2,048 bytes, exactly nine integer keys
  affected_pending_lines
  affected_quantity
  eligible_lines
  deferred_lines
  conflicting_lines
  already_mapped_lines
  warning_count
  unresolved_destination_count
  unknown_classification_count
```

Every count is `0..2_147_483_647`. Summaries contain no identifiers or source text. Customer names/emails, billing/shipping data, order payloads, payment data, ticket tokens, WordPress credentials, raw responses, titles/descriptions, arbitrary metadata, exceptions and stack traces are rejected from decisions, logs, PubSub and admin rendering.

### Database row invariants and indexes

Database-enforceable row facts are separate from transition-history and concurrency invariants:

```sql
UNIQUE (catalog_sync_run_id, dry_run_hash, policy_version)
UNIQUE (apply_enqueue_key)
UNIQUE (apply_job_id) WHERE apply_job_id IS NOT NULL
INDEX (catalog_sync_run_id, evaluated_at DESC, id DESC)
INDEX (source_system_id, inserted_at DESC, id DESC)
INDEX (next_attempt_at, source_system_id, id)
  WHERE enqueue_state IN ('pending', 'claimed', 'retryable_failure')
INDEX (policy_version, snapshot_schema_version, evaluated_at DESC)

CHECK closed values for decision_result, enqueue_state, apply_audit_state,
  origin and all mode fields
CHECK dry_run_hash ~ '^[a-f0-9]{64}$'
CHECK configuration_fingerprint ~ '^[a-f0-9]{64}$'
CHECK snapshot/policy version ~ '^[a-z0-9][a-z0-9._-]{0,79}$'
CHECK configuration_revision >= 0
CHECK enqueue_attempts BETWEEN 0 AND 20
CHECK cardinality(reason_codes) <= 32
CHECK every reason code length <= 80
CHECK summary byte limits
CHECK retryable_failure requires next_attempt_at; every other state, including claimed, requires null
CHECK terminal states have no future next_attempt_at
CHECK enqueued requires apply_job_id
CHECK not_applicable has no apply_job_id
CHECK superseded is not enqueued
CHECK completed has decision/job/run linkage and apply_completed_at
```

“Completed was previously claimed” cannot be proven by an ordinary row check. Private transactional actions enforce `claimed → completed|failed`, successful automatic run claim before `apply_audit_state=claimed`, enqueue claim only from eligible pending/retryable work, terminal/superseded irreversibility, copied source ownership, and audit updates after their corresponding durable run transition. Concurrency tests prove evaluator/enqueuer convergence, run-claim races and terminal non-revival.

### Explicit state ownership and retry contract

The pure evaluator creates the immutable identity and records observe/eligible/ineligible; it never enqueues. Orchestration owns pending/claimed/job linkage/retryable/terminal/superseded transitions. Apply owns claim rejection, successful automatic claim, completion and failure audit. Recovery reclaims stale claims, retries retryable work, reconciles the one linked job and marks exhaustion terminal.

```text
maximum enqueue attempts: 20; initial committed job insertion consumes attempt 1
delay after failure n: min(30 * 2^(n-1), 1800) seconds
maximum backoff: 30 minutes
stale enqueue claim: 10 minutes
recovery cadence: every 5 minutes
recovery batch: 100 ordered rows with FOR UPDATE SKIP LOCKED
attempt 20 failure: terminal_failure, no next_attempt_at, bounded operator-visible reason; attempt 21 is impossible
```

Duplicate evaluation returns the existing immutable decision. Stale hash/version/configuration becomes superseded. Disabled/removed-allowlist decisions cannot enqueue. Manual Apply/cancellation wins through the existing atomic run claim; automatic rejection records `claim_rejected` and leaves applicable ready runs Human-Apply compatible. Successful Apply records completed; failure after catalogue claim records failed.

### Exact atomic Oban insertion

The repository pins Oban `2.22.1`, configured with `EventSales.Repo`. Its inspected API supports `Oban.insert/3` with an `Ecto.Multi`, operation name and changeset/function. Select this strategy; no outbox alternative remains open:

```elixir
Ecto.Multi.new()
|> Ecto.Multi.run(:locked_decision, &lock_decision/2)
|> Ecto.Multi.run(:revalidated, &revalidate_enqueue/2)
|> Ecto.Multi.update(:claimed_decision, &claim_changeset/1)
|> Oban.insert(:apply_job, fn changes ->
  ApplyTickeraCatalogWorker.new(job_args(changes))
end)
|> Ecto.Multi.run(:linked_decision, &link_job/2)
|> EventSales.Repo.transaction()
```

Decision claim, Oban insertion and linkage commit or roll back together. Only a decision without committed `apply_job_id` may perform this initial insertion. Infinite-period uniqueness by decision ID is defense in depth, not correctness authority.

### Linked-job reconciliation

Once linked, recovery never inserts a replacement job:

| Oban state | Exact result |
|---|---|
| available | Leave enqueued; no insert/retry. |
| scheduled or retryable | Leave enqueued; no insert. |
| executing | Leave enqueued; no insert. |
| completed | Reload run/audit. Reconcile completed only when run is applied; otherwise terminal inconsistency + alert. Never retry. |
| discarded | Reconcile terminal if run/audit already applied/claimed/failed. Otherwise schedule the exact same linked job through the delayed state machine below. |
| cancelled | Same delayed same-job state machine; operator/run cancellation instead records terminal/claim_rejected. |
| absent | `terminal_failure: linked_job_missing`; no new job; operator review. |

`enqueue_attempts` means execution attempts already consumed or reserved. Initial insertion atomically changes it from 0 to 1. When recovery first observes discarded/cancelled attempt `n < 20`, it locks the decision and linked job, revalidates run/hash/version/config/linkage/audit, atomically sets `enqueue_attempts=n+1`, `enqueue_state=retryable_failure`, and `next_attempt_at=now + min(30 * 2^((n+1)-1), 1800)` seconds, then commits without calling Oban. Thus the first retry reserves attempt 2. When attempt 19 fails, recovery reserves final attempt 20; if attempt 20 fails, recovery sets terminal_failure without scheduling or incrementing.

A later recovery pass may act only when `next_attempt_at <= now`. It reloads/locks the same decision and exact job, revalidates effective enabled configuration, allowlist, run readiness, hash, versions, linkage and non-terminal audit, transitions retryable_failure to claimed and clears `next_attempt_at`, then invokes the installed default-instance API `Oban.retry_job(linked_job_id)` inside the same `EventSales.Repo` transaction and returns to enqueued on success. The call is immediate only after the durable delay expires; rollback leaves the prior retryable state/due timestamp. It never increments attempts at claim time and never changes `apply_job_id`.

Installed Oban 2.22.1 `Oban.retry_job/1` reuses the same job ID and ignores jobs already available/executing. Tests cover discarded/cancelled before due time, no immediate retry, exact due-time retry, atomic scheduling increment, backoff values/cap, attempts 19→20, terminal failure after attempt 20, no attempt 21, completed run/audit, executing job, two recovery nodes and unchanged linked ID.

### Automatic Apply audit boundary

Automatic arguments contain decision ID, run ID and exact hash. Before existing Apply claim, require linked decision/job, eligible result, supported versions, exact hash, enabled current configuration, allowed source/origin and matching configuration revision/fingerprint. Guard rejection records claim_rejected. Accepted run claim records claimed; successful catalogue/run transaction records completed; transaction failure records failed. Human jobs omit decision ID and retain current behavior.

## Exact file inventory

### Create

- `lib/event_sales/catalog/tickera_catalog/source_risk.ex`
- `lib/event_sales/catalog/tickera_catalog/snapshot_canonicalizer.ex`
- `lib/event_sales/catalog/tickera_catalog/auto_apply_policy.ex`
- `lib/event_sales/ingestion/resources/tickera_catalog_auto_apply_decision.ex`
- `lib/event_sales/ingestion/resources/tickera_catalog_auto_apply_config.ex`
- `lib/event_sales/ingestion/tickera_catalog_auto_apply.ex`
- `lib/event_sales/ingestion/tickera_catalog_auto_apply_config.ex`
- `lib/event_sales/ingestion/workers/evaluate_tickera_catalog_auto_apply_worker.ex`
- `lib/event_sales/ingestion/workers/recover_tickera_catalog_auto_apply_worker.ex`
- `test/event_sales/catalog/tickera_catalog/snapshot_canonicalizer_test.exs`
- `test/event_sales/catalog/tickera_catalog/auto_apply_policy_test.exs`
- `test/event_sales/ingestion/resources/tickera_catalog_auto_apply_config_test.exs`
- `test/event_sales/ingestion/tickera_catalog_auto_apply_test.exs`
- `test/event_sales/ingestion/workers/evaluate_tickera_catalog_auto_apply_worker_test.exs`
- `test/event_sales/ingestion/workers/recover_tickera_catalog_auto_apply_worker_test.exs`
- `integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-feed-test.php`
- `docs/architecture/tickera-catalog-auto-apply.md`
- `docs/runbooks/tickera-catalog-auto-apply.md`
- `docs/runbooks/tickera-catalog-auto-apply-rollback.md`
- `docs/evidence/vs-26e2-implementation-evidence.md`

### Modify

- `integrations/wordpress/eventsales-tickera-catalog-feed/eventsales-tickera-catalog-feed.php`
- `docs/ops/tickera_catalog_feed_contract.md`
- `lib/event_sales/catalog/tickera_catalog/wordpress_feed_response.ex`
- `lib/event_sales/catalog/tickera_catalog/wordpress_feed_discovery_source.ex`
- `lib/event_sales/catalog/tickera_catalog/discovery_result.ex`
- `lib/event_sales/catalog/tickera_catalog/catalog_row.ex`
- `lib/event_sales/catalog/tickera_catalog/normalizer.ex`
- `lib/event_sales/catalog/tickera_catalog/plan.ex`
- `lib/event_sales/catalog/tickera_catalog/planner.ex`
- `lib/event_sales/catalog/tickera_catalog/applier.ex`
- `lib/event_sales/catalog/resources/source_system.ex`
- `lib/event_sales/ingestion/resources/tickera_catalog_sync_run.ex`
- `lib/event_sales/ingestion/tickera_catalog_sync.ex`
- `lib/event_sales/ingestion/catalog_change_dispatch.ex`
- `lib/event_sales/ingestion/workers/discover_tickera_catalog_worker.ex`
- `lib/event_sales/ingestion/workers/apply_tickera_catalog_worker.ex`
- `lib/event_sales/ingestion.ex`
- `lib/event_sales/telemetry.ex`
- `lib/event_sales_web/live/admin/catalog_sync_live.ex`
- `config/config.exs`
- `config/runtime.exs`
- `test/support/tickera_catalog_fixtures.ex`
- `test/support/catalog_sync_run_helpers.ex`
- `test/event_sales/catalog/tickera_catalog/wordpress_feed_response_test.exs`
- `test/event_sales/catalog/tickera_catalog/wordpress_feed_discovery_source_test.exs`
- `test/event_sales/catalog/tickera_catalog/normalizer_test.exs`
- `test/event_sales/catalog/tickera_catalog/planner_applier_test.exs`
- `test/event_sales/ingestion/tickera_catalog_sync_test.exs`
- `test/event_sales/ingestion/tickera_catalog_sync_concurrency_test.exs`
- `test/event_sales/ingestion/workers/discover_tickera_catalog_worker_test.exs`
- `test/event_sales/ingestion/workers/apply_tickera_catalog_worker_test.exs`
- `test/event_sales_web/live/admin/catalog_sync_live_test.exs`
- `test/event_sales/ash_resource_smoke_test.exs`
- `test/event_sales/domain_boundaries_test.exs`

### Generated

Ash resources are schema authority. Run `mix ash.codegen vs_26e2_catalog_auto_apply` exactly once during the authorised implementation gate; do not predeclare a timestamp and do not create a second hand-authored migration. Review the emitted migration before commit. Generated output categories are:

- `priv/repo/migrations/<generated>_vs_26e2_catalog_auto_apply.exs`;
- new snapshots under `priv/resource_snapshots/repo/catalog_source_systems/`;
- new snapshots under `priv/resource_snapshots/repo/ingestion_tickera_catalog_sync_runs/`;
- new snapshots under `priv/resource_snapshots/repo/ingestion_tickera_catalog_auto_apply_configs/`;
- new snapshots under `priv/resource_snapshots/repo/ingestion_tickera_catalog_auto_apply_decisions/`;
- repository-tool updates to `docs/architecture/domain_map.json` and `docs/architecture/module_manifest.json`.

The generated migration must implement the reviewed design: decision/config tables, direct source FK, constraints/indexes, run origin and SourceSystem policy fields. Add run origin nullable with database default `legacy_unknown`, backfill existing rows to `legacy_unknown`, validate, then make non-null while retaining that default. New code writes `human_admin` or `targeted_catalog_change`; old nodes/scripts that omit origin safely receive permanently auto-ineligible `legacy_unknown`. Retain the default throughout v1 as a fail-closed compatibility guard. Removing it requires a separately reviewed migration proving every application and operational writer supplies origin. Add SourceSystem mode/allowlist with `inherit`/false safe defaults. Never rewrite existing snapshots or hashes.

New decision/config indexes are ordinary transactional indexes because those tables begin empty. Existing-table changes use expand/backfill/validate/contract in the single reviewed generated migration: add nullable columns, backfill run origin in primary-key batches of 1,000, validate allowed values, then set non-null. Each `ALTER TABLE` may take a brief PostgreSQL `ACCESS EXCLUSIVE` metadata lock; set migration `lock_timeout` to 5 seconds and `statement_timeout` to 60 seconds so deployment fails safely instead of waiting indefinitely. JC-129 must measure run/source cardinality; more than 10,000 run rows or a projected batch over 60 seconds returns `REFRESH REQUIRED` for a separately reviewed batched migration.

Runtime uses the documented PgBouncer session-pooling path; migrations use direct/session-capable `DIRECT_DATABASE_URL`. Transaction-pooling compatibility is not claimed and no non-transactional concurrent index is required by this design. Old/new code can overlap while automation remains hard-disabled: old code ignores additive columns and receives the `legacy_unknown` database default, new code treats nullable/pre-backfill origin as `legacy_unknown`, and workers cannot enable until constraints/backfill verify. Migration tests cover old-writer omission, all three stored origins, permanent legacy ineligibility, mixed nodes, post-backfill non-null and old-code rollback with additive schema/default retained.

Rollback keeps additive schema by default: roll code back and hard-disable automation. Schema rollback is permitted only when no decision rows or linked jobs exist. Otherwise retain audit rows/schema; never drop them automatically.

### Documentation

- Architecture: `docs/architecture/tickera-catalog-auto-apply.md`
- Operation/rollout: `docs/runbooks/tickera-catalog-auto-apply.md`
- Rollback/failure handling: `docs/runbooks/tickera-catalog-auto-apply-rollback.md`
- Implementation evidence: `docs/evidence/vs-26e2-implementation-evidence.md`

### Forbidden areas

- Do not add a second Event/TicketType/ProductMapping writer.
- Do not alter Human Apply authorization or warning behavior.
- Do not call WooCommerce/WordPress from policy, evaluator, LiveView, controller, or MappingResolver.
- Do not make Redis/ETS/Cachex/GenServer state authoritative.
- Do not add periodic catalog reconciliation or order catch-up.
- Do not enable runtime modes during implementation.

## Tests-first implementation sequence

### Task 1: Freeze feed v2 and risk-code behavior

**Files:** WordPress feed PHP/test, feed contract, `wordpress_feed_response.ex`, response tests.

- [ ] Add failing PHP and ExUnit cases for schema `2026-07-22.v2`, all supported simple/risky product types, explicit trash/delete observations, missing fields, and unknown semantics.
- [ ] Run `php integrations/wordpress/eventsales-tickera-catalog-feed/tests/catalog-feed-test.php`; expect new v2 assertions to fail.
- [ ] Run `mix test test/event_sales/catalog/tickera_catalog/wordpress_feed_response_test.exs`; expect missing schema/risk-field failures.
- [ ] Extend the feed with deterministic `product_type`, reviewed reason codes, and targeted observation fields; retain old schema parsing only for Human review and mark its proof incomplete.
- [ ] Re-run both focused suites; expect pass.
- [ ] **STOP:** stop if a required semantic has no deterministic reviewed source; persist it as unknown rather than inventing a field.
- [ ] Commit feed contract and parser changes.

### Task 2: Persist complete risk proof through normalization

**Files:** `source_risk.ex`, DiscoveryResult, CatalogRow, discovery source, Normalizer, fixtures and normalization tests.

- [ ] Write table-driven failing tests for every locked source-risk code and for missing/unknown fields.
- [ ] Add tests proving non-published product/variation rows are represented in risks/findings instead of silently disappearing.
- [ ] Add tests for signed-trigger `deleted` tombstones and unexplained empty targeted responses.
- [ ] Run the focused Normalizer/discovery tests; expect missing SourceRisk contract failures.
- [ ] Implement the exact sorted `source_risks` output and bounded findings.
- [ ] Re-run focused tests; expect pass.
- [ ] **STOP:** stop if any filtered/non-published identity can disappear without a persisted risk/finding.
- [ ] Commit risk propagation.

### Task 3: Version and strengthen the deterministic snapshot

**Files:** Plan, Planner, `snapshot_canonicalizer.ex`, canonicalizer/planner/applier tests.

- [ ] Write failing tests for `tickera_catalog_plan.v2`, stable hash generation, source-risk inclusion, exact reuse proof, same-event membership, and missing-proof rejection fixtures.
- [ ] Add failing tests for every enumerated action/nested/proof/destination/touched object and nullable field; every unknown-key boundary and persisted-name collection permutation; decimal/datetime normalization; floats; legacy feed/unversioned/unsupported snapshots; identical bytes/hash and meaningful-change hash differences.
- [ ] Add failing boundary tests proving the persisted v2 snapshot has exactly eleven keys, a `dry_run_hash` snapshot key is rejected, recomputation matches `TickeraCatalogSyncRun.dry_run_hash`, decision/run mismatch is ineligible, automatic job/run/decision mismatch rejects claim, Human Apply retains its existing exact-hash behavior, and existing unversioned snapshots are not rewritten.
- [ ] Run planner tests; expect missing version/proof failures.
- [ ] Implement the closed canonicalizer contract, snapshot schema version, sorted risk/reuse proof and exact byte boundary; persist the exact eleven-key snapshot unchanged and store `dry_run_hash` only on the run, decision and automatic job linkage.
- [ ] Re-run planner/applier tests; expect pass and unchanged existing manual Apply behavior.
- [ ] **STOP:** stop if equivalent logical input hashes differently, unknown keys are accepted, or an unversioned snapshot becomes auto-eligible.
- [ ] Commit snapshot v2.

### Task 4: Implement the pure conservative policy

**Files:** `auto_apply_policy.ex`, `auto_apply_policy_test.exs`.

- [ ] Write exhaustive failing matrix tests for every Event, TicketType, ProductMapping action, mixed plans, all findings/severities, every risk, variation, origin, version, missing field, and every historical total/warning/destination state.
- [ ] Add tests proving `update_metadata`, adoption, any finding, any variation, and one historical line reject the whole run.
- [ ] Add a purity test using only immutable maps and verify repeated evaluation returns identical results/reasons/summaries.
- [ ] Run the policy test file; expect module-not-found failure.
- [ ] Implement minimal policy with closed action/risk/reason vocabularies and no side-effect dependencies.
- [ ] Re-run policy tests; expect pass.
- [ ] **STOP:** stop if any finding/history/risk/variation/update_metadata/unsupported action becomes eligible or policy requires a side-effect dependency.
- [ ] Commit policy.

### Task 5: Add explicit origin, source mode, and durable decision resource

**Files:** SourceSystem, SyncRun, decision resource, Ingestion domain, migration, Ash snapshots, resource tests.

- [ ] Write failing Ash resource tests for explicit origins, database-enforced `global` config singleton/private bootstrap/no delete, atomic revision/no-op/stale updates, source mode/allowlist, decision fields, copied source ownership, closed summaries, constraints, relationships, cursor/recovery indexes and private transition actions.
- [ ] Add migration-level assertions for every SQL constraint/index, nullable→batched backfill→validated non-null sequence, 5-second lock timeout, 60-second statement timeout, old-code compatibility and non-destructive rollback guard.
- [ ] Run focused resource/domain tests; expect missing attributes/resource failures.
- [ ] Add origin to run, mode/allowlist to SourceSystem, singleton durable config and dedicated source-owned decision resource.
- [ ] Run `mix ash.codegen vs_26e2_catalog_auto_apply`; inspect and retain the exact generated migration/snapshots, reconciling the generated migration to the locked constraint names without weakening them.
- [ ] Run focused resource/domain tests; expect pass.
- [ ] **STOP:** stop if source ownership can be client-forged, a required invariant is mislabeled as a row check, or generated schema cannot express the reviewed design.
- [ ] Commit schema/resource changes.

### Task 6: Make run origin explicit on every creation path

**Files:** TickeraCatalogSync, CatalogChangeDispatch, CatalogSyncLive, sync tests.

- [ ] Write failing tests that admin runs persist `human_admin`, targeted runs persist `targeted_catalog_change`, existing/old-writer rows receive database-default `legacy_unknown`, mixed nodes remain compatible, trigger reason is copied into sanitized scope, and missing/forged origins are rejected.
- [ ] Prove nil `requested_by_user_id` never implies automation eligibility.
- [ ] Run focused sync tests; expect missing origin failures.
- [ ] Set origin internally at each facade entry point; do not accept arbitrary browser-supplied origin.
- [ ] Re-run focused tests; expect pass.
- [ ] **STOP:** stop if origin is inferred from nil user identity or arbitrary caller input.
- [ ] Commit origin wiring.

### Task 7: Persist decisions and schedule evaluation without gaps

**Files:** auto-apply facade/config, evaluator worker, Discover worker, config files, tests.

- [ ] Write failing tests for hard-kill/global/source composition, canonical configuration fingerprint/revision, malformed config disabled with health error, empty allowlist, policy exception, audit failure, duplicate evaluator and exact closed summaries.
- [ ] Add a transaction rollback test proving dry-run readiness and evaluator job insertion succeed or fail together.
- [ ] Run focused evaluator/discovery tests; expect missing orchestrator failures.
- [ ] Insert evaluator jobs for every ready run inside the existing readiness transaction; non-targeted runs persist ineligible decisions rather than being silently skipped.
- [ ] Persist one decision using the unique run/hash/policy identity; handle unique-conflict reload as idempotent success.
- [ ] Publish decision PubSub only after commit.
- [ ] Re-run focused tests; expect pass.
- [ ] **STOP:** stop if malformed configuration can enable, fingerprint bytes are nondeterministic, audit failure can enqueue, or duplicate evaluation diverges.
- [ ] Commit evaluator scheduling.

### Task 8: Implement transactional once-only Apply enqueue

**Files:** auto-apply facade, evaluator tests, sync concurrency tests.

- [ ] Write failing concurrent multi-node tests for source-consistent decision creation and multiple enqueuers attempting the same decision.
- [ ] Add rollback injection tests before Oban insert, after insert, and before decision update; assert zero or exactly one committed job with recoverable pending state.
- [ ] Assert the first committed insertion sets `enqueue_attempts=1`, returns one linked job ID and never consumes an attempt on transaction rollback.
- [ ] Add tests for config/source disable between evaluation and enqueue.
- [ ] Run focused concurrency tests; expect duplicate/recovery failures.
- [ ] Implement the exact inspected `Ecto.Multi |> Oban.insert(:apply_job, changeset_or_fun) |> EventSales.Repo.transaction()` path with decision lock, revalidation, claim, stable key, insertion and linkage.
- [ ] Re-run focused tests; expect exactly one linked job.
- [ ] **STOP:** stop if any crash window commits job without linkage, linkage without job, or concurrent execution can create two jobs.
- [ ] Commit enqueue state machine.

### Task 9: Guard automated Apply without changing Human Apply

**Files:** Apply worker, Applier, TickeraCatalogSync claim path, worker/sync tests.

- [ ] Write failing tests for linkage, current configuration revision, disabled source/global/hard kill, stale hash, cancelled run, Human/auto races, missing decision, and claimed/completed/failed audit transitions.
- [ ] Assert blocked auto claims leave the run `dry_run_ready` and Human Apply remains available.
- [ ] Assert manual jobs without decision ID retain current warning and authorization behavior.
- [ ] Run focused worker/concurrency tests; expect missing guard failures.
- [ ] Add optional auto context and claim guard while retaining the current manual call path.
- [ ] Re-run focused tests; expect pass.
- [ ] **STOP:** stop if Human Apply requires policy state, automatic Apply can run without valid linkage, or audit does not follow durable run transitions.
- [ ] Commit claim guard.

### Task 10: Add bounded recovery and multi-node safety

**Files:** recovery worker, config/runtime cron, recovery tests.

- [ ] Write failing tests for every linked Oban state, delayed same-ID `Oban.retry_job/1`, missing/cancelled jobs, before/due timing, atomic consumed-attempt accounting, backoff/cap, 19→20/final failure/no 21, completed run/audit, executing job, stale 10-minute claims, two recovery nodes, partial-index SKIP-LOCKED batch and no full scan.
- [ ] Assert simultaneous recovery workers converge via database uniqueness/row locks.
- [ ] Run recovery tests; expect missing worker failures.
- [ ] Implement the exact linked-job table, limit-100 `FOR UPDATE SKIP LOCKED` recovery every five minutes, and never insert a replacement after linkage.
- [ ] Re-run tests; inspect query plan in the migration/index test fixture where supported.
- [ ] **STOP:** stop if attempt exhaustion remains recoverable, completed work can be retried, linked-job absence inserts a replacement, or query plan is unbounded.
- [ ] Commit recovery.

### Task 11: Add admin explanation, PubSub, and telemetry

**Files:** CatalogSyncLive, telemetry, LiveView tests.

- [ ] Write failing LiveView tests for all decision/enqueue/apply-audit states, admin-only source isolation, cursor pages (25 default/100 max), bounded allowlisted fields and PubSub refresh without polling.
- [ ] Add telemetry tests for low-cardinality policy version/result/effective mode/enqueue outcome; prohibit run IDs, source payloads, titles and customer data in metadata.
- [ ] Run focused LiveView/telemetry tests; expect missing decision UI failures.
- [ ] Load the latest decision by indexed run relationship, render bounded badges/reasons, and refresh through existing run-topic PubSub.
- [ ] Re-run tests and `mix assets.build`; expect pass.
- [ ] **STOP:** stop if UI polls, bypasses source authorization, renders protected/free-form data, or uses an unbounded query.
- [ ] Commit admin observability.

## Final Verification and JC-129 Handoff

**Files:** `docs/architecture/domain_map.json`, `docs/architecture/module_manifest.json`, `docs/architecture/tickera-catalog-auto-apply.md`, `docs/runbooks/tickera-catalog-auto-apply.md`, `docs/runbooks/tickera-catalog-auto-apply-rollback.md`, `docs/evidence/vs-26e2-implementation-evidence.md`.

Tasks 1–11 are the tests-first implementation units and each contains failing test, expected failure, minimum implementation, focused validation, regression validation, local STOP and commit boundary. This final phase is verification/handoff, not a twelfth implementation unit, so it does not introduce another failing test or production behavior.

- [ ] **Preconditions:** confirm implementation worktree clean except intended branch changes; exact activated pack/plan digests and JC-129 baseline still match; automation configuration remains hard-disabled.
- [ ] Update generated architecture manifests through repository tooling and run `bash scripts/check_no_web_woocommerce_refs.sh`.
- [ ] Run `mix format --check-formatted` and `mix compile --warnings-as-errors`.
- [ ] Run every focused test command named in Tasks 1–11 and record counts/results in `docs/evidence/vs-26e2-implementation-evidence.md`.
- [ ] Run `mix assets.build` and `mix test test/event_sales/assets_pipeline_config_test.exs` because LiveView changed.
- [ ] Run `bash scripts/local_ci.sh` as the full regression/CI gate.
- [ ] Verify generated migration/resource snapshots and architecture-manifest diffs against the exact reviewed inventory; stop on an extra or weakened constraint/index/default.
- [ ] Record EXPLAIN evidence for recovery, latest-run decision and recent-source cursor page; normal staging p95 targets are below 100ms for bounded reads.
- [ ] Complete the implementation evidence report with source-risk/policy matrices, concurrency/recovery proofs, Human Apply regression, security scan, disabled defaults and prohibited-actions confirmation.
- [ ] Open the required draft implementation PR only after all checks pass; verify it contains no runtime enablement, merge, deployment or shared-environment migration.
- [ ] Record exact implementation branch/head SHA, generated migration name, file inventory, test evidence and draft PR URL as JC-129 handoff artifacts.
- [ ] **STOP:** stop on any global STOP condition below, any incomplete CI/evidence, or any PR scope beyond the reviewed implementation.
- [ ] Stop after the draft PR and handoff report; do not merge, deploy, migrate a shared environment, enable automation or begin JC-129 automatically.

## Configuration and runtime contract

Add only the hard emergency gate and execution bounds to application configuration:

```elixir
config :event_sales, :catalog_auto_apply,
  hard_enabled: false,
  evaluator_max_attempts: 5,
  recovery_batch_size: 100,
  recovery_max_enqueue_attempts: 20
```

`runtime.exs` parses only `CATALOG_AUTO_APPLY_HARD_ENABLED`; absent/malformed values become false and add an operator-visible health error. Durable global mode/version support/revision live in the singleton config resource; durable source mode/allowlist live on SourceSystem. Initial database defaults are global disabled, source inherit/not allowlisted, policy `conservative_auto_apply.v1`, snapshot `tickera_catalog_plan.v2`, revision 1. No secret belongs in either configuration layer.

## Failure and race analysis

| Failure/race | Required result |
|---|---|
| Risk/version/history field missing | Durable ineligible decision with bounded reason; no enqueue. |
| Policy raises | Durable ineligible `policy_error` when audit write works; no enqueue. |
| Audit write fails | Transaction rollback; no Apply job. |
| Duplicate evaluators | Unique decision reload; same result; at most one enqueue attempt owns row lock. |
| Crash before job insert | Decision remains pending/recoverable. |
| Crash after insert before linkage | Same transaction rolls job back. |
| Source/global disabled after evaluation | Pre-enqueue or claim guard blocks automation. |
| Manual cancellation wins | Auto worker discards; cancellation audit remains. |
| Human Apply wins | Auto worker sees non-ready status and discards without catalog mutation. |
| Auto Apply wins | Human job cannot claim; existing atomic status/hash fence wins. |
| Snapshot/hash changes | Decision/job becomes stale/claim-blocked; no Apply. |
| PubSub/cache fails | Durable truth remains; bounded log/telemetry; no rollback of committed decision. |
| Multiple app nodes | PostgreSQL unique constraints/row locks and Oban transaction govern correctness. |
| Attempt 20 | Durable terminal_failure, no next attempt, bounded operator-visible error. |
| Linked job available/scheduled/retryable/executing | Preserve linkage; never insert/retry active work. |
| Linked job completed | Reconcile only with applied run; inconsistency becomes terminal alert; never retry. |
| Linked job discarded/cancelled | Reserve the next attempt with deterministic delay, then guarded in-place `Oban.retry_job/1` only when due and still safe; never insert replacement. |
| Linked job absent | Terminal `linked_job_missing`; operator review; no replacement. |

## Performance and scaling

- Decisions/configuration audit are cold durable Postgres truth; evaluator/enqueue are bounded Oban work; admin current status is an indexed Postgres read with optional existing Cachex/ETS acceleration; PubSub is notification only after commit.
- Maximum one decision exists per run/hash/policy version. Growth follows Catalog Sync run growth; no automatic v1 deletion and no unbounded identifier arrays.
- Evaluator loads one run by primary key, its indexed findings by run ID, one direct source row and singleton config; it never scans catalog tables or calls WordPress.
- Historical policy reads only the already-persisted aggregate in the snapshot. Existing forecast remains pair-batched at 25 and bounded at 5,000 touched pairs.
- Recovery uses the partial `(next_attempt_at, source_system_id, id)` index, `FOR UPDATE SKIP LOCKED`, limit 100 and stable ordering.
- Admin history is source-filtered cursor pagination by inserted_at/id, default 25 and maximum 100; it performs no peak full-table counts or polling.
- Normal staging p95 targets are below 100ms for indexed single-decision and bounded recent-source page reads. Implementation/JC-129 evidence includes EXPLAIN for recovery, latest decision by run and recent decisions by source.
- No Redis/ETS/Cachex decision authority and no new GenServer.
- No cache is required for correctness. If decision reads are cached, invalidate after commit and use existing Cachex stampede patterns before PubSub. Redis never owns eligibility.
- Oban retries are bounded: evaluator 5, recovery job bounded by batch/cadence, Apply remains 3, enqueue attempts terminate at 20.
- Evaluator adds no WooCommerce request and no checkout, scanner or ticket-sale write-path work.

## Security and privacy contract

Telemetry event names are fixed at compile time; permitted labels are policy version, snapshot version, decision result, effective mode, enqueue outcome and bounded operational error code. Admin fields are limited to authorized run/source IDs, versions, states, modes, bounded reason/count summaries and timestamps. Reason codes and summary keys use closed allowlists.

Never create atoms from source values, emit free-form source text as telemetry labels, persist raw exception messages, or expose configuration secrets. Operational failures persist a bounded code plus internal UUID reference. Every query includes authorized source isolation. Tests prove protected keys cannot enter decisions, logs, PubSub or UI.

## Global implementation STOP conditions

Stop the implementation gate immediately when:

- unrelated worktree changes exist or main differs from the JC-129 activation baseline;
- pack/plan digest differs from the approved activation supplement;
- generated migration materially differs from this reviewed design;
- existing Apply tests regress or Human Apply requires auto-policy state;
- source risk can disappear without durable evidence;
- canonical bytes/hash differ for equivalent logical input;
- unversioned/unsupported snapshot becomes auto-eligible;
- a required database row constraint cannot be expressed;
- concurrent tests can create duplicate decisions/jobs or source mismatch;
- attempt ceiling lacks terminal outcome or completed work can be retried;
- protected data enters summaries/logs/PubSub/UI;
- recovery/source/admin query is unbounded or source isolation fails;
- malformed configuration does not fail disabled;
- migration requires unsafe rewrite/unacceptable lock or topology cannot support it;
- the same implementation test fails twice without new evidence;
- repository AGENTS.md timebox is exceeded;
- Railway, WordPress or production mutation would be required before JC-129 APPROVE.

The implementation gate stops after code/generated migration, focused/full CI, exact evidence report and draft implementation PR. It does not merge, deploy, migrate a shared environment or enable automation.

## JC-129 activation inputs

JC-129 must refresh and approve:

1. exact implementation-plan and JC-128 verdict;
2. exact current main and implementation PR head;
3. final feed schema, snapshot schema and policy versions;
4. final closed action/risk/reason/finding vocabularies;
5. migration, constraints, indexes and generated Ash snapshots;
6. global/source mode precedence and exact disabled defaults;
7. source allowlist contents (initially one isolated source only);
8. zero-history contract and query evidence;
9. eligible additive canary plus rejected finding/variation/private/special-product/history/unknown canaries;
10. mode disable at enqueue and claim, duplicate evaluation, single job linkage, Human Apply compatibility, and rollback evidence;
11. additional end-to-end WordPress lifecycle evidence required because VS-26E.1 acceptance was isolated staging;
12. stop conditions and immediate global/source kill-switch procedure.

## Intellectual-sparring decisions

| Challenge | Selected design | Rejected alternative and reason | Invariant | Planned proof |
|---|---|---|---|---|
| Dedicated decision resource | Separate source-owned decision/config audit lifecycle. | Extending run overloads run status and cannot represent versioned observation/enqueue history cleanly. | One immutable decision per run/hash/policy. | Resource identity/retry-history tests. |
| Crash-safe boundary | One inspected Ecto.Multi with Oban.insert/3 and Repo transaction. | Split insert/link or open-ended outbox leaves crash windows or unnecessary authority. | Claim/job/link commit together. | Rollback injection at every operation. |
| Apply without valid linked decision | Automatic job requires exact decision/job linkage; Human job omits it. | Optional linkage permits unaudited automation. | No automatic claim without linked eligible decision. | Missing/forged linkage tests. |
| Stale observation activation | Revision/fingerprint change supersedes and requires reevaluation. | Reusing observe decision would activate stale policy/config truth. | Observation never becomes enqueued in place. | Observe→enabled revision test. |
| Source enabled vs global observe | Global observe wins. | Source override broadens rollout unexpectedly. | Enabled only under the exact precedence table. | Exhaustive mode matrix. |
| Existing snapshots | Human Apply unchanged; auto-ineligible until new v2 dry run. | Rehash/migration would invalidate exact-hash audit. | No old hash rewrite or auto eligibility. | Unversioned/v1 compatibility tests. |
| Filtered source rows | V2 emits durable status/tombstone/unknown risks. | Silent filtering loses safety truth. | Every observed target has safe proof or explicit risk. | Non-published/empty target tests. |
| Origin breadth | Only targeted_catalog_change eligible. | All system/nil-user runs are ambiguous. | Missing, legacy and human origins reject. | Creation-path/policy tests. |
| Human vs automatic Apply | Existing atomic run claim remains authority. | Separate catalogue claim would create a second writer/race. | Exactly one claimant mutates through Applier. | Concurrent Human/auto tests. |
| Cancellation after enqueue | Claim guard reloads run and records rejection. | Enqueue-time-only checks miss later cancellation. | Cancelled run never auto-claims. | Enqueue/cancel/perform race. |
| Multi-node decisions | Database identity plus row locks and copied source ownership. | Process locks are node-local. | Nodes converge on one source-consistent row/job. | Multi-process concurrency tests. |
| Summary growth/privacy | Closed aggregate-only JSON with byte/key bounds. | Arbitrary maps/identifiers are unbounded and leak-prone. | Only reviewed bounded counts persist. | Unknown/protected key and byte-limit tests. |
| Admin refresh | Cursor reads plus post-commit PubSub. | Polling causes database load and stale race behavior. | No polling/full-table count. | LiveView subscription/query tests. |
| Recovery indexes | Partial source-scoped index and SKIP LOCKED limit 100. | Generic/full-state scan grows without bound. | Every recovery batch is indexed/bounded. | EXPLAIN and simultaneous worker tests. |
| Abstraction level | Canonicalizer, pure policy, config, orchestration and recovery each own one boundary. | GenServer/cache authority or further writers duplicate Postgres/Applier. | Postgres and existing Applier remain sole durable/write authorities. | Domain-boundary architecture tests. |

## Plan self-review

- Spec coverage: all approved v0.9.1 action, finding, risk, history, version, origin, durability, mode, compatibility, performance and rollout requirements map to explicit tasks.
- Placeholder scan: no deferred safety decision or open initial-v1 allowlist remains. Generated Ash snapshot filenames are intentionally tool-owned; the exact generator command and required resources are specified.
- Type consistency: `tickera_catalog_plan.v2`, `conservative_auto_apply.v1`, origins `human_admin | targeted_catalog_change | legacy_unknown`, state vocabularies, modes and run/hash/policy identity are consistent throughout.
- Scope: one vertical slice; no periodic reconciliation, order catch-up, parallel writer or production enablement.

## Prohibited-actions statement

JC-127 performed repository reconnaissance and produced this plan only. It did not write implementation code, create or run a migration, queue Catalog Sync/Apply, deploy, access Railway/WordPress, mutate PostgreSQL/Redis, open an implementation PR, or authorize implementation.

**Pack assessment: `PACK VALID`.** The approved pack is implementable against merged main `d489931c5e18da57fa4055538b7b2ac7a87e704d` with the exact design above. JC-128 independent plan review is required next.
