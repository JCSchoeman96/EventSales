# Slice 1.6 — Real WooCommerce Payload Fixture Verification

| Field | Content |
|---|---|
| Task | Capture or obtain sanitized real WooCommerce/Tickera payload examples and compare them against the project fixture catalogue before parser implementation. |
| Objective | Prevent parser and mapping logic from being built around guessed payload shapes. |
| Output | Updated `test/fixtures/woocommerce/*`, `docs/architecture/fixture-verification.md`, and a documented fixture gap list. |
| Note | Do not include real customer data, secrets, production URLs, cookies, authorization headers, or raw personally identifying data. This slice must happen before final parser work in Slice 7.0. |

## Required Payload Cases

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

## Strict Checks

- Compare real sanitized payloads with existing fixtures.
- Document missing fields, renamed fields, nested metadata differences, Tickera-specific fields, and plugin-specific structures.
- Confirm order line item IDs, product IDs, variation IDs, totals, discounts, statuses, and timestamps are represented.
- Confirm no real PII/secrets/live URLs remain in fixtures.
- Do not implement final parser assumptions until gaps are resolved or explicitly documented.

## Stop Condition

Stop if real WooCommerce/Tickera payloads materially differ from fixtures. Update the fixture catalogue and parser plan first.
