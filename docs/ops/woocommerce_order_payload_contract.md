# WooCommerce Order Payload Contract

VS-26J prepares EventSales to attribute ticket order lines by Tickera event ID
before falling back to Woo product and variation mapping.

## Ticket Line Event Identity

For ticket line items, WooCommerce webhook payloads should include an
allowlisted line meta entry:

```json
{
  "line_items": [
    {
      "id": 900001,
      "product_id": 109132,
      "variation_id": 109167,
      "name": "Ticket",
      "quantity": 5,
      "subtotal": "500.00",
      "total": "500.00",
      "meta_data": [
        {
          "key": "tickera_event_id",
          "value": "109120"
        }
      ]
    }
  ]
}
```

`tickera_event_id` is the Tickera event post ID for the issued ticket line.
EventSales accepts either a positive integer or a numeric string. Missing or
blank values remain nil for legacy compatibility. Invalid or conflicting values
set `attribution_status_reason` to `invalid_source_tickera_event_id`.

EventSales does not infer event identity from event names, product names,
variation names, ticket labels, or display text.

## Rollout Caveat

VS-26J does not modify WordPress webhook enrichment. Event-first attribution
protects future orders only when Woo line item metadata includes
`tickera_event_id`. Until then, reviewed ProductMapping cutover is the immediate
control that stops stale ProductMapping fallback for future webhook attribution.

Do not include customer names, emails, phone numbers, IP addresses, payment
references, provider payloads, delivery tokens, ticket URLs, QR hashes, signed
URLs, headers, or raw webhook payloads in examples or logs.
