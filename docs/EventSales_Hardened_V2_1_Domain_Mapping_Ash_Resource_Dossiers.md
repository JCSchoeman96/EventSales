# EventSales — Hardened V2.1 Domain Mapping and Ash Resource Dossiers
## Domain boundary summary
```text
Accounts = users, authentication, roles, event access, PII visibility.
Catalog = source systems, events, ticket types, product mappings, dashboard settings, missing catalog recovery.
Sales = normalized orders, order items, coupons, status truth.
Ingestion = webhooks, syncs, CSV imports, REST boundary, replay/recovery, flash-sale intake protection.
Analytics = metric rules, hot state, cache, snapshots, reporting.
Audit = operational audit and PaperTrail-backed resource history.
```
## Ash ecosystem policy
```text
Use AshAuthentication for user authentication.
Use AshAdmin for internal protected resource visibility.
Use AshStateMachine for resources with controlled statuses.
Use AshPaperTrail for resource mutation history where valuable.
Use custom AuditLog for operational/security events.
Do not use Redis/Cachex/ETS as an Ash DataLayer.
```

---

## Accounts — User
**Module:** `EventSales.Accounts.Resources.User`  
**Path:** `lib/event_sales/accounts/resources/user.ex`  
**Data layer:** AshPostgres

**Purpose:** Authenticated actor for admin, staff, and future event-scoped access. Uses AshAuthentication for password/session flows.

### Fields
- id: uuid primary key
- email: ci_string/string, required, unique lower(email)
- name: string
- active: boolean default true
- AshAuthentication password fields
- timestamps

### Relationships
- has_many UserRole
- has_many EventAccessGrant

### Actions
- read :read
- create/update through AshAuthentication strategy
- update :deactivate admin-only
- read :current_user self-only helper if needed

### Validations / invariants
- email required and normalized
- active must be boolean
- password strategy requirements from AshAuthentication

### Policies
- admin can manage users
- user can read own profile
- non-admin cannot list users

### Indexes / constraints
- unique lower(email)
- active

### State machine
No AshStateMachine required. Use active flag for deactivation, not deletion.

### PaperTrail / audit
Usually no PaperTrail for password/auth internals; audit security events with AuditLog.

### Cache / PubSub / invalidation
Do not cache full user PII broadly. Session/current-user lookup can use normal Phoenix/AshAuthentication mechanisms.

### Required tests
- auth login works
- inactive user cannot authenticate/access admin
- non-admin cannot list users
- email uniqueness enforced

---

## Accounts — Role
**Module:** `EventSales.Accounts.Resources.Role`  
**Path:** `lib/event_sales/accounts/resources/role.ex`  
**Data layer:** AshPostgres

**Purpose:** Canonical global role catalogue.

### Fields
- id
- name enum: admin/staff

### Global vs event-scoped roles
- `admin` and `staff` are global roles.
- `event_owner` and `event_staff` must be represented through `EventAccessGrant.role`, not assigned as global roles in MVP.
- Do not treat event-scoped grants as global authorization.
- description
- timestamps

### Relationships
- has_many UserRole

### Actions
- seed/read roles
- admin manage roles only if needed

### Validations / invariants
- name in allowed role enum
- unique name

### Policies
- admin can manage
- authenticated users can read only assigned role names if needed

### Indexes / constraints
- unique name

### State machine
No state machine.

### PaperTrail / audit
Optional PaperTrail; role list should be stable.

### Cache / PubSub / invalidation
Small role list may be cached, but not required.

### Required tests
- allowed roles exist
- invalid role rejected
- unique role enforced

---

## Accounts — UserRole
**Module:** `EventSales.Accounts.Resources.UserRole`  
**Path:** `lib/event_sales/accounts/resources/user_role.ex`  
**Data layer:** AshPostgres

**Purpose:** Join between users and global roles.

### Fields
- id
- user_id
- role_id
- timestamps

### Relationships
- belongs_to User
- belongs_to Role

### Actions
- admin assign/remove role

### Validations / invariants
- user_id required
- role_id required
- unique user_id + role_id

### Policies
- admin only

### Indexes / constraints
- user_id
- role_id
- unique user_id + role_id

### State machine
No state machine.

### PaperTrail / audit
Optional PaperTrail; custom AuditLog for role assignment/removal.

### Cache / PubSub / invalidation
Invalidate auth/role cache if introduced.

### Required tests
- admin can assign role
- duplicate assignment rejected
- non-admin rejected

---

## Accounts — EventAccessGrant
**Module:** `EventSales.Accounts.Resources.EventAccessGrant`  
**Path:** `lib/event_sales/accounts/resources/event_access_grant.ex`  
**Data layer:** AshPostgres

**Purpose:** Event-scoped access for future event owners and event staff.

### Fields
- id
- user_id
- event_id
- role enum: event_owner/event_staff
- expires_at
- active
- timestamps

### Relationships
- belongs_to User
- belongs_to Event

### Actions
- admin create/update/revoke
- read active grants for actor
- expire/revoke action

### Validations / invariants
- user_id required
- event_id required
- role must be event-scoped role
- expired grants deny access

### Policies
- admin manage all
- grant owner may read own grant metadata
- event access policies consume active grants

### Indexes / constraints
- user_id
- event_id
- expires_at
- active
- unique active user_id + event_id + role

### State machine
Optional active/revoked state if needed; do not delete access history.

### PaperTrail / audit
Use AshPaperTrail for grant changes.

