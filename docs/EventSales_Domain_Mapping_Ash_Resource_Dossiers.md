# EventSales Domain Mapping and Ash Resource Dossiers

## Document Purpose

This document defines the domain map and Ash resource dossiers for **EventSales**, a Phoenix + Ash 3.x + LiveView sales analytics system for WooCommerce + Tickera events.

The goal is to give a coding agent a clear, bounded, and testable map of:

- domains
- resources
- relationships
- invariants
- actions
- policies
- indexes
- cache rules
- webhook/reconciliation behavior
- testing requirements
- edge cases and risk areas

This document is a planning and implementation guidance document. It does not contain final implementation code.

---

## Core System Principle

EventSales must act as a reporting and analytics layer, not as a live proxy for WordPress.

```text
WooCommerce / Tickera = sales and checkout system
EventSales = ingestion, normalization, reporting, dashboards, reconciliation, exports
```

Non-negotiable rules:

```text
Dashboard pages must never call WooCommerce directly.
Webhook requests must return quickly.
Heavy processing must happen through Oban.
REST API access is only for reconciliation, backfill, and missing details.
Completed-only order rules drive MVP sold/revenue metrics.
Event access must be enforced through Ash policies, not only UI routes.
```

---

## High-Level Domain Map

```text
EventSales
├── Accounts
│   ├── User
│   ├── Role
│   ├── UserRole
│   └── EventAccessGrant
│
├── Catalog
│   ├── SourceSystem
│   ├── Event
│   ├── TicketType
│   ├── ProductMapping
│   └── EventDashboardSetting
│
├── Sales
│   ├── Order
│   ├── OrderItem
│   └── CouponSnapshot
│
├── Ingestion
│   ├── WebhookEvent
│   ├── WebhookDeliveryFailure
│   ├── SyncRun
│   ├── SyncCursor
│   ├── CsvImportBatch
│   └── CsvImportRow
│
├── Analytics
│   ├── EventAggregate
│   ├── TicketTypeAggregate
│   ├── DailySalesAggregate
│   └── DashboardCacheState
│
└── Audit
    └── AuditLog
```

---

## Domain Boundaries

## 1. Accounts Domain

### Responsibility

The `EventSales.Accounts` domain owns identity, roles, and event-scoped access.

It must support:

- admin users
- staff users
- future event owner users
- future event staff users
- event-scoped permissions
- role-aware PII masking
- expiry of event access grants

### Resources

```text
EventSales.Accounts.User
EventSales.Accounts.Role
EventSales.Accounts.UserRole
EventSales.Accounts.EventAccessGrant
```

### Hard Boundary

Accounts may know about event IDs for access control, but it must not contain sales logic, webhook logic, WooCommerce logic, or analytics logic.

---

## 2. Catalog Domain

### Responsibility

The `EventSales.Catalog` domain owns the internal representation of events, ticket types, WooCommerce source systems, and product/variation mappings.

It must support:

- one WooCommerce source system for MVP
- future light support for more sources
- events
- ticket types
- manual capacity
- product-to-ticket mapping
- variation-to-ticket mapping
- event dashboard settings for future client dashboards

### Resources

```text
EventSales.Catalog.SourceSystem
EventSales.Catalog.Event
EventSales.Catalog.TicketType
EventSales.Catalog.ProductMapping
EventSales.Catalog.EventDashboardSetting
```

### Hard Boundary

Catalog must not process orders directly. It provides mappings and event metadata used by Sales, Ingestion, and Analytics.

---

## 3. Sales Domain

### Responsibility

The `EventSales.Sales` domain owns normalized order and order item records.

It must support:

- WooCommerce order headers
- WooCommerce line items
- multiple ticket products per order
- mixed-event orders
- completed-only sold/revenue rules
- non-ticket item storage
- minimal customer information
- status tracking
- coupon snapshots

### Resources

```text
EventSales.Sales.Order
EventSales.Sales.OrderItem
EventSales.Sales.CouponSnapshot
```

### Hard Boundary

Sales stores facts. It does not know how to call WooCommerce. It does not own webhook delivery. It should not contain LiveView-specific logic.

---

## 4. Ingestion Domain

### Responsibility

The `EventSales.Ingestion` domain owns all external data intake, reconciliation, CSV imports, webhook delivery records, and sync state.

It must support:

- WooCommerce webhook delivery storage
- webhook signature verification support
- idempotent processing
- failed delivery visibility
- webhook replay
- REST reconciliation
- cursor-based backfill
- CSV dry-run validation
- queued CSV application
- raw payload retention

### Resources

```text
EventSales.Ingestion.WebhookEvent
EventSales.Inestion.WebhookDeliveryFailure
EventSales.Ingestion.SyncRun
EventSales.Ingestion.SyncCursor
EventSales.Ingestion.CsvImportBatch
EventSales.Ingestion.CsvImportRow
```

### Hard Boundary

Ingestion can call external systems through a boundary client, but it must not contain dashboard rendering logic or bypass Ash resource actions.

---

## 5. Analytics Domain

### Responsibility

The `EventSales.Analytics` domain owns dashboard aggregates, counters, cache state, and derived metrics.

It must support:

- tickets sold today
- tickets sold total
- completed revenue today
- completed revenue total
- tickets by event
- tickets by ticket type
- orders by status
- failed webhook/sync alert counts
- unmapped item alert counts
- cache invalidation
- PubSub update events

### Resources

```text
EventSales.Analytics.EventAggregate
EventSales.Analytics.TicketTypeAggregate
EventSales.Analytics.DailySalesAggregate
EventSales.Analytics.DashboardCacheState
```

### Hard Boundary

Analytics must derive data from EventSales Postgres records and cache layers only. It must never query WooCommerce.

---

## 6. Audit Domain

### Responsibility

The `EventSales.Audit` domain owns traceability of sensitive actions.

It must support auditing of:

- mapping changes
- manual sync triggers
- webhook replay
- CSV import dry-runs and applies
- future client dashboard access
- export actions
- dangerous maintenance actions

### Resources

```text
EventSales.Audit.AuditLog
```

### Hard Boundary

Audit records must never store secrets, raw webhook payloads, complete customer billing data, or large unbounded metadata.

---

# Cross-Domain Relationship Map

