# Fixture Verification

Slice 1.6 records whether the WooCommerce fixture catalogue is backed by
sanitized real payload evidence before Slice 7.0 parser work begins.

## Raw sample workflow

Use repo-root paths for all commands:

```bash
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"
```

Raw source samples may exist outside the repo:

```text
/tmp/real_payload_samples/woocommerce/
/tmp/real_payload_samples/tickera/
```

If staging is useful, copy them into ignored repo-root paths:

```bash
mkdir -p tmp/real_payload_samples/woocommerce tmp/real_payload_samples/tickera
cp -n /tmp/real_payload_samples/woocommerce/* tmp/real_payload_samples/woocommerce/ 2>/dev/null || true
cp -n /tmp/real_payload_samples/tickera/* tmp/real_payload_samples/tickera/ 2>/dev/null || true
git status --short -- tmp
```

Do not commit anything under `tmp/`. Commit only sanitized fixtures under
`test/fixtures/woocommerce/` and this verification record.

## Sanitization rules

Committed fixtures must not contain real names, real emails, phone numbers,
addresses, production URLs, cookies, authorization headers, webhook secrets,
API keys, customer IPs, or raw unsanitized payloads.

Preserve structural evidence that affects parser and mapping decisions:
WooCommerce IDs, status fields, date fields, totals, discounts, line item IDs,
product IDs, variation IDs, quantities, refund structures, product update
fields, variation update fields, Tickera metadata keys, and plugin-specific
metadata keys.

## Required case matrix

| Required case | Fixture | Status | Real payload source | Notes |
|---|---|---|---|---|
| completed order | `test/fixtures/woocommerce/order_completed.json` | `synthetic_placeholder` | Not provided in `/tmp/real_payload_samples/woocommerce/` | Synthetic shape retained from Slice 1.5 and expanded with explicit status. |
| pending order | `test/fixtures/woocommerce/order_pending.json` | `synthetic_placeholder` | Not provided in `/tmp/real_payload_samples/woocommerce/` | Synthetic shape retained from Slice 1.5 and expanded with explicit status. |
| refunded order | `test/fixtures/woocommerce/order_refunded.json` | `synthetic_placeholder` | Not provided in `/tmp/real_payload_samples/woocommerce/` | Synthetic refund structure added so tests can guard required fields. |
| mixed-event order | `test/fixtures/woocommerce/order_mixed_event.json` | `synthetic_placeholder` | Not provided in `/tmp/real_payload_samples/woocommerce/` | Synthetic two-line order models separate Tickera event metadata per line. |
| variation ticket order | `test/fixtures/woocommerce/order_variation_ticket.json` | `synthetic_placeholder` | Not provided in `/tmp/real_payload_samples/woocommerce/` | Synthetic line item includes non-zero `variation_id`. |
| non-ticket product order | `test/fixtures/woocommerce/order_with_non_ticket_item.json` | `synthetic_placeholder` | Not provided in `/tmp/real_payload_samples/woocommerce/` | Synthetic line item includes `event_sales_item_kind=non_ticket`. |
| product.updated | `test/fixtures/woocommerce/product_updated.json` | `synthetic_placeholder` | Not provided in `/tmp/real_payload_samples/woocommerce/` | Synthetic variable product update shape added. |
| variation updated | `test/fixtures/woocommerce/product_variation_updated.json` | `synthetic_placeholder` | Not provided in `/tmp/real_payload_samples/woocommerce/` | Synthetic variation update shape added. |

## Differences from Slice 1.5 synthetic fixtures

| Area | Difference recorded |
|---|---|
| Fixture status | All required fixtures now declare `_event_sales_fixture_status`. |
| Required case coverage | Refunded, mixed-event, variation-ticket, non-ticket, product update, and variation update fixtures now have structured synthetic placeholders instead of bare placeholder objects. |
| Sensitive data | Customer IP fields were removed from committed required fixtures. Phone and address values are redacted. Emails use the reserved `example.test` domain. |
| Tickera metadata | Synthetic metadata keys include `tickera_event_name` and `tickera_ticket_type` where relevant. These are not yet verified against real Tickera payloads. |
| Plugin metadata | Synthetic metadata includes `event_sales_product_kind` and `event_sales_item_kind` to document expected parser-relevant plugin metadata positions. These are not yet verified against real plugin payloads. |

## Fixture gaps

All required Slice 1.6 cases are currently synthetic placeholders because no
raw samples were available under `/tmp/real_payload_samples/woocommerce/` or
`/tmp/real_payload_samples/tickera/` during implementation.

Before parser work can proceed, each required case must be replaced or
confirmed with a sanitized real payload sample, and this document must record
the actual field differences discovered from those samples.

## Parser decision

STOP - Slice 7.0 parser work is blocked until real sanitized payload evidence exists