### Cache / PubSub / invalidation
Invalidate event access/authorization cache on grant create/update/revoke.

### Required tests
- expired grant denied
- event owner only assigned event
- event staff cannot see revenue by default
- PaperTrail version created

---

## Catalog — SourceSystem
**Module:** `EventSales.Catalog.Resources.SourceSystem`  
**Path:** `lib/event_sales/catalog/resources/source_system.ex`  
**Data layer:** AshPostgres

**Purpose:** Represents the WooCommerce store while keeping light future support for more sources.

### Fields
- id
- name
- kind enum: woocommerce
- base_url
- active
- timestamps

### Relationships
- has_many Event
- has_many Order
- has_many WebhookEvent

### Actions
- admin create/update/read
- deactivate

### Validations / invariants
- kind required
- base_url required
- unique kind + base_url
- do not store secrets

### Policies
- admin manage
- staff read

### Indexes / constraints
- kind + base_url unique
- active

### State machine
No state machine.

### PaperTrail / audit
Use PaperTrail if source settings are editable.

### Cache / PubSub / invalidation
Source metadata can be cached; secrets remain env only.

### Required tests
- unique source enforced
- secrets absent
- deactivate does not delete related data

---

## Catalog — Event
**Module:** `EventSales.Catalog.Resources.Event`  
**Path:** `lib/event_sales/catalog/resources/event.ex`  
**Data layer:** AshPostgres

**Purpose:** Event-level reporting and permission scope.

### Fields
- id
- source_system_id
- name
- slug
- starts_at
- ends_at
- capacity nullable
- status
- timestamps

### Relationships
- belongs_to SourceSystem
- has_many TicketType
- has_many ProductMapping
- has_many OrderItem
- has_one EventDashboardSetting
- has_many EventAccessGrant

### Actions
- admin create/update/archive
- read by event scope
- list active/upcoming

### Validations / invariants
- name required
- slug unique per source
- capacity nil or >= 0
- ends_at after starts_at if both set

### Policies
- admin all
- staff read internal
- event_owner read assigned event according to grant
- event_staff read limited assigned event

### Indexes / constraints
- source_system_id
- slug
- starts_at
- status
- unique source_system_id + slug

### State machine
Optional status state machine: draft/active/archived/cancelled. Keep simple for MVP.

### PaperTrail / audit
Use AshPaperTrail.

### Cache / PubSub / invalidation
Invalidate event aggregate/dashboard snapshot on event/ticket/mapping changes.

### Required tests
- event scope policy enforced
- capacity nil safe
- slug uniqueness
- PaperTrail version on update

---

## Catalog — TicketType
**Module:** `EventSales.Catalog.Resources.TicketType`  
**Path:** `lib/event_sales/catalog/resources/ticket_type.ex`  
**Data layer:** AshPostgres

**Purpose:** Reportable ticket category under an event.

### Fields
- id
- event_id
- name
- capacity nullable
- active
- timestamps

### Relationships
- belongs_to Event
- has_many ProductMapping
- has_many OrderItem

### Actions
- admin create/update/deactivate
- read by event scope

### Validations / invariants
- event required
- name required
- capacity nil or >= 0

### Policies
- admin manage
- staff read
- event_owner/staff read assigned event limited

### Indexes / constraints
- event_id
- active
- unique event_id + name if appropriate

### State machine
No state machine; active flag is enough.

### PaperTrail / audit
Use AshPaperTrail.

### Cache / PubSub / invalidation
Invalidate event/ticket aggregate cache on change.

### Required tests
- ticket type belongs to event
- capacity behavior
- policy scope
- PaperTrail version on update

---

## Catalog — ProductMapping
**Module:** `EventSales.Catalog.Resources.ProductMapping`  
**Path:** `lib/event_sales/catalog/resources/product_mapping.ex`  
**Data layer:** AshPostgres

**Purpose:** Maps WooCommerce product/variation IDs to EventSales events and ticket types.

### Fields
- id
- source_system_id
- event_id
- ticket_type_id
- woo_product_id
- woo_variation_id nullable
- original_label
- current_label
- active
- timestamps

### Relationships
- belongs_to SourceSystem
- belongs_to Event
- belongs_to TicketType

### Actions
- admin create/update/deactivate
- resolve mapping read action
- remap action enqueues recalculation

### Validations / invariants
- source/event/ticket/product required
- one active mapping per source + product + variation
- variation-specific mapping wins

### Policies
- admin manage
- staff may read
- event_owner read mapping labels for assigned events if needed

### Indexes / constraints
- source_system_id
- woo_product_id
- woo_variation_id
- event_id
- ticket_type_id
- unique active product-level mapping: source_system_id + woo_product_id WHERE active = true AND woo_variation_id IS NULL
- unique active variation mapping: source_system_id + woo_product_id + woo_variation_id WHERE active = true AND woo_variation_id IS NOT NULL

### Null variation uniqueness warning
Postgres unique indexes treat NULL values differently. Do not rely on a single naive unique index over `source_system_id + woo_product_id + woo_variation_id` if `woo_variation_id` can be NULL. Use the partial indexes above or an explicitly documented expression index such as `COALESCE(woo_variation_id, 0)`.

### State machine
No state machine required; active flag and audit history are enough.

### PaperTrail / audit
Use AshPaperTrail.

### Cache / PubSub / invalidation
Invalidate product mapping cache, affected event aggregate cache, and dashboard snapshots on change. Broadcast mapping_changed if UI needs it.