```text
SourceSystem
└── has_many Events
└── has_many ProductMappings
└── has_many Orders
└── has_many WebhookEvents
└── has_many SyncRuns

Event
└── belongs_to SourceSystem
└── has_many TicketTypes
└── has_many ProductMappings
└── has_many OrderItems
└── has_many EventAccessGrants
└── has_one EventDashboardSetting
└── has_many EventAggregates
└── has_many DailySalesAggregates

TicketType
└── belongs_to Event
└── has_many ProductMappings
└── has_many OrderItems
└── has_many TicketTypeAggregates

ProductMapping
└── belongs_to SourceSystem
└── belongs_to Event
└── belongs_to TicketType

Order
└── belongs_to SourceSystem
└── has_many OrderItems
└── has_many CouponSnapshots

OrderItem
└── belongs_to Order
└── optionally belongs_to Event
└── optionally belongs_to TicketType

WebhookEvent
└── belongs_to SourceSystem
└── may reference external WooCommerce resource ID

SyncRun
└── belongs_to SourceSystem
└── optionally belongs_to Event
└── has_many SyncCursors

CsvImportBatch
└── belongs_to Event
└── belongs_to User
└── has_many CsvImportRows

AuditLog
└── optionally belongs_to User
└── optionally belongs_to Event
```

---

# Global Invariants

These invariants apply across the whole system.

## Sales and Revenue

```text
Tickets sold = completed orders only.
Basic revenue = completed ticket line item total after discounts.
Pending, processing, failed, cancelled, and refunded orders are visible but excluded from sold totals in MVP.
Non-ticket products are stored but excluded from ticket metrics.
Unmapped products are stored but excluded from ticket metrics.
One order may contain tickets for multiple events.
One order item may have quantity greater than 1.
Reporting must split mixed-event orders by line item.
```

## Ingestion

```text
Webhook intake must be fast.
Webhook processing must be async.
Webhook processing must be idempotent.
Invalid webhook signatures must be rejected before payload storage.
Raw webhook payloads are retained for 90 days.
REST reconciliation must not exceed 2 concurrent WooCommerce requests.
REST reconciliation must pause on 429, 500, timeouts, or slow response patterns.
CSV import must dry-run before apply.
```

## Access and Privacy

```text
Admin can see full internal data.
Staff access is configurable and restricted.
Event owner access is event-scoped.
Event staff access is event-scoped and revenue-restricted by default.
Customer PII must be masked or hidden by role.
Future client dashboards must be aggregate-first.
Ash policies must enforce event access.
```

## Performance

```text
Dashboard pages must read from EventSales Postgres/cache only.
Dashboard manual refresh must not call WooCommerce.
PubSub is used for live dashboard updates.
Manual sync triggers Oban jobs.
Heavy calculations must not run inline in LiveView events.
Large CSV files must be streamed/chunked.
Exports must be streamed or paginated.
```

---

# Cache and Scaling Architecture

## Hot Layer

```text
Technology: ETS / GenServer / Cachex
TTL: 10 seconds to 5 minutes
Purpose:
- active dashboard counters
- today totals
- current event counters
- recent alert counts
- quick status summaries
```

## Warm Layer

```text
Technology: Redis
TTL: 30 minutes to 24 hours
Purpose:
- event aggregates
- ticket type aggregates
- chart datasets
- future client dashboard snapshots
- mapping lookup cache after correctness is proven
```

## Cold Layer

```text
Technology: Postgres
Purpose:
- orders
- order items
- mappings
- events
- webhook events
- sync runs
- CSV import records
- audit logs
- durable aggregates
```

## Invalidations

Caches must be invalidated when:

```text
order processed
order status changed
order item mapping changed
product mapping changed
CSV import applied
REST reconciliation applied
manual recalculation completed
refund/cancelled status processed
```

---

# Ash Resource Dossiers

---

# Accounts Domain Dossiers

## Resource: `EventSales.Accounts.User`

### Purpose

Represents an authenticated person who can access EventSales.

### Responsibilities

```text
authentication identity
admin/staff/event role assignments
future client dashboard access identity
audit actor reference
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `email` | string | Yes | Unique, normalized lowercase |
| `name` | string | No | Display name |
| `hashed_password` | string | Yes/Depends | If password auth is used |
| `confirmed_at` | utc_datetime | No | Optional account confirmation |
| `active` | boolean | Yes | Default true |
| `last_signed_in_at` | utc_datetime | No | Optional operational visibility |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
has_many UserRole
has_many EventAccessGrant
has_many AuditLog
```

### Actions

```text
create_user
update_user
deactivate_user
assign_role
remove_role
read_current_user
```

### Policies

```text
admin can manage all users
user can read limited own profile
staff cannot manage users by default
event_owner/event_staff cannot manage users
```

### Indexes

```text
unique users.email
index users.active
```

### Edge Cases

```text
email casing differences
inactive user with old event access grant
user with expired event access
user with multiple roles
```

### Required Tests

```text
email uniqueness
email normalization
admin can create user
non-admin cannot create user
inactive user cannot access admin dashboard
role assignment works
```

---

## Resource: `EventSales.Accounts.Role`

### Purpose

Defines supported system roles.

### Responsibilities

```text
admin/staff/event_owner/event_staff role catalog
stable permission references
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `name` | enum/string | Yes | `admin`, `staff`, `event_owner`, `event_staff` |
| `description` | string | No | Human readable |
| `active` | boolean | Yes | Default true |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
has_many UserRole
```

### Actions

```text
seed_default_roles
read_roles
```

### Policies

```text
admin can read/manage roles
other roles read only if needed
```

### Indexes

```text
unique roles.name
```

### Required Tests

```text
default roles exist
role names are constrained
roles are unique
```

---

## Resource: `EventSales.Accounts.UserRole`

### Purpose

Joins users to roles.

### Responsibilities

