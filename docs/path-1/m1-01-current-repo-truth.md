Document:
Path 1 M1-01 Current Repository Truth

Audit base HEAD:
0bd0526a383a0d7faa1e61472f8551f779773223

origin/main:
0bd0526a383a0d7faa1e61472f8551f779773223

Audit date:
2026-08-09

Verdict:
PASS

---

# Path 1 M1-01 — Current Repository Truth

| Field | Value |
| --- | --- |
| Document | Path 1 M1-01 Current Repository Truth |
| Status | Complete audit baseline |
| Scope | Physical repository truth for identity, writers, attribution, status, money, refunds, timestamps, catch-up, reconciliation, analytics |
| Authority | Current source under audit HEAD; programme handoff and product decisions for locked contracts only |
| Path 1 plan file | At audit time, `EVENTSALES_PATH_1_UPDATED_PHASE_BREAKDOWN.md` was not tracked in the repository. Canonical execution roadmap after M1-01A: `docs/path-1/path-1-phase-breakdown.md` (supersedes provisional M1-03..M1-08 labels in §18 of this audit). |

### Revision log

- `v1` — initial M1-01 repository truth audit at Path 1 activation HEAD
- `v1.1` — note canonical Path 1 roadmap after M1-01A (`docs/path-1/path-1-phase-breakdown.md`)

---

## 1. Executive Result

```text
M1-01 = PASS
```

Reasons:

```text
Source identifiers are unambiguously labelled and traced
  (internal UUID PK ≠ kind+base_url ≠ producer wordpress_tickera:<hash>).

OrderUpserter is the sole durable order writer for webhook, catch-up, and CSV.

Order and OrderItem idempotency keys are proven in Ash identities + Postgres unique indexes.

Event/product/variation identity is physical today via Event + TicketType + ProductMapping
  (no first-class Product / ProductVariation / Event*Link resources).

Attribution authority is event-first when source_tickera_event_id is present,
  with ProductMapping fallback and fail-closed review reasons.

Refunds are established as status-only (independent Refund resources MISSING),
  which is a Path 1 contract gap for later milestones, not an M1-01 identity blocker.

Path 2 / Phase 5E remain paused; no Apply/AutoApply or production access used.
```

---

## 2. Repository Baseline

| Item | Value |
| --- | --- |
| Branch | `main` |
| HEAD | `0bd0526a383a0d7faa1e61472f8551f779773223` |
| origin/main | `0bd0526a383a0d7faa1e61472f8551f779773223` |
| Worktree preflight | Clean (`git status --short` empty); sync check ahead=0 behind=0 |
| Latest commit | `0bd0526 Merge pull request #166 from JCSchoeman96/docs/current-state-path-handoff` |
| Path 1 activation SHA | Same as HEAD (historical checkpoint still current) |
| Phase 5E | Remains paused per handoff; no Phase 5E work observed in this audit |
| Code changes this task | None (documentation only) |

Authoritative documents read:

```text
AGENTS.md
docs/agent/01_PROJECT_WIDE_RULES.md
docs/roadmap/current-state-and-path-handoff.md
docs/roadmap/EVENTSALES_PRODUCT_DECISIONS.md
docs/phase-5d/native-v3-e2e-run-report.md
```

Planning context (not in repository):

```text
EVENTSALES_PATH_1_UPDATED_PHASE_BREAKDOWN.md — absent from repo; not invented as a path
```

Navigation aids consulted, then verified against source:

```text
docs/architecture/domain_map.json (navigation only)
docs/architecture/module_manifest.json (navigation only)
```

Linear note: creating/updating a Path 1 M1-01 issue failed (`free issue limit` exceeded on workspace). Repository document remains the durable deliverable.

---

## 3. Physical Domain Map

Conceptual Path 1 names map to **existing** Ash domains. Do **not** create `EventSales.Sources`, `EventSales.Reconciliation`, or `EventSales.Management`.