### Required tests
- variation-specific wins
- duplicate active mapping rejected
- mapping change enqueues recalculation
- PaperTrail version created
- cache invalidation triggered

---

## Catalog — EventDashboardSetting
**Module:** `EventSales.Catalog.Resources.EventDashboardSetting`  
**Path:** `lib/event_sales/catalog/resources/event_dashboard_setting.ex`  
**Data layer:** AshPostgres

**Purpose:** Future event/client dashboard visibility configuration.

### Fields
- id
- event_id
- revenue_visible_to_event_owner
- revenue_visible_to_event_staff
- order_numbers_visible
- pii_visible default false
- access_expires_at
- timestamps

### Relationships
- belongs_to Event

### Actions
- admin create/update
- read by event policy

### Validations / invariants
- event required
- pii_visible false by default
- access_expires_at optional

### Policies
- admin manage
- event_owner read only their settings summary if needed

### Indexes / constraints
- event_id unique
- access_expires_at

### State machine
No state machine.

### PaperTrail / audit
Use AshPaperTrail.

### Cache / PubSub / invalidation
Invalidate event dashboard snapshot and access-derived caches on change.

### Required tests
- PII disabled by default
- revenue visibility controls policy
- PaperTrail version created

---

## Sales — Order
**Module:** `EventSales.Sales.Resources.Order`  
**Path:** `lib/event_sales/sales/resources/order.ex`  
**Data layer:** AshPostgres

**Purpose:** Normalized WooCommerce order header. Durable truth for order-level status and raw totals.

### Fields
- id
- source_system_id
- woo_order_id
- order_number
- status
- currency
- completed_at
- created_at_source
- updated_at_source
- customer_name
- customer_email
- raw_total
- raw_discount_total
- raw_tax_total
- timestamps

### Relationships
- belongs_to SourceSystem
- has_many OrderItem
- has_many CouponSnapshot

### Actions
- upsert_from_source
- sync_status_from_source
- read internal
- read masked

### Validations / invariants
- source_system_id required
- woo_order_id required
- status enum
- newer payload wins for source sync
- money decimals valid

### Policies
- admin full read
- staff masked PII
- event-scoped actors cannot read global orders by default
- field policies for PII

### Indexes / constraints
- source_system_id
- woo_order_id
- unique source_system_id + woo_order_id
- status
- completed_at
- updated_at_source
- order_number

### State machine
AshStateMachine for internal transitions. External source sync action can mirror WooCommerce truth if payload is newer and is audited.

### PaperTrail / audit
Do not enable AshPaperTrail on high-volume Order records by default for MVP. Store source version fields and audit important source status changes. Add PaperTrail later only if a proven audit requirement appears.

### Cache / PubSub / invalidation
After committed upsert/status change, emit aggregate event for HotStateAggregator and invalidate affected order/event caches.

### Required tests
- unique source order
- duplicate webhook idempotent
- completed-only rules
- external newer sync allowed
- older payload ignored or handled explicitly
- PII policies

---

## Sales — OrderItem
**Module:** `EventSales.Sales.Resources.OrderItem`  
**Path:** `lib/event_sales/sales/resources/order_item.ex`  
**Data layer:** AshPostgres

**Purpose:** Normalized line item and event/ticket reporting record. This is the reporting unit for mixed-event orders.

### Fields
- id
- order_id
- event_id nullable
- ticket_type_id nullable
- woo_line_item_id
- woo_product_id
- woo_variation_id nullable
- name
- quantity
- line_subtotal
- line_total
- discount_total
- item_kind enum ticket/non_ticket/unknown
- mapping_status
- timestamps

### Relationships
- belongs_to Order
- belongs_to Event optional
- belongs_to TicketType optional

### Actions
- upsert_from_order
- apply_mapping
- mark_pending_mapping_resolution
- mark_unmapped
- mark_non_ticket
- remap

### Validations / invariants
- order required
- woo_line_item_id required
- quantity > 0 for normal sale line items
- zero or negative quantities must be explicitly classified as ignored/refund_adjustment/non_sale and must never count as sold tickets
- money decimals valid
- mapped requires event_id + ticket_type_id
- unmapped/non_ticket excluded from metrics

### Policies
- admin full read
- staff read internal
- event actors read only assigned event and no PII

### Indexes / constraints
- order_id
- event_id
- ticket_type_id
- mapping_status
- woo_product_id
- woo_variation_id
- unique order_id + woo_line_item_id

### State machine
AshStateMachine: pending_mapping_resolution → mapped/unmapped/non_ticket/ignored. Remap action can move mapped → pending/remapped explicitly and audited.

### PaperTrail / audit
Do not enable AshPaperTrail on high-volume OrderItem records by default for MVP. Use explicit mapping/status audit events and source version fields. Add PaperTrail later only if a proven audit requirement appears.

### Cache / PubSub / invalidation
Mapping/status changes invalidate event/ticket aggregates and enqueue recalculation if historical data affected.

### Required tests
- mixed-event split
- variation mapping
- unknown product pending first
- non-ticket excluded
- unmapped excluded
- mapped requires event/ticket
- state transition tests

---

## Sales — CouponSnapshot
**Module:** `EventSales.Sales.Resources.CouponSnapshot`  
**Path:** `lib/event_sales/sales/resources/coupon_snapshot.ex`  
**Data layer:** AshPostgres