```text
multiple role support
role assignment auditability
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `user_id` | UUID | Yes | User reference |
| `role_id` | UUID | Yes | Role reference |
| `assigned_by_user_id` | UUID | No | Audit helper |
| `inserted_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
belongs_to User
belongs_to Role
belongs_to assigned_by User optional
```

### Actions

```text
assign
revoke
read_for_user
```

### Policies

```text
admin can assign/revoke roles
non-admin cannot assign/revoke roles
```

### Indexes

```text
unique user_roles.user_id + role_id
index user_roles.user_id
index user_roles.role_id
```

### Required Tests

```text
cannot assign duplicate role
admin can assign role
non-admin cannot assign role
role revocation works
```

---

## Resource: `EventSales.Accounts.EventAccessGrant`

### Purpose

Grants event-scoped access to future event owners and event staff.

### Responsibilities

```text
event owner dashboard access foundation
event staff dashboard access foundation
expiry/revocation of event access
future client dashboard security
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `user_id` | UUID | Yes | User reference |
| `event_id` | UUID | Yes | Event reference |
| `access_role` | enum/string | Yes | `event_owner`, `event_staff` |
| `expires_at` | utc_datetime | No | Admin-controlled expiry |
| `revoked_at` | utc_datetime | No | Revocation timestamp |
| `granted_by_user_id` | UUID | No | Admin who granted |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
belongs_to User
belongs_to Event
belongs_to granted_by User optional
```

### Actions

```text
grant_event_access
revoke_event_access
read_active_for_user
read_active_for_event
```

### Policies

```text
admin can manage all grants
staff cannot manage grants by default
event_owner can only read own active grant if needed
event_staff can only read own active grant if needed
```

### Indexes

```text
index event_access_grants.user_id
index event_access_grants.event_id
index event_access_grants.expires_at
index event_access_grants.revoked_at
unique active grant per user + event + access_role where not revoked
```

### Cache Rules

```text
Warm cache possible for event access checks.
TTL: 5m–30m.
Invalidate on grant/revoke/expiry-sensitive access check.
```

### Edge Cases

```text
expired grant
revoked grant
user has staff and event_owner role
event deleted/archived
future token/password layer
```

### Required Tests

```text
active grant allows assigned event access
expired grant denies access
revoked grant denies access
unassigned event access denied
event_staff cannot see revenue by default
event_owner revenue visibility depends on event setting
```

---

# Catalog Domain Dossiers

## Resource: `EventSales.Catalog.SourceSystem`

### Purpose

Represents an external commerce source, initially one WooCommerce store.

### Responsibilities

```text
identify WooCommerce source
scope external IDs
support future light multi-source capability
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `name` | string | Yes | Human readable |
| `kind` | enum/string | Yes | `woocommerce` for MVP |
| `base_url` | string | Yes | Store URL, no secrets |
| `active` | boolean | Yes | Default true |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
has_many Events
has_many ProductMappings
has_many Orders
has_many WebhookEvents
has_many SyncRuns
```

### Actions

```text
create_source_system
update_source_system
deactivate_source_system
read_active_source_system
```

### Policies

```text
admin can manage
staff can read
future event roles cannot manage
```

### Indexes

```text
unique source_systems.kind + base_url
index source_systems.active
```

### Notes

```text
Do not store WooCommerce API keys or webhook secrets here in MVP.
Use Railway environment variables for secrets.
```

### Required Tests

```text
unique kind/base_url
credentials are not stored
active source lookup works
```

---

## Resource: `EventSales.Catalog.Event`

### Purpose

Represents an internal event used for sales reporting.

### Responsibilities

```text
event-level dashboard scope
ticket type grouping
manual capacity
future client dashboard access boundary
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `source_system_id` | UUID | Yes | Source reference |
| `name` | string | Yes | Event display name |
| `slug` | string | Yes | Internal route/reference |
| `starts_at` | utc_datetime | No | Optional |
| `ends_at` | utc_datetime | No | Optional |
| `capacity` | integer | No | Optional manual capacity |
| `status` | enum/string | Yes | `draft`, `active`, `completed`, `archived` |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
belongs_to SourceSystem
has_many TicketTypes
has_many ProductMappings
has_many OrderItems
has_many EventAccessGrants
has_one EventDashboardSetting
has_many EventAggregates
has_many DailySalesAggregates
```

### Actions

```text
create_event
update_event
archive_event
set_capacity
read_active_events
read_event_dashboard_scope
```

### Policies

```text
admin can manage all events
staff can read events
event_owner can read assigned events
event_staff can read assigned events with restricted metrics
```

### Indexes

```text
index events.source_system_id
unique events.source_system_id + slug
index events.starts_at
index events.status
```

### Cache Rules

```text
Event metadata can be warm cached in Redis.
TTL: 30m–24h.
Invalidate on event update, capacity update, dashboard setting update.
```

### Edge Cases

```text
capacity is nil
capacity lower than sold count after correction
archived event still needs historical reporting
mixed-event orders
future client access after event ends
```

### Required Tests

```text
event can be created with nil capacity
event slug uniqueness scoped by source system
archived event remains readable to admin
assigned event_owner can read event
unassigned event_owner cannot read event
capacity nil does not break remaining count rendering
```

---

## Resource: `EventSales.Catalog.TicketType`

### Purpose

Represents a reportable ticket category within an event.

### Responsibilities

```text
group mapped WooCommerce products/variations
drive ticket type breakdown
support optional per-ticket capacity
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `event_id` | UUID | Yes | Event reference |
| `name` | string | Yes | Ticket type name |
| `capacity` | integer | No | Optional capacity |
| `active` | boolean | Yes | Default true |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
belongs_to Event
has_many ProductMappings
has_many OrderItems
has_many TicketTypeAggregates
```

### Actions

```text
create_ticket_type
update_ticket_type
deactivate_ticket_type
set_capacity
```

### Policies

```text
admin can manage
staff can read
event_owner can read assigned event ticket types
event_staff can read assigned event ticket types without revenue by default
```

### Indexes

```text
index ticket_types.event_id
index ticket_types.active
unique ticket_types.event_id + name where active if needed
```

### Cache Rules

```text
Ticket type lists can be warm cached.
Invalidate on create/update/deactivate.
```

### Required Tests

```text
ticket type belongs to event
ticket type capacity may be nil
deactivated ticket type does not break historical order items
```

---

## Resource: `EventSales.Catalog.ProductMapping`

### Purpose

Maps WooCommerce products and variations to EventSales events and ticket types.

### Responsibilities

```text
resolve order items to event/ticket type
support product-only and variation-specific mapping
store original/current labels
trigger aggregate recalculation on changes
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `source_system_id` | UUID | Yes | Source reference |
| `event_id` | UUID | Yes | Event reference |
| `ticket_type_id` | UUID | Yes | Ticket type reference |
| `woo_product_id` | integer | Yes | WooCommerce product ID |
| `woo_variation_id` | integer | No | WooCommerce variation ID |
| `original_label` | string | No | First known label |
| `current_label` | string | No | Latest product/variation label |
| `active` | boolean | Yes | Default true |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
belongs_to SourceSystem
belongs_to Event
belongs_to TicketType
```

### Actions

```text
create_mapping
update_mapping
deactivate_mapping
resolve_mapping
refresh_current_label
```

### Policies

```text
admin can manage mappings
staff may read mappings
event_owner/event_staff cannot manage mappings in MVP
```

### Indexes

```text
unique active product_mappings.source_system_id + woo_product_id + woo_variation_id
index product_mappings.source_system_id
index product_mappings.event_id
index product_mappings.ticket_type_id
index product_mappings.woo_product_id
index product_mappings.woo_variation_id
index product_mappings.active
```

### Cache Rules

```text
Mapping lookup can be cached after correctness is proven.
Hot/Warm cache key: source_system_id:product_id:variation_id.
TTL: 30m–24h.
Invalidate on mapping create/update/deactivate/product.updated.
```

### Edge Cases

```text
variation-specific mapping should win over product-only mapping
same product sold under multiple events is risky and must be explicit
product label changes after orders exist
mapping changed after historic orders imported
```

### Required Tests

```text
product-only mapping resolves
variation-specific mapping resolves
variation-specific mapping wins over product mapping
duplicate active mapping is rejected
inactive mapping is ignored
mapping change enqueues recalculation
mapping change writes audit log
```

---

## Resource: `EventSales.Catalog.EventDashboardSetting`

### Purpose

Stores settings for future event-scoped dashboards.

### Responsibilities

```text
control revenue visibility
control future client dashboard behavior
support token/password layer later
support expiry defaults
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `event_id` | UUID | Yes | Event reference |
| `revenue_visible_to_event_owner` | boolean | Yes | Default false or configurable |
| `revenue_visible_to_event_staff` | boolean | Yes | Default false |
| `order_numbers_visible_to_event_owner` | boolean | Yes | Default false/optional |
| `client_dashboard_enabled` | boolean | Yes | Default false for MVP |
| `default_access_expires_at` | utc_datetime | No | Optional |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
belongs_to Event
```

### Actions

```text
create_default_for_event
update_dashboard_settings
read_for_event
```

### Policies

```text
admin can manage
staff can read if needed
event_owner/event_staff cannot manage settings
```

### Indexes

```text
unique event_dashboard_settings.event_id
```

### Required Tests

```text
default settings created for event
revenue hidden from event_staff by default
settings influence event_owner aggregate access
```

---

# Sales Domain Dossiers

## Resource: `EventSales.Sales.Order`

### Purpose

Stores normalized WooCommerce order header data.

### Responsibilities

```text
external order identity
order status tracking
minimal customer info
order-level totals for reconciliation
source timestamps
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `source_system_id` | UUID | Yes | Source reference |
| `woo_order_id` | integer | Yes | External ID |
| `order_number` | string | Yes | Human-readable WooCommerce order number |
| `status` | enum/string | Yes | WooCommerce status |
| `currency` | string | No | Example: `ZAR` |
| `order_total` | decimal | No | Raw order total |
| `discount_total` | decimal | No | Raw discount total |
| `tax_total` | decimal | No | Optional |
| `customer_name` | string | No | Admin-only PII |
| `customer_email` | string | No | Admin-only PII |
| `created_at_source` | utc_datetime | No | Woo created date |
| `updated_at_source` | utc_datetime | No | Woo modified date |
| `completed_at` | utc_datetime | No | Completed date if available |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
belongs_to SourceSystem
has_many OrderItems
has_many CouponSnapshots
```

### Actions

```text
upsert_from_woocommerce
update_status
read_by_external_id
read_recent_orders
read_by_event_via_items
```

### Policies

```text
admin can read all orders and PII
staff can read order data with possible PII masking
event_owner can read assigned event order summaries only if enabled
event_staff cannot read customer PII by default
```

### Indexes

```text
unique orders.source_system_id + woo_order_id
index orders.source_system_id
index orders.status
index orders.order_number
index orders.completed_at
index orders.created_at_source
index orders.updated_at_source
```

### Cache Rules

```text
Recent orders can be hot cached briefly.
TTL: 10s–5m.
Invalidate on order upsert/status change.
```

### Edge Cases

```text
order status changes multiple times
WooCommerce order number differs from ID
order contains only non-ticket products
order contains multiple event items
customer email missing
completed_at missing even with completed status
```

### Required Tests

```text
unique source/order ID enforced
status update does not duplicate order
completed order is visible
pending order is visible but not sold
customer PII policy applies
mixed-event order supported through order items
```

---

## Resource: `EventSales.Sales.OrderItem`

### Purpose

Stores normalized WooCommerce line items and their event/ticket mapping status.

### Responsibilities

```text
line-item-level reporting
quantity-aware ticket counts
mixed-event order splitting
ticket/non-ticket classification
mapping state
line revenue storage
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `order_id` | UUID | Yes | Order reference |
| `event_id` | UUID | No | Set when mapped |
| `ticket_type_id` | UUID | No | Set when mapped |
| `woo_line_item_id` | integer/string | Yes | Woo line item ID |
| `woo_product_id` | integer | No | Product ID |
| `woo_variation_id` | integer | No | Variation ID |
| `name` | string | Yes | Original line item name |
| `quantity` | integer | Yes | Must be >= 1 |
| `line_subtotal` | decimal | No | Before discount |
| `line_total` | decimal | No | After discount |
| `discount_total` | decimal | No | Derived/stored if available |
| `item_kind` | enum/string | Yes | `ticket`, `non_ticket`, `unknown` |
| `mapping_status` | enum/string | Yes | `mapped`, `unmapped`, `non_ticket` |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
belongs_to Order
belongs_to Event optional
belongs_to TicketType optional
```

### Actions

```text
upsert_from_woocommerce_line_item
apply_mapping
mark_unmapped
mark_non_ticket
read_unmapped
read_for_event
```

### Policies

```text
admin can read all
staff can read internal summaries
event_owner can read assigned event aggregates/order summaries if enabled
event_staff can read assigned event operational counts only
```

### Indexes

```text
unique order_items.order_id + woo_line_item_id
index order_items.order_id
index order_items.event_id
index order_items.ticket_type_id
index order_items.woo_product_id
index order_items.woo_variation_id
index order_items.mapping_status
index order_items.item_kind
```

### Cache Rules

```text
Order item changes invalidate:
- event aggregate cache
- ticket type aggregate cache
- dashboard counters
- unmapped item count
```

### Edge Cases

```text
quantity > 1
zero or negative quantity from bad import
line item missing product ID
variation ID is 0/null
non-ticket merch in same order
unmapped ticket product
order status change affects whether item counts as sold
```

### Required Tests

```text
quantity greater than 1 counts correctly
unmapped item excluded from ticket metrics
non-ticket item excluded from ticket metrics
mapped item included only if parent order completed
mixed-event line items split correctly
unique line item upsert works
```

---

## Resource: `EventSales.Sales.CouponSnapshot`

### Purpose

Stores basic coupon/discount information from WooCommerce orders.

### Responsibilities

```text
basic coupon visibility
future coupon analytics
order discount traceability
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `order_id` | UUID | Yes | Order reference |
| `code` | string | Yes | Coupon code |
| `discount_amount` | decimal | No | Amount if available |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
belongs_to Order
```

### Actions

```text
upsert_for_order
read_for_order
```

### Policies

```text
admin can read
staff can read if needed
event roles no access by default unless exposed in aggregate later
```

### Indexes

```text
index coupon_snapshots.order_id
index coupon_snapshots.code
unique coupon_snapshots.order_id + code
```

### Required Tests

```text
coupon code stored
coupon uniqueness per order enforced
coupon snapshot does not affect MVP revenue unless explicitly used
```

---

# Ingestion Domain Dossiers

## Resource: `EventSales.Ingestion.WebhookEvent`

### Purpose

Stores valid WooCommerce webhook deliveries for processing, debugging, replay, and retention.

### Responsibilities

```text
raw delivery storage
processing status
idempotency support
replay support
failure visibility
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `source_system_id` | UUID | Yes | Source reference |
| `topic` | string | Yes | Example: `order.created` |
| `resource_id` | string/integer | No | External resource ID |
| `delivery_id` | string | No | Woo delivery ID if available |
| `payload_hash` | string | Yes | Hash of raw payload |
| `payload` | map/jsonb | Yes | Valid payload, retained 90 days |
| `status` | enum/string | Yes | `received`, `processing`, `processed`, `failed`, `ignored` |
| `received_at` | utc_datetime | Yes | Delivery time |
| `processed_at` | utc_datetime | No | Processing completion |
| `error_message` | string | No | Sanitized failure message |
| `attempt_count` | integer | Yes | Default 0 |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
belongs_to SourceSystem
```

### Actions

```text
record_received
mark_processing
mark_processed
mark_failed
mark_ignored
replay_failed
purge_raw_payload
```

### Policies

```text
admin can read and replay failed events
staff can read status if permitted
non-admin cannot see raw payload
event roles cannot access raw webhooks
```

### Indexes

```text
index webhook_events.source_system_id
index webhook_events.topic
index webhook_events.resource_id
index webhook_events.delivery_id
index webhook_events.status
index webhook_events.received_at
index webhook_events.payload_hash
unique webhook_events.source_system_id + delivery_id where delivery_id is not null
optional unique source_system_id + topic + resource_id + payload_hash
```

### Cache and TTL

```text
Raw payload retention: 90 days.
Failed webhook count can be hot cached.
TTL: 10s–5m.
Invalidate on status change.
```

### Edge Cases

```text
duplicate webhook delivery
same order.updated arrives with new payload
payload missing expected headers
unsupported topic
failed processing then replay
raw payload purged after retention period
```

### Required Tests

```text
valid webhook event stored
invalid signature does not create WebhookEvent
unique delivery ID prevents duplicate storage or duplicate processing
duplicate payload does not duplicate sales records
failed event can be replayed by admin
raw payload purge does not delete event metadata
```

---

## Resource: `EventSales.Ingestion.WebhookDeliveryFailure`

### Purpose

Stores minimal metadata about rejected webhook requests, especially invalid signatures.

### Responsibilities

```text
security visibility
invalid request monitoring
minimal logging without raw payload storage
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `reason` | string | Yes | `invalid_signature`, `bad_token`, etc. |
| `topic` | string | No | Header if available |
| `remote_ip_hash` | string | No | Hashed IP if captured |
| `user_agent_hash` | string | No | Hashed user-agent if captured |
| `received_at` | utc_datetime | Yes | Timestamp |

