# Slice 14.5 — WooCommerce vs Tickera Attendee Reconciliation

## Purpose

Compare WooCommerce completed ticket sales against actual Tickera attendee registrations so admins can identify missing, extra, or inconsistent attendee records.

This slice also adds payment-method visibility to reconciliation reporting so the team can see whether specific payment gateways or payment methods correlate with registration failures.

## Implementation scope

```text
TickeraClient, TickeraAttendeeSnapshot, TickeraAttendeeSyncRun,
AttendeeReconciliationResult, AttendeeReconciliationSummary,
scoped Tickera attendee sync, Woo-vs-Tickera comparison,
payment method grouping, mismatch classification, admin report/export planning.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 14.5 — WooCommerce vs Tickera Attendee Reconciliation for EventSales. |
| Objective | Compare WooCommerce completed ticket sales against Tickera attendee registrations and expose mismatch reporting grouped by event, ticket type, order, attendee, and payment method. |
| Output | Tickera API client boundary, attendee snapshot storage, attendee sync run tracking, reconciliation result records, reconciliation summary query path, admin report, streamed export support, telemetry, audit logging, and strict tests. |
| Note | Do not implement this before Slice 14.0 exists. Do not call Tickera API from LiveView, components, or controllers. Tickera API access must be worker/service-module only. Store payment method fields on Order earlier through Slice 4.0/Slice 7.0, not here. Use scoped sync by event/date. Never full-scan during peak. Postgres is durable truth. Redis/Cachex may cache summary counts only. Required indexes: event ID, ticket type ID, source system ID, Woo order ID, Woo line item ID, Tickera attendee ID, Tickera ticket code, payment method, sync run ID, reconciliation status. TTL strategy: cache reconciliation summaries for 30s-5m depending on admin view freshness. Invalidation triggers: attendee sync completion, Woo order update, mapping change, manual reconciliation rerun. PubSub: broadcast scoped reconciliation refresh after durable write. Telemetry: Tickera API latency/errors, sync duration, mismatch count, payment-method mismatch count, circuit-breaker pauses. |

## Domain additions planned

```text
Ingestion
|> TickeraClient
|> TickeraAttendeeSyncRun
|> TickeraAttendeeSnapshot

Analytics
|> AttendeeReconciliationResult
|> AttendeeReconciliationSummary
```

## Data ownership

```text
WooCommerce Order
|> durable sales source
|> completed-only sales rules
|> stores payment_method and payment_method_title

Tickera Attendee Snapshot
|> durable imported attendee state
|> stores attendee/ticket identifiers from Tickera
|> stores event/ticket/order correlation fields where available

AttendeeReconciliationResult
|> durable comparison output
|> stores matched/mismatched status
|> stores mismatch reason
|> stores payment method copied from Woo order when available

AttendeeReconciliationSummary
|> cached/query-optimized admin summary
|> grouped by event, ticket type, mismatch status, and payment method
```

## Required payment method fields

Payment method must be captured earlier in the sales ingestion path, not only inside this reconciliation slice.

Add planning notes to Slice 4.0 and Slice 7.0 that Order should support:

```text
payment_method
payment_method_title
payment_gateway_transaction_id, optional
```

Rules:

```text
payment_method
|> stable gateway/source key from WooCommerce
|> example shape: "payfast", "cod", "stripe", "paypal", etc.
|> never use as display-only label

payment_method_title
|> human-readable WooCommerce payment method title
|> safe for admin reporting
|> may change over time

payment_gateway_transaction_id
|> optional
|> useful for future gateway-level troubleshooting
|> must be treated as sensitive operational metadata
```

## Matching strategy

Initial matching should prefer deterministic identifiers.

Preferred matching order:

1. source_system_id + woo_order_id + woo_line_item_id
2. source_system_id + woo_order_id + product_id + variation_id
3. event_id + ticket_type_id + attendee/ticket code when available
4. event_id + ticket_type_id + quantity/date fallback only as a warning-level heuristic

Do not silently match records using weak heuristics. Weak matches must be flagged for admin review.

## Mismatch statuses

```text
matched
|> Woo completed sale and Tickera attendee count agree

woo_only
|> Woo completed sale exists but matching Tickera attendee is missing

tickera_only
|> Tickera attendee exists but no matching completed Woo sale exists

quantity_mismatch
|> Woo line-item quantity and Tickera attendee count differ

status_mismatch
|> Woo order status does not support sold count, but Tickera attendee exists

mapping_mismatch
|> Product/ticket mapping changed or cannot resolve consistently

weak_match_review
|> match used fallback heuristic and requires admin review

ignored_non_ticket
|> Woo line item is not a ticket product and should not affect reconciliation

unknown
|> insufficient data to classify safely
```

## Strict tests

- Tickera sync requires event/date scope.
- Tickera API key and endpoint are loaded from env only.
- Worker fetches attendees through TickeraClient, not LiveView.
- LiveView reads stored reconciliation state only.
- Woo completed order with matching Tickera attendee is marked matched.
- Woo completed order without attendee is marked woo_only.
- Tickera attendee without completed Woo order is marked tickera_only.
- Quantity > 1 Woo line item can match multiple attendee rows.
- Quantity mismatch is classified correctly.
- Pending/cancelled/refunded Woo orders do not count as sold but remain visible.
- Payment method is included in reconciliation result.
- Mismatch summary can group by payment method.
- 401/403/404/429/500/timeout from Tickera API are handled as typed errors.
- 429/timeouts pause sync and record failure.
- Reconciliation is idempotent.
- Re-running the same sync does not duplicate attendee snapshots or reconciliation results.
- Export is streamed/paginated.
- Admin-only access enforced.
- Audit log written for manual sync/export.
- No secrets or real customer PII are written to fixtures/logs.

## Architecture guardrails

```text
External API boundary
|> TickeraClient may only be called by Oban workers or approved ingestion service modules
|> never from LiveView/controllers/components

Durable state
|> attendee snapshots and reconciliation results live in Postgres
|> Redis/Cachex can cache summaries only

Performance
|> no full sync during peak
|> sync must be scoped by event/date
|> stream/paginate large attendee reads
|> do not load all attendees/orders into memory
|> use indexed query paths for comparison

Cache
|> summary cache TTL 30s-5m
|> invalidate after Woo order update, Tickera sync completion, mapping change, or manual rerun

PubSub
|> broadcast scoped admin refresh after durable reconciliation write

Security
|> Tickera endpoint/key from env only
|> no hardcoded API credentials
|> no raw customer payload exposure to non-admins
|> transaction IDs treated as sensitive operational metadata
```

## Completion checklist

- [ ] Files/modules for this slice are created in the approved folder structure.
- [ ] Relevant Ash resources/actions/policies are implemented only where this slice owns them.
- [ ] Oban worker behavior is tested if this slice includes async work.
- [ ] LiveView/controller behavior is tested if this slice includes web UI or intake.
- [ ] Telemetry is emitted where the slice touches ingestion, REST, Oban, cache, or hot state.
- [ ] Cache invalidation is handled where durable data changes affect dashboard state.
- [ ] Export path streams/paginates instead of loading all rows.
- [ ] The global acceptance command passes.

## Stop condition

Stop and report if implementing this slice would require a direct Tickera API call from LiveView, a direct WooCommerce REST call from LiveView, an unscoped full attendee scan, an unindexed comparison query, a hardcoded secret, raw customer data in fixtures, Redis-as-truth shortcut, skipped policy, skipped test, or weak heuristic matching that is treated as certain.