| Concept | Actual Ash Domain | Module | File | Table | Classification |
| --- | --- | --- | --- | --- | --- |
| Source | Catalog | `EventSales.Catalog.Resources.SourceSystem` | `lib/event_sales/catalog/resources/source_system.ex` | `catalog_source_systems` | VERIFIED_REUSE |
| Event (Tickera) | Catalog | `EventSales.Catalog.Resources.Event` | `lib/event_sales/catalog/resources/event.ex` | `catalog_events` | VERIFIED_REUSE |
| Ticket type / Woo product-variation identity | Catalog | `EventSales.Catalog.Resources.TicketType` | `lib/event_sales/catalog/resources/ticket_type.ex` | `catalog_ticket_types` | VERIFIED_REUSE |
| Event↔product/variation link | Catalog | `EventSales.Catalog.Resources.ProductMapping` | `lib/event_sales/catalog/resources/product_mapping.ex` | `catalog_product_mappings` | VERIFIED_REUSE |
| Dashboard event settings | Catalog | `EventSales.Catalog.Resources.EventDashboardSetting` | `lib/event_sales/catalog/resources/event_dashboard_setting.ex` | `catalog_event_dashboard_settings` | VERIFIED_REUSE |
| Order | Sales | `EventSales.Sales.Resources.Order` | `lib/event_sales/sales/resources/order.ex` | `sales_orders` | VERIFIED_REUSE |
| Order item / sale line | Sales | `EventSales.Sales.Resources.OrderItem` | `lib/event_sales/sales/resources/order_item.ex` | `sales_order_items` | VERIFIED_REUSE |
| Coupon line snapshot | Sales | `EventSales.Sales.Resources.CouponSnapshot` | `lib/event_sales/sales/resources/coupon_snapshot.ex` | `sales_coupon_snapshots` | OUT_OF_SCOPE (peripheral to M1 identity) |
| Webhook intake | Ingestion | `EventSales.Ingestion.Resources.WebhookEvent` | `lib/event_sales/ingestion/resources/webhook_event.ex` | `ingestion_webhook_events` | VERIFIED_REUSE |
| Woo catch-up run | Ingestion | `EventSales.Ingestion.Resources.SyncRun` | `lib/event_sales/ingestion/resources/sync_run.ex` | `ingestion_sync_runs` | VERIFIED_REUSE |
| Woo catch-up cursor | Ingestion | `EventSales.Ingestion.Resources.SyncCursor` | `lib/event_sales/ingestion/resources/sync_cursor.ex` | `ingestion_sync_cursors` | VERIFIED_REUSE |
| Catalogue sync run | Ingestion | `TickeraCatalogSyncRun` | `lib/event_sales/ingestion/resources/tickera_catalog_sync_run.ex` | `ingestion_tickera_catalog_sync_runs` | OUT_OF_SCOPE (Path 2) |
| Catalogue sync finding | Ingestion | `TickeraCatalogSyncFinding` | `lib/event_sales/ingestion/resources/tickera_catalog_sync_finding.ex` | `ingestion_tickera_catalog_sync_findings` | OUT_OF_SCOPE (Path 2) |
| Tickera event source config | Ingestion | `TickeraEventSource` | `lib/event_sales/ingestion/resources/tickera_event_source.ex` | `ingestion_tickera_event_sources` | VERIFIED_REUSE |
| Attendee sync run | Ingestion | `TickeraAttendeeSyncRun` | `lib/event_sales/ingestion/resources/tickera_attendee_sync_run.ex` | `ingestion_tickera_attendee_sync_runs` | VERIFIED_REUSE |
| Attendee snapshot | Ingestion | `TickeraAttendeeSnapshot` | `lib/event_sales/ingestion/resources/tickera_attendee_snapshot.ex` | `ingestion_tickera_attendee_snapshots` | VERIFIED_REUSE |
| Attendee reconciliation run | Ingestion | `TickeraReconciliationRun` | `lib/event_sales/ingestion/resources/tickera_reconciliation_run.ex` | `ingestion_tickera_reconciliation_runs` | VERIFIED_REUSE |
| Attendee reconciliation finding | Ingestion | `TickeraReconciliationFinding` | `lib/event_sales/ingestion/resources/tickera_reconciliation_finding.ex` | `ingestion_tickera_reconciliation_findings` | VERIFIED_REUSE |
| Event aggregate snapshot | Analytics | `EventAggregateSnapshot` | `lib/event_sales/analytics/resources/event_aggregate_snapshot.ex` | `analytics_event_aggregate_snapshots` | VERIFIED_REUSE |
| Daily sales snapshot | Analytics | `DailySalesAggregateSnapshot` | `lib/event_sales/analytics/resources/daily_sales_aggregate_snapshot.ex` | `analytics_daily_sales_aggregate_snapshots` | VERIFIED_REUSE |
| User / role / grant | Accounts | `User`, `Role`, `UserRole`, `EventAccessGrant` | `lib/event_sales/accounts/resources/*` | `accounts_*` | VERIFIED_REUSE |
| First-class Product | — | — | — | — | MISSING |
| First-class ProductVariation | — | — | — | — | MISSING |
| EventProductLink | — | — | — | — | MISSING (use ProductMapping) |
| EventVariationLink | — | — | — | — | MISSING (use ProductMapping) |
| SaleFact | — | — | — | — | MISSING (use Order + OrderItem) |
| AnalyticsAggregate (named) | — | — | — | — | MISSING (use snapshots + HotStateAggregator) |
| Refund / RefundLine | — | — | — | — | MISSING |
| Path 1 financial reconciliation | — | — | — | — | MISSING |

All Ash domains registered today:

```text
EventSales.Accounts
EventSales.Analytics
EventSales.AshBaseline.Domain
EventSales.Audit
EventSales.Catalog
EventSales.Ingestion
EventSales.Sales
```

Evidence: domain modules under `lib/event_sales/*.ex` and resource `domain:` declarations (e.g. `lib/event_sales/catalog/resources/source_system.ex:8`, `lib/event_sales/sales/resources/order.ex:8`).

Ash `policies do` blocks: **none** under `lib/event_sales/`. Management access uses `EventSales.Accounts.Policies` helpers.

---

## 4. Identity Matrix

| Entity | Internal PK | External ID | Source Namespace | Ash Identity / Constraint | DB Index | Lookup Path |
| --- | --- | --- | --- | --- | --- | --- |
| Source | `SourceSystem.id` UUID | `kind` + `base_url` | N/A (is the namespace) | `unique_kind_base_url` `[:kind, :base_url]` | Unique via AshPostgres identity | Bootstrap / Ash read by kind+base_url |
| Producer wire ID | N/A | `wordpress_tickera:<sha256_hex>` | Derived from normalized `base_url` | Not stored as PK | N/A | `DiscoveryIntegrity.expected_source_system_id/1` + `verify_source_system_id/2` |
| Event | `Event.id` UUID | `external_event_id` + `external_event_kind=:tickera_event` | `source_system_id` | Ash: `unique_slug_per_source`; **external uniqueness is DB-only** | `catalog_events_unique_external_tickera_event_idx` partial unique | `OrderAttributionResolver.source_event/2` |
| TicketType | `TicketType.id` UUID | `external_ticket_type_kind` + `external_ticket_type_id`; also `external_product_id` / `external_variation_id` | Via `event_id` → Event.source | Ash: `unique_name_per_event`; DB partial unique on external ticket | `catalog_ticket_types_unique_external_ticket_idx` | Attribution ticket_type filters |
| Product / mapping | `ProductMapping.id` UUID | `woo_product_id` (+ optional `woo_variation_id`) | `source_system_id` | Partial unique active product / variation indexes | `catalog_mappings_unique_active_product_idx`, `catalog_mappings_unique_active_variation_idx` | `MappingResolver.resolve/3` |
| Variation / mapping | Same ProductMapping row when `woo_variation_id` set | Same | Same | Same variation unique index | Same | Same; variation preferred over product-only |
| Order | `Order.id` UUID | `woo_order_id` | `source_system_id` | `unique_source_order` | `sales_orders_unique_source_order_index` | `OrderUpserter.find_order/2` |
| Order item | `OrderItem.id` UUID | `woo_line_item_id` | Via `order_id` → Order.source | `unique_order_line` `[:order_id, :woo_line_item_id]` | Unique via identity | `OrderUpserter.find_order_item/2` |
| Refund | — | — | — | — | — | MISSING |

