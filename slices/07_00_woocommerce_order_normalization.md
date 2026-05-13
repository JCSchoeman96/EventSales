# Slice 7.0 — WooCommerce Order Normalization

## Purpose

Parse realistic WooCommerce order payloads into internal order data.

## Implementation scope

```text
WooCommerceOrderParser, status mapper, line item parser, decimal parser, customer sanitizer, coupon parser, OrderUpserter.
```

## Copy-paste TOON prompt

| Field | Content |
|---|---|
| Task | Implement Slice 7.0 — WooCommerce Order Normalization for EventSales. |
| Objective | Parse realistic WooCommerce order payloads into internal order data. |
| Output | WooCommerceOrderParser, status mapper, line item parser, decimal parser, customer sanitizer, coupon parser, OrderUpserter. |
| Note | Parser tolerant, but never silently corrupts money/status. Payment method parsing must preserve the stable gateway key separately from the human-readable title. Documentation only; do not implement parser changes in this slice. Include strict tests listed below. Do not violate project-wide rules. |

## Strict tests

- Completed order parses
- Pending order parses
- Refunded/cancelled parses
- Quantity preserved
- Product/variation IDs preserved
- Line total after discount parsed
- Missing optional fields safe
- Payment method fields parse from Woo order payload when present
- Missing payment method fields are safe and do not break parsing
- Malformed required fields controlled error

## Architecture guardrails

Parser tolerant, but never silently corrupts money/status. Payment method parsing must preserve the stable gateway key separately from the human-readable title. Documentation only; do not implement parser changes in this slice.

## Completion checklist

- [ ] Files/modules for this slice are created in the approved folder structure.
- [ ] Relevant Ash resources/actions/policies are implemented only where this slice owns them.
- [ ] Oban worker behavior is tested if this slice includes async work.
- [ ] LiveView/controller behavior is tested if this slice includes web UI or intake.
- [ ] Telemetry is emitted where the slice touches ingestion, REST, Oban, cache, or hot state.
- [ ] Cache invalidation is handled where durable data changes affect dashboard state.
- [ ] The global acceptance command passes.

## Stop condition

Stop and report if implementing this slice would require a direct WooCommerce call from LiveView, an untested state transition, a hardcoded secret, a Redis-as-truth shortcut, or a skipped policy/test.