### Actions

```text
record_failure
read_recent_failures
```

### Policies

```text
admin only
```

### Indexes

```text
index webhook_delivery_failures.reason
index webhook_delivery_failures.received_at
```

### Important Note

```text
Do not store full invalid payloads.
Do not store secrets.
```

### Required Tests

```text
invalid signature records minimal failure
invalid request does not store full body
admin can view failure count
```

---

## Resource: `EventSales.Ingestion.SyncRun`

### Purpose

Tracks reconciliation and backfill runs.

### Responsibilities

```text
manual sync visibility
scheduled sync visibility
result counts
error visibility
sync status
rate limiting/audit connection
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `source_system_id` | UUID | Yes | Source reference |
| `event_id` | UUID | No | Required for event-scoped manual sync |
| `kind` | enum/string | Yes | `hourly`, `daily`, `manual`, `backfill` |
| `status` | enum/string | Yes | `queued`, `running`, `paused`, `completed`, `failed` |
| `date_from` | date/datetime | No | Range start |
| `date_to` | date/datetime | No | Range end |
| `started_at` | utc_datetime | No | Start time |
| `completed_at` | utc_datetime | No | Finish time |
| `orders_seen` | integer | Yes | Default 0 |
| `orders_changed` | integer | Yes | Default 0 |
| `orders_failed` | integer | Yes | Default 0 |
| `error_message` | string | No | Sanitized |
| `triggered_by_user_id` | UUID | No | Manual trigger actor |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
belongs_to SourceSystem
belongs_to Event optional
belongs_to triggered_by User optional
has_many SyncCursors
```

