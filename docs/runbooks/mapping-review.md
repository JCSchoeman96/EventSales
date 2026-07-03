# Mapping Review

## Purpose

Verify catalog mappings before live cutover so unmapped WooCommerce items do not corrupt ticket metrics.

## Pre-launch review

1. Open `/admin/events` and confirm each live event has an active source system.
2. Open `/internal/mappings` (internal admin tools) and review product mappings.
3. For each ticket SKU in WooCommerce:
   - Confirm mapped `ProductMapping` exists
   - Confirm event split rules are correct for mixed-event orders
4. Review Tickera product links for attendee reconciliation coverage.
5. Record unmapped SKUs and either map them or accept explicit exclusion before cutover.

## Acceptance criteria

- No unmapped ticket SKUs expected during the live sale window
- Mixed-event orders split by line item as designed
- Unmapped items are understood and excluded from MVP totals intentionally

## If mappings are missing during live sales

1. Pause reconciliation if it is amplifying REST load.
2. Add mappings through the approved admin mapping UI.
3. Run missing catalog recovery / reconciliation from `/admin/reconciliation`.
4. Do not edit durable sales truth manually in the database.

## Related docs

- [`reconciliation.md`](reconciliation.md)
- [`event-launch-checklist.md`](event-launch-checklist.md)