Evidence:

```text
lib/event_sales/catalog/resources/source_system.ex:54-108
lib/event_sales/catalog/tickera_catalog/source_risk_v3/discovery_integrity.ex:79-106
lib/event_sales/catalog/resources/event.ex:121-167
priv/repo/migrations/20260703090000_vs_26a_tickera_catalog_sync.exs:13-18
lib/event_sales/catalog/resources/product_mapping.ex:24-34
lib/event_sales/sales/resources/order.ex:105-108,196-198
lib/event_sales/sales/resources/order_item.ex:195-207,278-280
priv/repo/migrations/20260515124923_slice_4_sales.exs:56-58
```

---

## 5. Source Identity Mapping

### Audit labels (use these; do not collapse meanings)

| Audit label | Real field / form | Type / shape | Stored? |
| --- | --- | --- | --- |
| **internal_source_pk** | `SourceSystem.id` / FK column `source_system_id` | UUID string | Yes — durable PK/FK |
| **canonical_source_key** | `SourceSystem.kind` + `SourceSystem.base_url` | `:woocommerce` + normalized URL string (trailing `/` stripped) | Yes — unique identity |
| **producer_source_system_id** | Wire string `wordpress_tickera:` + lowercase SHA-256 hex of normalized base URL | Example shape only: `wordpress_tickera:<64_hex_chars>` | **No** SourceSystem column; discovery/feed verification only |

### Generation and binding

```text
internal_source_pk
  → Ash uuid_primary_key on SourceSystem create
  → lib/event_sales/catalog/resources/source_system.ex:55

canonical_source_key
  → NormalizeBaseUrl on create/update
  → identity unique_kind_base_url
  → lib/event_sales/catalog/resources/source_system.ex:30-44,106-108

producer_source_system_id
  → DiscoveryIntegrity.expected_source_system_id(base_url)
  → sha256(normalized_base_url) → "wordpress_tickera:" <> hex
  → lib/event_sales/catalog/tickera_catalog/source_risk_v3/discovery_integrity.ex:79-88
  → verified against SourceSystem.base_url during native discovery
  → lib/event_sales/catalog/tickera_catalog/source_risk_v3/discovery_integrity.ex:93-104
```

### Resources holding which form

| Holds internal_source_pk FK | Holds external Woo/Tickera IDs (scoped by source or event) |
| --- | --- |
| Event, ProductMapping, Order, WebhookEvent, SyncRun, TickeraEventSource, catalogue sync runs | Event.external_event_id; TicketType external_*; ProductMapping.woo_*; Order.woo_order_id; OrderItem.woo_* + source_tickera_event_id |

### Resolution functions

```text
DiscoveryIntegrity.expected_source_system_id/1
DiscoveryIntegrity.verify_source_system_id/2
WordPressFeedDiscoverySource.load_source_system/1  (UUID → SourceSystem)
SourceSystemBootstrap / kind+base_url lookup
WebhookIntake.fetch_active_woocommerce_source_system/0
  → first active Woo source (Ash.Query.limit(1))
  → lib/event_sales/ingestion/webhook_intake.ex:360-368
MappingResolver.resolve/3
OrderAttributionResolver.source_event/2
```

### Same Woo numeric ID under two sources?

**Yes, by durable design.** Order uniqueness is `(source_system_id, woo_order_id)` (`lib/event_sales/sales/resources/order.ex:196-198`). ProductMapping uniqueness is source-scoped (`lib/event_sales/catalog/resources/product_mapping.ex:24-34`).

**Operational caveat:** webhook intake currently selects one active Woo SourceSystem with `limit(1)` and does not match webhook origin URL to `base_url` (`lib/event_sales/ingestion/webhook_intake.ex:360-368`). Multi-source **storage** is supported; multi-source **webhook routing** is not fully operationalized.

---

## 6. Event/Product/Variation Relationship Model

### Current physical model

```text
Catalog.SourceSystem (internal_source_pk)
  └── Catalog.Event
        external_event_kind = :tickera_event
        external_event_id   = Tickera event post id (integer)
        └── Catalog.TicketType
              external_ticket_type_kind = :woo_product | :woo_variation
              external_ticket_type_id   = parent product id OR variation id
              external_product_id / external_variation_id also stored
  └── Catalog.ProductMapping
        source_system_id + woo_product_id [+ woo_variation_id]
          → event_id + ticket_type_id
```

Evidence: `lib/event_sales/catalog/resources/event.ex:121-158`; TicketType and ProductMapping resources as mapped in §3.

### First-class resources?

| Resource | Exists? |
| --- | --- |
| Product | **No** |
| ProductVariation | **No** |
| EventProductLink | **No** |
| EventVariationLink | **No** |

Relationships are represented through **ProductMapping** and **TicketType** external fields, not separate link tables.