**Purpose:** Basic coupon/discount record for future reporting without full coupon analytics.

### Fields
- id
- order_id
- code
- discount_amount
- discount_tax
- timestamps

### Relationships
- belongs_to Order

### Actions
- upsert_from_order
- read

### Validations / invariants
- order required
- code required
- amount decimals valid

### Policies
- admin/staff internal read
- event-scoped read only if tied through assigned event and permitted

### Indexes / constraints
- order_id
- code

### State machine
No state machine.

### PaperTrail / audit
No PaperTrail required.

### Cache / PubSub / invalidation
Coupon changes may invalidate revenue snapshots if used in future reports.

### Required tests
- coupon parsed
- duplicate coupon snapshot prevented
- discount values stored

---

## Ingestion — WebhookEvent
**Module:** `EventSales.Ingestion.Resources.WebhookEvent`  
**Path:** `lib/event_sales/ingestion/resources/webhook_event.ex`  
**Data layer:** AshPostgres

**Purpose:** Received WooCommerce webhook delivery for idempotency, replay, and troubleshooting.

### Fields
- id
- source_system_id
- topic
- resource_id
- delivery_id
- payload_hash
- payload
- status
- received_at
- processed_at
- error_message
- timestamps

### Relationships
- belongs_to SourceSystem

### Actions
- receive
- queue
- mark_processing
- mark_processed
- mark_failed
- mark_ignored
- mark_buffered
- purge_payload

### Validations / invariants
- topic required
- payload_hash required
- raw payload retained only for valid requests
- idempotency uniqueness

### Policies
- admin read including payload
- staff metadata read if allowed
- non-admin no raw payload

### Indexes / constraints
- status
- topic
- resource_id
- delivery_id
- received_at
- payload_hash
- unique delivery/resource/hash where possible

### State machine
AshStateMachine: received → queued → processing → processed/failed/ignored. buffered → received after Redis drainer persists.

### PaperTrail / audit
No PaperTrail necessary; status history can be in AuditLog or delivery failure resource.

### Cache / PubSub / invalidation
Webhook processing updates aggregates after committed durable sales upsert. Raw payload TTL 90 days.

### Required tests
- invalid signature not stored full
- valid stored
- duplicate delivery safe
- replay failed only
- payload purge only raw field

---

## Ingestion — WebhookDeliveryFailure
**Module:** `EventSales.Ingestion.Resources.WebhookDeliveryFailure`  
**Path:** `lib/event_sales/ingestion/resources/webhook_delivery_failure.ex`  
**Data layer:** AshPostgres

**Purpose:** Minimal metadata for rejected or failed webhook attempts without storing unsafe raw bodies.

### Fields
- id
- source_system_id nullable
- reason
- topic nullable
- remote_ip_hash
- user_agent_hash
- received_at
- metadata bounded
- timestamps

### Relationships
- belongs_to SourceSystem optional

### Actions
- log_failure
- read admin

### Validations / invariants
- reason required
- metadata bounded
- no raw payload/secrets

### Policies
- admin only

### Indexes / constraints
- reason
- received_at
- source_system_id

### State machine
No state machine.

### PaperTrail / audit
No PaperTrail.

### Cache / PubSub / invalidation
Telemetry counter emitted on failure.

### Required tests
- invalid signature logs metadata only
- no raw payload stored
- admin-only read

---

## Ingestion — SyncRun
**Module:** `EventSales.Ingestion.Resources.SyncRun`  
**Path:** `lib/event_sales/ingestion/resources/sync_run.ex`  
**Data layer:** AshPostgres

**Purpose:** Tracks REST reconciliation/backfill run.

### Fields
- id
- source_system_id
- event_id nullable
- kind enum shallow/deep/manual/backfill
- status
- started_at
- finished_at
- date_from
- date_to
- orders_seen
- orders_updated
- errors_count
- last_error
- timestamps

### Relationships
- belongs_to SourceSystem
- belongs_to Event optional
- has_many SyncCursor

### Actions
- queue_manual_scoped
- start
- complete
- fail
- pause
- resume

### Validations / invariants
- manual sync requires event/date scope
- date_to after date_from
- kind enum
- REST max concurrency 2 enforced in worker not resource

### Policies
- admin manage/read
- staff read status maybe
- event actors no sync controls

### Indexes / constraints
- source_system_id
- event_id
- status
- started_at
- kind

### State machine
AshStateMachine: queued → running → completed/failed/paused/cancelled. Cannot complete without running.

### PaperTrail / audit
No PaperTrail; operational AuditLog for manual trigger.

### Cache / PubSub / invalidation
Sync completion invalidates affected event/date aggregates.

### Required tests
- scoped manual required
- pause on errors
- state transitions
- audit manual sync

---

## Ingestion — SyncCursor
**Module:** `EventSales.Ingestion.Resources.SyncCursor`  
**Path:** `lib/event_sales/ingestion/resources/sync_cursor.ex`  
**Data layer:** AshPostgres

**Purpose:** Resumable cursor state for REST reconciliation/backfill.

### Fields
- id
- sync_run_id
- cursor_kind
- page
- modified_after
- modified_before
- last_seen_order_id
- status
- metadata bounded
- timestamps

### Relationships
- belongs_to SyncRun

### Actions
- create/update cursor
- mark_done
- mark_failed

### Validations / invariants
- sync_run required
- cursor values bounded
- metadata bounded

### Policies
- admin read
- worker manage