### Actions

```text
queue_manual_sync
start_run
pause_run
complete_run
fail_run
record_counts
```

### Policies

```text
admin can queue/read all syncs
staff may read sync status if permitted
event roles cannot queue syncs in MVP
```

### Indexes

```text
index sync_runs.source_system_id
index sync_runs.event_id
index sync_runs.kind
index sync_runs.status
index sync_runs.started_at
index sync_runs.triggered_by_user_id
```

### Performance Rules

```text
Manual sync must be event/date scoped.
No global full sync from UI in MVP.
REST concurrency max 2.
Pause on 429/500/timeouts/slow responses.
```

### Required Tests

```text
manual sync requires admin
manual sync requires event/date scope
sync status transitions are valid
sync pauses on simulated 429
sync records counts
sync writes audit log
```

---

## Resource: `EventSales.Ingestion.SyncCursor`

### Purpose

Stores progress for resumable reconciliation/backfill.

### Responsibilities

```text
pagination progress
date cursor progress
resume after failure
avoid full rescans
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `sync_run_id` | UUID | Yes | SyncRun reference |
| `cursor_type` | enum/string | Yes | `page`, `date`, `modified_after` |
| `cursor_value` | string/map | No | Serialized cursor |
| `page` | integer | No | Page number if used |
| `per_page` | integer | No | Page size |
| `last_seen_external_id` | string | No | Optional |
| `status` | enum/string | Yes | `active`, `completed`, `failed` |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
belongs_to SyncRun
```

### Actions

```text
create_cursor
advance_cursor
mark_completed
mark_failed
read_active_cursor
```

### Indexes

```text
index sync_cursors.sync_run_id
index sync_cursors.status
```

### Required Tests

```text
cursor advances after successful page
cursor resumes after failure
completed cursor is not reused accidentally
```

---

## Resource: `EventSales.Ingestion.CsvImportBatch`

### Purpose

Represents a CSV import attempt for a specific event/date use case.

### Responsibilities

```text
CSV dry-run tracking
CSV apply tracking
batch auditability
row-level result grouping
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `event_id` | UUID | Yes | Event scope |
| `uploaded_by_user_id` | UUID | Yes | Admin actor |
| `filename` | string | Yes | Original filename |
| `status` | enum/string | Yes | `uploaded`, `dry_run_valid`, `dry_run_invalid`, `applying`, `applied`, `failed` |
| `total_rows` | integer | Yes | Default 0 |
| `valid_rows` | integer | Yes | Default 0 |
| `invalid_rows` | integer | Yes | Default 0 |
| `applied_rows` | integer | Yes | Default 0 |
| `error_message` | string | No | Sanitized |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
belongs_to Event
belongs_to uploaded_by User
has_many CsvImportRows
```