Variation → parent: stored as ProductMapping `(woo_product_id, woo_variation_id)` and TicketType `external_product_id` / `external_variation_id`. Native-v3 planning/validation owns parent integrity for catalogue automation (Path 2); sales attribution uses these fields as already persisted.

---

## 7. Sales Writer Flow

### Module-level flow (verified)

```text
WooCommerce webhook HTTP
  → EventSalesWeb.WebhookController
  → EventSales.Ingestion.WebhookIntake.accept/1
       (path token, HMAC on raw body, resolve SourceSystem UUID,
        WebhookReplayGuard, WebhookEvent receive)
  → EventSales.Ingestion.WebhookEnqueue
  → Oban EventSales.Ingestion.Workers.ProcessWebhookWorker
  → EventSales.Ingestion.WebhookProcessor.process/2
  → EventSales.Sales.OrderUpserter.upsert_from_webhook_event/1
  → EventSales.Ingestion.Parsers.WoocommerceOrderParser.parse/1
  → OrderUpserter.upsert_normalized_order/3
       → Ash Order :create_normalized | :sync_from_normalized
       → Ash OrderItem :create_normalized | :sync_from_order | :sync_from_mapped_import
       → EventSales.Sales.OrderItemMapper.map_pending_items_for_order/1
            → OrderAttributionResolver.resolve/4   (if source_tickera_event_id)
            → MappingResolver.resolve/3            (fallback)
  → EventSales.Analytics.OrderProcessedNotifier.notify_order_processed/2
       → DashboardCache.invalidate_event + HotStateAggregator apply/rebuild path

Woo catch-up / reconciliation
  → EventSales.Ingestion.ManualSync (optional queue)
  → Oban EventSales.Ingestion.Workers.ReconcileOrdersWorker
  → EventSales.Ingestion.OrderReconciliation.run_step/3
  → WooCommerceClient.list_orders/2
  → filter by active ProductMapping for SyncRun.event_id
  → OrderUpserter.upsert_order/2
  → OrderProcessedNotifier.notify_order_reconciled/3

CSV import apply
  → EventSales.Ingestion.Csv.ApplyImport.apply/2
  → OrderUpserter.upsert_normalized_order/3
  → OrderProcessedNotifier.notify_order_imported/3
```

Evidence:

```text
lib/event_sales/sales/order_upserter.ex:22-56,95-99
lib/event_sales/ingestion/parsers/woocommerce_order_parser.ex:12-48
lib/event_sales/ingestion/workers/process_webhook_worker.ex:9-34
lib/event_sales/ingestion/order_reconciliation.ex:1-17,61-70
lib/event_sales/analytics/order_processed_notifier.ex:19-50
```

### Writer table

| Path | Entry | Durable writer | Classification |
| --- | --- | --- | --- |
| Webhook | `upsert_from_webhook_event` | `OrderUpserter` | VERIFIED_REUSE — converges |
| Catch-up / SyncRun | `upsert_order` | `OrderUpserter` | VERIFIED_REUSE — converges |
| CSV apply | `upsert_normalized_order` | `OrderUpserter` | VERIFIED_REUSE — converges |
| Parallel order writer | — | — | MISSING (good — do not invent) |
| Post-write OrderItem mapping / correction | `OrderItemMapper`, `MissingCatalogResolver`, `OrderAttributionCorrection` | Mutates items only | Alternate mutators, not order creators |

---

## 8. Idempotency Matrix

| Operation | Idempotency Key | Enforcement | Retry Behaviour | Evidence |
| --- | --- | --- | --- | --- |
| Webhook accept | `WebhookEvent.delivery_id` | Ash identity `unique_delivery_id` | Replay classified; no duplicate durable delivery | Webhook intake + WebhookEvent resource |
| Webhook process job | Oban `webhook_event_id` | Oban unique 300s on args key | Duplicate jobs coalesce | `process_webhook_worker.ex:12-17` |
| Webhook processor | Terminal status + payload hash | Soft ignore duplicates | Short-circuit already processed | WebhookProcessor |
| Order upsert | `(source_system_id, woo_order_id)` | Find-then-create/update + Ash identity + DB unique | Same payload → same order; stale source → `:stale_noop` | `order_upserter.ex:36-92`; `order.ex:196-198`; migration unique index |
| Order item upsert | `(order_id, woo_line_item_id)` | Find-then-create/update + Ash identity | Same line → same item | `order_upserter.ex:112-147`; `order_item.ex:278-280` |
| Source version | `updated_at_source` | `SourceVersionGuard` / compare | Newer wins; older no-op; equal → child upsert only | `order_upserter.ex:68-92` |
| Mapped source event identity | `source_tickera_event_id` on mapped rows | `protect_mapped_source_identity/3` | Conflicting incoming event frozen; reason `:source_event_identity_conflict` | `order_upserter.ex:195-228` |
| Catch-up job | Oban `sync_run_id` | Unique infinity on sync_run_id | One worker per run | `reconcile_orders_worker.ex:6-14` |
| SyncCursor | `sync_run_id` | Unique one cursor per run | Checkpoint after durable page step | SyncCursor resource |

**Proof that retrying the same Woo order avoids duplicate durable sales:** application lookup by `(source_system_id, woo_order_id)` before create (`order_upserter.ex:36-41`) plus Postgres unique constraint (`sales_orders_unique_source_order_index`). Concurrent race would fail the unique index rather than silently duplicate.

---

## 9. Attribution Contract — Current Behaviour

### Authority

1. **Primary (when present):** line `source_tickera_event_id` from Woo meta key `tickera_event_id` (parser). Event-first resolution via `OrderAttributionResolver`.
2. **Inside event bucket:** TicketType matched by woo product/variation within that Event.
3. **ProductMapping in event-first path:** review context — missing mapping → map with reason `:missing_product_mapping`; mismatch → `:order_event_mapping_conflict`. Does **not** override the source event.
4. **Fallback (no source_tickera_event_id):** `MappingResolver` active ProductMapping (variation wins over product-level).

