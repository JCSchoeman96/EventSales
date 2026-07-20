# Tickera Catalog Change Trigger

The WordPress plugin emits asynchronous, signed, PII-free change notifications to
`POST /webhooks/catalog-change/:path_token`. EventSales stores immutable receipts,
coalesces exact event/product/variation targets, and queues existing Catalog Sync
dry-runs. It never generates full or `updated_since` scopes and never auto-Applies.

Both sender and receiver are disabled by default. Use a dedicated trigger secret;
never reuse the signed GET-feed or WooCommerce webhook credentials. Permanent
deletion remains an operator warning because the current feed has no tombstones.