### Actions

```text
create_batch
mark_dry_run_valid
mark_dry_run_invalid
queue_apply
mark_applied
mark_failed
```

### Policies

```text
admin can upload/apply
staff no apply by default
event roles cannot import in MVP
```

### Indexes

```text
index csv_import_batches.event_id
index csv_import_batches.uploaded_by_user_id
index csv_import_batches.status
index csv_import_batches.inserted_at
```

### Performance Rules

```text
Large CSV files must be streamed/chunked.
Apply must run through Oban.
Dry-run must not mutate sales records.
```

### Required Tests

```text
CSV import requires event scope
dry-run does not create sales orders
invalid rows are counted
apply can only run after valid dry-run
apply writes audit log
```

---

## Resource: `EventSales.Ingestion.CsvImportRow`

### Purpose

Stores row-level validation and apply results for CSV imports.

### Responsibilities

```text
row-level errors
row-level auditability
idempotent import apply
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `csv_import_batch_id` | UUID | Yes | Batch reference |
| `row_number` | integer | Yes | Original row number |
| `raw_data` | map/jsonb | Yes | Sanitized row data |
| `normalized_data` | map/jsonb | No | Parsed row data |
| `status` | enum/string | Yes | `valid`, `invalid`, `applied`, `failed`, `skipped` |
| `error_messages` | array/map | No | Validation errors |
| `external_order_number` | string | No | Duplicate detection |
| `external_line_item_key` | string | No | Duplicate detection |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
belongs_to CsvImportBatch
```

### Actions

```text
record_valid_row
record_invalid_row
mark_applied
mark_failed
```

### Indexes

```text
index csv_import_rows.csv_import_batch_id
index csv_import_rows.status
index csv_import_rows.external_order_number
unique csv_import_rows.csv_import_batch_id + row_number
```

### Required Tests

```text
row numbers are unique within batch
invalid row stores errors
valid row stores normalized data
apply is idempotent by batch/order/line item identity
```

---

# Analytics Domain Dossiers

## Resource: `EventSales.Analytics.EventAggregate`

### Purpose

Stores or represents event-level aggregate sales data.

### Responsibilities

```text
event dashboard totals
future client dashboard snapshots
cache-backed aggregate source
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `event_id` | UUID | Yes | Event reference |
| `tickets_sold_total` | integer | Yes | Completed mapped ticket quantity |
| `completed_revenue_total` | decimal | Yes | Completed ticket line total after discounts |
| `orders_completed_count` | integer | Yes | Completed order count relevant to event |
| `orders_pending_count` | integer | Yes | Visible status count |
| `orders_processing_count` | integer | Yes | Visible status count |
| `orders_failed_count` | integer | Yes | Visible status count |
| `orders_cancelled_count` | integer | Yes | Visible status count |
| `orders_refunded_count` | integer | Yes | Visible status count |
| `unmapped_items_count` | integer | Yes | Alert count |
| `calculated_at` | utc_datetime | Yes | Snapshot time |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
belongs_to Event
```

### Actions

```text
recalculate_for_event
read_for_dashboard
invalidate_for_event
```

### Policies

```text
admin can read all aggregates
staff can read internal aggregates
event_owner can read assigned event aggregate based on settings
event_staff can read assigned event ticket counts, no revenue by default
```

### Indexes

```text
unique event_aggregates.event_id
index event_aggregates.calculated_at
```

### Cache Rules

```text
Hot: ETS/Cachex active dashboard counters, TTL 10s–5m.
Warm: Redis event aggregate snapshot, TTL 30m–24h.
Invalidate on order upsert, mapping change, CSV apply, reconciliation apply.
```

### Required Tests

```text
completed mapped ticket items count
pending orders excluded from sold
unmapped items excluded from sold
non-ticket items excluded from sold
revenue uses completed ticket line total after discounts
event_staff cannot read revenue by default
```

---

## Resource: `EventSales.Analytics.TicketTypeAggregate`

### Purpose

Stores or represents ticket-type-level aggregate sales data.

### Responsibilities

```text
ticket type breakdown
ticket type capacity/sold/remaining view
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `event_id` | UUID | Yes | Event reference |
| `ticket_type_id` | UUID | Yes | Ticket type reference |
| `tickets_sold_total` | integer | Yes | Completed mapped quantity |
| `completed_revenue_total` | decimal | Yes | Completed line total |
| `calculated_at` | utc_datetime | Yes | Snapshot time |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
belongs_to Event
belongs_to TicketType
```

### Actions

```text
recalculate_for_ticket_type
read_for_event
```

### Indexes

```text
unique ticket_type_aggregates.event_id + ticket_type_id
index ticket_type_aggregates.event_id
index ticket_type_aggregates.ticket_type_id
```

### Cache Rules

```text
Warm Redis cache for event ticket type breakdown.
TTL: 30m–24h.
Invalidate on affected order item, mapping change, CSV apply.
```

### Required Tests

```text
ticket type totals count only mapped completed items
revenue respects completed-only rule
capacity nil renders safely
```

---

## Resource: `EventSales.Analytics.DailySalesAggregate`

### Purpose

Stores daily event sales snapshots for today/over-time charts.

### Responsibilities

```text
tickets sold today
daily revenue
time-series chart support
future materialized reporting
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `event_id` | UUID | Yes | Event reference |
| `date` | date | Yes | Reporting date in configured timezone |
| `tickets_sold` | integer | Yes | Completed mapped quantity |
| `completed_revenue` | decimal | Yes | Completed ticket line total |
| `orders_completed_count` | integer | Yes | Completed count |
| `calculated_at` | utc_datetime | Yes | Snapshot time |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
belongs_to Event
```

### Actions

```text
recalculate_for_event_date
read_range_for_event
read_today
```

### Indexes

```text
unique daily_sales_aggregates.event_id + date
index daily_sales_aggregates.date
index daily_sales_aggregates.event_id
```

### Cache Rules

```text
Today counters hot cached 10s–5m.
Chart ranges warm cached 30m–24h.
Invalidate affected event/date on order changes.
```

### Required Tests

```text
today metrics use configured timezone
same order does not count twice
status changes update daily aggregate
```

---

## Resource: `EventSales.Analytics.DashboardCacheState`

### Purpose

Tracks cache generation/invalidation metadata.

### Responsibilities