Evidence:

```text
lib/event_sales/catalog/order_attribution_resolver.ex:1-7,49-90,116-139
lib/event_sales/sales/order_item_mapper.ex:112-146
lib/event_sales/sales/resources/order_item.ex:13-28
```

### Mapping statuses

```text
:pending_mapping_resolution | :mapped | :unmapped | :non_ticket | :ignored
```

### Attribution reasons

```text
:invalid_source_tickera_event_id
:source_event_identity_conflict
:source_event_not_found
:source_ticket_type_not_found
:missing_product_mapping
:order_event_mapping_conflict
```

### Special behaviours

| Situation | Behaviour |
| --- | --- |
| Order status `:on_hold` | Automatic mapping **deferred** (`AutomaticMappingPolicy` + mapper) |
| Eligible + resolution mapped | → `:mapped` via `apply_mapping` / `apply_event_first_mapping` |
| Eligible + no mapping | stays pending; may later `:mark_unmapped` |
| Mapped historical row + conflicting source_tickera_event_id | frozen; `:source_event_identity_conflict` |
| Normal `:sync_from_order` | Does **not** accept `event_id` / `ticket_type_id` / `mapping_status` — preserves mapped attribution fields via separate actions |

Evidence: `lib/event_sales/sales/automatic_mapping_policy.ex:21-24`; `order_item.ex:90-104`; `order_upserter.ex:195-228`.

---

## 10. Order Status Matrix

Parser: `WoocommerceOrderParser.parse_status/1` (`lib/event_sales/ingestion/parsers/woocommerce_order_parser.ex:53-61`).

Recognised sale/revenue: `MetricRules.counts_as_sold?/2` — completed + mapped + ticket + qty>0 (`lib/event_sales/analytics/metric_rules.ex:72-92`).

Operational visibility: `MetricRules.visible_in_status_breakdown?/2` always true for Order+OrderItem (`metric_rules.ex:98-99`).

| Source status | Normalized | Persisted? | Recognised ticket sale? | Recognised revenue? | Eligible for mapping? | Operationally visible? | Special behaviour | Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `pending` | `:pending` | Yes | No | No | Yes | Yes | Initial SM state | parser:53; MetricRules:73-77 |
| `processing` | `:processing` | Yes | No | No | Yes | Yes | — | parser:54 |
| `on-hold` / `on_hold` | `:on_hold` | Yes | No | No | Deferred | Yes | Auto-map skipped until status advances | parser:55-56; AutoMapPolicy:21 |
| `completed` | `:completed` | Yes | Yes if mapped ticket | `line_total` if sold | Yes | Yes | `completed_at` from `date_completed_gmt` | parser:57; MetricRules:73-92 |
| `failed` | `:failed` | Yes | No | No | Yes | Yes | Extra SM state | parser:60 |
| `cancelled` | `:cancelled` | Yes | No | No | Yes | Yes | — | parser:58 |
| `refunded` | `:refunded` | Yes | No | No | Yes | Yes | SM `:mark_refunded` from completed; source sync force-sets | parser:59; order.ex:211 |
| other | — | No | — | — | — | — | Parse error `:unsupported` | parser:61 |

Note: AshStateMachine transitions on Order are narrow, but source sync bypasses them via forced attribute updates (`SyncStatusFromSource`), so persisted status can jump to any allowed atom from Woo.

---

## 11. Money / Financial Field Map

| Meaning | Resource.Field | Type | Source Field | Current Usage |
| --- | --- | --- | --- | --- |
| Order total | `Order.raw_total` | Ash `:decimal` / Postgres numeric | Woo `total` | Stored; not MetricRules sold revenue |
| Order discount | `Order.raw_discount_total` | `:decimal` | `discount_total` | Stored |
| Order tax | `Order.raw_tax_total` | `:decimal` | `total_tax` | Stored |
| Currency | `Order.currency` | `:string` | `currency` | Required |
| Line qty | `OrderItem.quantity` | `:integer` min 1 | `quantity` | Sold qty when counts_as_sold |
| Line subtotal | `OrderItem.line_subtotal` | `:decimal` | `subtotal` | Stored |
| Line total | `OrderItem.line_total` | `:decimal` | `total` | **Recognised revenue** when sold |
| Line discount | `OrderItem.discount_total` | `:decimal` | derived or field | Stored |
| Coupon discount | `CouponSnapshot.discount_amount` | `:decimal` | coupon line | Snapshot only |
| Shipping / fees | — | — | Fixture may have shipping; parser ignores | MISSING |
| Line tax | — | — | — | MISSING |
| Refunded qty/amount | — | — | — | MISSING |
| Float money calc | — | — | — | **Not used** in authoritative path |

Money path evidence:

```text
lib/event_sales/sales/resources/order.ex:148-163
lib/event_sales/sales/resources/order_item.ex:213-233
lib/event_sales/ingestion/parsers/woocommerce_order_parser.ex:23-41,79-98
lib/event_sales/analytics/metric_rules.ex:90-92
```

Parser money helpers use `Decimal.new/1` (reject non-binary). Analytics uses `Decimal.add` on `line_total`.

---

## 12. Refund Truth — Current State