### Indexes / constraints
- sync_run_id
- status
- modified_after

### State machine
Optional state: active/done/failed.

### PaperTrail / audit
No PaperTrail.

### Cache / PubSub / invalidation
None.

### Required tests
- resume from cursor
- cursor persists on failure
- metadata bounded

---

## Ingestion — CsvImportBatch
**Module:** `EventSales.Ingestion.Resources.CsvImportBatch`  
**Path:** `lib/event_sales/ingestion/resources/csv_import_batch.ex`  
**Data layer:** AshPostgres

**Purpose:** Event-scoped CSV dry-run/apply tracking.

### Fields
- id
- event_id
- uploaded_by_user_id
- source_filename
- status
- row_count
- valid_count
- error_count
- applied_at
- timestamps

### Relationships
- belongs_to Event
- belongs_to User
- has_many CsvImportRow

### Actions
- create_dry_run
- mark_validated
- queue_apply
- mark_applying
- mark_applied
- mark_failed

### Validations / invariants
- event required
- filename sanitized
- apply only after dry-run success

### Policies
- admin manage
- staff maybe no apply unless allowed
- event actors no import in MVP

### Indexes / constraints
- event_id
- status
- uploaded_by_user_id
- inserted_at

### State machine
AshStateMachine: uploaded → validating → dry_run_failed/dry_run_passed → applying → applied/failed. Cannot apply before dry_run_passed.

### PaperTrail / audit
No PaperTrail; AuditLog for apply confirmation.

### Cache / PubSub / invalidation
Apply invalidates affected event aggregates.

### Required tests
- dry-run before apply
- non-admin denied
- state transitions
- apply audit

---

## Ingestion — CsvImportRow
**Module:** `EventSales.Ingestion.Resources.CsvImportRow`  
**Path:** `lib/event_sales/ingestion/resources/csv_import_row.ex`  
**Data layer:** AshPostgres

**Purpose:** Row-level CSV validation and apply result.

### Fields
- id
- csv_import_batch_id
- row_number
- raw_data bounded
- normalized_data
- status
- error_messages
- external_order_number
- external_line_key
- timestamps

### Relationships
- belongs_to CsvImportBatch

### Actions
- store_validation_result
- mark_applied
- mark_failed

### Validations / invariants
- batch required
- row_number required
- raw/normalized data bounded
- duplicate row detection

### Policies
- admin read/manage

### Indexes / constraints
- csv_import_batch_id
- status
- external_order_number
- external_line_key
- unique batch + row_number

### State machine
Optional row status: pending/valid/invalid/applied/failed/skipped.

### PaperTrail / audit
No PaperTrail.

### Cache / PubSub / invalidation
Batch apply invalidates aggregates, not each row if batched.

### Required tests
- row errors stored
- duplicate detected
- large CSV streamed/chunked

---

## Analytics — EventAggregateSnapshot
**Module:** `EventSales.Analytics.Resources.EventAggregateSnapshot`  
**Path:** `lib/event_sales/analytics/resources/event_aggregate_snapshot.ex`  
**Data layer:** AshPostgres

**Purpose:** Durable aggregate snapshot for event historical reporting, not the live hot cache.

### Fields
- id
- event_id
- snapshot_at
- tickets_sold
- completed_revenue
- orders_by_status map/json
- tickets_by_type map/json
- source_version/hash
- timestamps

### Relationships
- belongs_to Event

### Actions
- upsert_snapshot
- read_latest
- refresh_scoped

### Validations / invariants
- event required
- snapshot_at required
- values non-negative
- json bounded

### Policies
- admin/staff read
- event-scoped actors read aggregate only based on settings

### Indexes / constraints
- event_id
- snapshot_at
- unique event_id + snapshot_at bucket if bucketed

### State machine
No state machine.

### PaperTrail / audit
No PaperTrail.

### Cache / PubSub / invalidation
Refresh invalidates Redis event snapshot and dashboard cache.

### Required tests
- snapshot upsert idempotent
- event scoped read excludes PII
- no full table scan in dashboard path

---

## Analytics — DailySalesAggregateSnapshot
**Module:** `EventSales.Analytics.Resources.DailySalesAggregateSnapshot`  
**Path:** `lib/event_sales/analytics/resources/daily_sales_aggregate_snapshot.ex`  
**Data layer:** AshPostgres

**Purpose:** Daily durable snapshot for trend charts and historical reports.

### Fields
- id
- event_id nullable
- date
- timezone
- tickets_sold
- completed_revenue
- orders_by_status json
- timestamps

### Relationships
- belongs_to Event optional

### Actions
- upsert_daily
- read_range
- refresh_range

### Validations / invariants
- date required
- timezone required
- values non-negative

### Policies
- admin/staff read
- event-scoped actors assigned events only

### Indexes / constraints
- event_id
- date
- unique event_id + date + timezone

### State machine
No state machine.

### PaperTrail / audit
No PaperTrail.

### Cache / PubSub / invalidation
Refresh invalidates daily chart Redis keys.

### Required tests
- today timezone correctness
- range read
- refresh idempotent

---

## Audit — AuditLog
**Module:** `EventSales.Audit.Resources.AuditLog`  
**Path:** `lib/event_sales/audit/resources/audit_log.ex`  
**Data layer:** AshPostgres

**Purpose:** Operational/security audit events not covered by PaperTrail.

