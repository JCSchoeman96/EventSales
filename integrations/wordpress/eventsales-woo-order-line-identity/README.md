# EventSales Woo Order Line Identity

Persists `tickera_event_id` on qualifying WooCommerce ticket order lines using
the same authoritative relationship as the Tickera catalog feed:

```text
parent product _tc_is_ticket = yes
parent product _event_name = <positive tc_events post ID>
```

No EventSales HTTP calls. WooCommerce webhooks remain the transport.

## Local install

Copy or symlink this directory into the local WordPress `wp-content/plugins/`
tree and activate **EventSales Woo Order Line Identity** in wp-admin.

## Tests

```bash
php -l integrations/wordpress/eventsales-woo-order-line-identity/*.php
php integrations/wordpress/eventsales-woo-order-line-identity/tests/order-line-identity-test.php
```