| Question | Verdict | Evidence |
| --- | --- | --- |
| Are Woo refunds ingested as objects? | **MISSING** | Parser never reads `"refunds"`; only status `"refunded"` → `:refunded` (`woocommerce_order_parser.ex:59`). Fixture `test/fixtures/woocommerce/order_refunded.json` has unused refunds array |
| Refund resource? | **MISSING** | No Ash module |
| RefundLine resource? | **MISSING** | No Ash module |
| Refund external IDs stored? | **MISSING** | — |
| Partial refunds supported? | **MISSING** | No partial model |
| Refunded quantity stored? | **MISSING** | — |
| Refunded monetary value stored? | **MISSING** | — |
| Completed + later partial refund distinguishable? | **MISSING** | Only full status transition; MetricRules drops sold when not `:completed` |
| Woo refund objects parsed independently? | **MISSING** | — |
| Refunds only via order status? | **VERIFIED** | Status enum + `mark_refunded`; Tickera recon buckets refunded/cancelled statuses |
| Duplicate refund prevention? | **MISSING** | N/A without refund entity |
| Refund timestamp available? | **MISSING** | No refund-at field |

**What exists:** order status `:refunded` and operational visibility of that status.

**What does not exist:** independent refund ingestion, monetary/qty refund facts, partial refund distinguishability.

**What is unknown:** none material for M1-02 — refund behaviour is established as status-only. Path 1 later milestones (M3/M4) must contract refund import separately.

---

## 13. Timestamp Matrix

| Meaning | Current Field | Resource | Source | Currently Used By |
| --- | --- | --- | --- | --- |
| Source order created | `created_at_source` | Order | `date_created_gmt` | Upsert / stale guards context |
| Source order modified | `updated_at_source` | Order | `date_modified_gmt` | SourceVersionGuard; catch-up `orderby=modified` |
| Payment timestamp | — | — | No `date_paid` stored | MISSING |
| Completion timestamp | `completed_at` | Order | `date_completed_gmt` | **MetricRules “today” sold buckets** (`metric_rules.ex:138`) |
| Refund timestamp | — | — | — | MISSING |
| Ingestion received | `received_at` (+ processing clocks) | WebhookEvent | Intake | Webhook lifecycle |
| Local inserted/updated | `inserted_at` / `updated_at` | Order, OrderItem, … | Ash timestamps | Admin/ops |
| Analytics snapshot refresh | `refreshed_at`, `source_watermark_at` | Event/Daily snapshots | Rebuild/refresh | Snapshot readers |
| Reconciliation run clocks | `started_at` / `finished_at` / cursor modified window | SyncRun / SyncCursor | Local + Woo modified_* | Catch-up progress |
| Hot-state freshness | `last_fresh_at` (process state) | HotStateAggregator | Restore/rebuild | Lifecycle `:ready`/`:stale` |

Do **not** treat this matrix as the future M1-07 contract — it records current behaviour only.

---

## 14. Catch-Up / Backfill Capability Map

### Present infrastructure (M3 base)

| Piece | Status | Evidence |
| --- | --- | --- |
| SyncRun | Present — source + event scoped, date_from/to, shallow/deep, pause/resume/fail/complete | `sync_run.ex` |
| SyncCursor | Present — page, modified window, last_seen_order_id | `sync_cursor.ex` |
| OrderReconciliation | Present — page step, mapping filter, upsert | `order_reconciliation.ex:61-70` |
| ReconcileOrdersWorker | Present — queue `:reconciliation`, unique on sync_run_id | `reconcile_orders_worker.ex:6-14` |
| Woo list_orders | Present | `woocommerce_client.ex` |
| modified-since / orderby / pagination | Present — modified_after/before, orderby=modified asc, page/per_page | OrderReconciliation woo params |
| Event scoping via ProductMapping | Present | Orders matched when line maps to SyncRun.event_id |
| Manual queueing | Present — ManualSync | `manual_sync.ex` |
| Source scoping | Present — SyncRun.source_system_id | SyncRun |

### Reuse vs extension vs absent for M3

```text
DIRECTLY REUSABLE
  SyncRun / SyncCursor / OrderReconciliation / ReconcileOrdersWorker
  WooCommerceClient.list_orders
  OrderUpserter + WoocommerceOrderParser convergence
  Oban uniqueness per sync_run_id

REQUIRES EXTENSION
  Historical backfill UX / event selection / completeness watermark
  Active SyncRun uniqueness (no one-active partial unique today — unlike catalogue sync)
  Refund object import (currently absent)
  Possibly wider than mapping-filtered catch-up for full financial import

CURRENTLY ABSENT
  Path 1 ANALYTICS_READY watermark resource
  Explicit “backfill from Tickera event creation date” orchestration module named as such
  Independent refund writer
```

**Could existing infrastructure form the base of M3?** Yes — with extensions. Do not invent a parallel order writer.

### Performance notes (catch-up)

```text
Truth layer: cold Postgres via OrderUpserter
Bounded reads: one Woo page per run_step
Overlap protection: Oban unique on sync_run_id (not DB one-active SyncRun)
Index: SyncCursor unique sync_run_id; Order unique (source, woo_order_id)
```

---

## 15. Reconciliation Capability Map

### A. Woo catch-up / order reconciliation

| Field | Value |
| --- | --- |
| Purpose | Pull modified Woo orders in a date window; upsert lines matching active ProductMappings for an event |
| Source of truth | WooCommerce REST order payloads → durable Order/OrderItem |
| Resources | SyncRun, SyncCursor |
| Worker/service | OrderReconciliation, ReconcileOrdersWorker, ManualSync |
| Metrics | orders_seen/matched/upserted/stale/failed (+ telemetry) |
| Durability | Postgres run/cursor + Oban |
| Source / time scope | source_system_id + event_id; date_from/to via modified_* |
| M4 reuse | High for catch-up mechanics; **not** financial audit |

### B. Tickera attendee vs local-order reconciliation