```text
cache observability
manual refresh support
stale cache detection
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `scope` | string | Yes | `global`, `event`, `ticket_type` |
| `scope_id` | UUID/string | No | Event/ticket type/etc. |
| `cache_key` | string | Yes | Concrete cache key |
| `version` | integer | Yes | Increment on invalidation |
| `last_invalidated_at` | utc_datetime | No | Timestamp |
| `last_rebuilt_at` | utc_datetime | No | Timestamp |
| `inserted_at` | utc_datetime | Yes | Timestamp |
| `updated_at` | utc_datetime | Yes | Timestamp |

### Actions

```text
record_invalidation
record_rebuild
read_state
```

### Indexes

```text
unique dashboard_cache_states.cache_key
index dashboard_cache_states.scope + scope_id
```

### Required Tests

```text
cache invalidation increments version
cache rebuild records timestamp
cache key uniqueness enforced
```

---

# Audit Domain Dossier

## Resource: `EventSales.Audit.AuditLog`

### Purpose

Records sensitive and operationally important actions.

### Responsibilities

```text
trace manual changes
trace access-sensitive operations
support debugging and accountability
avoid secret leakage
```

### Suggested Fields

| Field | Type | Required | Notes |
|---|---:|---:|---|
| `id` | UUID | Yes | Primary key |
| `user_id` | UUID | No | Actor if available |
| `event_id` | UUID | No | Event scope if relevant |
| `action` | string | Yes | Stable action name |
| `resource_type` | string | No | Example: `ProductMapping` |
| `resource_id` | UUID/string | No | Target ID |
| `metadata` | map/jsonb | No | Sanitized bounded metadata |
| `ip_hash` | string | No | Optional |
| `user_agent_hash` | string | No | Optional |
| `inserted_at` | utc_datetime | Yes | Timestamp |

### Relationships

```text
belongs_to User optional
belongs_to Event optional
```

### Actions

```text
record_audit_event
read_for_event
read_for_user
read_recent
```

### Policies

```text
admin can read audit logs
staff no audit access by default
event_owner/event_staff no audit access by default
```

### Indexes

```text
index audit_logs.user_id
index audit_logs.event_id
index audit_logs.action
index audit_logs.resource_type + resource_id
index audit_logs.inserted_at
```

### Must Audit

```text
mapping created/updated/deactivated
manual sync queued
webhook replay queued
CSV dry-run created
CSV apply queued/completed
export generated
raw payload purge
future client dashboard access
role/access grant changes
```

### Must Not Store

```text
WooCommerce API keys
webhook secrets
raw webhook payloads
full customer billing details
large CSV row bodies
passwords/tokens
```

### Required Tests

```text
audit log records mapping change
audit log records manual sync
audit log records webhook replay
audit metadata is sanitized
audit log does not include secrets
```

---

# External Boundary Modules

These are not Ash resources, but they are part of the domain architecture.

## `EventSales.Ingestion.Clients.WooCommerceClient`

### Purpose

Single boundary for WooCommerce REST API access.

### Rules

```text
Only workers or ingestion services may call this client.
LiveViews must never call this client.
REST concurrency max is 2.
Timeouts must be explicit.
Errors must return typed tuples/results.
```

### Required Tests

```text
authenticated request built correctly
pagination handled
401 handled
403 handled
404 handled
429 handled
500 handled
timeout handled
LiveView modules do not reference client
```

---

## `EventSales.Ingestion.Security.WebhookSignature`

### Purpose

Verify WooCommerce webhook authenticity.

### Rules

```text
Verify native WooCommerce webhook signature.
Verify secondary WEBHOOK_PATH_TOKEN.
Reject invalid signature before payload storage.
Never log secrets.
```

### Required Tests

```text
valid signature accepted
invalid signature rejected
missing signature rejected
wrong token rejected
signature verification handles whitespace/raw body correctly
```

---

## `EventSales.Catalog.MappingResolver`

### Purpose

Resolve WooCommerce product/variation IDs to EventSales event/ticket type.

### Rules

```text
variation-specific mapping wins over product-only mapping.
Inactive mappings are ignored.
Unmapped items remain stored but excluded from ticket metrics.
```

### Required Tests

```text
product-only mapping
variation mapping
variation wins
inactive ignored
unmapped result returned safely
```

---

## `EventSales.Analytics.DashboardCache`

### Purpose

Read/write dashboard aggregate data from hot/warm caches.

### Rules

```text
Prefer hot cache for active dashboard counters.
Use Redis for warm event aggregates.
Fall back to Postgres aggregate snapshots/queries only when safe.
Never call WooCommerce.
```

### Required Tests

```text
cache read hit
cache miss fallback
cache invalidation
cache key includes event scope
manual refresh does not call WooCommerce
```

---

# State Machines

## WebhookEvent Status

```text
received
→ processing
→ processed

received
→ processing
→ failed

failed
→ replay_queued
→ processing
→ processed

received
→ ignored
```

Invalid transitions:

```text
processed → received
processed → failed without explicit replay/process attempt
ignored → processed without explicit replay decision
```

---

## SyncRun Status

```text
queued
→ running
→ completed

queued
→ running
→ paused
→ running
→ completed

queued
→ running
→ failed
```

Pause triggers:

```text
WooCommerce 429
WooCommerce 500 bursts
timeouts
slow response pattern
manual admin pause later
```

---

## CsvImportBatch Status

```text
uploaded
→ dry_run_valid
→ applying
→ applied

uploaded
→ dry_run_invalid