### Fields
- id
- actor_user_id nullable
- actor_role
- event_id nullable
- action
- metadata bounded
- ip_hash
- user_agent_hash
- occurred_at
- timestamps

### Relationships
- belongs_to User optional
- belongs_to Event optional

### Actions
- log
- read admin
- read scoped if ever needed

### Validations / invariants
- action required
- metadata bounded
- no secrets
- no full raw payloads

### Policies
- admin read all
- non-admin no access in MVP

### Indexes / constraints
- actor_user_id
- event_id
- action
- occurred_at

### State machine
No state machine.

### PaperTrail / audit
No PaperTrail for audit logs.

### Cache / PubSub / invalidation
None; telemetry may count audit event categories.

### Required tests
- manual sync audited
- webhook replay audited
- CSV apply audited
- no secrets/raw payload in metadata

---

# Plain Elixir Module Dossiers

These modules are intentionally not Ash resources. They own caches, clients, pure rules, hot-state, and orchestration helpers.

## MappingResolver

**Module:** `EventSales.Catalog.MappingResolver`  
**Path:** `lib/event_sales/catalog/mapping_resolver.ex`

**Purpose:** Pure mapping lookup. Must not call WooCommerce REST. Returns mapped/non_ticket/pending/unmapped decisions based on local ProductMapping/cache state.

**Required tests:** Tests variation-specific priority, product-level fallback, unknown product -> pending, no external calls.

## MissingCatalogResolver

**Module:** `EventSales.Catalog.MissingCatalogResolver`  
**Path:** `lib/event_sales/catalog/missing_catalog_resolver.ex`

**Purpose:** Coordinates missing metadata recovery with worker/client/cache. External calls occur in worker/client boundary, not pure resolver.

**Required tests:** Tests unknown product recovery, cache write, remap retry, fallback unmapped.

## ProductMetadataCache

**Module:** `EventSales.Catalog.ProductMetadataCache`  
**Path:** `lib/event_sales/catalog/product_metadata_cache.ex`

**Purpose:** Redis/Cachex-backed warm metadata cache for Woo products/variations. TTL 30m-24h, invalidated by product.updated.

**Required tests:** Tests cache get/put/invalidate TTL behavior.

## WooCommerceClient

**Module:** `EventSales.Ingestion.Clients.WooCommerceClient`  
**Path:** `lib/event_sales/ingestion/clients/woocommerce_client.ex`

**Purpose:** Worker-only REST boundary with typed errors, telemetry, timeout, pagination, max concurrency integration.

**Required tests:** Tests 401/403/404/429/500/timeout, product/order fetch, no LiveView calls.

## RedisWebhookBuffer

**Module:** `EventSales.Ingestion.RedisWebhookBuffer`  
**Path:** `lib/event_sales/ingestion/redis_webhook_buffer.ex`

**Purpose:** Optional safety valve for webhook intake when DB pool is saturated. Not canonical durable truth. Uses bounded Redis list/stream and drainer.

**Required tests:** Tests buffer succeeds, buffer full fails, drainer idempotently persists.

## HotStateAggregator

**Module:** `EventSales.Analytics.HotStateAggregator`  
**Path:** `lib/event_sales/analytics/hot_state_aggregator.ex`

**Purpose:** Supervised GenServer for hot dashboard state. Redis-first restore, warming state, async rebuild. Not durable truth.

**Required tests:** Tests start, update, duplicate aggregate idempotency, Redis restore, async rebuild, telemetry.

## DashboardCache

**Module:** `EventSales.Analytics.DashboardCache`  
**Path:** `lib/event_sales/analytics/dashboard_cache.ex`

**Purpose:** Cache facade for hot ETS/Cachex and warm Redis snapshots. Keeps cache access out of LiveView internals.

**Required tests:** Tests keys scoped by event/user visibility, TTL, invalidate, fallback.

## MetricRules

**Module:** `EventSales.Analytics.MetricRules`  
**Path:** `lib/event_sales/analytics/metric_rules.ex`

**Purpose:** Pure functions for completed-only tickets/revenue, order status visibility, non-ticket/unmapped exclusions.

**Required tests:** Tests all status and item-kind rules.

## Audit.Logger

**Module:** `EventSales.Audit.Logger`  
**Path:** `lib/event_sales/audit/logger.ex`

**Purpose:** Thin helper to write operational AuditLog entries with bounded, sanitized metadata.

**Required tests:** Tests no secrets/raw payloads, action/event/user fields.

---

# Resource-to-slice ownership

```text
Slice 2.0 owns Accounts resources and authentication.
Slice 3.0 owns Catalog resources and ProductMapping.
Slice 4.0 owns Sales resources and initial sales state machines.
Slice 5.0 owns WebhookEvent and signature intake.
Slice 5.5 owns RedisWebhookBuffer and drainer behavior.
Slice 8.6 hardens state machines across ingestion, sync, CSV, and mapping.
Slice 8.8 applies PaperTrail and operational AuditLog split.
Slice 9.5 owns HotStateAggregator and hot/warm read model.
Slice 9.7 owns aggregate snapshots / materialized reporting path.
```


---

# V2 Dossier Hardening Addendum

These changes override or refine the resource dossiers above.

## Infrastructure Modules — Required

### EventSales.Repo
**Path:** `lib/event_sales/repo.ex`  
**Purpose:** Main Ecto/AshPostgres repository.