| Field | Value |
| --- | --- |
| Purpose | Compare local Woo-derived quantities vs Tickera attendee snapshots; emit findings |
| Source of truth | Local Order/OrderItem + TickeraAttendeeSnapshot (**not** live Woo financial totals) |
| Resources | TickeraReconciliationRun, TickeraReconciliationFinding, TickeraEventSource |
| Worker/service | TickeraReconciliation |
| Metrics | woo/tickera scanned counts, finding severity; refunded/cancelled **status buckets** |
| Durability | Runs + findings with fingerprint identity |
| Scope | Event + Tickera source; snapshot staleness hours |
| M4 reuse | Attendee/data-quality only — **do not label as Path 1 financial reconciliation** |

### C. Path 1 Woo financial source-vs-EventSales reconciliation

| Field | Value |
| --- | --- |
| Purpose | Programme FUTURE: financial totals reconciled before ANALYTICS_READY |
| Implementation | **MISSING** — no dedicated financial reconcile module/resource |
| M4 reuse | Greenfield on Order decimals + SyncRun patterns; must not confuse with (B) |

---

## 16. Analytics / Cache / PubSub Architecture

### Real flow

```text
durable Order / OrderItem (cold Postgres)
  → EventAggregator + MetricRules
  → HotStateAggregator writes ETS via DashboardCache (hot)
  → optional Redis warm snapshot via RedixAdapter (warm)
  → DashboardPubSub {:hot_state_updated, event_id, updated_at}
  → AdminDashboard / EventScopedDashboard / EventDetail facades
```

| Layer | Implementation |
| --- | --- |
| Cold / durable truth | `sales_orders` / `sales_order_items` + Ash Sales resources |
| Hot | ETS table owned by HotStateAggregator; facade `DashboardCache` (`dashboard_cache.ex:1-25`) |
| Warm | Redis key `eventsales:analytics:hot_state:v1:event:{id}:summary` (`cache_keys.ex:14-18`) |
| Cold derived snapshots | `EventAggregateSnapshot`, `DailySalesAggregateSnapshot` |
| Rebuild SoT | Postgres via EventAggregator in `RebuildHotStateWorker` |
| Single-flight | Aggregator `rebuild_in_flight?` + Oban unique scope hot_state (~300s) |
| Invalidation | `DashboardCache.invalidate_event` from OrderProcessedNotifier |
| PubSub | Topic `analytics:event:#{event_id}` (`dashboard_pub_sub.ex`) |
| Cachex | **Absent** from `mix.exs` — do not introduce for Path 1 |

**Does ETS + Redis already satisfy Path 1 hot/warm?** **Yes** for event dashboard summaries. Cachex is not required by current code.

### Freshness vs locked programme contract

| Capability | Classification | Notes |
| --- | --- | --- |
| Hot lifecycle ready/warming/stale | ALREADY_SUPPORTED | Default `stale_after_ms = 300_000` (5 min) — `hot_state_aggregator.ex:27,638-641` |
| Dashboard stale banner | ALREADY_SUPPORTED | `stale_data_banner.ex` |
| Manual refresh + rate limit | ALREADY_SUPPORTED | 30s limiter; queues rebuild |
| PubSub live updates | ALREADY_SUPPORTED | Event-scoped |
| Expected visibility &lt; 5 min | PARTIALLY_SUPPORTED | PubSub can update sooner; lifecycle freshness clock is rebuild-centric |
| Stale &gt; 10 min | CONFLICTING | Code default **5 minutes**, not 10 |

Do not implement freshness contract changes in M1-01.

### Performance notes (analytics)

```text
Truth: cold Postgres
Hot: ETS; Warm: Redis TTL ~1h (adapter default)
Bounded: event-scoped summaries; rebuild single-flight
Invalidation: per event_id after durable write notifier
Primary item index for event aggregations: sales_order_items_event_id_idx
```

---

## 17. Existing Database Constraints and Critical Indexes

### Proven constraints / indexes

| Concern | Enforcement | Evidence |
| --- | --- | --- |
| Source unique | Ash `unique_kind_base_url` | `source_system.ex:106-108` |
| Event external unique | DB partial unique `(source_system_id, external_event_kind, external_event_id)` | migration `20260703090000_…:13-18` (**not** Ash identity) |
| Event slug unique | Ash `unique_slug_per_source` | `event.ex:165-167` |
| ProductMapping active unique | Partial unique product / variation | `product_mapping.ex:24-34` |
| Woo order unique | Ash + DB `unique_source_order` | `order.ex:196-198`; migration slice_4 |
| Woo order item unique | Ash `unique_order_line` | `order_item.ex:278-280` |
| Order query helpers | indexes status, completed_at, updated_at_source | `order.ex:51-57` |
| OrderItem analytics helpers | event_id, mapping_status, source_tickera composites | `order_item.ex:58-77` |
| SyncCursor one-per-run | unique sync_run_id | SyncCursor |
| Catalogue one-active sync | partial unique (catalogue only) | Path 2 migration |
| Analytics snapshots | unique_event; unique_event_day_timezone | snapshot resources |

### Concrete M1-relevant gap (proven query path)

```text
Active SyncRun uniqueness — MISSING
  Manual/system can enqueue concurrent SyncRuns for same (source, event).
  Catalogue sync has one-active protection; order SyncRun does not.
  Proven create path: ManualSync → queue_manual_scoped without active-run DB guard.
```

No speculative `(event_id, completed_at)` recommendation — today-bucketing is in Elixir after load.

---

## 18. M1 Gap Matrix

Canonical M1 task titles after M1-01A live in `docs/path-1/path-1-phase-breakdown.md`:

```text
M1-02 source identity
M1-03 attribution
M1-04 order lifecycle
M1-05 refund / financial adjustment
M1-06 metric dictionary
M1-07 time / period / freshness
M1-08 completeness / reconciliation / ANALYTICS_READY
M1-09 certification
```

The table below remains the M1-01-era gap snapshot (provisional titles at audit time). Prefer the phase breakdown for execution sequencing.