dry_run_valid
→ applying
→ failed
```

Invalid transitions:

```text
dry_run_invalid → applying
uploaded → applying
applied → applying without explicit new batch
```

---

## Event Status

```text
draft
→ active
→ completed
→ archived
```

Rules:

```text
Archived events remain reportable.
Archived events may be hidden from default active dashboards.
Archiving does not delete sales records.
```

---

# Policy Matrix

| Capability | Admin | Staff | Event Owner | Event Staff |
|---|---:|---:|---:|---:|
| View global dashboard | Yes | Optional | No | No |
| View assigned event aggregate | Yes | Yes | Yes | Yes |
| View revenue | Yes | Optional | Configurable | No by default |
| View customer email | Yes | Masked/Optional | No by default | No |
| Manage mappings | Yes | Optional later | No | No |
| Trigger reconciliation | Yes | No by default | No | No |
| Replay webhook | Yes | No | No | No |
| Upload CSV | Yes | No by default | No | No |
| Apply CSV | Yes | No | No | No |
| Manage users/roles | Yes | No | No | No |
| View Oban Web | Yes | No | No | No |
| View raw webhook payload | Yes | No | No | No |

---

# Required Index Summary

## Accounts

```text
users.email unique
users.active
roles.name unique
user_roles.user_id
user_roles.role_id
user_roles.user_id + role_id unique
event_access_grants.user_id
event_access_grants.event_id
event_access_grants.expires_at
event_access_grants.revoked_at
```

## Catalog

```text
source_systems.kind + base_url unique
events.source_system_id
events.source_system_id + slug unique
events.starts_at
events.status
ticket_types.event_id
ticket_types.active
product_mappings.source_system_id
product_mappings.event_id
product_mappings.ticket_type_id
product_mappings.woo_product_id
product_mappings.woo_variation_id
product_mappings.active
active product_mappings.source_system_id + woo_product_id + woo_variation_id unique
```

## Sales

```text
orders.source_system_id + woo_order_id unique
orders.source_system_id
orders.status
orders.order_number
orders.completed_at
orders.created_at_source
orders.updated_at_source
order_items.order_id + woo_line_item_id unique
order_items.order_id
order_items.event_id
order_items.ticket_type_id
order_items.woo_product_id
order_items.woo_variation_id
order_items.mapping_status
order_items.item_kind
coupon_snapshots.order_id
coupon_snapshots.code
coupon_snapshots.order_id + code unique
```

## Ingestion

```text
webhook_events.source_system_id
webhook_events.topic
webhook_events.resource_id
webhook_events.delivery_id
webhook_events.status
webhook_events.received_at
webhook_events.payload_hash
webhook_events.source_system_id + delivery_id unique where delivery_id is not null
webhook_delivery_failures.reason
webhook_delivery_failures.received_at
sync_runs.source_system_id
sync_runs.event_id
sync_runs.kind
sync_runs.status
sync_runs.started_at
sync_cursors.sync_run_id
sync_cursors.status
csv_import_batches.event_id
csv_import_batches.uploaded_by_user_id
csv_import_batches.status
csv_import_rows.csv_import_batch_id
csv_import_rows.status
csv_import_rows.external_order_number
csv_import_rows.csv_import_batch_id + row_number unique
```

## Analytics

```text
event_aggregates.event_id unique
event_aggregates.calculated_at
ticket_type_aggregates.event_id + ticket_type_id unique
ticket_type_aggregates.event_id
ticket_type_aggregates.ticket_type_id
daily_sales_aggregates.event_id + date unique
daily_sales_aggregates.date
daily_sales_aggregates.event_id
dashboard_cache_states.cache_key unique
dashboard_cache_states.scope + scope_id
```

## Audit

```text
audit_logs.user_id
audit_logs.event_id
audit_logs.action
audit_logs.resource_type + resource_id
audit_logs.inserted_at
```

---

# Required Test Matrix

## Critical Unit Tests

```text
webhook signature validation
WooCommerce order parser
mapping resolver
metric rules
PII masking
cache key generation
CSV row parser
```

## Critical Ash Resource Tests

```text
user/role assignment
access grant expiry
source system uniqueness
event slug uniqueness
product mapping uniqueness
order upsert idempotency
order item upsert idempotency
webhook event uniqueness
sync run status transitions
CSV batch transitions
audit log sanitization
```

## Critical Worker Tests

```text
ProcessWebhookWorker idempotency
ReconcileOrdersWorker max concurrency behavior
ReconcileOrdersWorker pause behavior
ProcessCsvImportWorker idempotency
PurgeRawPayloadsWorker retention behavior
AggregateRecalculationWorker invalidation behavior
```

## Critical LiveView Tests

```text
admin dashboard access
unauthorized dashboard denial
manual refresh rate limiting
mappings screen admin-only
webhook replay confirmation
sync queue confirmation
CSV dry-run UI
PII masking in tables
```

## Critical End-to-End Tests

```text
completed webhook → order → item → mapping → aggregate → dashboard
pending webhook visible but not counted
duplicate webhook does not duplicate totals
mixed-event order splits by line item
unmapped item appears in alert queue and is excluded from metrics
REST reconciliation updates missing order
CSV dry-run then apply creates auditable rows
```

---

# Edge Case Register

## WooCommerce/Tickera

```text
order contains tickets for multiple events
order contains ticket and non-ticket products
variation ID missing or zero
product renamed after order
same product reused for future event
order status changes after completion
refund reflected only through order.updated
WooCommerce webhook delivered more than once
WooCommerce webhook payload incomplete
REST API slows during sales peak
```

## Data Integrity

```text
duplicate product mapping
unmapped product with revenue
capacity lower than sold count
order total differs from sum of line items
CSV duplicate order rows
CSV malformed money values
timezone mismatch for today metrics
```

## Access/Security

```text
event owner tries unassigned event URL
expired access grant still cached
staff sees customer email accidentally
raw webhook payload shown to non-admin
Oban Web exposed publicly
webhook token leaked in logs
```

## Performance

```text
large CSV loaded into memory
LiveView query loads all orders
manual sync without date/event scope
reconciliation hits WooCommerce with too much concurrency
aggregate recalculation runs inline
cache not invalidated after mapping change
```

---

# Implementation Notes for Coding Agent

## Use

```text
Ash 3.x resources and actions for domain logic.
Oban for async ingestion, reconciliation, imports, recalculation, and maintenance.
Phoenix PubSub for dashboard updates.
LiveView streams for recent orders and logs.
Redis for warm aggregates and cache snapshots.
ETS/Cachex/GenServer for hot dashboard counters.
Postgres as durable source of truth.
```

## Avoid

```text
Do not call WooCommerce from LiveView.
Do not process webhooks synchronously in the controller.
Do not let CSV imports bypass domain actions.
Do not calculate heavy aggregates on every dashboard mount.
Do not rely on route hiding for permissions.
Do not store secrets in DB resources for MVP.
Do not expose raw payloads to non-admin users.
```

## Success Looks Like

```text
The resource model makes incorrect reporting hard.
The policy layer makes data leakage hard.
The ingestion layer is replay-safe.
The dashboard is fast without touching WordPress.
The REST fallback protects WordPress performance.
The tests prove completed-only sales rules.
The system can safely evolve toward event-scoped client dashboards later.
```

---

# Recommended First Implementation Order

```text
1. Accounts.User / Role / UserRole / EventAccessGrant
2. Catalog.SourceSystem / Event / TicketType / ProductMapping
3. Sales.Order / OrderItem / CouponSnapshot
4. Ingestion.WebhookEvent / WebhookDeliveryFailure
5. WebhookSignature boundary module
6. ProcessWebhookWorker shell and idempotency tests
7. WooCommerce order parser
8. MappingResolver
9. Analytics metric rules
10. Admin dashboard aggregates
11. Reconciliation resources/workers
12. CSV import resources/workers
13. AuditLog
14. PII masking
15. EventDashboardSetting
```

This order builds the domain foundation before the dashboard gets pretty. That is intentional: for EventSales, correctness is the feature.
