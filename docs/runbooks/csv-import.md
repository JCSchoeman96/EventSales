# CSV Import Runbook

Slice 16.0 supports dry-run validation only. Apply remains unavailable until Slice 17.0.

Required columns:

```text
woo_order_id
order_number
woo_line_item_id
woo_product_id
quantity
line_subtotal
line_total
order_raw_total
status
currency
created_at_source
updated_at_source
```

Optional columns:

```text
woo_variation_id
name
line_discount_total
completed_at
customer_name
customer_email
order_raw_discount_total
order_raw_tax_total
payment_method
payment_method_title
payment_gateway_transaction_id
```

Process:

1. Open `/admin/imports`.
2. Select the event scope outside the CSV.
3. Upload a `.csv` file and run dry-run.
4. Review row errors and duplicate previews.
5. Fix missing product mappings in the mappings UI, then rerun dry-run.

Do not use `raw_total`, `raw_discount_total`, `raw_tax_total`, or `discount_total` as CSV headers. Use the explicit `order_*` and `line_*` names above.