| Future Task | Existing Foundation | Reuse | Extension Needed | Missing | Blocking Unknown |
| --- | --- | --- | --- | --- | --- |
| M1-02 Source-Scoped External Identity Contract | SourceSystem UUID + kind/base_url; producer hash verify; source-scoped Order/Event/Mapping uniques | Yes — document and lock labels | Webhook multi-source routing; Ash identity for Event external ID (DB-only today) | Producer ID not stored as column (by design) | None for locking the identity vocabulary |
| M1-03 Event/Product/Variation Identity Contract *(provisional)* | Event + TicketType + ProductMapping | Yes — do not invent Product resources | Clarify dual TicketType vs ProductMapping authority in one contract | First-class Product/Variation/Link resources | Whether dual fields can conflict in production data (needs M1 policy, not prod access) |
| M1-04 Sales Writer & Order Identity Contract *(provisional)* | OrderUpserter convergence + identities | Yes — mandate reuse | Document stale/equal timestamp races; CSV vs webhook opts | Parallel writer (intentionally absent) | None |
| M1-05 Attribution Contract *(provisional)* | OrderAttributionResolver + MappingResolver + immutability | Yes | Historical remap/admin correction policy | General remap API beyond special-case correction | None for documenting current behaviour |
| M1-06 Order Lifecycle Contract *(provisional)* | Parser statuses + MetricRules + AutoMapPolicy | Yes | Align SM transitions vs source force-sync language | — | None |
| M1-07 Timestamp Contract | created/updated/completed_at fields; MetricRules uses completed_at | Partial | Lock payment vs completion vs freshness clocks | `date_paid` / refund timestamps | Source field availability for payment time (source contract, not repo blocker for M1-02) |
| M1-08 Money / Refund / Freshness Contract *(provisional)* | Decimal money; status refunded; ETS+Redis hot/warm; 5‑min stale clock | Partial | Refund model; align 5‑min code vs 10‑min product stale; last_fresh_at on apply_event | Refund resources; 10‑min threshold | None for M1-02 |

---

## 19. Do-Not-Duplicate List

Path 1 must **reuse**, not rebuild:

```text
EventSales.Catalog.Resources.SourceSystem
EventSales.Catalog.Resources.Event
EventSales.Catalog.Resources.TicketType
EventSales.Catalog.Resources.ProductMapping
EventSales.Catalog.MappingResolver
EventSales.Catalog.OrderAttributionResolver
EventSales.Sales.Resources.Order
EventSales.Sales.Resources.OrderItem
EventSales.Sales.OrderUpserter
EventSales.Ingestion.Parsers.WoocommerceOrderParser
EventSales.Sales.OrderItemMapper
EventSales.Sales.AutomaticMappingPolicy
EventSales.Ingestion.Resources.WebhookEvent
EventSales.Ingestion.Resources.SyncRun
EventSales.Ingestion.Resources.SyncCursor
EventSales.Ingestion.OrderReconciliation
EventSales.Ingestion.Workers.ReconcileOrdersWorker
EventSales.Ingestion.Workers.ProcessWebhookWorker
EventSales.Analytics.MetricRules
EventSales.Analytics.HotStateAggregator
EventSales.Analytics.DashboardCache
EventSales.Analytics.OrderProcessedNotifier
EventSales.Analytics.DashboardPubSub
EventSales.Analytics.Resources.EventAggregateSnapshot
EventSales.Analytics.Resources.DailySalesAggregateSnapshot
EventSales.Accounts.Policies (+ role/grant resources)
DiscoveryIntegrity producer source_system_id verify pattern
```

Do **not** create merely because conceptual planning named them:

```text
EventSales.Sources
EventSales.Reconciliation (domain)
EventSales.Management
Product / ProductVariation / EventProductLink / EventVariationLink
SaleFact / AnalyticsAggregate
A second OrderUpserter or parallel sales writer
Cachex (absent; ETS+Redis already cover hot/warm)
```

Do **not** route ordinary Path 1 analytics through:

```text
FindingPolicy → Planner → Apply → AutoApply
```

---

## 20. Open Questions

| Question | Blocks M1-02? |
| --- | --- |
| Exact official titles for M1-03..M1-06 and M1-08 in `EVENTSALES_PATH_1_UPDATED_PHASE_BREAKDOWN.md` (file absent from repo) | DOES NOT BLOCK M1-02 |
| Whether production/local deployments ever run multiple active Woo SourceSystems (webhook `limit(1)` implication) | DOES NOT BLOCK M1-02 (identity model is clear; ops policy is separate) |
| Whether TicketType.external_* and ProductMapping.woo_* can disagree on the same durable rows in existing DBs | DOES NOT BLOCK M1-02 (source identity still clear; catalogue consistency is M1-03) |
| Whether Woo `date_paid` is available and should become the completion/payment clock | DOES NOT BLOCK M1-02 (owned by M1-07) |
| Exact future refund object schema / partial refund rules | DOES NOT BLOCK M1-02 (refund truth established as status-only MISSING) |
| Whether concurrent equal-timestamp order creates need stronger DB ON CONFLICT UX beyond unique index failure | DOES NOT BLOCK M1-02 |

No open question leaves source identity, OrderUpserter ownership, OrderItem identity, or attribution authority untraceable.

---

## 21. M1-01 Verdict

```text
M1-01 VERDICT:
PASS

M1-02 AUTHORIZATION:
NOT GRANTED BY THIS TASK

NEXT RECOMMENDED ACTION:
Commit docs/path-1/m1-01-current-repo-truth.md when ready, then start M1-02 to lock the source-scoped external identity vocabulary using the internal_source_pk / canonical_source_key / producer_source_system_id labels above.
```