Rules:
```text
Use pooled DATABASE_URL for normal app traffic.
Support PgBouncer-safe settings when enabled.
If PgBouncer transaction pooling is used, test prepare mode and Oban behavior explicitly.
Do not use normal pooled URL for migrations if a direct URL is required.
```

Required tests/smoke checks:
```text
Repo starts in test.
Repo configuration reads runtime env.
PgBouncer mode is documented.
```

### EventSales.Release
**Path:** `lib/event_sales/release.ex`  
**Purpose:** Railway/release migration helper.

Rules:
```text
Use DIRECT_DATABASE_URL for migrations when provided.
Fall back to DATABASE_URL only when direct URL is unavailable and documented safe.
Do not run migrations through PgBouncer transaction pooling unless tested.
```

### Oban DB/Notifier Topology
Rules:
```text
Oban must be smoke-tested under the selected production DB topology.
If using PgBouncer transaction pooling, do not assume PostgreSQL LISTEN/NOTIFY works.
Choose and document a compatible notifier/polling strategy.
```

---

## Sales — Order V2 Field Additions

Add fields:
```text
last_source_updated_at
last_source_payload_hash
last_webhook_event_id
source_version_counter optional
```

Rules:
```text
Newer WooCommerce source updated_at wins.
Older webhook payloads must not regress status, totals, or customer fields.
If timestamps are missing, use deterministic tie-breaker: payload hash + received_at + explicit stale policy.
External source sync must be auditable.
```

Additional tests:
```text
order.updated newer payload updates order once.
order.created older payload after update does not regress state.
Duplicate payload with different delivery ID does not double-process.
```

---

## Sales — OrderItem V2 Refinements

Change invariant:
```text
quantity must be > 0 for sale line items.
Refunds/negative adjustments are not represented as positive sold tickets in MVP.
```

Add fields if needed:
```text
last_source_payload_hash
last_webhook_event_id
```

Additional tests:
```text
zero quantity sale item rejected or ignored explicitly.
negative quantity does not count as sold.
refund-like line is not modeled as positive ticket sale.
```

---

## Ingestion — WebhookEvent V2 Field Additions

Add fields:
```text
accepted_via enum: postgres / redis_buffer
source_updated_at nullable
raw_body_size
signature_validated_at
sanitized_headers_snapshot
processing_attempt_count
stale boolean default false
```

Rules:
```text
Webhook signature verification uses raw request body.
Invalid signatures store only WebhookDeliveryFailure metadata.
Redis-buffered events must eventually be persisted to WebhookEvent before processing.
Stale events may be retained for audit but must not mutate current sales state.
```

Additional tests:
```text
raw-body HMAC valid case passes.
re-encoded JSON signature mismatch fails.
accepted_via is set correctly.
stale event is marked and does not mutate order.
```

---

## Ingestion — RedisWebhookBuffer V2 Rules

Purpose:
```text
Degraded-mode safety valve for DB pool saturation, not canonical truth.
```

Rules:
```text
Enable only via explicit config.
Document Redis persistence/durability assumptions.
Use bounded list/stream size.
If buffer is full/unavailable, return non-2xx.
Drainer must be idempotent.
Buffered payloads must be persisted to Postgres before processing.
```

Required tests:
```text
buffer disabled => DB failure returns non-2xx.
buffer enabled + Redis available => accepted_via redis_buffer.
buffer full => non-2xx.
drainer persists once despite retry.
```

---

## Ingestion — WooCommerceClient V2 Rules

Add modules:
```text
RestRateLimiter
RestCircuitBreaker
```

Rules:
```text
Max REST concurrency is 2 globally.
Pause/reject new REST jobs on repeated 429/500/timeouts.
Emit telemetry for latency, status, backoff, circuit open/close.
Workers use the client; LiveViews/controllers do not.
```

Required tests:
```text
concurrency cap enforced under concurrent worker attempts.
circuit opens after configured failures.
circuit half-open retry behavior works.
REST telemetry emitted.
```

---

## Analytics — AggregateEvent V2 Contract

Aggregate event must include:
```text
aggregate_event_id
source_system_id
order_id
order_item_id nullable
event_id nullable
ticket_type_id nullable
status_before/status_after nullable
quantity_delta
revenue_delta
source_updated_at
payload_hash
```

Rules:
```text
aggregate_event_id is idempotency key.
Apply only after durable sales write commits.
Never apply stale source update.
Rebuild from Postgres must match accumulated aggregate events.
```

Required tests:
```text
same aggregate_event_id applied once.
stale aggregate event ignored.
rebuild totals equal event-stream totals.
```

---

## Audit — MetadataSanitizer

Add module:
```text
EventSales.Audit.MetadataSanitizer
```

Rules:
```text
Strip authorization headers, cookies, API keys, webhook secrets, raw payloads, and oversized metadata.
Hash IP/user-agent where stored.
Bound metadata size.
```

Required tests:
```text
secret-like keys removed.
raw payload omitted.
metadata size bounded.
```


---

# V2.1 Final Dossier Hardening Addendum

These rules directly override older loose wording in this file.

## WooCommerce REST Boundary

```text
No LiveView, component, controller, or MappingResolver may call WooCommerce REST.
Only Oban workers and approved ingestion service modules may call WooCommerceClient.
The webhook controller receives WooCommerce webhooks but must not call WooCommerce REST.
```

## Business Runtime Configuration

```text
EVENTSALES_BUSINESS_TIMEZONE=Africa/Johannesburg
EVENTSALES_DEFAULT_CURRENCY=ZAR
```

These values must be available to metric rules, date bucketing, snapshots, dashboard “today” calculations, and exports.

## Raw Body HMAC Verification

```text
RawBodyReader must run before JSON body parsing.
Do not rely on conn.body_params for WooCommerce HMAC verification.
Do not verify signatures against decoded or re-encoded JSON.
Store raw body only after signature validation succeeds.
```

## Redis Degraded-Mode Intake

```text
Return 2xx only if:
1. the webhook was persisted to Postgres, or
2. Redis degraded-mode buffer is explicitly enabled, bounded, monitored, and its durability risk has been accepted.

If neither condition is true, return non-2xx so WooCommerce retries.
```

## Real Payload Verification Requirement

Before implementing final WooCommerce parsers, capture or obtain sanitized real payloads for:

```text
completed order
pending order
refunded order
mixed-event order
variation ticket order
non-ticket product order
product.updated
variation updated
```

Compare them against the fixtures and record all gaps in `docs/architecture/fixture-verification.md`.


## Ingestion — TickeraAttendeeSyncRun (Planned Slice 14.5)
**Domain:** Ingestion
**Purpose:** Track scoped Tickera attendee sync executions by event/date with observable outcomes and retry-safe status.
**Durable data ownership:** Postgres durable truth for sync run metadata, scope, status, and failure reasons.
**Relationships:** belongs_to SourceSystem/Event; has_many TickeraAttendeeSnapshot and AttendeeReconciliationResult via sync run ID.
**Actions planned:** create/run/start/complete/fail scoped sync lifecycle actions.
**Permissions/policies planned:** admin/staff scoped to authorized events; no public access.
**Indexes required:** source_system_id, event_id, sync_status, started_at, finished_at.
**Cache/PubSub rules:** invalidate reconciliation summary caches and broadcast scoped refresh after completion/failure writes.
**Telemetry rules:** emit sync start/stop duration, attendee count, API error, and circuit-breaker pause metrics.
**Strict tests:** event/date scope required, idempotent rerun behavior, typed API failures captured, admin-only initiation.
**Edge cases:** partial page failures, API throttling, timeout pauses, repeated reruns with same scope.

## Ingestion — TickeraAttendeeSnapshot (Planned Slice 14.5)
**Domain:** Ingestion
**Purpose:** Persist imported Tickera attendee records as durable reconciliation input.
**Durable data ownership:** Postgres durable attendee snapshot keyed to source identifiers and sync run context.
**Relationships:** belongs_to TickeraAttendeeSyncRun/Event/TicketType where resolvable.
**Actions planned:** upsert snapshot rows scoped to sync run and attendee identity.
**Permissions/policies planned:** internal ingestion writes; admin/staff read through reconciliation views only.
**Indexes required:** event_id, ticket_type_id, tickera_attendee_id, tickera_ticket_code, woo_order_id, sync_run_id.
**Cache/PubSub rules:** no direct cache truth; summary caches invalidated only after durable writes complete.
**Telemetry rules:** per-page import counts, upsert latency, duplicate suppression counts.
**Strict tests:** no duplicate rows on rerun, scoped imports only, sensitive fields sanitized in logs/fixtures.
**Edge cases:** missing order correlation fields, duplicate attendee IDs, out-of-order source updates.

## Analytics — AttendeeReconciliationResult (Planned Slice 14.5)
**Domain:** Analytics
**Purpose:** Durable Woo-vs-Tickera comparison output per reconciliation unit.
**Durable data ownership:** Postgres durable status/mismatch reason/payment method context for audit-safe reporting.
**Relationships:** belongs_to Event/TicketType/Order/SyncRun where available.
**Actions planned:** classify matched/mismatched states and persist idempotent comparison rows.
**Permissions/policies planned:** admin/staff event-scoped read; internal workers write.
**Indexes required:** event_id, ticket_type_id, woo_order_id, woo_line_item_id, reconciliation_status, payment_method, sync_run_id.
**Cache/PubSub rules:** summary cache invalidation and scoped PubSub broadcast after durable reconciliation writes.
**Telemetry rules:** mismatch counts by status and payment method, classification latency, weak-match warning counts.
**Strict tests:** status taxonomy coverage, completed-only Woo counting, payment-method persistence, idempotent reruns.
**Edge cases:** quantity > 1 mapping, mapping drift, weak heuristic fallback flagged for review only.

## Analytics — AttendeeReconciliationSummary (Planned Slice 14.5)
**Domain:** Analytics
**Purpose:** Query-optimized/cached summary grouped by event, ticket type, mismatch status, and payment method.
**Durable data ownership:** Derived query path over durable reconciliation results; Redis/Cachex used for short-lived summary cache only.
**Relationships:** aggregates AttendeeReconciliationResult by scoped dimensions.
**Actions planned:** read/list grouped summaries and export query paths.
**Permissions/policies planned:** admin/staff event-scoped read; no public exposure.
**Indexes required:** event_id, ticket_type_id, reconciliation_status, payment_method, sync_run_id.
**Cache/PubSub rules:** TTL 30s-5m; invalidate on attendee sync completion, Woo order update, mapping change, manual rerun.
**Telemetry rules:** summary query latency, cache hit/miss, export stream throughput.
**Strict tests:** payment-method grouping accuracy, streamed/paginated export behavior, cache invalidation triggers.
**Edge cases:** large event cardinality, stale cache after rerun, empty payment method buckets.
